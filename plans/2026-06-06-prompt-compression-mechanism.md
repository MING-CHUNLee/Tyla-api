# Prompt Compression Mechanism — Design

**Date:** 2026-06-06
**Status:** 設計已收斂（2026-06-06 決策鎖定），可進入實作
**Scope:** `POST /api/v1/tutor_chats` 的 LLM 輸入組裝。延伸自
[2026-05-28-token-budget-algorithm.md](./2026-05-28-token-budget-algorithm.md)
的 budget 機制。
**參考:**
- Anthropic, *Effective context engineering for AI agents*
  （<https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents>）—
  本案多處設計對齊其框架，下文以〔CE〕標注。
- Anthropic cookbook, *Tool use — automatic context compaction*
  （<https://platform.claude.com/cookbook/tool-use-automatic-context-compaction>）—
  見 §3.1「compaction 不該做成 tool」。

## 已鎖定決策（2026-06-06）

1. **可以接受每回合多一次 LLM 呼叫** → 採用 LLM rolling summary 壓縮 history。
2. **summary 無狀態**：每回合用前端送來的完整 history 即時重算，**不加 DB schema、
   不改前後端 contract**。
3. **file_context 整塊保留、不壓縮**，且在 budget 中**優先於 history**。

---

## 1. 問題

前端的 `file_context` / `history` 加上後端的 persona / assignment / solution，
合成的 system prompt **可能超過 channel 上限**（GitHub Models hard cap **8 000
tokens**，是 hot path）。

### 1.1 現況是「丟棄」不是「壓縮」

[`BudgetAwarePromptAssembler`](../app/application/prompts/builders/budget_aware_prompt_assembler.rb)
目前是 lossy **drop**：base 必留（超過→413）；workspace 整塊放得下才放、放不下整塊
丟；history 由新到舊 `break`，第一個放不下就連同更舊全丟。

### 1.2 在 8K 下被丟掉的是什麼（既有 plan §3 試算）

| 區塊 | 估計 tokens |
|---|---|
| persona + assignment + solution + prompt + overhead | ~5 000 |
| 學生檔 | ~2 640 |
| 剩給 history | **~350** |

→ **history 今天幾乎永遠被丟光**。這正是 rolling summary 要救的東西。

### 1.3 不只是「塞進 8K」——這是 attention budget 問題〔CE〕

〔CE〕指出 context 是稀缺資源：注意力對 token 數呈 n² 攤薄，是**漸進劣化（gradient）
不是硬斷崖**，目標是找「**最小的高訊號 token 集合**」。推論：**就算沒超過 8K，每回合
都花掉的 ~5K 靜態教材也在稀釋注意力、讓 tutoring 變差**。因此壓縮有兩個目的——
(a) 避免溢出 413，(b) **在沒溢出時也提升回答品質**。這強化了策略 A（精簡靜態教材）
即使「放得下」也值得做。

---

## 2. 設計空間（保留紀錄）

| | A. 靜態 fixture 預壓縮 | B. Runtime 機械式壓縮 | **C. LLM rolling summary（選定）** |
|---|---|---|---|
| 對象 | persona/assignment/solution | history、workspace | **舊 history turns** |
| 成本 | runtime 0 | runtime 近 0 | **多一次 LLM 呼叫** |
| lossy | 人工審核 | 近 lossless | lossy（語意濃縮） |
| 需要新物件接 infra？ | 否 | 否 | **是（collaborator，非 endpoint service）** |

- **A** = 仍是性價比最高的並行小招（人工精簡教材），**獨立可做、不擋本案**。
  〔CE〕的 attention-budget（§1.3）讓它即使不溢出也有價值。
- **B** = history 改用 C 後大致被取代；workspace 不壓縮（見決策 3），故 **B 退出主線**。
- **C** = 本案主體。對應〔CE〕的 **compaction**；摘要啟發見 §5.1。
- **D（新增，受〔CE〕啟發）= just-in-time context**：不預載整個 workspace，改成
  「**正在編輯的檔案預載 + 其他檔案給路徑、讓 tutor 用 `load_file` 按需取**」。
  〔CE〕明確背書「維護輕量識別碼（file paths）+ runtime 載入」優於預載全部，並建議
  動態內容用 just-in-time、穩定內容可預載（混合）。本專案的 `load_file` action 已是此
  pattern——這是**近零成本**的壓縮槓桿，與 C 互補。範圍見 §8。

> **刻意不採 structured note-taking（外部記憶持久化）**〔CE〕：那是有狀態版本，與
> 決策 2「無狀態重算」衝突。我們用每回合重算換取零 schema / 零 contract 改動，代價是
> 重複摘要舊內容——這是清楚的取捨，不是疏漏。

---

## 3. 「要不要寫 Service？」的精確答案

依 [`services/SKILL.md`](../app/application/services/SKILL.md)（service = 接
infrastructure / 跨 domain model）：

- summary 要呼叫 LLM（infrastructure）→ **需要一個新物件**，但它**不是 RunTutorChat
  那種 endpoint orchestration service**，而是一個被注入的 **collaborator**。
- **本專案已有同型 precedent**：[`GuardAgent`](../app/application/services/guard/guard_agent.rb)
  就是「包一次 LLM 呼叫、被 endpoint service（`RunGuardCheck`）使用」的 collaborator，
  本身不是 Dry::Monads endpoint service。
- 因此新增 **`Tyla::Prompts::HistorySummarizer`**（與其他 prompt builder 同層），
  由 assembler 注入使用。**不新增 endpoint service、不動 controller、不動 routes。**

### 3.1 那 compress 該不該做成「tool」？——不該〔cookbook〕

Anthropic 的 *automatic context compaction* cookbook 給了直接答案：**連 Anthropic
自己都不把 compaction 做成 model 呼叫的 tool**，而是 Agent SDK 的 harness 功能
（`tool_runner(compaction_control={...})`，對 model 隱藏）。分工是 **harness 決定
「何時 / 壓什麼」（deterministic）、model 只負責「怎麼摘要」**。這正好**驗證本案設計**：
assembler（= 我們的 harness）持有 budget 決策、`HistorySummarizer`（= model 呼叫）只
做摘要。**不該退化成 tool**，三個理由：

1. **順序矛盾**：tool call 發生在 generation 中、prompt 早已進 context；「塞進 8K」
   必須在 send 之前完成。用「prompt 超標才觸發的 tool」修「prompt 已超標」是死結 →
   fit-to-budget 天生是 pre-send server step。
2. **架構不符**：該 cookbook 明文**不適用 stateless REST endpoint**（正是 tutor_chats），
   且需長駐 `tool_runner` agent loop。
3. **平台不符**：Anthropic Agent SDK 專屬；hot path 是 GitHub Models。

**可借鏡**：cookbook 用較便宜模型（`claude-haiku-4-5`）做摘要 → `HistorySummarizer`
可挑比主 tutor 便宜/小的模型；`<summary>` tag 包裹 + injected summary prompt → 對齊
`history-summary.md`（§5.1）。

> tool 在 context 管理的正解是**把需要的拉進來**（`load_file` / 策略 D），不是把多的
> 壓出去；壓縮屬 harness 的 deterministic 職責。
>
> **未來性**：若哪天改成 server 端長駐、且走 Anthropic-native，則
> `tool_runner + compaction_control` 可直接免費取得本案的摘要機制——但代價是放棄
> stateless 與 GitHub Models hot path，屬大改不在本案。

---

## 4. Pipeline（收斂後）

預算順序不變（base → file_context → history），差別在 **history 從「丟」改成
「丟不下就摘要」**，且 file_context 維持整塊、不壓縮：

```
1. base = persona+assignment+solution+prompt+overhead   (必留；超過→overflow→413)
2. file_context（整塊、不壓縮、優先）：放得下就整塊放；
   只有它本身就 > budget 才整塊丟（保留 whole-or-drop 後盾）
3. history：
   a. 先估：若全部 verbatim 放得下 → 直接放，【不呼叫 LLM】
   b. 若會溢出 → 保留 SUMMARY_TOKEN_CAP 預算，newest→oldest 收 verbatim turns，
      被擠掉的舊 turns 交給 HistorySummarizer 摘要成 ≤ cap 的一段，置於前面
   c. summarizer 回 nil（LLM 失敗）→ fail-open 退回今天的 drop 行為
```

> **成本控制**：只有在 history 真的溢出時才呼叫 summary（短對話零成本）；
> 一回合最多一次 summary 呼叫。

---

## 5. `HistorySummarizer` 設計

### 5.1 介面與落點

- 新檔 `app/application/prompts/history_summarizer.rb`，`Tyla::Prompts::HistorySummarizer`。
- `new(llm_client:)`；`#call(turns:, token_cap:) -> String | nil`。
  - 內部以新 system prompt 把 `turns` 序列化後丟給 `llm_client.send_prompt(
    system_prompt:, user_message:, max_tokens: token_cap, tools: [])`。
  - **rescue `Infrastructure::LlmError::*` → 回 `nil`（fail-open）**，不讓整個 turn 失敗。
  - 無 tools（純文字摘要）。
- 新 prompt 教材 `app/application/prompts/history-summary.md`（對齊既有
  [`guard-judge.md`](../app/application/prompts/guard-judge.md)）。摘要啟發直接採
  〔CE〕的 compaction 準則：
  - **保留**：學生的問題與**誤解 / bug**、已給的建議與**決定**、出現過的**檔名 / 函式名**；
  - **丟棄**：冗餘的 tool / file 輸出（〔CE〕："discard redundant tool outputs"）；
  - **調校順序**：先衝 **recall（寧可多留、別漏關鍵）**，再逐步收 **precision**；
  - 不得杜撰。

### 5.2 assembler 改動（budget 腦袋仍在這）

- `BudgetAwarePromptAssembler.call(..., history_summarizer: nil)` 新增**可選注入**參數。
  - `nil`（既有測試／不需要時）→ 行為等於今天的 drop（向後相容）。
  - 有注入時 → 走 §4 step 3 的「丟不下就摘要」。
- 新常數 `SUMMARY_TOKEN_CAP`（例如 400），summary 區塊與其 `max_tokens` 共用此上限。
- summary 放進 system prompt 的獨立區塊
  （[`TutorSystemPrompt.build`](../app/application/prompts/builders/tutor_system_prompt.rb)
  新增可選 `history_summary:` → 渲染 `## Earlier Conversation (summary)`），
  語意上明確標示「這是背景摘要，不是真正的學生發言」。

### 5.3 `RunTutorChat` 改動

- 在
  [`assemble_prompt`](../app/application/services/tutor_chat/run_tutor_chat.rb)
  之前用 credentials 建一個 `HistorySummarizer.new(llm_client: LlmClient.for(...))`
  並傳進 assembler（可把 `request_tutor_reply` 內建 client 的動作上移、建一次共用）。
- **ROP railway 不變、不新增 failure tag**：summary 失敗是 fail-open（回 nil），
  不會變成 `Failure`。

---

## 6. 風險

- **`edit_file` 需 exact search 字串**（見
  [2026-06-04-response-design-challenges-report.md](./2026-06-04-response-design-challenges-report.md)
  Case 1）：history 摘要無妨（history 不會被 patch）；**workspace/file_context 維持
  整塊不壓縮**正是為此。
- **summary 呼叫吃學生 quota，且自身 input 也受 8K 限**：input 受 transport 層
  `MAX_HISTORY_BYTES` 上界保護；必要時對丟給 summarizer 的 turns 再設一個輸入上界。
- **延遲**：summary 呼叫在主 tutor 呼叫之前、序列發生 → 回應時間增加（已接受）。
- **有損 + 無狀態**：每回合重算，模型看到的 history 與學生端原文會分歧（server-side
  only，可接受）；無狀態代價是重算舊內容，但省掉 schema/contract 改動。
- **Tokenizer 是 heuristic（chars/3.5）**：壓縮率 ≠ token 節省率，需 §7 Phase 0 實測校準。

---

## 7. 實作階段

- **Phase 0 — 先量測（零風險，建議先做）**：用既有 pre-call 估計（`Tokenizer`）+
  post-call 實際值（`usage.input_tokens`，見
  [`LlmResponse`](../app/infrastructure/llm/llm_response.rb)）加 server-side log，
  確認 token 花在哪、history 多常溢出。`Tokenizer` 註解本來就要求 post-deploy 校準。
- **Phase 1 — `HistorySummarizer` + assembler 注入 + summary 教材**（本案主體）。
  - 新檔：`history_summarizer.rb`、`history-summary.md`、對應 spec。
  - 改檔：`budget_aware_prompt_assembler.rb`（注入 + 兩段式 budget）、
    `tutor_system_prompt.rb`（可選 `history_summary:`）、`run_tutor_chat.rb`（建並傳
    summarizer）。
  - controller / routes / DB **零改動**。
- **Phase 2（並行、可選）— 策略 A**：人工精簡 persona/assignment/solution 教材，
  直接砍掉最大的 5K 固定成本。無程式風險。

> **前端先行依賴**：膨脹的另一半源頭在前端 `file_context`（每回合幾乎塞進全部 R 檔、
> 且無 token 上限）。見前端計畫
> [`MindyCLI_demo/plans/2026-06-06-frontend-context-optimization.md`](../../MindyCLI_demo/plans/2026-06-06-frontend-context-optimization.md)。
> 〔CE〕「最便宜的 token 是沒送出去的那個」→ **前端 F1（收緊檔案比對）+ F2（file_context
> token cap）應先於本案 Phase 1**：前端先讓出 budget，後端 rolling summary 才有空間落地，
> 否則 file_context 仍會把 history 連同 summary 一起擠掉。兩邊的 `FILE_CONTEXT_TOKEN_CAP`
> ↔ `SUMMARY_TOKEN_CAP` 需在各自 Phase 0 一起校準。

---

## 8. 待決定（剩餘小決策）

1. `SUMMARY_TOKEN_CAP` 的值（暫定 400；Phase 0 量測後定）。
2. 保留幾個最近 turn 一定 verbatim（例如至少最後 1 對 Q/A），還是純靠 budget 決定？
3. summary 失敗時除了 fail-open，要不要也補一行 server log 方便觀察觸發率？（建議要。）
4. Phase 0 的量測 log 是否現在就先加（零風險、能直接給數據）？
5. 策略 D（just-in-time / `load_file`）要不要納入本案範圍？最小作法：workspace 改為
   「正在編輯的檔案預載 + 其他檔案只給路徑清單」，並在 `## Tool Use Guide` 加強引導
   tutor 用 `load_file`。近零成本，但要確認不傷現有 `edit_file` 的 exact-match 流程。

   **`load_file` 的正確運作模式（已釐清）**：它是**對前端中介、跨回合**的請求，
   **不是後端讀本地暫存檔**。理由：
   - 學生 workspace 檔案在**前端**，後端 stateless、手上只有這次 `file_context` 送來的
     內容；對「前端沒送的檔案」後端無從載入——而那正是 `load_file` 的用途。
   - 後端暫存檔 = 跨 request 的**後端狀態**，與決策 2（無狀態）矛盾；且前端已送的內容
     本就在 request 記憶體裡，落地成檔只多 I/O / 並發 / 清理 / 安全面，零收益。
   - 後端 server-side `load_file` 需要「送→tool_use→讀→再送」的 agentic loop，但現行
     `RunTutorChat` 是**單次 `send_prompt` + 把 tool_calls 當 actions 原封回傳前端**，
     不 loop。改 loop = 每回合多次 LLM 呼叫、在 8K 下可能比預載更貴。

   結論流程：回合 N 後端只放「路徑清單 + 正在編輯的檔案」→ tutor 產生 `load_file`
   action（path）→ 原封回傳前端 → 回合 N+1 前端讀真實檔放進 `file_context`。
   無狀態、零額外後端 LLM 呼叫、無暫存檔；代價僅多一個 user 回合的延遲。
