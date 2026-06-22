# 路線 (C)：Provider rate-limit 透傳 — 攔 429、撈 `*ratelimit*` header、提示限流

**Date:** 2026-06-18
**Status:** 規劃中（尚未實作）。教授 2026-06-17 拍板：在 `2026-06-16-max-usage-end-conversation.md` 的三條軸中，做 **(C) provider rate-limit quota**。2026-06-18 與團隊再確認**落地定位**：**以 (A) 為主、(C) 補充、(B) 不做** —— (A)（`session_limit_reached`）留作主要的「開新對話」訊號；C1（429 攔截）當**獨立的正確性修復先做**；C2（軟警告）**量完欄位再補**；(B)（對話累計額度）**有意識地不做**（見 §2）。本文是 (C) 的逐檔實作 + 測試 + 前端規劃。
**父文件：** [`plans/2026-06-16-max-usage-end-conversation.md`](2026-06-16-max-usage-end-conversation.md)（三軸盤點，§5 路線 C、§7「若同時做 C」）
**(A) 先例（同一個 `warnings` 機制、可照抄的串接模式）：** [`plans/2026-06-16-session-token-limit-signal.md`](2026-06-16-session-token-limit-signal.md)

**相關程式：**
- LLM client（header/usage 解析點）：[openai_client.rb](../app/infrastructure/llm/openai_client.rb)、[anthropic_client.rb](../app/infrastructure/llm/anthropic_client.rb)
- 回應值物件：[llm_response.rb](../app/infrastructure/llm/llm_response.rb)；錯誤型別：[llm_error.rb](../app/infrastructure/llm/llm_error.rb)
- debug log：[llm_debug_log.rb](../app/infrastructure/llm/llm_debug_log.rb)
- service：[run_tutor_chat.rb](../app/application/services/tutor_chat/run_tutor_chat.rb)
- controller 失敗碼對照：[api.rb](../app/application/controllers/api.rb)；HTTP 碼：[http_response.rb](../app/presentation/representers/http_response.rb)；狀態 enum：[result.rb](../app/presentation/responses/result.rb)
- 通道判定（GitHub/OpenAI/Anthropic）：[token_budget.rb](../app/domain/values/token_budget.rb)

---

> **一句話：** provider 真的會在 response header 回限流資訊（`x-ratelimit-*` / `anthropic-ratelimit-*` / `Retry-After`），但我們現在**整包丟掉**，而且把 429 跟其他 upstream 錯誤混成同一個 `LlmError::Upstream`（一律 502）。本案做三件事：(C1) **把 429 從一般 upstream 錯誤拆出來**，回正確的 **HTTP 429 + `Retry-After`**；(C2) **通用透傳**所有 `*ratelimit*` / `retry-after` header 進 `LlmResponse#rate_limit`，剩餘額度逼近門檻時在 `warnings` 加 `provider_rate_limited`（沿用 (A) 既有機制）；(C3) **debug log 連 header 一起記**，先用它量出 GitHub Models 真實欄位名再收斂 (C2) 的門檻邏輯。**不寫死任一家的 schema**——provider 給什麼就撈什麼。

> **語意警語（務必寫進 doc／前端）：** (C) 量的是**帳號層級、會週期重置的 rate 窗口剩餘**，不是「這段對話太長」。它回答的是「你的金鑰這分鐘/今天快被限流了」，**不等於** DEV 原句「這段對話夠長了 → 收尾開新的」（那是 (B)，不做）。所以 `provider_rate_limited` 與既有 `session_limit_reached` 是**兩個正交訊號**，前端訊息要分開講。
>
> **部署事實（2026-06-18 與 DEV 確認）：每位學生各自一把 key。** 所以 (C) 的訊號**乾淨、可直接對該生提示**「你的金鑰快用完了」，不必加「可能是別人打爆的」這種 hedge。（仍是帳號層級：同一學生跨裝置/session 用同把 key 會合計 —— 但那也仍是「該生自己的」額度。若日後改成共用 key，才需把文案改回中性的「服務忙碌」。）

---

## 1. 現況缺口（父文件 §3 的精確定位）

| 缺口 | 現在的行為 | 依據 |
|---|---|---|
| 429 沒被獨立辨識 | 所有非 2xx（含 429）都 `raise LlmError::Upstream` → service `:upstream_error` → **HTTP 502** | [openai_client.rb:81](../app/infrastructure/llm/openai_client.rb#L81)、[anthropic_client.rb:70](../app/infrastructure/llm/anthropic_client.rb#L70) |
| rate-limit header 整包丟掉 | `parse` 只讀 `response.body`，從不讀 `response.each_header` | 兩個 client 的 `parse` |
| `LlmResponse` 無 rate-limit 欄 | 只有 `content / usage / tool_calls` | [llm_response.rb:5](../app/infrastructure/llm/llm_response.rb#L5) |
| debug log 不記 header | `response(trace, status:, body:)` 只寫 body | [llm_debug_log.rb:68](../app/infrastructure/llm/llm_debug_log.rb#L68) |

**重點認知（決定設計）：**
- **GitHub Models 走的是 OpenAI 相容 API**：學生通道用 `X-LLM-Endpoint` 覆寫到 `models.github.ai` / `models.inference.ai.azure.com`（見 [token_budget.rb:14-19](../app/domain/values/token_budget.rb#L14-L19)），但**仍由 `OpenAiClient` 送出**。所以**只要改 `OpenAiClient` 的 header 解析，就同時覆蓋了學生最常撞限流的 GitHub 通道**。`AnthropicClient` 則覆蓋老師/native key。
- **各家 header 命名不一**（父文件 §4.2）：OpenAI `x-ratelimit-remaining-requests`、Anthropic `anthropic-ratelimit-requests-remaining`（前綴與字序都不同）、GitHub 確切欄位**未知、需量**。→ **絕不寫死欄位**，改用「名稱含 `ratelimit` 或等於 `retry-after` 就整包撈」的通用透傳。

---

## 2. 整體定位與落地順序（四軸決策，2026-06-18 與團隊確認）

本案不孤立看 (C)，而是放回父文件三軸的全局裡定位。**核心決策：以 (A) 為主、(C) 補充、(B) 不做。** 對應的落地順序：

| 軸 / 子項 | 角色 | 狀態 / 動作 |
|---|---|---|
| **(A) 單次脈絡上限**（`session_limit_reached`） | **主要的「開新對話」訊號** | **已上線、保留不動。** 學生面「這段對話太大 → 開新的」一律由它負責 |
| **(C1) 429 攔截** | **獨立的正確性修復** | **① 最先做。** 與「MAX_USAGE 功能」無關 —— 現在 429 被誤報成 502，前端可能盲目重打、更快撞限流。即使不要軟訊號，這條也該修 |
| **(C3) header 量測** | 餵 C2 的前置量測 | **① 與 C1 同批。** debug log 記 header，打一發真實 GitHub Models 確認欄位 |
| **(C2) `provider_rate_limited` 軟警告** | **真正的「補充」訊號** | **② C3 量完欄位再做。** 提前預警「金鑰快被限流」，門檻依賴 C3 實測校準 |
| **(B) 對話累計額度** | — | **有意識地不做。** 理由見 §2.1 |

### 2.1 為什麼以 (A) 為主、(B) 不做

- **(A) 已經是 DEV 原句最務實的落地**：不改合約/DB，用真實 `usage.input_tokens` 比通道視窗，逼近就提示開新對話。學生面「收尾、開新的」這件事由 (A) 全包，(C) 不取代它。
- **(B) 對實際部署對象是「自己發明的配額」**：GitHub Models 免費層**沒有「每段對話累計 token」這種限制**（父文件 §4.3）—— 它擋的是單次 token 上限（(A) + 硬 8K/4K 已蓋）、每分/每天請求數（(C) 蓋）、並發數。所以 (B) 要付 migration + session_id + 改合約的代價，卻只為一個 provider 根本不強制的合成配額。**除非產品端日後明確要求「對每段對話的花費設上限」（計費/公平性），否則不做**；屆時再走父文件路線 B1，與本案正交、可並存。

### 2.2 為什麼 C1 先於 C2、且把 C1 當「獨立修復」而非功能的一部分

- **C1 是 standalone 正確性修復，不綁 MAX_USAGE 框架**：今天任何 429 都 `raise LlmError::Upstream` → 502，前端拿到 502 很可能當一般 upstream 錯誤盲目重打，反而**加速**撞限流。把 429 拆出來、回 `429 + Retry-After` 讓前端**退避**，這個價值與軟訊號完全無關、應最先落地（父文件 §8.5 亦持此立場）。它可以單獨開一個 PR、單獨驗收。
- **C2 依賴 C3 的實測欄位**：各家 `*ratelimit*` 命名不一、GitHub 確切欄位未知。「剩餘額度低於門檻」的判斷得先知道欄位長相與單位（reset 是 unix ts 還是秒數？remaining 是 requests 還是 tokens？）。與其猜，不如靠 C3 量一次（父文件 §4.2「可以直接量」）再把門檻定死。
- **透傳 plumbing 在 C1 就一起做掉**（把 header 撈進 `LlmResponse#rate_limit`）—— 這零風險、立即可上；C2 只是多一個讀 `rate_limit` 的判斷式，改動極小。

> **兩批交付：** ① **C1 + 透傳 plumbing + C3**（正確性修復，可獨立上）→ ② **C2 軟警告 + doc + 前端文案**（量完欄位後補）。下面 §4 已照這兩批切分。

---

## 3. 通用透傳：header matcher（不綁任一家 schema）

新增一個小模組，集中「哪些 header 算 rate-limit 資訊」的判斷，兩個 client 共用、好測：

`app/infrastructure/llm/rate_limit_headers.rb`（新檔）
```ruby
# frozen_string_literal: true

module Tyla
  module Infrastructure
    # Generic, schema-agnostic extractor for provider rate-limit headers.
    # Providers disagree on names (OpenAI `x-ratelimit-remaining-requests`,
    # Anthropic `anthropic-ratelimit-requests-remaining`, GitHub Models TBD),
    # so we DO NOT hard-code a field set: we keep every header whose (downcased)
    # name contains "ratelimit", plus `retry-after`. "Provider gives what it
    # gives" — no assumptions about prefix, ordering, or reset-time units.
    module RateLimitHeaders
      module_function

      # response: a Net::HTTPResponse. Returns { downcased_name => value(String) }.
      def extract(response)
        headers = {}
        response.each_header do |name, value|
          key = name.to_s.downcase
          headers[key] = value if key.include?('ratelimit') || key == 'retry-after'
        end
        headers
      end
    end
  end
end
```

`spec_helper` 用 glob 載入 `app/infrastructure/llm/**/*.rb`（見 [spec/spec_helper.rb](../spec/spec_helper.rb)），`require_app` 亦同 — 新檔**自動被載入**，兩個 client 無需顯式 `require_relative`（與現有 `LlmDebugLog`/`LlmError`/`LlmResponse` 的用法一致）。

### 3.1 標註「哪一種上限」(which limit) — 維度分類（DEV 補充需求）

DEV 想（if possible）在訊號裡附上「撞到的是**哪一種** limit」。先把**標得出來的維度**講清楚，再講**哪些根本標不出來** —— 標不出來的就誠實回 `unknown`，**絕不臆造**。

**關鍵事實：最大的「which limit」其實系統已經分好了。** 因為 (A) 與 (C) 用的是**兩個不同的 warning token**，scope 天然分流：

| `limit_scope`（上限所在層）| 軸 | token / 通道 | 來源 | 標得出來？ |
|---|---|---|---|---|
| `per_request`（單次脈絡視窗）| (A) | `session_limit_reached`（warnings）| 我們自己算 `input_tokens` vs 通道視窗 | ✅ 已上線 |
| `provider_account`（帳號 rate 窗口）| (C) | `provider_rate_limited`（軟, warnings）／`rate_limited`（硬, 429）| provider `*ratelimit*` header / 429 | ✅ 本案 |
| `conversation`（整段對話累計）| (B) | —（**永不發**）| provider **無對話概念、不回報**；我們也未存（未做 B）| ❌ 標不出來 |

> 學生面看到 `session_limit_reached` 就是「**這一次**的輸入太長（per-request）」；看到 `provider_rate_limited`/429 就是「你的**金鑰帳號**這個 rate 窗口快滿（provider account）」。**兩個 token 已把最大的兩種 scope 分開** —— 這就是「which limit」的第一層答案，不必額外做什麼。

**(C) 內可再標的子維度（best-effort，純從 header 名推）：**

| `limit_dimension` | 從哪個 header 推 | 例 |
|---|---|---|
| `requests` | 名稱含 `...remaining-requests` / `requests-remaining...` | OpenAI `x-ratelimit-remaining-requests`、Anthropic `anthropic-ratelimit-requests-remaining` |
| `tokens` | 名稱含 `...remaining-tokens` / `tokens-remaining...` | `x-ratelimit-remaining-tokens` |
| `unknown` | 撈不到可辨識的 remaining 欄位（或 429 只給 `Retry-After`、無 body 線索）| — |

（`limit_window`：`per_minute` / `per_day` / `unknown` —— C3 實測確認 GitHub Models 的 `x-ratelimit-renewalperiod-*` = `60`（秒），可從此欄推出 `per_minute`；若欄位缺失則 fallback `unknown`。第一版可先不發 window，只發 scope + dimension。）

**承載方式（依硬/軟分流）：**
- **硬 429** → 塞進**已經結構化**的 `errors`：`{ retry_after, limit_scope: 'provider_account', limit_dimension: 'requests'|'tokens'|'unknown' }`。**零新合約欄位**（`errors` 本就是任意結構 payload，representer 已 `property :errors`）。
- **軟 `provider_rate_limited`** → `warnings` 是**扁平字串陣列**；不破壞該合約的前提下，**第一版維持單一通用 token**（前端泛用在地化、membership 判斷最簡單、舊 client 不受影響）。**若 DEV 要在軟路徑也分軸**，再改成維度後綴 token（`provider_rate_limited_requests` / `_tokens`；前端用 `provider_rate_limited` 前綴比對、讀後綴拿細節，仍向後相容）。這是 §10 的一個小決策。

> **鐵則：永不把 (C) 標成 `conversation`。** provider 回的是帳號 rate 窗口、不是「這段對話多長」；說成 conversation-level 就是父文件 §2 警告的那個誤讀。`conversation` scope 只有做了 (B) 才存在，本案不做、故永不發 —— 表中列它只是把 taxonomy 講完整、並明示我們**不**冒充它。

---

## 4. 逐檔改動（後端）

### 4.1 C1 + 透傳 plumbing（先做）

| 檔案 | 改動 |
|---|---|
| `app/infrastructure/llm/rate_limit_headers.rb` | **新檔**（§3） |
| `app/infrastructure/llm/llm_error.rb` | 新增 `class RateLimited < Base`，帶 `retry_after` / `rate_limit` 屬性 |
| `app/infrastructure/llm/llm_response.rb` | `Data.define` 加 `:rate_limit`，預設 `{}`（向後相容：既有 `LlmResponse.new(content:, usage:)` 不受影響） |
| `app/infrastructure/llm/openai_client.rb` | `parse`：先 `RateLimitHeaders.extract`；**429 → `raise LlmError::RateLimited`**（帶 retry-after + rate_limit）；成功時把 `rate_limit:` 塞進 `LlmResponse`。`post_json` 的 debug log call 多帶 `headers:`（C3） |
| `app/infrastructure/llm/anthropic_client.rb` | 同上（Anthropic 的 `retry-after` 小寫一樣由通用 matcher 撈到） |
| `app/infrastructure/llm/llm_debug_log.rb` | `response(trace, status:, body:, headers: {})` 多記 header 區塊（C3） |
| `app/application/services/tutor_chat/run_tutor_chat.rb` | `request_tutor_reply` 多一條 `rescue LlmError::RateLimited => e → Failure[:rate_limited, ..., { retry_after: e.retry_after }]` |
| `app/application/controllers/api.rb` | `SERVICE_FAILURE_STATUS` 加 `rate_limited: :too_many_requests`；（選配）失敗為 `:rate_limited` 時把 `Retry-After` 設進 response header |
| `app/presentation/responses/result.rb` | `FAILURE` set 加 `:too_many_requests` |
| `app/presentation/representers/http_response.rb` | `HTTP_CODE` 加 `too_many_requests: 429` |

#### `llm_error.rb`
```ruby
module Tyla
  module Infrastructure
    module LlmError
      class Base < StandardError; end
      class Timeout < Base; end
      class Upstream < Base; end
      class UnsupportedProvider < Base; end

      # 429 from the provider. Distinct from Upstream so the API can answer
      # 429 (+ Retry-After) instead of a generic 502, and the frontend can
      # back off rather than hammer-retry.
      class RateLimited < Base
        attr_reader :retry_after, :rate_limit

        def initialize(message = nil, retry_after: nil, rate_limit: {})
          super(message)
          @retry_after = retry_after
          @rate_limit  = rate_limit
        end
      end
    end
  end
end
```

#### `llm_response.rb`
```ruby
module Tyla
  module Infrastructure
    # `rate_limit` carries the provider's pass-through rate-limit headers
    # (schema-agnostic bag; see RateLimitHeaders). Empty {} when none / unknown.
    LlmResponse = Data.define(:content, :usage, :tool_calls, :rate_limit) do
      def initialize(content:, usage:, tool_calls: [], rate_limit: {})
        super
      end
    end
  end
end
```

#### `openai_client.rb` — `parse`（Anthropic 對稱照改）
```ruby
def parse(response)
  rate_limit = RateLimitHeaders.extract(response)

  if response.is_a?(Net::HTTPTooManyRequests)            # 429
    raise LlmError::RateLimited.new(
      "openai rate limited (429)",
      retry_after: response['retry-after'],
      rate_limit:  rate_limit
    )
  end
  raise LlmError::Upstream, "openai returned #{response.code}" unless response.is_a?(Net::HTTPSuccess)

  data    = JSON.parse(response.body)
  # ... 既有 content / usage / tool_calls 解析不變 ...
  LlmResponse.new(content: content, usage: usage, tool_calls: tool_calls, rate_limit: rate_limit)
rescue JSON::ParserError => e
  raise LlmError::Upstream, "openai returned malformed JSON: #{e.message}"
end
```
> `Net::HTTPTooManyRequests` 是 429 的標準類別，沿用既有 `is_a?(Net::HTTPSuccess)` 的風格、不必比對字串 code。`retry-after` 小寫由 `response['retry-after']` 取得（Net::HTTP header 查找大小寫不敏感）。

#### `run_tutor_chat.rb` — `request_tutor_reply` rescue（三者皆 `< Base`、互不繼承，順序無礙）
```ruby
rescue Infrastructure::LlmError::Timeout
  Failure[:upstream_timeout, 'LLM request timed out']
rescue Infrastructure::LlmError::RateLimited => e
  Failure[:rate_limited, 'LLM provider rate limited',
          { retry_after:     e.retry_after,
            limit_scope:     'provider_account',                              # §3.1 — 429 一定是帳號層級
            limit_dimension: tripped_rate_limit_dimension(e.rate_limit) || 'unknown' }]  # best-effort
rescue Infrastructure::LlmError::Upstream => e
  Failure[:upstream_error, e.message]
```
> `limit_dimension` 由 §4.2 的 `tripped_rate_limit_dimension` 從 `e.rate_limit`（429 通常 `remaining=0` → 可辨軸）推得；只給 `Retry-After`、無 remaining header 時退回 `'unknown'`。`limit_scope` 對 429 恆為 `provider_account`（永不是 `conversation`，§3.1 鐵則）。此 helper 在 C1 批先落地（硬路徑用得到），C2 批再被軟路徑共用。

#### `api.rb` — 失敗碼對照
```ruby
SERVICE_FAILURE_STATUS = {
  # ... 既有 ...
  upstream_error:   :upstream_error,
  upstream_timeout: :upstream_timeout,
  rate_limited:     :too_many_requests,   # NEW (C1) — 429
  db_error:         :internal_error
}.freeze
```
> （選配）若要回 `Retry-After` HTTP header：在 `outcome.failure?` 分支中，當 `tag == :rate_limited` 且 `errors[:retry_after]` 存在時 `response['Retry-After'] = errors[:retry_after].to_s`，再 `r.halt`。第一版可省略，`errors.retry_after` 已在 JSON body 內。

### 4.2 C2 軟訊號（C3 量完欄位後收斂）

| 檔案 | 改動 |
|---|---|
| `app/application/services/tutor_chat/run_tutor_chat.rb` | 新增 `PROVIDER_RATE_LIMIT_WARNING = 'provider_rate_limited'`、`PROVIDER_REMAINING_FLOOR = ENV.fetch('PROVIDER_REMAINING_FLOOR', '2').to_i`、`provider_rate_limited?(rate_limit)`；`ok_outcome` 算旗標、穿進 `warnings_for`；`warnings_for` 多一行 |

**關鍵：不必動 mini-loop 的 4-tuple。** 與 (A) 不同 —— (A) 要量的「終端輪 input_tokens」會被 `finish_loop` 的 `reply.with(usage: Σ)` 蓋掉，所以得在改寫前先算旗標、沿 tuple 串回。**`rate_limit` 不會被 `.with(usage:)` 蓋掉**（Data `#with` 只改指定欄位），所以 `ok_outcome` 拿到的 `reply.rate_limit` 就是**終端輪**的 header bag，**直接在 `ok_outcome` 讀 `reply.rate_limit` 即可**，無需擴張 tuple、無需碰 `finish_loop`/`tutor_mini_loop`/`call`。

```ruby
PROVIDER_RATE_LIMIT_WARNING = 'provider_rate_limited'
# 任一「remaining」軸（requests 或 tokens）跌到這個地板就提示。預設 2，可用 ENV 調。
PROVIDER_REMAINING_FLOOR = ENV.fetch('PROVIDER_REMAINING_FLOOR', '2').to_i

# best-effort：回傳「觸發的維度」('requests'/'tokens'/'unknown')，未觸發回 nil。
# rate_limit 是 schema-agnostic 的 header bag —— 只看名稱含 "remaining" 的整數欄位，
# 取跌破地板者中最小的那一個，由它的名稱推軸（§3.1）。reset/retry-after 不含
# "remaining" → 自然排除。安全預設：bag 空（unknown 通道/沒給 header）→ nil（不觸發）。
# 同一個 helper 供「軟路徑（warning 是否觸發）」與「硬 429（errors.limit_dimension）」共用。
def tripped_rate_limit_dimension(rate_limit)
  return nil if rate_limit.nil? || rate_limit.empty?

  low = rate_limit.filter_map do |name, value|
    n = name.to_s.downcase
    next unless n.include?('remaining')

    v = Integer(value, exception: false)   # 非整數值（百分比/字串）→ nil → 丟掉
    [n, v] if v && v <= PROVIDER_REMAINING_FLOOR
  end.min_by { |_n, v| v }
  return nil unless low

  name = low.first
  return 'requests' if name.include?('request')
  return 'tokens'   if name.include?('token')

  'unknown'
end
```

`ok_outcome` 內（軟路徑第一版只用「有沒有觸發」，不把 dimension 塞進扁平的 warnings —— §3.1）：
```ruby
provider_limited = !tripped_rate_limit_dimension(reply.rate_limit).nil?
warnings = warnings_for(assembled,
                        reference_loaded:       reference_loaded,
                        edit_file_redirected:   edit_file_redirected,
                        redundant_load_dropped: redundant_load_dropped,
                        approaching_limit:      approaching_limit,
                        provider_rate_limited:  provider_limited)
```

`warnings_for` 末尾新增一行（沿用既有明列風格）：
```ruby
warnings << PROVIDER_RATE_LIMIT_WARNING if provider_rate_limited
```

> **門檻 matcher 的不確定性收口在 C3：** 上面用「名稱含 `remaining` 取最小值 ≤ 地板」是不綁 schema 的安全起手式。等 C3 量到 GitHub 真實欄位，再決定要不要只看 requests 軸、或分軸設不同地板。matcher 與軸推導集中在這**一個** helper、好改。
>
> **若 §10 決定軟路徑也要分軸**：把上面那行換成 `dim = tripped_rate_limit_dimension(reply.rate_limit)`、`provider_limited = !dim.nil?`，並讓 `warnings_for` 推 `dim == 'unknown' ? base : "#{base}_#{dim}"`（base = `provider_rate_limited`）。前端用前綴比對，仍向後相容。

---

## 5. C3：debug log 記 header（先量再猜）

`llm_debug_log.rb` 的 `response` 加一個選填 `headers:`，避免破壞現有呼叫/測試：
```ruby
def response(trace, status:, body:, headers: {})
  return unless trace

  header_block = headers.empty? ? '' : "headers=#{headers.inspect}\n#{divider}\n"
  write <<~ENTRY
    [#{timestamp}] ##{trace.id} #{trace.provider} ← RESPONSE status=#{status} (#{elapsed_ms(trace)}ms)
    #{divider}
    #{header_block}#{pretty(body)}
  ENTRY
  nil
rescue StandardError
  nil
end
```
兩個 client 的 `post_json` 把 header 帶進來（**所有** response 都記，含 429/500）：
```ruby
LlmDebugLog.response(trace, status: response.code, body: response.body, headers: response.to_hash)
```
> `Net::HTTPResponse#to_hash` 回 `{ "name" => ["value", ...] }`。`KEY_PATTERN` scrub 仍會跑（header 一般無 `sk-…`，但防禦性保留）。

**量測步驟（C3 的產出，餵給 C2）：**
1. `LLM_DEBUG_LOG=1`，用真實 GitHub Models 的 `X-LLM-Key` + `X-LLM-Endpoint` 打一發 `/api/v1/tutor_chats`。
2. 看 `log/llm_debug.log` 的 `headers=...`，記下 GitHub 實際回的 `*ratelimit*` 欄位名與值的單位（reset 是 unix ts 還是秒數？remaining 是 requests 還是 tokens？）。
3. 據此確認/微調 `provider_rate_limited?` 的 matcher 與 `PROVIDER_REMAINING_FLOOR`。

---

## 6. 前端（MindyCLI）改動 — **另開 track，不屬本批交付**

> **範圍（2026-06-18 決定）：後端先行、前端另開 track。** 本節是給前端 track 的**規格**，不是本批（C1+透傳+C3、C2+doc）的交付物。比照 doc 既有 **backend-first** 慣例：先上後端（含 429 → 429+`Retry-After`、`provider_rate_limited` warning），**舊 CLI 不受影響**（未知 warning 字串忽略、429 落既有錯誤分支仍可運作，只是還沒退避）；前端文案/退避隨後在自己的 track 跟上。

兩個新訊號、兩種處理，沿用既有 `warnings` 在地化 render 的分工：

| 訊號 | 來源 | 前端行為 |
|---|---|---|
| **429 `rate_limited`（硬）** | HTTP 狀態碼 429 + body `{ status: "rate_limited", message, errors: { retry_after } }`（若有設 `Retry-After` header 則優先讀 header） | 顯示「你的 LLM 金鑰暫時被限流，請等約 N 秒再試」；**退避重試**（依 `retry_after`/`Retry-After`，無值則用預設退避），**不可**立即重打；不要把它當一般 502 錯誤吞掉 |
| **`provider_rate_limited`（軟）** | 成功回應 `warnings[]` 內含此字串（turn 仍成功） | 比照既有 `session_limit_reached` 等 warning，render 一行柔性提示「你的金鑰配額快用完了（這分鐘/今天）」；**這是帳號層級、不是這段對話太長**，措辭要與 `session_limit_reached`（→ 建議開新對話）區分 |

- 既有 CLI 已有 `warnings` 的 render 管線（`session_limit_reached`、`history_truncated`…），新增一個字串值即可，**舊 CLI 不受影響**（未知 warning 字串忽略即可）。
- 429 是新的 HTTP 路徑：CLI 目前對 429 可能落進泛用錯誤分支。需新增分支辨識 429／`status: "rate_limited"`，做退避而非報錯。

> **⚠️ (A) 與 (C) 的使用者動作「相反」 —— 這是前端最不能搞錯的地方。** 因為 (A) 是主要的「開新對話」訊號、(C) 是補充的「限流」訊號，兩者可能幾乎同時觸發，但**正確動作恰好相反**：
>
> | 訊號 | 語意 | 正確動作 |
> |---|---|---|
> | **(A) `session_limit_reached`** | 這段對話對視窗太大了 | **開新對話** —— 新對話清空 history，視窗就空出來了 |
> | **(C) `provider_rate_limited` / 429** | 你的金鑰這個 rate 窗口快被限流 | **等一下、退避** —— 開新對話**沒用**，rate 窗口是帳號層級，新對話照樣吃同一把 key 的額度，立刻重打反而**更快撞牆** |
>
> 若把兩者混成一句「你達到上限了，請開新對話」，對 (C) 就是**給錯建議**（叫學生去做一件無效甚至有害的事）。所以：**文案、引導動作、甚至 handler 出口都必須分流**，不可共用同一條「碰到上限」路徑。(A) 引導「開新 session」；(C) 引導「稍候 N 秒重試」（N 取自 `Retry-After`/`errors.retry_after`，硬 429）或純資訊提示（軟 `provider_rate_limited`，turn 仍成功、不需任何動作，只是預警）。

- **「哪一種上限」可在文案裡點明（§3.1）：** token 本身已分 scope（`session_limit_reached`=per-request／`provider_rate_limited`·`rate_limited`=provider account）。硬 429 另有 `errors.limit_dimension`（`requests`/`tokens`/`unknown`）可讓文案更精準 ——「你的金鑰**每分鐘請求數**快用完」(requests) vs「**token 配額**快用完」(tokens)；為 `unknown` 時退回泛用句即可。**永遠不要對學生說這是「對話太長」之類的 conversation-level 限制**（那是 (A) 的事，且 (C) 根本不是 conversation scope）。軟路徑是否也帶 dimension，待 §10 決定；未帶時前端就只渲染泛用 `provider_rate_limited` 句。

---

## 7. doc 改動（`doc/api_tutor_chats.md`）

1. **Error responses 表**新增一列：
   | `429` | `rate_limited` | The tutor LLM provider returned 429 (account rate-limit window exhausted). Body `errors.retry_after` (and, if present, the `Retry-After` header) carries the suggested back-off seconds; `errors.limit_scope` is always `"provider_account"` and `errors.limit_dimension` is best-effort `"requests"`/`"tokens"`/`"unknown"`. **Distinct from `502 upstream_error`** — back off and retry, do not treat as a hard failure. |
2. **`warnings` 段**新增 `provider_rate_limited` 值的說明：provider 回報的剩餘額度逼近上限（帳號層級 rate 窗口、會週期重置；本部署每位學生各自的 key → 為該生自己的額度）；turn 仍成功；**明確區分**它與 `session_limit_reached`（後者是單次脈絡逼近、語意是「開新對話」，前者是「金鑰被限流、稍候」）。
3. **新增「Which limit (scope/dimension)」小段（§3.1）：** 用一張表把 `session_limit_reached`→`per_request`、`provider_rate_limited`/`rate_limited`→`provider_account`、(B)`conversation`→**永不發**講清楚；說明 429 的 `errors.limit_scope`/`limit_dimension` 欄位語意與 best-effort 性質；明寫**後端永不把 (C) 標成 conversation-level**。
4. **Security/Notes** 補一句：rate-limit header 為通用透傳（不綁特定 provider schema），`X-LLM-Key` 不入 header log。

---

## 8. 測試部署（test plan）

> 全程 `RACK_ENV=test`；client spec 用 `webmock`（既有模式，見 [openai_client_spec.rb](../spec/infrastructure/llm/openai_client_spec.rb)），可在 `to_return(headers: {...})` 直接塞 rate-limit header。

### 8.1 新增 — `spec/infrastructure/llm/rate_limit_headers_spec.rb`
- `extract` 只留名稱含 `ratelimit` 的 header + `retry-after`，其餘（`content-type` 等）丟掉。
- header 名大小寫正規化為小寫（OpenAI `x-ratelimit-...` 與假造大寫都收斂）。
- Anthropic 前綴 `anthropic-ratelimit-requests-remaining` 也被撈到（證明不綁 OpenAI 前綴）。
- 沒有任何 rate-limit header → 回 `{}`。

### 8.2 `spec/infrastructure/llm/openai_client_spec.rb`（擴充）
- **429 → `LlmError::RateLimited`**：`to_return(status: 429, headers: { 'Retry-After' => '30', 'x-ratelimit-remaining-requests' => '0' })`；斷言 raise `RateLimited`、`err.retry_after == '30'`、`err.rate_limit` 含該欄位。
- **成功帶 rate header**：200 + `x-ratelimit-remaining-requests: 5` → `resp.rate_limit['x-ratelimit-remaining-requests'] == '5'`。
- **成功無 rate header**：既有成功案斷言 `resp.rate_limit == {}`（向後相容）。
- 既有「500 → `Upstream`」案不變（證明只有 429 被拆出來，其他非 2xx 仍是 `Upstream`）。

### 8.3 `spec/infrastructure/llm/anthropic_client_spec.rb`（擴充）
- 429 → `RateLimited`（帶 `retry-after`）。
- 成功帶 `anthropic-ratelimit-requests-remaining` → 進 `resp.rate_limit`。
- 既有「503 → `Upstream`」案不變。

### 8.4 `spec/infrastructure/llm/llm_debug_log_spec.rb`（擴充）
- `response(trace, status:, body:, headers: { 'x-ratelimit-remaining-requests' => ['0'] })` → log 內出現 `headers=` 與該欄位。
- 不帶 `headers:`（預設 `{}`）→ 既有行為不變（不寫 header 區塊）；既有測試全綠。

### 8.5 `spec/application/services/run_tutor_chat_spec.rb`（擴充）
> 既有 `tutor_llm` / `scripted_llm` helper 建的 `LlmResponse` 不帶 `rate_limit`（預設 `{}`）→ 既有測試不受影響。新增一個 helper 讓回應帶 `rate_limit`，或直接在測試裡 `LlmResponse.new(..., rate_limit: {...})`。

- **軟訊號觸發**：終端 reply `rate_limit: { 'x-ratelimit-remaining-requests' => '0' }` → `dto.warnings` 含 `provider_rate_limited`。
- **未觸發（剩餘充足）**：`{ 'x-ratelimit-remaining-requests' => '500' }` → 不含。
- **未觸發（unknown 通道沒給 header）**：`rate_limit: {}` → 不含（安全預設）。
- **與 `session_limit_reached` 正交**：終端 reply 同時 `input_tokens: 7_500`（觸發 session）＋ `remaining-requests: 0`（觸發 provider）→ 兩個 warning 並存。
- **mini-loop 量終端輪**：round 1 剩餘充足、round 2 `remaining: 0` → 觸發（證明讀的是 `reply.rate_limit` = 終端輪，且 `.with(usage: Σ)` 沒蓋掉它）。
- **429 硬失敗**：client `send_prompt` raise `LlmError::RateLimited` → `outcome.failure.first == :rate_limited`，`outcome.failure[2][:retry_after]` 帶值，`[:limit_scope] == 'provider_account'`。
- **429 帶 dimension**：raise `RateLimited(rate_limit: { 'x-ratelimit-remaining-requests' => '0' })` → `failure[2][:limit_dimension] == 'requests'`；只給 `Retry-After`、無 remaining header → `'unknown'`。
- **mini-loop round-2 429**：round 1 觸發 load_reference、round 2 raise `RateLimited` → `:rate_limited`（比照既有 round-2 timeout 案）。
- **`tripped_rate_limit_dimension` 單元**（可在 service spec 內直接測該方法或經 dto 驗證）：`remaining-requests:0`→`'requests'`；`remaining-tokens:0`→`'tokens'`；兩軸都低→取較小者之軸；含 `remaining` 但名稱無 request/token 字樣→`'unknown'`；剩餘充足或空 bag→`nil`。

### 8.6 `spec/presentation/responses/result_spec.rb`（擴充）
- `Response::Result.new(status: :too_many_requests)` 不 raise（已加進 `FAILURE` set）。

### 8.7 `spec/presentation/representers/http_response_representer_spec.rb`（擴充）
- `status: :too_many_requests` → `http_status_code == 429`。

### 8.8 整合（若有 controller/route 層 spec）
- service 回 `Failure[:rate_limited, ...]` → HTTP 429、body `status: "rate_limited"`、`errors.retry_after` 有值。（若無既有 route spec，至少由 8.5 + 8.6 + 8.7 覆蓋對照表正確性。）

### 8.9 驗收
- `bundle exec rake test` 全綠（既有 + 新增）。
- C3 量測：開 `LLM_DEBUG_LOG` 對真實 GitHub Models 打一發，log 確認 `headers=` 區塊出現且含 `*ratelimit*` 欄位（手動、非自動化斷言）。
- RuboCop 註記：`warnings_for` 在 (A) 後已 cyclomatic 8/7，(C2) 再 +1 條 guard 會再升一階；沿用既有「明列 `<< token if cond`」風格、不為閃 cop 改 idiom（與 [run_tutor_chat.rb](../app/application/services/tutor_chat/run_tutor_chat.rb) 既有註記一致）。`rake style`/`quality` 為獨立任務、`main` 本就帶數個 Metrics offense。

---

## 9. 邊界與取捨

- **(C) ≠ (B)。** 再次強調：429/`provider_rate_limited` 是帳號 rate 窗口、會週期重置；不是「這段對話太長」。本部署每位學生各自的 key，故訊號是該生自己的額度（乾淨、可直接提示）。(B) 已決定不做；本案與 (B) 正交、若日後翻案可並存。
- **GitHub 欄位未知 → 先量再定門檻。** C2 的 matcher 第一版用「名稱含 `remaining` 取 min ≤ 地板」這種不綁 schema 的寫法先上，靠 C3 校準。透傳 plumbing 在 C1 就做掉，C2 風險僅在門檻數值。
- **429 是退避訊號不是錯誤。** 拆出 `:rate_limited`/429 的價值就在讓前端**退避**而非當 502 報錯或盲目重打（盲重打會更快撞限流）。`Retry-After` 直接給前端退避秒數。
- **向後相容三處保證**：`LlmResponse#rate_limit` 預設 `{}`、`LlmDebugLog.response` 的 `headers:` 預設 `{}`、`provider_rate_limited?` 對空 bag 回 false——既有 client/service/representer 測試與舊 CLI 都不受影響。
- **`token`-remaining 與 `requests`-remaining 混在一起**：第一版用 min 跨軸（任一軸快耗盡就提示）。若 C3 發現 token 軸數字噪音大（例如總是回很大值），再改成只看 requests 軸——改一個方法即可。

---

## 10. 決策

### 已拍板（2026-06-18 與 DEV）
- **scope：(A) 為主 + (C) 補充、(B) 不做。** GitHub 免費層無「對話累計」配額，(A)+(C) 已蓋學生實際會撞的所有上限。(B) 唯一翻案觸發點＝產品端要求「對每段對話花費設上限」。
- **key 部署：每位學生各自一把。** → (C) 訊號乾淨、屬該生自己的額度，前端可直接提示，不必加「可能別人打爆」hedge。
- **前端範圍：後端先行、前端另開 track。** 本批只交付後端 + doc（§6 是給前端 track 的規格）。

### 仍待拍板（皆不阻擋第一批；我已給預設）

1. **429 要回硬失敗（HTTP 429）還是只當 warning？** 建議**硬失敗 429**（provider 已實際拒絕這次呼叫，turn 無法完成），另用 `provider_rate_limited` warning 處理「成功但快滿」。
2. **`PROVIDER_REMAINING_FLOOR` 數值？** 先給 ENV 可覆寫、預設 2（requests 軸）。C3 量到 GitHub 實際配額（每分/每天）後再定。
3. **要不要同時回 `Retry-After` HTTP header？**（§4.1 選配）建議要——前端退避最直接；body 的 `errors.retry_after` 作為 fallback。
4. **C2 的剩餘判斷只看 requests 軸，還是 requests＋tokens 都看？** 建議先「任一軸 min ≤ 地板」都提示，C3 量完再縮。
6. **「which limit」detail 要做到多細（§3.1）？** 建議：**硬 429 一定帶** `errors.limit_scope` + best-effort `limit_dimension`（`errors` 已結構化、零成本）；**軟 `provider_rate_limited` 第一版維持單一通用 token**（扁平字串通道、最簡單、舊 client 不受影響），要分軸再升級成 `provider_rate_limited_requests`/`_tokens` 後綴 token。`limit_window`（per_minute/per_day）待 C3 量到才談。**任何情況都不發 `conversation` scope。**
5. **429 要回硬失敗還是 warning？** 預設硬失敗 429（true 429 根本沒有可用回覆、無法回成功 turn —— 其實沒有第二選項）。`provider_rate_limited` warning 處理的是「成功但快滿」，兩者不衝突。
（(B) 做不做、key 部署、前端範圍 → 見上方「已拍板」。）

---

## 11. 落地檢查清單

**第一批 — C1 + 透傳 plumbing + C3（獨立的正確性修復，可單獨開 PR / 驗收，不依賴 MAX_USAGE 功能）**
- [x] `rate_limit_headers.rb` 新檔 + spec
- [x] `LlmError::RateLimited`（帶 retry_after/rate_limit）
- [x] `LlmResponse` 加 `rate_limit`（預設 `{}`）
- [x] 兩個 client `parse`：撈 header、429 → `RateLimited`、成功帶 `rate_limit`
- [x] 兩個 client `post_json`：debug log 帶 `headers:`
- [x] `LlmDebugLog.response` 加 `headers:`（預設 `{}`）
- [x] service `request_tutor_reply` rescue `RateLimited → :rate_limited`，`errors` 帶 `retry_after` + `limit_scope: 'provider_account'` + best-effort `limit_dimension`（§3.1）
- [x] service `tripped_rate_limit_dimension` helper（硬路徑先用；C2 軟路徑共用）
- [x] `api.rb` / `result.rb` / `http_response.rb` 串 429（`too_many_requests`）
- [x] client/debug-log/result/http_response spec
- [x] 開 `LLM_DEBUG_LOG` 對真實 GitHub Models 量一次 header　← **已完成 2026-06-22**
  - Script: `scripts/measure_github_models_headers.rb`
  - **實測結果（`gpt-4o-mini` via `models.inference.ai.azure.com`，2026-06-22）：**
    ```
    x-ratelimit-limit-requests:      20000
    x-ratelimit-remaining-requests:  19999
    x-ratelimit-reset-requests:      0        ← 秒數（非 Unix ts），0 = 當下窗口未耗盡
    x-ratelimit-limit-tokens:        2000000
    x-ratelimit-remaining-tokens:    1999976
    x-ratelimit-reset-tokens:        0
    x-ratelimit-renewalperiod-requests: 60    ← 每 60 秒重置 → limit_window = per_minute
    x-ratelimit-renewalperiod-tokens:   60
    x-ratelimit-key:                 gpt-4o-mini   ← model-scoped key
    x-ratelimit-abusepenalty-active: False
    ```
  - **結論：**
    - `tripped_rate_limit_dimension` 的 `remaining-requests` / `remaining-tokens` pattern **直接命中**，不需調整。
    - `x-ratelimit-renewalperiod-*` = `60` → `limit_window` 可從此欄推出 `per_minute`（C2 optional）。
    - `reset-*` 值是「距重置的秒數」而非 Unix timestamp。
    - 正常回應**不帶 `retry-after`**；429 時才會出現。
    - ⚠️ 回應含 `deprecation`/`sunset`/`link` header（舊 Azure endpoint 將於 2025-10-17 sunset）；endpoint 已改換 `https://github.models.ai/inference`。本測試仍走舊端點但結果有效。

**第二批 — C2 軟警告（C3 量完欄位後再做）　← 已完成 2026-06-22**
- [x] service 常數（`PROVIDER_RATE_LIMIT_WARNING`/`PROVIDER_REMAINING_FLOOR`）+ `ok_outcome`/`warnings_for` 串接（軟路徑共用第一批的 `tripped_rate_limit_dimension`；`ok_outcome` 直讀終端輪 `reply.rate_limit`，`finish_loop` 的 `.with(usage:)` 不蓋 rate_limit）
- [x] service spec（觸發/未觸發/空 bag/與 session 正交/mini-loop 終端輪）
- [x] `doc/api_tutor_chats.md`（429 列 + `errors.limit_scope`/`limit_dimension` + `provider_rate_limited` warning + 「Which limit」taxonomy 小段 + 語意警語）

**前端 track（另開，不屬本批 — §6 為其規格）**
- [ ] 429 退避分支（讀 `Retry-After`/`errors.retry_after`）
- [ ] `provider_rate_limited` warning render，文案與 `session_limit_reached` **分流**（一個「開新對話」、一個「稍候」）
- [ ] （選配）讀 `errors.limit_dimension` 讓 429 文案分 requests/tokens
