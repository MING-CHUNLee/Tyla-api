# Backend Agentic Loop — 評估與決策

**Date:** 2026-06-07
**Status:** 評估中（方向＝認真評估 B；目標＝產品與論文兼顧）
**Scope:** `POST /api/v1/tutor_chats` 收到 `prompt + file_context` 後，「誰決定做什麼任務、
要不要載入檔案、要不要在單一 user turn 內 read→edit」的編排架構。
**參考（本案直接延伸 / 牴觸這三份）:**
- [2026-06-06-prompt-compression-mechanism.md](./2026-06-06-prompt-compression-mechanism.md)
  — §8.5 已鎖定「`load_file` 對前端中介、跨回合、無狀態，**不做後端 loop**」。本案重新檢視此決策。
- [2026-06-04-action-reliability-issue.md](./2026-06-04-action-reliability-issue.md)
  — actions 已改用 native tool_use；`edit_file` / `execute_script` / `load_file` 是現成 tools。
- [2026-06-04-response-design-challenges-report.md](./2026-06-04-response-design-challenges-report.md)
  — actions 觸發規則改為「學生意圖」、禁止 confirmation reflex。
- Anthropic, *Effective context engineering for AI agents*〔CE〕。

---

## 0. TL;DR

1. 你圖上畫的是**後端主導的 agentic loop**（prompt → LLM read → Tyla 給檔 → LLM edit → status）。
   它直接踩到 §8.5 已鎖定的相反決策——所以要嘛推翻、要嘛找一個能共存的版本。
2. **B 有三種做法**（§3）：B1 後端內部 loop、B2 雙向 callback、**B3 前端驅動的自動續傳**。
   三者成本差非常多。
3. **關鍵發現：B3 後端幾乎零改動、且不推翻 §8.5，而是「消費」它。** loop 不住在後端、
   住在前端驅動器；後端維持單次 `send_prompt`、stateless、8K 內。§8.5 唯一被改寫的，是
   「`load_file` 是普通的下一個 user turn」→「`load_file` 觸發前端自動續傳」。
4. **task routing 不另加分類器**：guard 已是一個 pre-pass，模型在單次呼叫用 tool_use 決定已足夠。
5. **建議**：Phase 1 做 B3（最小代價拿到 read→edit 的 agentic 體驗，可量測）；B1 留作 Phase 2
   的「backend-as-agent」研究變體——若論文需要那個敘事再做。

---

## 1. 你的圖在問什麼

附圖由上而下：

```
USER-TUI         USER-API            LLM
USER: <prompt>  ───────────────────► LLM: <read action>      (load_file)
                TYLA: <file>  ◄────── （把檔案餵回 LLM）
                              ───────► LLM: <edit action 2>   (edit_file)
                TYLA: <status>        TYLA: <status>
```

語意＝**在同一個 user turn 內**，系統要能「先讀一個還沒在 context 裡的檔案、再據此編輯」。
這混了三個其實不同的子問題，先拆開：

| 子問題 | 現況（已 ship） | 本案要不要改 |
|---|---|---|
| **(1) 誰決定做什麼任務** | tutor LLM 單次呼叫內用 native tool_use 隱式決定 | **不改**（見 §6.1） |
| **(2) 要不要 / 如何載入檔案** | `load_file` 是現成 tool，當 action 原封回前端 | 改觸發時機（§4） |
| **(3) 後端要不要 agentic loop** | 否——單次 `send_prompt`，不 loop | **本案主體**（§3） |

---

## 2. 決定性限制（任何 B 方案都繞不開）

1. **檔案在前端**：後端 stateless，手上只有這次 request 送來的 `file_context`。對「前端沒送的
   檔案」後端無從自取——而那正是 `load_file` 的用途。
2. **Stateless REST**：[`RunTutorChat`](../app/application/services/tutor_chat/run_tutor_chat.rb)
   每個 request 獨立，無跨 request 記憶。
3. **GitHub Models 8K hard cap**（hot path）：每次 LLM 呼叫的 input 受
   [`BudgetAwarePromptAssembler`](../app/application/prompts/builders/budget_aware_prompt_assembler.rb)
   壓在上限內；loop 的每一圈都得重新塞進 8K。

> 推論：B 的真正難點不是「寫一個 while 迴圈」，而是「**後端如何在 turn 中途拿到前端的檔案**」。
> 三種 B 方案的差別，本質就是這個問題的三種答案。

---

## 3. B 的設計空間（三種，成本差很多）

| | B1 後端內部 loop | B2 雙向 callback | **B3 前端驅動續傳（推薦）** |
|---|---|---|---|
| 後端怎麼拿到檔案 | 前端**一次上傳整個 workspace**，後端從 pool 取 | 後端 turn 中途**回呼前端**要檔（SSE/WS/callback URL） | 前端收到 `load_file` action → 讀檔 → **重發 POST**（同 prompt、`file_context` 加上該檔） |
| loop 住在哪 | 後端（內部多次 `send_prompt`） | 後端（被 callback 阻塞） | **前端驅動器**（後端仍單次呼叫） |
| 後端改動 | 大（變成 mini-agent + budget 每圈重組 + max-iter） | 大（新傳輸層 + 放棄 stateless） | **近零**（見 §4） |
| contract 改動 | `file_context:String` → `files[]` bundle | 新增 callback 協定 | **無**（§7） |
| stateless | 保留（pool 用完即丟） | **破壞**（turn 中途需保持連線/狀態） | **保留** |
| transport 成本 | 高（每 turn 整包 workspace） | 中 | 低（只多送被載入的檔） |
| LLM 呼叫/turn | 多（一個 HTTP request 內） | 多 | 多（**分散在多個 stateless request、pay-per-use**） |
| 單一 request 延遲 | 長（loop 全包在一個 request → timeout 風險） | 長 | 每個 request 短，總延遲＝N 次 round-trip |
| 研究敘事 | 「**後端就是 agent**」最強 | 無特別加分、複雜 | 「**stateless API 上的前端編排式 agentic tutoring**」 |
| 主要工作落點 | 後端 | 後端 + 傳輸 | **前端（MindyCLI_demo）**，後端近零 |

- **B2 直接淘汰**：破壞 stateless、需要長駐連線，與整個 REST 設計與 8K hot path 都不合，
  且不帶來 B1/B3 沒有的好處。
- **B1 vs B3** 是真正的取捨，見 §4。

---

## 4. 建議：B3（前端驅動續傳），後端零 contract 改動

機制（對照 §1 的圖）：

```
回合 N (turn t):
  POST /tutor_chats { prompt, guard_log_id, history, file_context=「路徑清單 + 編輯中檔案」}
  → 後端單次 send_prompt → LLM 回 action: load_file(path=X)
  → 後端原封回傳 actions:[{type:load_file, path:X}]   ← 後端到此為止，跟今天一模一樣

前端驅動器（新邏輯，住在前端）:
  收到 load_file action → 讀 X → file_context' = file_context ⊕ X 的內容
  → 自動 重發 POST { 同 prompt、同 guard_log_id、同 history、file_context' }
  （不需要學生再輸入——這就是「單一 user turn 內 read→edit」的體驗來源）

回合 N 的第 2 次 POST:
  → 後端單次 send_prompt（這次 context 裡有 X）→ LLM 回 action: edit_file(...)
  → 前端套用 patch → 顯示 status
```

**為什麼後端零改動：**
- `load_file` 已是 [`TOOLS`](../app/application/services/tutor_chat/run_tutor_chat.rb#L57) 之一，
  已會以 action 形式原封回傳前端。
- 續傳就是「**同 prompt、加大的 `file_context`**」的另一次普通 POST。
  [`Request::TutorChat`](../app/application/requests/tutor_chat.rb) 的 `file_context` 是
  optional string，**塞得下**；不需要新欄位。
- guard：續傳 prompt 不變 → `guard_log_id` 對應的 row `prompt` 仍 match
  （[`derive_verdict`](../app/application/services/tutor_chat/run_tutor_chat.rb#L176) 的
  `guard_log.prompt == params[:prompt]`），**verdict 仍有效、無需重跑 guard、也無法被繞過**。
- loop 計數器天然住在前端驅動器（後端 stateless，根本不知道自己在 loop）。

**為什麼這不算「推翻 §8.5」、而是「消費」它：**
§8.5 反對後端 loop 的理由是「每回合多次 LLM 呼叫、在 8K 下可能比預載更貴」——B3 **仍會**多次呼叫，
但 (a) 只在真的 `load_file` 時才發生、pay-per-use，(b) 分散在多個 stateless request、無單一長 request
的 timeout 風險。§8.5 唯一被改寫的一句，是把 `load_file` 從「普通的下一個 user turn」升級成
「**前端自動續傳**」。其餘（無狀態、無暫存檔、無後端 agentic loop）全部保留。

### 4.1 與 Claude Code 的對照（佐證「為什麼 B3」與「為什麼 Tyla 不能收掉後端層」）

Claude Code（本機 agent CLI）就是 B3 的精神：**loop 跑在「檔案所在的那一側」，LLM 維持 stateless。**

| Claude Code | Tyla | 角色 |
|---|---|---|
| 本機 harness（CLI） | TUI 前端 | **持有檔案 + 驅動 loop** |
| Anthropic API | LLM provider | stateless，只回應每次請求 |
| —（沒有） | **Tyla API 後端** | ← 這層 Claude Code 沒有 |

Claude Code 的迴圈：harness 送對話 + tools 給 API → 模型回 `tool_use`（Read/Edit）→ **harness 在本機
讀檔/改檔** → `tool_result` 接回去再送 → 重複。檔案就在本機，harness 自己 resolve `load_file`，API 全程
無狀態。這正是 B3 核心：**持檔的一方 resolve 工具、驅動續傳；LLM 不記狀態。**

**關鍵差別——Tyla 不能像 Claude Code 收掉中間層：**
Claude Code 只有兩層（harness 直連 LLM），因為使用者擁有所有本機檔案、沒有要對使用者保密的東西。
Tyla 的整個重點卻是 **reference solution / answer key / persona / guard 必須留在 server、絕不能到學生
機器**。所以：

> **Tyla 的 B3 ≠ 前端直連 LLM。** 每一圈續傳都得**繞回後端**，讓後端重新組裝帶著機密 reference
> solution 的 system prompt、並驗證 guard，才呼叫 LLM。
>
> 一句話：**Claude Code =「B3 但前端直連 LLM、無後端」；Tyla =「B3 但每圈都過一次 stateless 後端
> 注入機密 context」。** 後端那層是 Tyla 為了「保密教材 + server-side guard + log」付的代價。

**兩個延伸推論：**
1. **決定 vs 執行要分清**：「要不要載入」由 **LLM**（provider 側發 tool call，即 §6.1 的隱式 routing）；
   「resolve 那個載入（讀真實檔）」由**持檔側**（Claude Code＝本機 harness；Tyla＝前端 driver）。
2. **成本控制更吃緊**：Claude Code 靠 **prompt caching** 壓「每圈重送對話」的成本；Tyla hot path 是
   GitHub Models 8K，caching 不一定有、每圈都要硬塞進 8K → **Tyla 的 loop 比 Claude Code 更依賴
   §5 的 just-in-time + rolling summary**。這反過來強化了「B3 依賴 file_context 結構化先落地」。

---

## 5. B3 與 compression plan 的耦合（重要：B3 需要 §8.5 那塊）

B3 不是獨立的——它讓 `file_context` **在一個 user turn 內跨多次 POST 成長**，這放大了
compression plan 既有的弱點：

1. **`file_context` 是 whole-or-drop**：assembler 對 workspace 整塊放或整塊丟
   （[budget_aware_prompt_assembler.rb:58-66](../app/application/prompts/builders/budget_aware_prompt_assembler.rb#L58)）。
   loop 載入越多檔 → `file_context` 越大 → 某一圈整塊超過 budget 被丟 → 剛載入的檔消失 →
   LLM 又發 `load_file` → **無限 loop**。
   → **對策**：採 §8.5 策略 D 的 just-in-time——`file_context` 改「路徑清單 + 已載入檔」結構，
   並對單檔/總量設 `FILE_CONTEXT_TOKEN_CAP`；超量時走 per-file 取捨而非整塊丟。
2. **8K 預算競爭**：loop 後期 context（教材 + 多個已載檔 + history）很容易撞 8K。
   → rolling summary（compression plan Phase 1）壓 history，把預算讓給已載入的檔。
3. **校準**：`FILE_CONTEXT_TOKEN_CAP` ↔ `SUMMARY_TOKEN_CAP` 要一起在 Phase 0 量測定值。

> 結論：**先有（或至少同時做）compression plan 的 just-in-time `file_context` 結構化，B3 才穩**。
> 否則 whole-or-drop 會讓 loop 自我中毒。這也回答了「我們現在適不適合做」——
> **B3 的前置條件是 file_context 的結構化，那件事本來就在 §8.5 的待辦裡。**

---

## 6. 三個子問題的明確答案

### 6.1 (1) task routing — 不要另加分類器
現況：tutor LLM 在單次呼叫用 tool_use 隱式決定要不要 `edit_file` / `execute_script` / `load_file`
（2026-06-04 已 ship 並調校過觸發規則）。再加一個獨立「先分類任務」的 LLM 步驟會：多一次延遲、
多一筆學生 quota、多一個會判錯且與 tutor 判斷不一致的點。guard 已經是 incoming 的 pre-pass。
**保持隱式 routing。** loop 本身（§4）就是「讀完再決定下一步」的 routing。

### 6.2 (2) load_file 機制 — 前端驅動續傳（§4）
跨多次 stateless POST、`file_context` 結構化成長（§5）、guard 因 prompt 不變而續傳安全。

### 6.3 (3) agentic loop — 在前端、有界
loop 住在前端驅動器，後端無感。**必須有 max-iterations 上界**（建議 2~3）與終止條件（§7、§9）。

---

## 7. 具體要改什麼

**後端（本 repo）— 近零：**
- 程式碼：**不需要改 `RunTutorChat` / contract / routes / DB**。B3 是現有單次語意的重複呼叫。
- 唯一可能要動的是配合 §5 把 `file_context` 結構化（路徑清單 + 已載檔 + cap）——但那是
  compression plan §8.5 的工作，不是 B3 新增的。
- 建議補一行 server log：記錄本次 request 是否含 `load_file` action、`file_context` token 量，
  供 Phase 0 量測 loop 深度與成本（零風險）。

**前端（MindyCLI_demo）— 主要工作：**
- 新增 **continuation driver**：收到 `actions` 含 `load_file` → 解析 `path` → 讀檔 →
  併入 `file_context` → 自動重發 POST（同 prompt / guard_log_id / history）。
- **max-iterations 上界** + 計數；達上界仍要 `load_file` → 停止並把「已達載入上限」回饋給使用者/下一圈。
- **路徑安全**（見 §9）：driver 只允許讀**學生 workspace 內**的相對路徑；拒絕跳脫
  （`..`、絕對路徑）與任何會解析到 reference solution / persona / answer-key 的路徑。
- 對「檔案不存在 / 被拒」的 `load_file`：回一個明確的錯誤標記放進 `file_context`，讓模型停止重試。

> 工作量分布：**B3 的大頭在前端**，與 compression plan 的「前端先行依賴」一致——兩份前端工作可一起做。

---

## 8. 研究框架（for 論文目標）

把 B3 寫成可發表的貢獻，需要明確的問題與量測：

**Research question（候選）**：
> 在一個 **stateless、token 受限（8K）的 REST tutoring API** 上，能否以**前端驅動的續傳**
> 取得可靠的多步 agentic 檔案操作（read→edit），且成本/延遲可控？相對於「單次 + 跨回合手動」與
> 「整包預載」兩種 baseline，品質/成本如何權衡？

**Baselines（對照組）**：
1. **A**：單次呼叫 + `load_file` 當普通下一個 user turn（§8.5 原案，需學生再輸入）。
2. **B3**：前端自動續傳（本案）。
3. **Full-preload**：每 turn 直接把整個 workspace 塞進 context（撞 8K、無 loop）。
4.（可選）**B1**：後端 internal loop（backend-as-agent）。

**Metrics**：
- 任務成功率：需要 read→edit 的情境，actions 是否正確產生並可套用（延續
  [response-design-challenges-report](./2026-06-04-response-design-challenges-report.md) 的案例集）。
- loop 深度分布（多少 turn 需要 1/2/3+ 次續傳）。
- 每個被解決任務的**額外 LLM 呼叫數與 token 成本**（pre-call `Tokenizer` 估計 vs
  post-call `usage.input_tokens`）。
- 端到端延遲（A 的「多一個 user 回合」vs B3 的「N 次自動 round-trip」）。
- just-in-time vs full-preload 的 token 節省率（§5 的 cap 效果）。

> 論文敘事兩條都成立：**產品**＝seamless read→edit；**研究**＝「stateless API 上的有界前端編排」
> 是一個和 §8.5、CE 框架對齊的設計點（最便宜的 token 是沒送出去的那個；just-in-time 取檔）。

---

## 9. 風險

- **無限 loop / 自我中毒**：§5 的 whole-or-drop 把剛載入的檔丟掉 → 反覆 `load_file`。
  對策：先做 file_context 結構化 + cap + **前端 max-iterations 上界**。
- **路徑安全（最關鍵）**：B3 讓模型「指名要哪個檔」並自動被讀回。必須在前端 driver 強制：
  限學生 workspace 相對路徑、擋 `..`/絕對路徑、**永不讓 `load_file` 解析到 reference solution /
  persona / refusal 教材**。否則等於開了一條 exfiltration 通道。guard 雖會評分，但 driver 的
  path allowlist 才是硬防線。
- **延遲累加**：N 次續傳＝N 次 round-trip；N 必須小（2~3）。
- **成本**：多次 LLM 呼叫吃學生 quota；pay-per-use 但要在 §8 量測實際分布。
- **前端依賴**：B3 大頭在 MindyCLI_demo；後端先準備好（已就緒）但體驗要前端 driver 才成立。
- **與 compression 的順序**：B3 穩定**依賴** §8.5 的 file_context 結構化先落地（§5）。

---

## 10. 建議階段

- **Phase 0 — 量測（零風險，先做）**：在後端加 log（request 是否含 `load_file`、`file_context`
  token 量、`usage.input_tokens`）。先收一批真實/腳本化對話，量「多少 turn 真的需要 read→edit」、
  「loop 會多深」。沒有這個數據，B1 vs B3 的成本論證只是猜測。
- **Phase 1 — B3 最小實作**：
  - 後端：零程式改動（+ Phase 0 的 log）。
  - 前端：continuation driver + max-iter + path allowlist。
  - 前置：file_context 結構化（與 compression §8.5 策略 D 合併做）。
  - 產出：§8 的 A vs B3 vs full-preload 對照數據。
- **Phase 2（可選、研究變體）— B1 backend-as-agent**：只有當論文需要「後端就是 agent」的敘事、
  且 Phase 0 顯示 loop 夠常見/夠深、值得把 loop 移進後端時才做。代價：contract 改 `files[]` bundle、
  後端 budget 每圈重組、單 request 長延遲/timeout 處理。

---

## 11. 待決定

1. **B3 vs B1 的最終取捨**：預設 B3（§4）。若論文評審/貢獻點明確要 backend-as-agent，才升 B1。
2. **max-iterations 值**（暫定 2~3；Phase 0 量測後定）。
3. **file_context 結構化** 要在本案做、還是併回 compression plan §8.5 做？（建議併回，單一真相源。）
4. **path allowlist 規則** 的精確定義（哪些前綴/檔名永遠禁止 `load_file`）。
5. Phase 0 的 log 是否現在就先加？（建議要，零風險、直接給 B1/B3 決策數據。）
