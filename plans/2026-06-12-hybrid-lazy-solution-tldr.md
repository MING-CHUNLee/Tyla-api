# Hybrid Lazy Loading — 一頁 TL;DR + 風險重排

**Date:** 2026-06-12
**Status:** 未定案（先量測再決定是否實作）
**完整實作分析：** [2026-06-11-hybrid-lazy-solution-implementation.md](./2026-06-11-hybrid-lazy-solution-implementation.md)
**評估前置：** [2026-06-11-lazy-context-loading-evaluation.md](./2026-06-11-lazy-context-loading-evaluation.md)（§4 hybrid 方案）

> 這頁是給「隔天回來三十秒 reload」用的。要看論證、code sketch、spec 清單請進完整文件。

---

## 30 秒摘要

**問題**：今天每次家教對話，後端都把老師參考解答塞進 system prompt——不管學生問的是不是解題相關。解答約 **2.3K input tokens**，很多回合根本用不到。

**提案**：解答平常不載入；只有模型自己判斷「這題需要對照解答」時，才透過新 tool `load_reference` 去要。解答內容**永遠只在 server 端**，不回傳前端。

**怎麼做（唯一要記的機制）**：不走教科書 `tool_result` 續傳（那要重寫兩個 LLM client，§1.1），改用 **Re-assemble 重新組裝**——
- **Round 1**：system = persona + 作業 + manifest（只說「有解答可調閱」）；工具含 `load_reference`。
- 模型沒要 → 直接結束（同今天，省解答 token）。
- 模型要了 → **Round 2**：重組 system 把解答塞進去 + **從工具拿掉 `load_reference`**，同一組 user message 再呼叫一次。Round 2 必為終點（工具沒了，物理上不能再要）。

**現況**：一行 code 都還沒動（檔案未進 git，`load_reference` 不存在於任何 `.rb`）。文件標「未定案」。

---

## 決策狀態

| 已定 | 待量測後定 |
|---|---|
| 走 Re-assemble，不走 tool_result（避開重寫兩 client） | hybrid 要不要上 production，還是只當論文對照組 → 看 **D2** |
| 分流邏輯活在 prompt 指引，不加後端分類器 | 是否需要 D1 的選項 B（client 回送 `reference_requested`）→ 看重複載入率 |
| 解答內容永不回傳 client（只多 `warnings: reference_loaded` 訊號） | 先做本案還是先做 compression → 看 **D8** |
| 終止為結構性保證（round 2 無此 tool）、guard 路徑零改動 | |

---

## 待量測數字（Phase 0，決策的依據）

| 數字 | 為什麼要量 | 門檻 / 用途 |
|---|---|---|
| **調閱率**（模型要 `load_reference` 的回合佔比） | 決定 hybrid 是省錢還是反而更貴 | **> ~50% → hybrid 開始虧**（D3） |
| **品質劣化**（eager vs hybrid 在 evaluation set 的回答品質） | 模型偷懶不調閱會靜默劣化 | 劣化顯著 → hybrid 只當論文對照組（D2） |
| **同一對話內重複載入率** | 後端 stateless，多輪每輪都要重載 | 高 → 考慮上 D1 選項 B |
| **token / round 分布**（round 數、兩輪 input_tokens） | 成本基線 | Step 4 的 Phase 0 log |

> 為什麼先量再做：evaluation 文件 §4 把實作排在量測之後，就是因為「真實調閱率沒人知道」，而它直接決定整個方案的成本論證成不成立。

---

## 安心邊界（看起來大、其實被框住的）

- **不產生新的爆量(413)路徑**：round 2 base = 今天 base，今天放得下的 round 2 必放得下（單調性）。
- **洩題面沒變大**：解答內容在任何 response 欄位都不出現；唯一外洩是 `warnings: reference_loaded`（不含內容）。
- **guard 路徑零改動**；終止是結構性的，不靠 prompt 勸模型。
- **每步獨立綠燈**：動到 3 個核心檔，但可分開提交（完整文件 §5）。
- **manifest 責任分屬兩 repo**（S1）：課程素材的 manifest 後端自己列得出（固定 loader + tool `enum` 白名單 → 路徑幻覺不可能）；學生 workspace 的 manifest 後端看不到檔案系統、列不出，必須由前端塞進 `file_context`。**本案後端只新增「課程素材」那半邊；workspace 那半邊是前端（MindyCLI_demo / B3）的事。**

---

## 風險重排（按「會不會真的擋住你」排序）

> 原文件 §4 按 D1→D8 編號（D1 自稱「最大缺陷」）。這裡保留原編號方便回查，但**按實際嚴重度重排**：能否上線的存亡題在最上面，已知且可接受的代價在最下面。

### 🔴 Tier 1 — 真正的 BLOCKER（先解決這三個再談實作）

**D2 — 品質靜默劣化（hybrid 的本質賭注）**
模型若憑常識回答「怎麼寫比較好」而不調閱解答，回答品質會悄悄變差——**學生看不出、論文評測看得出**。今天解答永遠在場，建議永遠有 ground truth；hybrid 把這個保證拿掉了。這不是 bug，是 lazy loading 的固有代價。**唯一防線**：Step 2 的 manifest 措辭 + Phase 0 用 evaluation set 對比 eager/hybrid。**若劣化顯著，hybrid 只能當論文對照組，不能當 production 預設。**

**D3 — 成本反轉（推翻省錢的初衷）**
反向風險：tool description 太誘人 → 模型每輪都調閱 → 每輪固定兩次呼叫，**比 eager 更貴**（eager 一次呼叫多付 2.3K input；兩次呼叫 = 重付整個 base ~2-3K + 兩次 output）。**損益平衡點約調閱率 50%**。CSDS 家教場景的真實調閱率沒人知道——**這就是 Phase 0 必須先量的核心數字**。

**D8 — 與 compression 計畫撞同一批檔（排程 blocker）**
本案與 HistorySummarizer 都動 `budget_aware_prompt_assembler.rb` / `run_tutor_chat.rb` / `tutor_system_prompt.rb`，**不可並行開發**。順序有講究：**先做本案**（縮小 round 1 base → 送給 history 更多預算 → compression 觸發率下降、校準值會變）；或反序但 `SUMMARY_TOKEN_CAP` 要重跑校準。**動手前必須先定這個順序。**

### 🟠 Tier 2 — 嚴重、會塑造設計（不擋上線，但要先想清楚）

**D1 — 跨 turn 無 stickiness（後端 stateless 撞牆）** *（原文件稱「最大缺陷」，實為 D3 在多輪上的放大）*
解答只活在 round 2 的 system prompt，不進 history、不回傳 client。下一個 user turn 從零組裝 → 模型必須**再次**調閱 → 改作業型多輪對話**每輪都付兩次呼叫**，對話越深、hybrid 的成本優勢越被吃掉甚至反超。
- **A（Phase 1 定案）**：接受重請求，round 1 很便宜，量測後再說。
- **B（量測後可能上）**：client 回送 `reference_requested: true`；改 request contract（向後相容），洩題面不變。
- **C：否決**——後端從 history 嗅探（history 是 client 自由文字，可偽造可誤判）。

**D5 — 延遲上界翻倍，疊 B3 是乘法**
單請求最壞 = 2 × READ_TIMEOUT(30s)。疊上 B3 前端 `MAX_CONTINUATIONS=3` → 一個 user turn 最壞 **8 次 LLM 呼叫**（機率低但存在）。**跨 repo 行動項**：前端 gateway timeout 必須 > 兩輪上界（查 `MindyCLI_demo`）。

### 🟡 Tier 3 — 已知代價，記錄並接受（不需先解決）

**D4 — round 1 的 prose 被丟棄**：模型常在 tool call 前先寫一段話，Re-assemble 下全丟。通常是好事（半成品不該給學生），但若「完整回答 + 順手調閱」同輪，會丟掉一個本可終端的好回答。無解，記為已知代價。

**D7 — `load_reference` 向模型暴露「有解答」**：tool 定義與 manifest 只進 LLM payload、不進 response。唯一外洩是 `warnings: reference_loaded`（學生知道「這次查了參考資料」，不含內容）。對論文 demo 反而是可解釋性加分；若在意，改成只進 server log。

**D6 — 兩輪間 prefix 不穩，未來上 prompt caching 會痛**：solution 注入在 prompt 中段，round1/2 共同前綴只到 manifest。目前無 caching、無影響；未來上 Anthropic prompt caching 時把 solution 移到可快取前綴之後。現在記下免得未來踩。

---

## 下一步（不是「開始實作」，是「解鎖實作」）

1. 定 **D8** 的開發順序（本案 vs compression）——這是動手前的第一個閘門。
2. 跑 **Phase 0** 量測：調閱率、品質劣化、重複載入率（產出 D2/D3/D1 的決策數據）。
3. 看調閱率與品質：決定 hybrid 是 production 預設、還是純論文對照組。
