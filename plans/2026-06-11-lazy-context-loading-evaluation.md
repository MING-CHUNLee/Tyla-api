# Lazy Context Loading（按需載入課程素材）— 提案評估

**Date:** 2026-06-11
**Status:** 評估記錄（提案討論，未定案）
**相關計畫：**
- [2026-06-07-backend-agentic-loop-evaluation.md](./2026-06-07-backend-agentic-loop-evaluation.md)（B1/B2/B3 選型）
- [2026-06-07-b3-frontend-continuation-driver.md](./2026-06-07-b3-frontend-continuation-driver.md)（B3 設計）
- [2026-06-06-prompt-compression-mechanism.md](./2026-06-06-prompt-compression-mechanism.md)（budget pipeline）
- [2026-06-08-plan-decisions-summary.md](./2026-06-08-plan-decisions-summary.md)（已鎖定決策）

---

## 0. 提案內容（原始想法）

現況：後端每次 `/tutor_chats` 都自動把 `spec/fixtures/assignments/CSDS-HW2`
的素材全部組進 prompt，因此需要 `BudgetAwarePromptAssembler` 做預算裁切。

提案改成 **lazy loading**：

1. 預設不載入任何課程素材；等 LLM 呼叫 `load_file` 才去後端找。
2. **Scenario 1**：學生問「What are the submission requirements?」
   → LLM 應呼叫 `load_file` 詢問 → 下一回合後端供給
   `assignment/HW 02.docx.txt`。
3. **Scenario 2**：學生問「HW 要怎麼寫比較好？」
   → 同時供給 `assignment/HW 02.docx.txt` 與 `solutions/Hw2.Rmd`。

---

## 1. 現況確認（提案的前提是對的）

`run_tutor_chat.rb#assemble_prompt` 每次請求**無條件**載入四個 fixture：

| 素材 | Loader | 大小 | 在 assembler 中的地位 |
|---|---|---|---|
| persona（TUTOR.md） | `TutorPersonaLoader` | ~1.7 KB | **mandatory**（base） |
| assignment（HW 02.docx.txt） | `AssignmentLoader` | ~5.2 KB ≈ 1.3K tokens | **mandatory**（base） |
| solution（solutions/Hw2.Rmd） | `SolutionLoader` | ~9.2 KB ≈ 2.3K tokens | **mandatory**（base） |
| student file（student-files/Hw2.Rmd） | `StudentFileLoader` | ~9.2 KB | droppable（workspace slot，`file_context` 存在時被抑制） |

`budget_aware_prompt_assembler.rb` 的存在理由正是「全量 eager 載入 + 8K 預算」
→ 必須裁切。**確認：提案對現況的理解正確。**

---

## 2. 提案的三個問題（評估結論）

### 2.1 ⚠️ Solution 走 `load_file` = 直接洩題（最關鍵的遺漏 scenario）

已定案的 B3 是**前端驅動續傳**：`load_file` 由前端 driver 消費——前端讀檔、
塞進 `file_context`、重發 POST。內容會流經**學生的機器與學生可見的 channel**。

B3 設計（決策摘要 §三・安全模型）明寫：

> 保護對象是學生自己的機器…不是課程機密（reference solution 在 server，
> `load_file` **物理上無法外洩**）。

若後端開始透過 `load_file` 回應 server 端素材，這條安全前提即失效：
solution 的全文會出現在前端的 tool 回灌內容裡，學生抓 client log 就拿到解答檔。
今天 solution 只存在於 server 端組出的 system prompt，**從不回傳給 client**——
這個性質必須保住。

**結論：solution 若要 lazy，不能走 B3 的 `load_file` channel，只能 server 端解決**
（後端攔截 tool call、同一個 HTTP request 內把 solution 注入 system prompt 後
再呼叫一次 LLM）——這就是被排到 Phase 2 的 **B1 mini-loop**。

### 2.2 Scenario 1 的素材（assignment）lazy 化是負優化

家教場景幾乎每一輪都需要 assignment spec（含 Scenario 1 自己）。Lazy 化後：

- 1 次 LLM 呼叫 → 2 次（第二次**重付整個 prompt** 的 input tokens）
- 延遲約 ×2（多一個完整 round trip）
- 省下的只是 ~1.3K tokens 的常駐成本

Lazy loading 的收益公式：**(命中率低 × 體積大) 才划算**。
Assignment 是「命中率極高 × 體積小」，是最不該 lazy 的素材。
Solution 是「命中率中等（只有改作業/怎麼寫類問題需要）× 體積大 × 敏感」，
才是正確的 lazy 候選。

### 2.3 Scenario 2 的「我們同時給兩個檔」——決定者是誰？

「學生問怎麼寫 → 後端同時給 assignment + solution」隱含後端要判斷學生意圖，
但這需要意圖分類器，違反已鎖定決策（agentic-loop evaluation §子問題 1：
「**不另加分類器**——tutor LLM 在單次呼叫用 tool_use 隱式決定」）。

正確做法：讓 **LLM 自己決定**要哪些檔，並在**同一輪用 parallel tool calls
一次請齊**（native tool_use 支援一個 assistant turn 多個 tool_use block），
這樣 Scenario 2 仍只多一個 round trip，不是兩個。

---

## 3. 其他遺漏的 Scenario

| # | Scenario | 問題 | 處理方向 |
|---|---|---|---|
| S1 | **LLM 不知道有什麼檔可以要** | 什麼都不預載時，`load_file` 的路徑只能用猜的（幻覺路徑） | system prompt 放**檔案 manifest**（logical name + 一行描述），這是 lazy 模式的必要前提 |
| S2 | **多輪對話的第 2+ 輪** | 第 1 輪載過 assignment，第 2 輪要重新請求嗎？不處理 → 每輪都多 1 round trip | 載過的非敏感素材標記為 sticky（前端在後續 `file_context` 重送，或 history 裡的 tool round 保留）；solution 永遠 server 端、不 sticky |
| S3 | **LLM 該問卻不問** | 模型反問學生「你有作業說明檔嗎？」而不是呼叫 tool → 浪費一輪、體驗差 | tool description + Tool Use Guide 明確指示「需要素材就直接 call，不要問學生」；eager 載入 assignment 直接消滅這個 case |
| S4 | **請求不存在的素材** | manifest 之外的路徑 | 回 marker（同 B3 §4.10「unavailable, do not request again」），勿 silent fail |
| S5 | **Lazy 載入的內容也要過預算** | 按需載入不等於不佔 token | server 端注入 solution 時仍走 assembler 的 budget；前端側已有 per-file/per-turn cap |
| S6 | **Guard verdict 沿用** | 續傳輪不重跑 guard 是否安全 | B3 已定案：prompt 不變 → verdict 沿用；server 端 mini-loop 同一 request 內更無此問題 |
| S7 | **每個 continuation 重付全 prompt** | lazy 不是免費：省常駐 token、換 round trip 成本 | Phase 0 log 量測「需要 solution 的輪次占比」，用數據決定 eager/lazy 分界 |

---

## 4. 建議方案：分層 eager/lazy（hybrid）

| 素材 | 策略 | 理由 |
|---|---|---|
| persona | **永遠 eager** | 是 policy/安全邊界，不可協商 |
| assignment | **eager**（維持現狀） | 小（~1.3K tokens）、幾乎每輪命中；lazy 化是負優化（§2.2） |
| solution | **lazy，但 server 端解析** | 大、敏感、命中率中等；LLM 以 tool 請求（如 `load_reference`，與 workspace 的 `load_file` 分開命名），後端在同一 HTTP request 內注入 system prompt 後重呼叫 LLM（bounded 1 iteration 的 B1 mini-loop）；**內容永不回傳 client** |
| student workspace files | **lazy（已定案）** | 走 B3 前端 continuation driver，按既有計畫實作 |
| manifest | **新增、eager** | 一行一檔的清單（logical name + 描述），lazy 模式的前提（S1） |

要點：

1. **兩個 tool、兩個解析端**：`load_file` = 前端解析（學生 workspace，B3）；
   `load_reference`（或同名但保留路徑 namespace）= 後端解析（課程素材）。
   混用一個 tool 會讓 solution 流向錯誤的 channel（§2.1）。
2. **Scenario 2 由 parallel tool calls 解決**，不加分類器（§2.3）。
3. **實作順序**：Phase 1 維持 solution eager（現狀）+ 完成 B3；
   Phase 0 log 加量測「含 solution 相關意圖的輪次占比」；
   數據支持再做 server 端 lazy solution（順便成為論文的 B1 研究變體——
   與 plan-decisions-summary 的 Phase 2 安排一致）。
4. Solution lazy 化後，`BudgetAwarePromptAssembler` 的 mandatory base 縮小
   （overflow 風險下降），但注入 solution 的那一輪仍要走同一套 budget。

---

## 5. 結論

- 提案對現況的理解**正確**：fixture 全量 eager 載入是 budget 演算法存在的原因。
- 「全部 lazy」**不建議**：assignment lazy 是負優化、solution 走 `load_file`
  會洩題、且缺 manifest 時 LLM 無從請求。
- 建議走 **hybrid**：persona + assignment + manifest eager；
  solution 為 lazy 的唯一候選且必須 server 端解析（= Phase 2 B1 變體，
  先用 Phase 0 數據驗證值不值得）；workspace files 照 B3。
- Scenario 2 的多檔供給由 **LLM parallel tool calls** 決定，不在後端做意圖判斷。
