# 路線 (D)：Provider 413 透傳 — 把 `tokens_limit_reached` 從 502 拆出來，回正確的 413（per-request 硬失敗）

**Date:** 2026-06-24
**Status:** 後端 + doc 批次**已實作（2026-06-24）**，`bundle exec rake test` 全綠（393 runs, 0 failures）；真實 GitHub Models 413 量測已完成（2026-06-24），parser 不需修改，**後端全數完成**；待辦僅剩前端 track（另開）。延續 (C) 的「把 provider 真實狀態碼從一般 upstream 錯誤拆出來」模式：(C) 拆 **429**（帳號 rate 窗口），本案 (D) 拆 **413**（單次請求 input 超過 provider 的 per-request token 上限）。動機來自 2026-06-24 對「GitHub Models 會不會自己回報對話太長」的查證 —— 結論是**不會預警，只會在超量時硬回 413 `tokens_limit_reached`**，而我們現在把它跟其他非 2xx 一起吞成 502、把 provider 的 `Request body too large for <model>. Max size: N tokens.` 訊息丟掉。

**父文件 / 三軸盤點：** [`plans/2026-06-16-max-usage-end-conversation.md`](2026-06-16-max-usage-end-conversation.md)
**同軸先例 (A)（per-request **軟**警告，可照抄的 `warnings` 機制）：** [`plans/2026-06-16-session-token-limit-signal.md`](2026-06-16-session-token-limit-signal.md)
**可照抄的拆分模式 (C)（把 429 從 `Upstream` 拆出來、串到 HTTP 狀態碼）：** [`plans/2026-06-18-provider-rate-limit-passthrough.md`](2026-06-18-provider-rate-limit-passthrough.md)

**相關程式：**
- LLM client（status 判定點）：[openai_client.rb](../app/infrastructure/llm/openai_client.rb)（`parse`/`raise_if_rate_limited`）、[anthropic_client.rb](../app/infrastructure/llm/anthropic_client.rb)
- 錯誤型別：[llm_error.rb](../app/infrastructure/llm/llm_error.rb)（已有 `RateLimited`，照它加 `InputTooLarge`）
- service：[run_tutor_chat.rb](../app/application/services/tutor_chat/run_tutor_chat.rb)（`request_tutor_reply` rescue、`rate_limited_failure` 旁邊加 `input_too_large_failure`）
- controller 失敗碼對照：[api.rb](../app/application/controllers/api.rb#L8-L19)（`SERVICE_FAILURE_STATUS`）
- **已存在、不必改**：[result.rb](../app/presentation/responses/result.rb#L9-L13)（`payload_too_large` 已在 `FAILURE`）、[http_response.rb](../app/presentation/representers/http_response.rb#L33)（`payload_too_large: 413` 已有）
- 通道/上限：[token_budget.rb](../app/domain/values/token_budget.rb#L14-L35)（GitHub 通道 input 硬寫 8K —— 與本案的「per-model 4K/16K 偏差」直接相關）

---

> **一句話：** GitHub Models 在單次 input 超過 per-request token 上限時，會硬回 **HTTP 413**，body `code: "tokens_limit_reached"`、message `Request body too large for <model> model. Max size: N tokens.`。我們現在 `parse` 把所有非 2xx（含 413）一律 `raise LlmError::Upstream` → service `:upstream_error` → **HTTP 502**，並把 provider 那句含 **N（每模型不同）** 的訊息丟掉。本案照 (C) 拆 429 的同一手法，把 **413 拆成 `LlmError::InputTooLarge`**，service 回 **`:input_too_large` → HTTP 413**，`errors` 帶 `limit_scope: 'per_request'` / `limit_dimension: 'tokens'` / `max_input_tokens: N`。**413 wire path（`payload_too_large` → 413）早已存在**（既有 pre-flight `context_overflow` 在用），所以本案改動比 (C) 更小：**不動 `result.rb` / `http_response.rb`**。

> **語意警語（務必寫進 doc／前端）：** 413 `input_too_large` 是 **per-request 硬失敗** —— 這次呼叫**沒有任何可用回覆**，turn 失敗。它的 scope 與 (A) `session_limit_reached` **同一軸（per_request）**，引導動作也相同：**開新對話**（清空 history → body 變小 → 不再撞 413）。**這與 (C) 的 429 恰好相反** —— 429 是帳號 rate 窗口、引導「稍候退避」、開新對話**沒用**。前端**不可**把 413 與 429 併進同一條「碰到上限」路徑（見 (C) §6 的相反動作表）。

---

## 1. 現況缺口

| 缺口 | 現在的行為 | 依據 |
|---|---|---|
| 413 沒被獨立辨識 | 所有非 2xx（含 413）`raise LlmError::Upstream` → `:upstream_error` → **HTTP 502** | [openai_client.rb:96](../app/infrastructure/llm/openai_client.rb#L96) |
| provider 的 413 訊息整句丟掉 | `parse` 只把 `response.code` 串進 `"openai returned 413"`，`response.body` 的 `Max size: N tokens` 只進 debug log、不上 API | 同上 |
| 前端拿到 502 可能盲目重打 | 502 常被當「上游暫時掛了」重試 —— 但 413 重打**必然再 413**（input 沒變小），白白多打 | 前端慣例 |

**關鍵認知（決定設計）：**
- **413 wire path 已經完整存在。** 既有 pre-flight 估算 `assemble_prompt` 在 `assembled.overflow?` 時回 `Failure[:context_overflow, ...]`（[run_tutor_chat.rb:195](../app/application/services/tutor_chat/run_tutor_chat.rb#L195)），`api.rb` 已把 `context_overflow → :payload_too_large`、`http_response.rb` 已把 `payload_too_large → 413`。**所以 413 的 result/representer 層完全不用動**，本案只補「provider 真的回 413」這條來源。
- **provider 413 是 pre-flight 估算的安全網，不是重複。** 三層防線：
  1. **pre-flight 估算**（`assembled.overflow?` vs 通道 `input_token_limit`）→ `:context_overflow` → 413：送出前先擋掉大部分超量。
  2. **0.9 軟警告**（`session_limit_reached`）→ warning（turn 仍成功）：逼近時提醒開新對話。
  3. **本案：provider 真實 413**（`tokens_limit_reached`）→ `:input_too_large` → 413：**接住第 1 層漏掉的**。
- **第 1 層為什麼會漏（本案存在的理由）：**
  - **估算 ≠ provider tokenizer。** 我們的 `BudgetAwarePromptAssembler` 是估算；provider 用真 tokenizer，且把**整包 body**（system prompt + tool definitions 的 OpenAI function 包裝 + JSON 結構）一起算。估算過了、真值超了 → provider 413。
  - **per-model 上限不一，我們硬寫 8K。** [token_budget.rb:16](../app/domain/values/token_budget.rb#L16) 對所有 `github_models_free` 一律 `input: 8_000`，但實際上 `gpt-4.1` = 16K、`gpt-4o/4o-mini` = 8K、`o1-mini/gpt-5-mini/deepseek-r1/o3-mini` = **4K**。學生若用 4K 上限的模型，我們的 8K pre-flight **太寬** → 送出 → provider 413（這正是 token_budget 註解自承「false-wide is a hard 400/413」卻無法靠單一常數覆蓋的情況）。

---

## 2. 定位：填滿 §3.1 taxonomy 裡「per_request / 硬」那格

(C) §3.1 用 scope × 軟硬 把訊號分類。(A) 給了 per_request 的**軟**格，(C) 給了 provider_account 的兩格，**per_request 的「硬」格一直空著**（只有 pre-flight 的 `context_overflow` 半填）。本案把它補滿、且註明 provenance：

| `limit_scope` | 軟（warning，turn 成功） | 硬（failure，無回覆） |
|---|---|---|
| `per_request`（單次脈絡視窗）| `session_limit_reached`（A，我們自己數 `input_tokens`）| **`context_overflow`（pre-flight 估算）+ 本案 `input_too_large`（provider 真值）** ← 本案 |
| `provider_account`（帳號 rate 窗口）| `provider_rate_limited`（C2）| `rate_limited` / 429（C1）|
| `conversation`（整段累計）| —（永不發）| —（永不發）|

- **per_request 的軟→硬是同一軸的連續體：** 逼近 → (A) 軟警告；真的撞牆 → 413 硬失敗。兩者**引導動作一致（開新對話）**，所以前端可共用同一條「per-request 上限」UX，只差「警告 vs 錯誤」呈現。
- **與 429 嚴格分流：** 429 是另一軸、引導相反（退避）。**鐵則：413 永遠標 `per_request`，429 永遠標 `provider_account`，兩者永不互換、永不標 `conversation`。**

---

## 3. provider 413 body 解析（防禦式 + 先量再定）

GitHub Models（Azure AI Inference 相容）413 的 body 觀測到的 message 原文：
```
Request body too large for gpt-4.1 model. Max size: 16000 tokens.
```
envelope 多半是 OpenAI/Azure 風格 `{"error":{"code":"tokens_limit_reached","message":"...","details":"..."}}`，但**確切結構需實測確認**（照 (C) 的 C3 紀律，先用 `LLM_DEBUG_LOG` 量一發真實 413 再收斂 parser）。所以解析**防禦式**：

- **取訊息：** `JSON.parse(body).dig('error','message')`，失敗（非 JSON / 無此鍵）就退回 `response.body` 原字串。
- **取 N：** 對訊息跑 `/max size:\s*(\d+)\s*tokens/i`，命中就 `max_input_tokens = N.to_i`，沒命中 → `nil`（前端退回不帶數字的泛用文案）。
- **scope/dimension 不用猜：** 413 必為 `limit_scope: 'per_request'`、`limit_dimension: 'tokens'`（它就是 token-size 上限）。不像 429 要 best-effort 推軸。
- **provider_message 只進 log，不上 API：** 原句含內部 model 名（`gpt-4.1`），不外洩給學生；`errors` 只帶結構化 `max_input_tokens`。

> **量測步驟（產出餵給 parser 收斂）：** `LLM_DEBUG_LOG=1`，用真實 GitHub Models key 對 `/api/v1/tutor_chats` 打一發**刻意超量**（塞大 `file_context` 或長 history）的請求；看 `log/llm_debug.log` 確認 413 body 的 `error.code` / `error.message` 確切結構與 `Max size: N` 的格式。debug log 已會記 body（(C) 既有），不需新增 plumbing。

---

## 4. 逐檔改動（後端）

| 檔案 | 改動 |
|---|---|
| `app/infrastructure/llm/llm_error.rb` | 新增 `class InputTooLarge < Base`，帶 `max_input_tokens` / `provider_message` |
| `app/infrastructure/llm/openai_client.rb` | `parse`：在 429 判定後、generic Upstream 前，加 `raise_if_input_too_large(response)`；新增該方法 + `extract_provider_error_message` / `parse_max_input_tokens` 兩個 private helper |
| `app/infrastructure/llm/anthropic_client.rb` | 對稱加 `raise_if_input_too_large`（**但 Anthropic 用 400 不是 413**，此判定對 Anthropic 實質 no-op；加上去只為兩 client 對稱、零風險，見 §9）|
| `app/application/services/tutor_chat/run_tutor_chat.rb` | (a) `request_tutor_reply` 多一條 `rescue LlmError::InputTooLarge => e`；新增 `input_too_large_failure(e)` helper（放在 `rate_limited_failure` 旁）。(b) **決策 2**：`assemble_prompt` 的 pre-flight overflow 一併補 `errors.limit_scope: 'per_request'` |
| `app/application/controllers/api.rb` | `SERVICE_FAILURE_STATUS` 加 `input_too_large: :payload_too_large` |
| `app/presentation/responses/result.rb` | **不動**（`payload_too_large` 已在 `FAILURE`）|
| `app/presentation/representers/http_response.rb` | **不動**（`payload_too_large: 413` 已有）|

#### `llm_error.rb` — 照 `RateLimited` 加一個
```ruby
# 413 from the provider (per-request token cap exceeded; e.g. GitHub Models
# `tokens_limit_reached`). Distinct from Upstream so the API can answer 413
# instead of a generic 502, and the frontend can stop hammer-retrying (a 413
# re-sent with the same body is always a 413 again). max_input_tokens is the
# provider's per-model cap parsed from "Max size: N tokens" (nil if absent).
class InputTooLarge < Base
  attr_reader :max_input_tokens, :provider_message

  def initialize(message = nil, max_input_tokens: nil, provider_message: nil)
    super(message)
    @max_input_tokens = max_input_tokens
    @provider_message = provider_message
  end
end
```

#### `openai_client.rb` — `parse` 串接（Anthropic 對稱）
```ruby
def parse(response)
  rate_limit = RateLimitHeaders.extract(response)
  raise_if_rate_limited(response, rate_limit)
  raise_if_input_too_large(response)                                   # NEW — 413
  raise LlmError::Upstream, "openai returned #{response.code}" unless response.is_a?(Net::HTTPSuccess)
  # ... 既有 content / usage / tool_calls 解析不變 ...
end

# 413 → distinct InputTooLarge (per-request token cap). Parse the provider's
# "Max size: N tokens" so the frontend can localize "input too long (max N) —
# start a fresh conversation". No-op on any non-413 response.
def raise_if_input_too_large(response)
  return unless response.is_a?(Net::HTTPRequestEntityTooLarge)         # 413

  provider_message = extract_provider_error_message(response.body)
  raise LlmError::InputTooLarge.new(
    'openai input too large (413)',
    max_input_tokens: parse_max_input_tokens(provider_message),
    provider_message: provider_message
  )
end

def extract_provider_error_message(body)
  JSON.parse(body).dig('error', 'message') || body.to_s
rescue JSON::ParserError
  body.to_s
end

def parse_max_input_tokens(message)
  m = message.to_s.match(/max size:\s*(\d+)\s*tokens/i)
  m && m[1].to_i
end
```
> `Net::HTTPRequestEntityTooLarge` 是 413 的標準類別，沿用既有 `Net::HTTPTooManyRequests`(429) / `Net::HTTPSuccess` 的 `is_a?` 風格。**落地時確認 Ruby 版本的常數名**（部分 3.x 另有別名 `Net::HTTPContentTooLarge`/`Net::HTTPPayloadTooLarge`）；若有疑慮可改 `response.code == '413'`。

#### `run_tutor_chat.rb` — rescue + helper
```ruby
rescue Infrastructure::LlmError::RateLimited => e
  rate_limited_failure(e)
rescue Infrastructure::LlmError::InputTooLarge => e
  input_too_large_failure(e)
rescue Infrastructure::LlmError::Upstream => e
  Failure[:upstream_error, e.message]
```
```ruby
# 413 → :input_too_large (HTTP 413). per-request scope, ALWAYS — never
# provider_account (that's 429) and never conversation. The student-facing
# wording is the frontend's job (localized from the stable tag + max_input_tokens),
# mirroring how `warnings` tokens are localized; we only ship the signal + N.
def input_too_large_failure(error)
  Failure[:input_too_large, 'tutor input exceeds the provider per-request limit',
          { limit_scope:      'per_request',
            limit_dimension:  'tokens',
            max_input_tokens: error.max_input_tokens }]   # nil when provider omitted it
end
```
> **mini-loop 無需特別處理。** `request_tutor_reply` 每輪都跑這段 rescue，413 在 round 1 或 round 2 觸發都會被接住、`yield` 短路整個 loop（與既有 timeout/429 一致）。round 2 因注入 solution 而 body 更大、更容易 413 —— 測試要涵蓋 round-2 413（§8）。

**決策 2 — pre-flight `context_overflow` 補 scope（taxonomy 對齊）。** `assemble_prompt` 既有那行加上 `errors`，讓兩個 413 來源都帶一致的 `limit_scope`：
```ruby
# 既有：return Failure[:context_overflow, 'prompt exceeds model context window'] if assembled.overflow?
return Failure[:context_overflow, 'prompt exceeds model context window',
               { limit_scope: 'per_request' }] if assembled.overflow?
```
> `api.rb` 已 `tag, message, errors = outcome.failure` 並透傳 `errors`（representer 有 `property :errors`），所以零串接成本。pre-flight 不帶 `max_input_tokens`（它是估算、給不出 provider 每模型真值）——這正是與 `input_too_large` 的 provenance 差異（§9）。既有 `context_overflow` 測試若斷言 `failure` 長度為 2，需放寬為含第三元素。

#### `api.rb` — 失敗碼對照（唯一要動的 presentation 串接）
```ruby
SERVICE_FAILURE_STATUS = {
  # ... 既有 ...
  context_overflow: :payload_too_large,   # 既有：pre-flight 估算
  input_too_large:  :payload_too_large,   # NEW (D)：provider 真實 413
  rate_limited:     :too_many_requests,   # (C1) 429
  # ...
}.freeze
```

---

## 5. 在地化文案分工（採「自己組」，2026-06-24 拍板）

**決定：後端只給訊號 + 數字，前端組句。** 不把 provider 的英文原句直接丟給學生（含內部 model 名、純英文）。

- **後端：** Failure tag `:input_too_large`（穩定）、`errors.max_input_tokens: N`、`errors.limit_scope: 'per_request'`、`errors.limit_dimension: 'tokens'`。
- **前端：** 比照既有 `warnings` token 的在地化分工 —— 用 tag/status 對到在地化模板，把 N 填進去。例：
  - 有 N：「這次輸入太長（單次上限 {N} tokens），請開新對話再試。」
  - 無 N（provider 沒回數字）：退回泛用句「這次輸入太長，請開新對話再試。」
- **與 (A) 一致：** `session_limit_reached`（軟）與 `input_too_large`（硬）文案都導向「開新對話」，可共用同一組 per-request 文案資產，只差「提醒」vs「錯誤」語氣。**務必與 429 文案分流**（429 導向「稍候」）。

---

## 6. 前端（MindyCLI）改動 — **另開 track，不屬本批交付**

比照 (C) §6：後端先行，前端另開 track；舊 CLI 不受影響（413 目前可能落既有錯誤分支，行為不變，只是還沒分流文案）。

| 訊號 | 來源 | 前端行為 |
|---|---|---|
| **413 `input_too_large`（硬）** | HTTP 413 + body `{ status:"payload_too_large", errors:{ limit_scope:"per_request", limit_dimension:"tokens", max_input_tokens } }` | 顯示「輸入太長（上限 N tokens），請**開新對話**」；**不要**自動重打（同 body 必再 413）；**不要**與 429 共用「碰到上限」路徑 |

- 既有 CLI 對 413（pre-flight `context_overflow`）若已有處理，本案沿用同一條；只是多了 `errors.max_input_tokens` 可選讀。
- **⚠️ 與 429 動作相反**（沿用 (C) §6 的相反動作表）：413 → 開新對話；429 → 稍候退避。

---

## 7. doc 改動（`doc/api_tutor_chats.md`）

1. **Error responses 表**把既有 `413` 列補上**第二個來源**：說明 413 `payload_too_large` 現在有兩個觸發 —— pre-flight 估算（`context_overflow`，prompt 估算就超通道視窗）與 **provider 真實回報**（`input_too_large`，provider 的 per-request tokenizer 上限，`errors.max_input_tokens` 帶每模型 N、`errors.limit_scope="per_request"`、`limit_dimension="tokens"`）。**明寫：與 `429 rate_limited` 不同 —— 413 要「開新對話」、429 要「退避」。**
2. **「Which limit」taxonomy 小段**（(C) 已建）把 per_request 列補上「硬」格：`session_limit_reached`(軟) ／ `context_overflow`+`input_too_large`(硬)，並強調與 429 的相反動作。
3. **Notes** 補：413 訊息為防禦式解析（provider envelope 未保證），後端只透傳結構化 `max_input_tokens`、不外洩 provider 原句（含內部 model 名）。

---

## 8. 測試部署（test plan）

> client spec 用既有 `webmock`，可 `to_return(status: 413, body: ...)` 直接造 413。

### 8.1 `spec/infrastructure/llm/openai_client_spec.rb`（擴充）
- **413 → `InputTooLarge`**：`to_return(status: 413, body: '{"error":{"code":"tokens_limit_reached","message":"Request body too large for gpt-4.1 model. Max size: 16000 tokens."}}')` → raise `InputTooLarge`、`err.max_input_tokens == 16000`、`err.provider_message` 含原句。
- **413 但 message 無 `Max size`**（或非 JSON body）→ raise `InputTooLarge`、`max_input_tokens == nil`（防禦式不炸）。
- **既有「500 → `Upstream`」案不變**（證明只有 413/429 被拆出來，其他非 2xx 仍 `Upstream`）。
- **既有 429 案不變**（兩個拆分互不干擾）。

### 8.2 `spec/infrastructure/llm/anthropic_client_spec.rb`（擴充）
- Anthropic 回 400（context 太大）→ 仍走既有 `Upstream`（證明 413 判定對 Anthropic no-op、未誤接 400）。

### 8.3 `spec/application/services/run_tutor_chat_spec.rb`（擴充）
- **413 硬失敗**：client `send_prompt` raise `InputTooLarge(max_input_tokens: 8000)` → `outcome.failure.first == :input_too_large`、`failure[2][:limit_scope] == 'per_request'`、`[:limit_dimension] == 'tokens'`、`[:max_input_tokens] == 8000`。
- **413 無 N**：raise `InputTooLarge(max_input_tokens: nil)` → `failure[2][:max_input_tokens].nil?`，tag 仍 `:input_too_large`。
- **mini-loop round-2 413**：round 1 觸發 load_reference、round 2 raise `InputTooLarge`（注入 solution 後 body 變大）→ `:input_too_large`（比照既有 round-2 timeout/429 案）。
- **與 429 分流**：raise `RateLimited` → `:rate_limited`（不被 413 分支誤接）；raise `InputTooLarge` → `:input_too_large`（不被 429 分支誤接）。

### 8.4 `spec/application/controllers/`（若有 route 層 spec）
- service 回 `Failure[:input_too_large, ...]` → HTTP **413**、body `status:"payload_too_large"`、`errors.max_input_tokens` 有值。（若無 route spec，至少由既有 `result_spec` / `http_response_representer_spec` 對 `payload_too_large → 413` 的覆蓋 + 8.3 覆蓋對照表正確性 —— 這兩個 presentation spec **不需新增**，因為 `payload_too_large` 早已被既有 `context_overflow` 測過。）

### 8.5 驗收
- `bundle exec rake test` 全綠（既有 + 新增）。
- **量測（§3）**：開 `LLM_DEBUG_LOG` 對真實 GitHub Models 打一發刻意超量請求，log 確認 413 body 的 `error.code`/`error.message` 結構與 `Max size: N` 格式，據此微調 `extract_provider_error_message`/`parse_max_input_tokens`（手動、非自動化斷言）。
- RuboCop：`parse` 多一個 guard、新增三個短 helper —— 沿用既有風格；`rake style`/`quality` 為獨立任務。

---

## 9. 邊界與取捨

- **413 是 OpenAI/GitHub 通道的事；Anthropic 不回 413。** Anthropic 對 context 過大回 **400 `invalid_request_error`**，不是 413。所以 `raise_if_input_too_large` 對 Anthropic 實質 no-op；加上去只為兩 client 對稱、避免日後有人以為漏接。**若日後想接 Anthropic 的 400-too-large**，那是另一個（更難辨識、要比對 `error.type`）的工作，不在本案。
- **provider 413 vs pre-flight `context_overflow` 為何不合併成一個 tag。** 兩者同 HTTP 413、同 remedy（開新對話），但 provenance 不同：pre-flight 是**我們估算**、provider 是**真值**，且只有 provider 能給每模型真實 N。保留兩個 service tag（都 → `payload_too_large`）讓「估算說 OK 但 provider 拒了」可被 log/診斷。前端對兩者處理相同 —— 零額外分支。（見 §10 決策 1；若要極簡可合併，但會失去 provenance 與 N。）
- **per-model 上限偏差是 root cause 之一，但本案不修 `token_budget.rb`。** 真正一勞永逸是讓 pre-flight 知道每模型 4K/8K/16K，但那要 model→cap 對照表、且 GitHub 可能隨時調整（如 2025-04 把 4o-mini 調到 16K）。本案的 413 安全網**讓我們不必精準預測**也能正確收尾；per-model cap 表列為日後 optional follow-up（可由實測 413 的 N 回填）。
- **413 是「開新對話」訊號不是錯誤。** 拆出 `:input_too_large`/413 的價值就在讓前端**開新對話**而非當 502 盲目重打（同 body 重打必再 413）。
- **向後相容：** `LlmResponse` 不變；`InputTooLarge` 是新 raise 路徑，舊成功路徑不受影響；`payload_too_large`/413 contract 早已存在，舊 CLI 對 413 的既有處理不變。

---

## 10. 決策（全數於 2026-06-24 拍板）

### 早先已定
- **拆 413、回正確 413（per_request 硬失敗）**，照 (C) 拆 429 的模式。
- **在地化採「自己組」**：後端給穩定 tag + `max_input_tokens`，前端組在地化句（§5）。不外洩 provider 英文原句／內部 model 名。
- **前端另開 track**：本批只交付後端 + doc。

### 2026-06-24 拍板（原「待拍板」四項，全採建議預設）
1. **新 tag `:input_too_large`（不複用 `context_overflow`）。** 保留 provenance（估算 vs provider 真值）+ 帶 provider 真實每模型 N；兩者都 → `payload_too_large`(413)、前端零額外分支。
2. **pre-flight `context_overflow` 一併補 `errors.limit_scope: 'per_request'`。** taxonomy 對齊、零成本，讓兩個 413 來源帶一致 scope 欄位給前端。→ 已納入 §4 / §11。
3. **`max_input_tokens` 解析不到 → `nil`，不 fallback 8K。** 不塞估計值（4K/16K 模型會誤導）；`nil` 讓前端退泛用文案更誠實。
4. **不接 Anthropic 的 400-too-large。** 本案只處理 413（見 §9）。

---

## 11. 落地檢查清單

**單批交付（後端 + doc；可獨立開 PR / 驗收）**
- [x] `LlmError::InputTooLarge`（帶 `max_input_tokens` / `provider_message`）
- [x] `openai_client.rb`：`raise_if_input_too_large` + `extract_provider_error_message` + `parse_max_input_tokens`，`parse` 串接（429 後、Upstream 前）
- [x] `anthropic_client.rb`：對稱加 `raise_if_input_too_large`（no-op，僅對稱）
- [x] service `request_tutor_reply` rescue `InputTooLarge → :input_too_large` + `input_too_large_failure` helper（`errors`: scope/dimension/max_input_tokens）
- [x] **決策 2**：`assemble_prompt` 的 `context_overflow` 補 `errors: { limit_scope: 'per_request' }`（無既有斷言需放寬 —— grep 確認 spec 未斷言其 failure 長度）
- [x] `api.rb`：`SERVICE_FAILURE_STATUS` 加 `input_too_large: :payload_too_large`
- [x] `result.rb` / `http_response.rb`：**確認不需改**（`payload_too_large`/413 已存在，未改）
- [x] client spec（413→InputTooLarge、無 N、非 JSON body、500 仍 Upstream、429 不受影響；Anthropic 400 仍 Upstream）
- [x] service spec（413 硬失敗、無 N、round-2 413、與 429 分流）
- [x] `doc/api_tutor_chats.md`（413 第二來源 + taxonomy per_request 硬格 + 與 429 分流警語）
- [x] 開 `LLM_DEBUG_LOG` 對真實 GitHub Models 量一發超量請求，確認 413 body 結構並收斂 parser ←（**2026-06-24 已量測**；body `{"error":{"code":"tokens_limit_reached","message":"Request body too large for gpt-4o-mini model. Max size: 8000 tokens.","details":"..."}}` 與 `dig('error','message')` 路徑及 `/max size:\s*(\d+)\s*tokens/i` regex 完全命中，`max_input_tokens` 正確解析為 `8000`，**parser 不需修改**）

**前端 track（另開，不屬本批）**
- [ ] 413 `input_too_large` 分支：顯示「輸入太長（上限 N）→ 開新對話」，**不**自動重打
- [ ] 文案與 429 **分流**（一個「開新對話」、一個「稍候」）
- [ ] （選配）讀 `errors.max_input_tokens` 讓文案帶上 N
