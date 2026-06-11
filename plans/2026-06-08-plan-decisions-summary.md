# 計畫決策整理

**Date:** 2026-06-08
**涵蓋計畫：**
- [2026-06-06-prompt-compression-mechanism.md](./2026-06-06-prompt-compression-mechanism.md)
- [2026-06-07-backend-agentic-loop-evaluation.md](./2026-06-07-backend-agentic-loop-evaluation.md)
- [2026-06-07-b3-frontend-continuation-driver.md](./2026-06-07-b3-frontend-continuation-driver.md)
- [2026-06-07-b3-implementation-steps.md](./2026-06-07-b3-implementation-steps.md)

---

## 一、Prompt Compression Mechanism（2026-06-06）

### 已鎖定決策（3 條）

| # | 決策 | 理由 |
|---|---|---|
| 1 | 每回合接受多一次 LLM 呼叫，採 **LLM rolling summary** 壓縮 history | History 在 8K 下幾乎永遠被整批丟棄，需要語意濃縮 |
| 2 | Summary **無狀態**——每回合用前端送來的完整 history 即時重算，**不動 DB / 前後端 contract** | 無狀態代價是重複摘要舊內容，但省掉 schema 改動，這是清楚的取捨 |
| 3 | `file_context` **整塊保留、不壓縮**，且 budget 優先於 history | `edit_file` 需要 exact-match 字串，壓縮會破壞它 |

### 架構決策

- 新增 `Tyla::Prompts::HistorySummarizer`（collaborator，非 endpoint service），模式同 `GuardAgent`
- 壓縮**不做成 tool**：三個理由——順序矛盾（tool call 在 generation 中，fit-to-budget 必須在 send 前完成）、架構不符 stateless REST、平台不符（Anthropic Agent SDK 限定）
- **Pipeline**：base → file_context（整塊）→ history（放得下直接放；放不下 → 保留最近 verbatim turns + 舊 turns 交 Summarizer 摘要；Summarizer 失敗 → fail-open 退回丟棄行為）
- `SUMMARY_TOKEN_CAP` 暫定 400，Phase 0 量測後定值

### 實作範圍

- 新檔：`history_summarizer.rb`、`history-summary.md`、對應 spec
- 改檔：`budget_aware_prompt_assembler.rb`、`tutor_system_prompt.rb`、`run_tutor_chat.rb`
- controller / routes / DB **零改動**

---

## 二、Backend Agentic Loop Evaluation（2026-06-07）

### 核心決策：選 B3（前端驅動續傳）

| 方案 | 後端改動 | 評定 |
|---|---|---|
| B1：後端內部 loop | 大（mini-agent，contract 改 `files[]`） | Phase 2 保留研究變體 |
| B2：雙向 callback | 大（破壞 stateless） | **直接淘汰** |
| **B3：前端驅動續傳** | **近零** | **Phase 1 選定** |

### 三個子問題的答案

1. **Task routing**：不另加分類器——tutor LLM 在單次呼叫用 `tool_use` 隱式決定，guard 已是 pre-pass
2. **load_file 機制**：前端收到 action → 讀檔 → 重發 POST（同 prompt / guard_log_id / history，`file_context` 加上該檔）
3. **Agentic loop**：迴圈住在前端 driver，後端無感，需 max-iterations 上界（建議 2～3）

### 關鍵認知

- **B3 ≠ Claude Code**：Claude Code 前端直連 LLM；Tyla B3 每圈都要繞回後端，讓後端注入 reference solution + 驗證 guard
- **不推翻 §8.5**，而是「消費」它：`load_file` 從「普通的下一個 user turn」升級成「前端自動續傳」，其餘（無狀態、無暫存檔、無後端 loop）全部保留
- B3 穩定**依賴** `file_context` 結構化（per-file cap + 路徑清單取代 whole-or-drop）先落地，否則 whole-or-drop 會讓迴圈自我中毒

### 實作階段

- **Phase 0**：後端加 log（file_context token 量、reply 是否含 load_file），量 loop 深度與成本
- **Phase 1**：B3 最小實作（前端 continuation driver + path 邊界 + cap/dedup；後端零改動）
- **Phase 2（可選）**：B1 backend-as-agent，僅當論文需要「後端就是 agent」敘事且 Phase 0 數據支撐

---

## 三、B3 Frontend Continuation Driver（2026-06-07）

### 設計決策（7 條，已定案）

| # | 決策 | 要點 |
|---|---|---|
| 4.1 | `load_file` **text-only**；PDF 為唯一例外，走 `pdf_read` 抽文字 | Raw binary 無意義進 8K context |
| 4.2 | PDF 同受 token cap；cap **由 driver 統一施加於抽取後文字** | 集中在 driver 才有單一真相源；PDF 先 raw-byte 預過濾再 token cap |
| 4.3 | loaded-file cache **per-turn ephemeral**；`edit_file` 是迴圈終端 → Phase 1 不需顯式失效 | turn 內不會出現 stale cache |
| 4.4 | `MAX_CONTINUATIONS` 是**迴圈硬終止不變式**（取 2～3）；成本控制由去重 + cap 負責 | 兩者職責不同，不可混用 |
| 4.5 | `load + edit` 同回時 → **load 優先**（僅當 load 可行；已解析過的 load 視為 no-op，直接 dispatch edit） | 載入後重決 edit 較有根據 |
| 4.6 | `file_context` 在 B3 為 **append-only**；超 cap 以 marker **明確拒絕**，不靜默 drop | 靜默 evict 是迴圈中毒的元兇 |
| 4.7 | **單一 resolved set**（loaded ∪ unavailable），key = realpath；失敗路徑也記錄、去重；`buildFileContext()` 每 turn 僅跑一次 | 避免重複請求耗 iteration |

### 安全模型

- 採 **workspace boundary**（非固定目錄名 allowlist），支援任意專案結構
- 核心防線：`realpath` 後確認仍在 workspace root 內，以 `path.relative` 判斷收斂（不對原始字串比對 `..`）
- 保護對象是**學生自己的機器**（`.env`、`.ssh` 等），不是課程機密（reference solution 在 server，`load_file` 物理上無法外洩）

### 三項現況修正

| 修正 | 問題 | 正確做法 |
|---|---|---|
| Symlink 未收斂 | `file-read-service.ts` 只做 `path.resolve`，無 realpath | 兩端都 `realpathSync`，用 `path.relative` 判斷是否跳脫 |
| Windows 絕對路徑 | 僅擋 `/foo` 形式 | 需用 `path.win32.isAbsolute` 同時擋 drive-letter、UNC、`\\?\` |
| Per-file cap 過鬆 | 現行 100k chars ≈ 25k tokens，是 8K 預算的 3 倍 | B3 需自有 per-file + per-turn token cap，校準在 8K 以下 |

### 待定值（Phase 0 校準）

- `MAX_CONTINUATIONS`：暫定 **3**
- `FILE_CONTEXT_PER_FILE_TOKEN_CAP`：暫定 **~1.5k tokens**
- `FILE_CONTEXT_TURN_TOKEN_CAP`：暫定 **~3k tokens**（或 `headroom − base` 自適應）

---

## 四、B3 Step-by-Step 實作計畫（2026-06-07）

### 現況盤點

**已完成（毋需重做）：** PathConfinement（含完整單元測試）、FileContextBudget、base 讀檔已套用預算、常數（`PER_FILE_TOKEN_CAP=1200`、`PER_TURN_FILE_CONTEXT_TOKEN_CAP=2200`）、後端 contract 零改動確認

**仍缺（本次要做）：** 續傳迴圈本身（G1）、load_file 退出終端 dispatch（G2）、預算提升到 turn scope（G3）、resolved set（G4）、append 區段（G5）、MAX_CONTINUATIONS（G6）、載入解析器（G7）、binary 嗅探（G8）、跨圈 usage 累加（G9）、失敗 marker（G10）

### 五項實作前定案修正

| # | 問題 | 修正 | 落點 |
|---|---|---|---|
| 2.1 | `pdf_read` 繞過 PathConfinement（路徑相對 cwd，無 root 收斂） | `load_file` 路徑一律先 `PathConfinement.resolveWithinRoot`，再交共用 `extractPdfText(buf)`；`PdfReadTool` 不動 | Step 2 + Step 2b |
| 2.2 | `dispatchLoadFile()` 留著是未收斂後門 | **整個刪除**；`case 'load_file'` 從終端 dispatch 移除；型別 `TutorAction` 保留 | Step 5 |
| 2.3 | `FileContextBudget` 在 `buildFileContext` 內 new，base 與 load 無法共用同一 pool | **提升到 turn scope**，由 `callGateway()` 建立並傳入 | Step 3 + Step 4 |
| 2.4 | Codebase 完全沒有 binary 嗅探 | 新增 `isProbablyText(buf)`（NUL byte → false；控制字元 > 30% → false） | Step 1 + Step 2 |
| 2.5 | Unavailable 路徑算不出 realpath，key 二分問題 | 成功 → `canonicalPath`；失敗 → `unresolved:<reason>:<原字串>` | Step 2 + Step 4 |

### 建議提交順序

| 步驟 | 內容 | 依賴 |
|---|---|---|
| Step 1 | `text-content-policy.ts`（binary 嗅探 + 單元測試） | 葉節點，無依賴 |
| Step 2b | 抽出共用 `extractPdfText`，`PdfReadTool` 改用（純重構） | 無依賴 |
| Step 2 | `ContinuationFileLoader`（解析器 + 單元測試） | 依賴 1 + 2b |
| Step 3 | Budget 提升到 turn scope（小重構） | 依賴 2 |
| Step 4+5+6 | 續傳迴圈 + 刪除死碼 + `MAX_CONTINUATIONS` 常數（B3 核心，一起提交） | 依賴 1～3 |
| Step 7 | TUI `continuation` 事件（可選） | 獨立 |
| 後端 log | Phase 0 量測 log（可選，獨立 PR） | 獨立 |

### 驗收清單

- [ ] `load_file` 不再進終端 dispatch；`dispatchLoadFile()` 已刪
- [ ] PDF 載入路徑經 PathConfinement 收斂（不走 `pdf_read` 的 cwd resolve）
- [ ] Binary 檔以 marker 拒絕，不進 context
- [ ] Resolved set 對成功 / 失敗皆去重，失敗 key 用 `unresolved:`
- [ ] Base 讀檔與續傳載入共用同一 `FileContextBudget`
- [ ] `load A → edit A` 在單一 user turn 內自動完成（B3 體驗成立）
- [ ] 達 `MAX_CONTINUATIONS` 必終止並回饋使用者
- [ ] 跨圈 usage 正確累加（guard + Σ tutor）
- [ ] 後端零程式改動（除可選 Phase 0 log）
- [ ] §5 測試全綠

---

## 跨計畫依賴與順序

```
Phase 0（量測，零風險）
  ├─ 後端加 log：file_context token 量 + reply 是否含 load_file
  └─ 校準 SUMMARY_TOKEN_CAP、FILE_CONTEXT_*_TOKEN_CAP

Phase 1（主體，兩邊平行）
  ├─ 前端 B3（MindyCLI_demo）
  │    前置：file_context 結構化 / per-file cap（§8.5）
  │    主體：Step 1 → 2b → 2 → 3 → 4+5+6（→ 7 可選）
  └─ 後端 Compression
       主體：HistorySummarizer + assembler 注入 + summary 教材
       並行：策略 A（人工精簡靜態教材，無程式風險）

Phase 2（可選研究變體）
  └─ B1 backend-as-agent（僅當論文需要且 Phase 0 數據支撐）
```

**關鍵耦合**：前端 `FILE_CONTEXT_TURN_TOKEN_CAP` 與後端 `SUMMARY_TOKEN_CAP` 必須在 Phase 0 一起校準，確保 base + loaded 穩定 < 後端 8K，否則 whole-or-drop 會讓 B3 迴圈自我中毒。
