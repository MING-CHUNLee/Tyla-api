# `MAX_USAGE` 收尾：對話達額度時主動請學生開新對話

**Date:** 2026-06-16
**Status:** 規劃中（尚未實作）。本文盤點 DEV 目標、釐清「MAX_USAGE」的三種解讀、列出目前能做/不能做與待拍板決策。
**DEV 需求原句：**

> If token count ~ MAX_USAGE -- tell student we are ending conversation and starting a new one.

**相關文件：**
- 已上線的 (A) 單次脈絡上限訊號：`plans/2026-06-16-session-token-limit-signal.md`、`app/application/services/tutor_chat/run_tutor_chat.rb`（`session_limit_reached`）
- 每通道 token 上限：`app/domain/values/token_budget.rb`
- LLM client（usage/header 解析點）：`app/infrastructure/llm/openai_client.rb`、`app/infrastructure/llm/anthropic_client.rb`、`app/infrastructure/llm/llm_response.rb`、`app/infrastructure/llm/llm_error.rb`
- `warnings` 通道與前後端分工：`doc/api_tutor_chats.md`、`app/presentation/representers/tutor_chat_representer.rb`

> **一句話：** DEV 想在「token 接近 MAX_USAGE」時主動請學生收尾、開新對話。盤點後發現 **「MAX_USAGE」其實有三種互不相同的量測軸**，而我們最在意的那一種（整段對話累計）**provider 不會回報給我們**——因為 provider 端根本沒有「一段對話」的概念，每次呼叫都是無狀態獨立請求。本文把三種解讀拆開，標明哪些**現在就能做**、哪些**需要改合約或 DB**、哪些**只能拿 provider 真實 rate-limit header**，並給出推薦路線與待決策清單。

---

## 1. 背景：這是 (A) 的後續

`plans/2026-06-16-session-token-limit-signal.md` 已上線了一個 **(A) 單次請求脈絡上限** 訊號 `session_limit_reached`：每回合 tutor 回來後，拿那次呼叫真實的 `usage.input_tokens` 跟通道 `input_token_limit`（8K/128K/200K）比，達 90% 就在 `warnings` 加旗標。那份 plan 的 §6 明白把 **(B) 整段對話累計額度** 列為「後端目前做不到、需改合約／DB、另案處理」。

本文就是補上那個「另案」：把 DEV 的 `MAX_USAGE` 需求徹底拆清楚、規劃實作。

---

## 2. 核心發現：「MAX_USAGE」有三種解讀，且不是同一個東西

盤點後，「token count ~ MAX_USAGE」可以指三條完全不同的軸：

| 軸 | 意思 | 量測來源 | 現狀 |
|---|---|---|---|
| **(A) 單次請求脈絡上限** | 這一次組好的 prompt 逼近通道 context window | tutor 回傳 `usage.input_tokens` vs `TokenBudget#input_token_limit` | **已上線**（`session_limit_reached`） |
| **(B) 整段對話累計額度** | 這段對話歷來總共花的 token 達到某個產品配額 | 每回合 client-facing `usage`（Σ over rounds）的**再累加** vs 自訂 `MAX_USAGE` | **做不到（現況）**，需改合約或 DB |
| **(C) provider rate-limit 窗口剩餘** | 你的 LLM 帳號在這個 rate 窗口（每分/每天）快被限流 | provider 回的 `x-ratelimit-*` header / 429 + `Retry-After` | **真實資料，但目前整包丟掉**；且各家命名不一 |

**關鍵認知：**

- **(B) 的「對話累計」provider 不會給我們。** 對 provider 而言，每次 `/chat/completions`／`/messages` 都是無狀態、彼此獨立的呼叫（我們每回合把整個 history 重送）。它看到 N 個獨立請求，沒有「一段對話」，因此**不可能**回報「這段對話累計花了多少」。這個概念只存在我們這側。
- **(C) provider 真的會回**，但它量的是**帳號層級、會週期重置的 rate 窗口剩餘**，不是「這段對話多長」。多個學生共用一把 key 時還會互相吃額度。它能回答「今天/這分鐘快被限流了」，**不能**回答「這段對話太貴了」。

DEV 原句的精神（「ending conversation and starting a new one」＝這段對話夠長了、收尾開新的）**最貼近 (B)**。(C) 是另一個有價值但語意不同的訊號。

---

## 3. 目前能做到 / 做不到

| 能力 | 狀態 | 依據 |
|---|---|---|
| 拿到**單次呼叫**的 input/output token | ✅ 已有 | `openai_client.rb:86-89`、`anthropic_client.rb:80-83` 解析 body 的 `usage` |
| 比對單次 input vs 通道 context 上限並發訊號 | ✅ 已上線 | `run_tutor_chat.rb` `approaching_session_limit?` → `session_limit_reached` |
| 把單回合 usage（Σ over mini-loop rounds）回給前端 | ✅ 已有 | `ok_outcome` 的 `usage: reply.usage` |
| **跨回合累加**整段對話 usage | ❌ 做不到 | 後端逐回合無狀態；usage **未持久化**（`prompt_logs` 無 usage 欄）；`session_turns` **不帶 per-turn usage**；**無 session_id** |
| 取得 provider 的 **rate-limit header** | ❌ 目前丟掉 | 兩個 client 的 `parse` 只讀 `response.body`，從不讀 `response.each_header` |
| 區分 **429（限流）** 與其他 upstream 錯誤 | ❌ 混在一起 | `openai_client.rb:81`、`anthropic_client.rb:70` 把所有非 2xx 都 raise `LlmError::Upstream` |
| debug log 記錄 response header | ❌ 只記 body | `llm_debug_log.rb` `response` 只寫 `body` |
| 從 provider 取得「整段對話累計額度」 | ❌ 本質不可能 | provider 無對話概念（見 §2） |

**一句話總結現況：** 我們能算「單次」，不能算「累計」；provider 能給「帳號 rate 窗口」，不能給「對話累計」。所以 (B) 的 `MAX_USAGE` **只能由我們自己定義並自己記**。

---

## 4. 問題盤點

### 4.1 (B) 的三個結構性缺口

1. **usage 未持久化**：`Entity::PromptLog` 無 usage 欄位，`prompt_logs` 表也沒有。
2. **無 session 概念**：每回合是獨立 row，沒有 session_id 把同一段對話串起來。
3. **`session_turns` 不帶 usage**：前端 Option C 傳上來的 rich turns 只有 prompt/prose/actions，沒有 per-turn token。

→ 要做 (B)，狀態要嘛**前端帶上來**（無狀態後端比對），要嘛**後端自己存**（加欄 + session_id）。兩者都**跨 HTTP 合約或 DB schema**。

### 4.2 (C) 的最大坑：各家 rate-limit header 命名不一致

「provider 給什麼就撈什麼」不能寫死一組欄位，因為三家不一樣：

| Provider | remaining 系列 | reset 系列 | 限流碼 |
|---|---|---|---|
| OpenAI (`api.openai.com`) | `x-ratelimit-remaining-requests`、`x-ratelimit-remaining-tokens` | `x-ratelimit-reset-requests`、`x-ratelimit-reset-tokens` | 429 |
| Anthropic (`api.anthropic.com`) | `anthropic-ratelimit-requests-remaining`、`anthropic-ratelimit-tokens-remaining`（**前綴不同**） | `anthropic-ratelimit-*-reset` | 429 + `retry-after` |
| GitHub Models（Azure inference，學生免費通道） | `x-ratelimit-*` 一族，**確切欄位需以實際回應確認** | 多半 429 時給 `Retry-After` | 429 |

- 前綴、`reset` 是 unix timestamp 還是「剩餘秒數/時長字串」都可能不同。
- **正確做法是「通用透傳」**：撈所有符合 `*ratelimit*` / `retry-after` 的 header 整包帶上去，不假設固定 schema——這才真的是「provider 給什麼就做什麼」，也免去猜欄位。
- **GitHub 到底回哪些，可以直接量**：開 `LLM_DEBUG_LOG`（已有 `llm_debug_log.rb`）並讓它連 header 一起記，打一發真實 GitHub Models 請求看 log，不必猜。

### 4.3 GitHub 免費層先撞到的不是「對話累計」

GitHub Models 免費層的限制維度是：**單次請求 token 上限**（input 8K／output 4K——這條 (A) 已經擋了）、**每分鐘/每天請求數**、**並發數**。**沒有**「每段對話累計 token」這種配額。所以對學生通道而言，(C) 主要幫你擋到的是「今天請求數快用完、快被限流」，是**帳號層級、與對話無關**的訊號。

---

## 5. 三條實作路線

### 路線 B1 — 前端帶 running total，後端無狀態比對（針對 (B)，推薦）

順著本專案既定架構（前端持有 session 狀態、後端逐回合無狀態；見 Option C 的 `session_turns` 設計）。讓**後端**計算並回傳新的累計值，前端下一回合**原封帶回**（opaque counter）——「什麼算進額度」的定義 100% 留在後端。

- 請求新增 `session_usage`（整數，選填，預設 0）＝後端上一回合回的值；首回合省略 → 0。
- 後端算 `new_total = session_usage + (reply.usage.input + reply.usage.output)`。
- `new_total >= MAX_USAGE * RATIO` → `warnings << 'conversation_limit_reached'`。
- response 回傳 `session_usage: new_total`。

**優點**：零 schema 變更、零 migration；改動收斂在一個 service method（`ok_outcome`）；用的是已是 Σ 的 `reply.usage`，**不動** `call`/`finish_loop`/`tutor_mini_loop`；與 (A) 正交、可同時觸發。
**缺點**：信任前端誠實累加（但這是學生自己的配額，少報只是讓自己這段對話多撐幾回，風險低）；跨裝置不權威。

### 路線 B2 — 後端持久化 usage + session_id（針對 (B)，權威但重）

- migration 加 `prompt_logs.input_tokens / output_tokens / session_id`（nullable）。
- `Entity::PromptLog`、`Repository::PromptLogs`（`rebuild_entity` + 新增 `sum_session_usage(session_id)` 聚合）。
- 請求加 `session_id`（後端無 session 表，仍需前端帶——所以**一樣改合約**）。
- service：`persist_turn` 寫 session_id；tutor call 後用既有 `Repository::PromptLogs.update` 補寫 usage；查 `sum_session_usage` 比對 `MAX_USAGE`。
- 連帶改 `run_tutor_chat_spec.rb` 裡的 in-memory 測試表、entity/repo spec。

**優點**：權威、跨裝置、不可被 client 少報、usage 可做事後分析/計費。
**缺點**：migration + 每回合多一次 write + 一次聚合查詢；**仍需前端傳 session_id**；moving parts 多。對「提醒學生收尾」成本不成比例。

### 路線 C — provider rate-limit 透傳（針對 (C)，真資料但語意不同）

把 provider 真實回的限流資訊撈出來，而非自訂常數。

- **硬訊號（先做、最可靠）**：攔 **429 + `Retry-After`**，從 `LlmError::Upstream` 拆出新的 `LlmError::RateLimited`（帶 retry-after）。跨家一致、不用猜 header 名。
- **軟訊號**：`parse` 從 `response.each_header` 通用撈 `*ratelimit*`／`retry-after` 整包 → `remaining` 低於門檻給 `provider_rate_limited` warning。
- **配套**：`llm_debug_log.rb` 連 header 一起記（先用來確認 GitHub 真實欄位）。

**優點**：用 provider 真資料、未來換 provider 也不壞。
**缺點**：量的是帳號 rate 窗口、會重置、非對話層級（多人共用 key 會互相干擾）；**不等於** DEV 想要的「這段對話太長」。要在 doc/前端講清楚避免誤讀。

---

## 6. 推薦

- **要落地 DEV 原句的語意（這段對話夠長了 → 收尾開新的）：走 B1。** 最貼近需求、最省、與既有 (A)／`warnings` 模式一致。
- **C 當作補充、不是替代**：429 攔截值得獨立做（避免把限流誤判成一般 upstream 錯誤），但它回答的是「provider 在限流我」，不是 (B)。若 DEV 真正擔心的是「GitHub 免費層被擋」，才以 C 為主。
- **B2 僅在需要權威計費/分析時再做**：usage 欄有獨立價值，但對即時收尾提示是殺雞用牛刀。

> 命名提醒：(A) 已占用 `session_limit_reached`（單次脈絡）。(B) 建議用 `conversation_limit_reached`，(C) 建議 `provider_rate_limited`，三者語意不同、可並存。

---

## 7. 逐檔改動（B1，推薦路線）

| 檔案 | 改動 |
|---|---|
| `app/application/requests/tutor_chat.rb` | `params` 加 `optional(:session_usage).filled(:integer)`；加 `rule(:session_usage)` 拒負數 |
| `app/application/services/tutor_chat/run_tutor_chat.rb` | 新增 `CONVERSATION_QUOTA_RATIO = 0.9`、`CONVERSATION_TOKEN_QUOTA = ENV.fetch('CONVERSATION_TOKEN_QUOTA', '500000').to_i`、`CONVERSATION_LIMIT_WARNING = 'conversation_limit_reached'`；在 `ok_outcome` 算 `new_total` 與 `quota_reached`，穿進 `warnings_for`；DTO 多帶 `session_usage: new_total`。**不動** `call`/`finish_loop`/`tutor_mini_loop` |
| `app/presentation/representers/tutor_chat_representer.rb` | `Data.define` 加 `:session_usage`；`property :session_usage`（沿用 nil 即省略） |
| `doc/api_tutor_chats.md` | 請求欄位表加 `session_usage`；回應加 echo；`warnings` 補 `conversation_limit_reached`（並說明與 `session_limit_reached` 的差異） |
| `spec/application/services/run_tutor_chat_spec.rb` | 觸發／未觸發／與 `session_limit_reached` 正交／計入 output／echo 正確 |
| `spec/application/requests/tutor_chat_spec.rb` | 接受整數、拒非整數/負數、缺省可 |
| `spec/presentation/representers/tutor_chat_representer_spec.rb` | echo 欄位有 render |

### service 骨架

```ruby
# (B) 整段對話累計額度：跟 (A) 的單次脈絡上限不同 —— 量的是 client-facing
# usage（Σ over rounds）的跨回合再累加，達 MAX_USAGE 的 90% 就提示收尾。
# 前端把後端回的 session_usage 原封帶回（opaque counter，定義留在後端）。
CONVERSATION_QUOTA_RATIO   = 0.9
CONVERSATION_TOKEN_QUOTA   = ENV.fetch('CONVERSATION_TOKEN_QUOTA', '500000').to_i  # MAX_USAGE
CONVERSATION_LIMIT_WARNING = 'conversation_limit_reached'

# 在 ok_outcome 內（reply.usage 此時已是 Σ）：
turn_total    = usage_count(reply.usage, :input_tokens) + usage_count(reply.usage, :output_tokens)
session_total = params[:session_usage].to_i + turn_total
quota_reached = CONVERSATION_TOKEN_QUOTA.positive? &&
                session_total >= CONVERSATION_TOKEN_QUOTA * CONVERSATION_QUOTA_RATIO
```

### 若同時做 C（429 攔截，最小版）

| 檔案 | 改動 |
|---|---|
| `app/infrastructure/llm/llm_error.rb` | 新增 `class RateLimited < Base; end` |
| `app/infrastructure/llm/llm_response.rb` | `Data.define` 加 `:rate_limit`（裝撈到的 header hash，預設 `{}`） |
| `app/infrastructure/llm/openai_client.rb` / `anthropic_client.rb` | `parse` 從 `response.each_header` 通用撈 `*ratelimit*`/`retry-after`；429 → raise `LlmError::RateLimited`（帶 retry-after） |
| `app/infrastructure/llm/llm_debug_log.rb` | `response` 多記 header（先用來量 GitHub 真實欄位） |
| `app/application/services/tutor_chat/run_tutor_chat.rb` | 讀終端 reply 的 `rate_limit`，門檻判斷 → `provider_rate_limited`；429 對應明確失敗/警告 |
| `app/application/controllers/api.rb` | `SERVICE_FAILURE_STATUS` 視需要加 `rate_limited → :too_many_requests`（429 路徑） |

---

## 8. 待 DEV／產品拍板的決策

1. **DEV 的 `MAX_USAGE` 到底指哪一軸？** (A) 單次脈絡（已做）／(B) 對話累計（B1）／(C) provider 限流（C）。原句語意最像 (B)。
2. **`MAX_USAGE` 數值？** 無現成來源，需產品定。先給 ENV 可覆寫、預設 500K 占位。
3. **什麼算進額度？** 建議 `input + output`（計費語意；input 每回合重送 history，累計天然反映對話變長變貴）。要改成 input-only 是一行運算式的事。
4. **「達到」還是「逼近」？** 建議比照 (A) 取 0.9，在硬配額前先優雅收尾。
5. **要不要同時做 C 的 429 攔截？** 即使 (B) 走 B1，把 429 從一般 upstream 錯誤拆出來仍有獨立價值。

---

## 9. 驗證計畫

- B1：service spec 三案（觸發/未觸發/與 `session_limit_reached` 正交）+ echo 正確 + request 驗證 + representer render；`bundle exec rake test` 全綠。
- C（若做）：client spec stub 429 + `Retry-After` → `LlmError::RateLimited`；stub `x-ratelimit-remaining-*` 低/高 → warning 有/無；先用 `LLM_DEBUG_LOG` 對真實 GitHub Models 量一次 header 確認欄位名。
- RuboCop：`warnings_for` 已是 cyclomatic 8/7（(A) 那條 guard 所致），(B) 再加一條會再 +1，沿用明列風格、不為閃 cop 改 idiom（與既有 `run_tutor_chat.rb` 註記一致）。
