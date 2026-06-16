# 接近脈絡上限主動收尾：`session_limit_reached` 訊號

**Date:** 2026-06-16
**Status:** 已實作上線（全套測試綠，342 runs / 0 failures）。本文為設計決策與實作紀錄。
**相關文件：**
- 每通道 token 上限來源：`app/domain/values/token_budget.rb`、`plans/2026-05-28-token-budget-algorithm.md`
- budget-aware 組裝與既有 trim 行為：`app/application/prompts/builders/budget_aware_prompt_assembler.rb`、`plans/2026-06-15-option-c-backend-owned-history-compression.md`
- `warnings` 通道與前後端職責分工：`doc/api_tutor_chats.md`「`warnings`」、`app/presentation/representers/tutor_chat_representer.rb`
- DEV 需求原句：`If token count ~ MAX_USAGE -- tell student we are ending conversation and starting a new one.`

> **一句話：** 每回合 tutor 呼叫回來後，後端拿那次呼叫**真實的 `usage.input_tokens`** 跟該通道的 `input_token_limit`（即「MAX_USAGE」：GitHub 8K／OpenAI 128K／Anthropic 200K）比對，達到 **90%** 就在 `warnings` 加一個 `session_limit_reached`；前端據此提醒學生**收尾、開新對話**。這補上了原本「接近上限只會默默裁掉舊對話（`history_truncated`），最壞直接 413」的缺口，把默默降級換成**主動、優雅的收尾提示**。訊號為**結構化 token**，學生面的在地化訊息由前端 render（沿用既有 `warnings` 機制與前後端分工）。

---

## 1. 動機與現況

DEV 想在「token 數接近上限」時，主動告訴學生這段對話要結束、請開新的。盤點現況：

- **沒有 `MAX_USAGE` 常數。** 最接近的是 `TokenBudget` 的 `input_token_limit`，依通道而定（GitHub Models 免費 8K／OpenAI 128K／Anthropic 200K）。這是**單次請求的輸入上限**，不是整段對話的累計額度。
- **後端對 usage 是「逐回合、無狀態」。** 不累加整段對話 token，也**沒存進 `prompt_logs`**（`Entity::PromptLog` 無 usage 欄位）；session 狀態由前端持有，每回合靠 `history` / `session_turns` 傳上來，且 `session_turns` **不帶 per-turn usage**。回傳的 `usage` 只是該回合 tutor 的 input/output（mini-loop 兩輪相加）。
- **接近上限時原本是默默降級的**：history 由新到舊被裁（`warnings: history_truncated`）、`file_context`/overview 被丟、最壞連 base 本身就超過 → 回 413 `context_overflow`。

所以這個需求本質上就是：把「默默降級／硬失敗」換成**「在那之前先優雅地提醒學生收尾」**。

---

## 2. 兩個設計分歧與決策（2026-06-16 與 DEV 確認）

### 2.1 「MAX_USAGE」是哪一種？→ **單次請求的脈絡上限**

| 解讀 | 可行性 | 決策 |
|---|---|---|
| **(A) 單次請求脈絡上限**：組好的 prompt 接近通道 `input_token_limit` | 完全後端可做、**不改合約**、用真實 `usage.input_tokens` 比對即可 | **採用** |
| (B) 整段對話累計額度：對話總共花的 token 達到產品配額 | 後端目前**做不到**（usage 未持久化、`session_turns` 不帶 usage、無 session_id）。需前端傳累計值或後端加 usage 欄＋session 概念 | 不在本次範圍（見 §6） |

### 2.2 「告訴學生」的訊息由誰產生？→ **後端回結構化訊號**

| 方式 | 決策 |
|---|---|
| **後端回結構化訊號**：`warnings` 加一個 token，學生面文字由前端在地化 render | **採用**（符合既有 `warnings` 機制與前後端職責分工） |
| 後端直接把訊息寫進 `content`（學生面 prose） | 否——會把系統提示混進 tutor 回覆，且難在地化 |

---

## 3. 量測點：終端那一輪的真實 input，不是回傳的 `usage` 總和

關鍵細節：mini-loop（hybrid lazy solution，`plans/2026-06-11-hybrid-lazy-solution-implementation.md`）跑兩輪時，回傳給前端的 `usage` 是**兩輪相加**（計費語意）。但「脈絡視窗壓力」要看**實際送出的最終 prompt**——通常是注入解答後較大的 round 2。

所以判斷用 `rounds.last.usage[:input_tokens]`（終端那一輪自己的 input），**不是**那個會變成 client-facing `usage` 的跨輪 Σ。`finish_loop` 在把 `usage` 改成 Σ **之前**先算好這個布林旗標，沿 4-tuple 串回 `ok_outcome`。

判斷式（安全預設 false：上限未知或 provider 沒給 usage 時 count→0）：

```ruby
SESSION_LIMIT_RATIO = 0.9

def approaching_session_limit?(terminal_round, assembled)
  limit = assembled.input_token_limit.to_i
  return false unless limit.positive?
  usage_count(terminal_round.usage, :input_tokens) >= (limit * SESSION_LIMIT_RATIO)
end
```

---

## 4. 實作（已落地）

| 檔案 | 改動 |
|---|---|
| `app/application/prompts/builders/budget_aware_prompt_assembler.rb` | `Result` 新增 `input_token_limit`（正常 + overflow 兩條 return path 都帶上 `budget.input_token_limit`），讓呼叫端不必重新從 endpoint 推導通道 |
| `app/application/services/tutor_chat/run_tutor_chat.rb` | 新增 `SESSION_LIMIT_RATIO = 0.9`、`SESSION_LIMIT_WARNING = 'session_limit_reached'`；`approaching_session_limit?` 判斷；`finish_loop` 多回傳第 4 個值（approaching 旗標）；`call` / `ok_outcome` / `warnings_for` 串接該旗標 |
| `doc/api_tutor_chats.md` | `warnings` 文件補上 `session_limit_reached` 語意（≥90% 通道輸入上限、turn 仍成功、前端應提示開新對話） |
| `spec/application/services/run_tutor_chat_spec.rb` | 3 測試：觸發、未觸發、mini-loop 量終端輪而非兩輪相加 |
| `spec/application/prompts/builders/budget_aware_prompt_assembler_spec.rb` | 2 測試：正常與 overflow 路徑都回傳 `input_token_limit` |

`warnings_for` 維持既有「`<< token if cond`」明列風格（與檔案其餘 gate 一致），新增一行：

```ruby
warnings << SESSION_LIMIT_WARNING if approaching_limit
```

---

## 5. 邊界與取捨

- **小通道（8K）會比較早觸發。** persona＋作業等固定開銷本身就吃掉不小比例，8K 通道上對話沒長多少就接近上限——這是對的（空間真的少）。開新對話**不會**降低這份固定 base，但提示學生收尾仍合理，因為可用的對話成長空間確實已耗盡。
- **因為組裝器會 trim 到 fit，真實 input 幾乎不會超過上限**，所以語意是「approaching（≥90%）」而非「exceeded」。閾值是常數 `SESSION_LIMIT_RATIO`，要調敏感度直接改即可；若未來要依通道分別設定，再抽成 map。
- **與既有 `history_truncated` 的關係**：`history_truncated` 是「已經在丟舊對話」的事後事實；`session_limit_reached` 是 turn 仍成功、但視窗已逼近滿載的**主動收尾號**。兩者可同時出現，前端應把後者讀成「該開新對話」的 call-to-action，而非錯誤。
- **不破壞舊行為**：既有 `must_equal ['file_context_dropped']` 等測試用的 stub usage 很小（input_tokens: 10），遠低於 0.9×8000=7200，不會誤觸；`warnings` 仍在空陣列時由 representer 省略。

---

## 6. 不在本次範圍（若日後要做 (B) 累計配額）

要做「整段對話累計 token 達配額就收尾」，需改合約其一：

1. **前端每回合送 `session_usage` running total**（後端無狀態地比對產品配額 `MAX_USAGE`）；或
2. **後端在 `prompt_logs` 加 usage 欄 + 引入 session_id**，按 session 累加。

兩者都跨 HTTP 契約／DB schema，與本次「純後端、不改合約」的決策（§2.1）相斥，故另案處理。

---

## 7. 驗證

- `bundle exec rake test` → **342 runs, 1126 assertions, 0 failures, 0 errors**。
- RuboCop 註記：`run_tutor_chat.rb` 在 `main` 上本就帶 8 個 Metrics offense（如 `ok_outcome` 參數數、`ClassLength`），`rake style`/`quality` 為獨立任務、非 `rake test` 一環且 `main` 已紅。本次新增 1 個邊界性 offense（`warnings_for` cyclomatic 8/7，多一條 guard 所致），刻意保留明列風格以與周邊程式一致，未為閃避 cop 而改成不同 idiom。
