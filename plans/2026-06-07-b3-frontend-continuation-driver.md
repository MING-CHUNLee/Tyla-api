# B3 — 前端續傳驅動器（Frontend Continuation Driver）實作計畫

**Date:** 2026-06-07
**Status:** 設計已定案，待實作（decisions locked, ready to implement）
**Scope:** 在 `MindyCLI_demo` 前端實作 B3「前端驅動的自動續傳」，讓單一 user turn 內能
`load_file → 重發 POST → edit_file`。後端（本 repo）**零程式改動**。
**直接延伸：**
- [2026-06-07-backend-agentic-loop-evaluation.md](./2026-06-07-backend-agentic-loop-evaluation.md)
  — 本案是該評估 §3/§4 選定的 **B3** 之落地計畫；§7「具體要改什麼」「前端為主要工作」即本文展開。
- [2026-06-06-prompt-compression-mechanism.md](./2026-06-06-prompt-compression-mechanism.md)
  — §8.5 的 `file_context` just-in-time 結構化是 B3 穩定的前置條件（見 §6 風險）。

> 前端 repo：`C:\Users\Mindy\OneDrive - NTHU\paper\project\MindyCLI_demo`
> 主要落點檔：`tyla/src/application/use-cases/execute-tutor-use-case.ts`

---

## 0. TL;DR

1. 前端**今天已經做了 B3 所需的一切，唯獨缺「重發 POST」**。`load_file` 目前是死路：
   `dispatchLoadFile()` 讀檔後只把內容當成一則訊息印出，學生得自己再問一次——這正是評估 §8 的
   **Baseline A**。**B3 = 把這條死路接成迴圈。**
2. 後端 stateless 契約不動：`file_context` 已是 optional string；續傳 prompt 不變，
   `guard_log_id` 仍 match（`guard_log.prompt == params[:prompt]`），**guard 不重跑、無法被繞過**。
3. 安全模型採 **workspace boundary**（非固定目錄名 allowlist），對 Python / R / Go / Rust 等任意
   專案結構都成立。核心硬防線：`realpath` 後確認仍在 workspace root 內。
4. 所有設計邊角（binary / cache 失效 / MAX_CONTINUATIONS 定位 / load+edit 同回 / append-only）
   已定案，見 §4。

---

## 1. 現況：turn 生命週期與 `load_file` 死在哪

```
agent-service.executeInstruction()
  └─ tutorUseCase.execute(instruction, history)            ← 一個 student turn
       └─ callGateway():
            1. fileContext = buildFileContext(instruction)  // scan + 讀相關/fallback 檔
            2. guard.check(instruction)        → guard.logId
            3. tutorChatGateway.send(instruction, history, guard.logId, fileContext) → result.actions
            4. dispatchActions(result.actions) // edit_file / execute_script / load_file
```

- 後端 [`RunTutorChat`](../app/application/services/tutor_chat/run_tutor_chat.rb) 單次 `send_prompt`、
  stateless，`load_file` 以 action 原封回傳。
- 前端 `dispatchActions()`（[execute-tutor-use-case.ts:189]）把三種 action 都當**終端**處理。
  `dispatchLoadFile()`（[execute-tutor-use-case.ts:260-265]）讀檔→印出，**不重發**。
- 結論：今天一次 `load_file` ＝ 螢幕上多一段檔案內容，學生要手動再問 → Baseline A。

---

## 2. B3 續傳迴圈（核心改動）

落點：`callGateway()`（[execute-tutor-use-case.ts:104]）。把第 3～4 步包進**有界迴圈**：

```
turn 開始：
  baseContext = buildFileContext(instruction)        // 只跑一次（見 §4.3）
  resolved    = Map<realpath, 'loaded'|'unavailable'>// 去重 + 終止判斷
  loadedBlocks = []                                  // 逐圈累加
  usage       = guard.usage

迴圈 i = 0..MAX_CONTINUATIONS:
  fileContext = baseContext + "\n\n## Files Loaded On Request\n" + loadedBlocks.join("\n")
  result = tutorChatGateway.send(instruction, history, guard.logId, fileContext)
  usage += result.usage
  處理 forbidden / error → 比照現況 return

  actionable = result.actions
      .filter(a => a.type === 'load_file')
      .map(a => resolveSafe(a.path))            // §3 安全解析
      .filter(r => !resolved.has(r.canonicalPath))   // 去重（loaded ∪ unavailable）

  if (actionable.length > 0 && i < MAX_CONTINUATIONS):
      for r of actionable:
          block = r.ok ? readWithCap(r) : unavailableMarker(r)
          loadedBlocks.push(block)
          resolved.set(r.canonicalPath, r.ok ? 'loaded' : 'unavailable')
      emit('continuation', {...})
      continue                                   // 重發 POST，同 prompt/history/guardLogId

  // 終端 turn：emit 文字 + dispatch edit_file / execute_script（load_file 不在此 dispatch）
  emit('text_output', result.content)
  await dispatchActions(result.actions.filter(a => a.type !== 'load_file'))
  return { content, usage }
```

**為什麼這是 B3 而非後端 loop：** 迴圈住在前端 driver；後端每圈仍是獨立 stateless 呼叫、無感。

---

## 3. 安全模型 — workspace boundary（最關鍵）

採「邊界」而非「固定目錄名 allowlist」，以支援任意專案結構。六條規則 + 三項依現有程式碼的修正。

### 3.1 六條規則
1. 只讀 **workspace root 之內**的檔。
2. 拒絕**絕對路徑**。
3. 拒絕**跳脫 workspace 的 traversal**。
4. **解析 symlink**，並對「解析後的真實路徑」強制邊界。
5. 限制**檔案大小 / token 量**。
6. 限制 `load_file` 為 **text-readable** 檔。

### 3.2 依程式碼的三項修正
- **規則 4（symlink）：兩端都 `realpath`，用真實路徑比對。**
  現況 reader 只做 `path.resolve(filePath)`（[file-read-service.ts:20]）——無 realpath、無收斂。
  正確形：
  ```ts
  const root      = fs.realpathSync(this.deps.directory);   // root 自身可能在 symlink 下
  const candidate = path.resolve(root, requested);          // requested 必須是相對路徑
  const real      = fs.realpathSync(candidate);             // 收斂目標端 symlink
  const rel       = path.relative(root, real);
  // 拒絕：rel 以 '..' 開頭，或 path.isAbsolute(rel)
  ```
  以 `path.relative` 判斷收斂，**不要**對原始輸入字串比對 `..`（脆弱、漏 symlink/編碼跳脫）。
  `realpathSync` 對不存在的目標會 throw → 當成 unavailable（與 not-found 同路徑）。
- **規則 2（絕對路徑）：Windows 上不只是 `/foo`。** 需用 `path.win32.isAbsolute` 同時擋
  drive-letter（`C:\…`）、UNC（`\\server\share`）、`\\?\` 形式。
- **規則 5（大小）：現有 cap 對 8K hot path 太鬆。** `MAX_FILE_CONTENT_CHARS = 100_000`
  ≈ 25k tokens（[agent-file-policy.ts:56]），是 GitHub Models 8K 預算的約 3 倍。單一「合法」檔即可
  撐爆 `file_context`、觸發後端 whole-or-drop（[budget_aware_prompt_assembler.rb:58]）並啟動 §6 的
  自我中毒迴圈。**B3 需自有 per-file token cap + per-turn 總量 cap，校準在 8K 以下**，不可沿用 100k。

### 3.3 威脅模型再框定（重要）
本架構中 reference solution / persona / refusal 教材**永遠留在 server、不到學生機**（評估 §4.1）。
故 `load_file` **物理上無法外洩答案**——它不在學生機上。邊界規則保護的是**學生自己的機器**
（`.env`、`.ssh`、`.git/config` token、其他課程的作業），非課程機密。
→ 邊界收斂即足夠；不需為「課程機密」加檔名 deny-list。可選的 within-boundary deny-list
（`.env`、`.git/`、`.ssh`）屬 defense-in-depth。

---

## 4. 定案的設計決策

### 4.1 `load_file` 不支援 binary；text-only，PDF 為唯一例外
`file_context` 是字串、進 8K 預算，raw binary 無意義。規則 6 實作：讀 bytes，遇 NUL byte / 高
非-UTF-8 比例即拒。唯一例外已接好線：`dispatchLoadFile` 對 `.pdf` 路由到 `pdf_read`
（[execute-tutor-use-case.ts:261]）做**文字抽取**。故規則精確為 **「抽取後的文字」**：純文字檔直接讀、
PDF 走 `pdf_read`，其餘以明確 marker 拒絕。

### 4.2 PDF 同受 token cap，且 cap 由 driver 統一施加於「抽取後文字」
cap 目的是保護 8K；PDF 最可能撐爆（fallback 邏輯已視 PDF 為「大、不自動讀」，
[execute-tutor-use-case.ts:25-30]）。因此：
- cap 量在 **post-extraction 文字的 token 數**（那才是進 `file_context` 的東西），非檔案 byte 數。
- **由 continuation driver 對任一來源回傳的文字統一施 cap**，不依賴各 tool 內部 cap
  （`file_read` 走 `FileReadService` 的 100k 檢查、`pdf_read` 是另一支 tool、限制不同；集中在 driver
  才有單一真相源）。
- PDF 效率修正：抽取昂貴 → 先加**便宜的 raw-byte 預過濾**（明顯過大者抽取前就拒），再對抽取文字施
  token cap。順序：byte 預過濾 → 抽取 → token cap → append 或 marker 拒絕。

### 4.3 loaded-file cache 為 per-turn ephemeral；`edit_file` 為迴圈終端 → 不需顯式失效
- 迴圈**只在 `load_file` 續傳**，`edit_file` 終結該 turn。故一個 turn 內可
  `load A → load B → edit（終端）`，但不會 `edit → 再 load`。**turn 內不會出現 stale cache。**
- 跨 turn：`buildFileContext()` 會從磁碟重建，cache 自然新鮮。
- → **Phase 1 不需顯式 cache 失效。** 僅當未來允許「edit 後繼續 loop」才需失效——且只對
  **已套用（approved & applied）** 的 edit 失效；被拒絕的 edit 未動磁碟、cache 仍有效
  （approval gate 在 [execute-tutor-use-case.ts:232]）。

### 4.4 `MAX_CONTINUATIONS` 主要是**迴圈防止（硬終止不變式）**，成本為次要
whole-or-drop 可能讓迴圈因「非成本」因素不終止——那是**正確性**錯誤，`MAX_CONTINUATIONS` 是無論模型/
預算如何都保證 turn 結束的硬 backstop（取小值 2～3）。真正的**成本**控制由 **resolved set 去重** +
**per-file/per-turn token cap** 負責（不誤砍合理深度）。框定：
`MAX_CONTINUATIONS` ＝「此 turn 必結束」；去重 + cap ＝「此 turn 不浪費」。

### 4.5 `load_file` 與 `edit_file` 同回傳 → load 優先，但僅當 load 「可行（actionable）」
預設：任一 `load_file` 存在 → 視為續傳、延後終端 actions（edit 是在看到載入檔**之前**形成的，
載入後重決較有根據）。精確規則避免空耗 iteration：
> `load_file` 優先 **iff** 它解析到一個**新的、合法的、尚未解析過**的檔；否則視為已解析（no-op），
> 直接 dispatch 同回的 `edit_file`。

### 4.6 `file_context` 在 B3 為 **append-only**；sliding window 屬 §8.5、且須 reference-aware
- Phase 1：turn 內 append-only，受 per-turn token cap + `MAX_CONTINUATIONS` 約束。
- 超過 cap 時：**以明確 marker 拒絕後續載入**，而非靜默 evict（靜默 evict 正是毒化迴圈的元兇）。
- 未來的有界形式屬 compression plan §8.5（單一真相源），且 eviction 必須
  **per-file、keep-most-recently-referenced**，**絕不可 FIFO**（FIFO 可能 evict 模型正要編輯的檔 →
  re-load 迴圈）。且須與後端 assembler 共同設計（§5.3 校準），因為最終是它決定什麼進得了 8K。

### 4.7 unavailable 路徑也進 resolved set；continuation 沿用 base、不重跑 buildFileContext
- **單一 resolved set**，key 為 **canonical realpath**，值為 `loaded | unavailable`：
  - 首次遇 X：解析後 append「內容區塊（loaded）」或「UNAVAILABLE marker（failed）」到 `file_context`，
    並記錄 X。marker 即是叫模型停止再問的訊號。
  - 再次遇 X：去重命中 → no-op、不重複 append、不耗 iteration。
  - 一回應的 `load_file` 全數已解析（loaded 或 failed）→ 無新事 → 該 turn 轉終端。
  - key 用 realpath：`hw.R`、`./hw.R`、symlink 皆去重為一筆。
  - 失敗即使是 transient 也當「本 turn 已解析」；set 為 per-turn ephemeral，下個 student turn 自然重試。
- **`buildFileContext()` 每 turn 只跑一次**（[execute-tutor-use-case.ts:269-285]）。續傳沿用 `baseContext`、
  只 append 已解析區塊到獨立的 `## Files Loaded On Request` 區段。重跑會重做 scan/read、且可能讓 base
  區塊在各圈間變大小、與 whole-or-drop 預算互咬。
- per-turn 載入預算可自適應：估 `baseContext` token（已有 `/4` 估算）後，載入預算 = `headroom − base`。

---

## 5. 不變式（實作前定案）

- `load_file` 解析 **相對於 `realpath(workspace_root)`**；拒絕 絕對/UNC/`\\?\`；
  `realpath(target)` 跳脫 root 即拒；不存在/壞 symlink → unavailable marker。
- **text-only**（NUL / UTF-8 嗅探）；PDF 走 `pdf_read`；其餘 → 「unsupported type」marker。
- **新增** per-file token cap + per-turn 總量 cap，校準在 8K 以下（先放 placeholder，Phase 0 校準）
  ——**非**沿用 100k char cap。PDF：先 raw-byte 預過濾，再對抽取文字施 cap。
- 迴圈**僅**在 actionable `load_file` 續傳；`edit_file` / `execute_script` 為終端。
- **單一 resolved set**（loaded ∪ unavailable），key=realpath；去重使重複/被擋請求成 no-op；
  全數已解析的回應 → 終端。
- `MAX_CONTINUATIONS` = 2～3，硬上界（終止不變式）。
- `file_context` 本 turn **append-only**；超 cap 載入以 marker 拒絕、不靜默 drop。
- `buildFileContext()` 每 turn 一次；loaded 檔進獨立 `## Files Loaded On Request` 區段。
- loaded-file cache **per-turn ephemeral**；Phase 1 不需跨 turn 失效。

---

## 6. 風險（多為 codebase 特有）

1. **whole-or-drop 自我中毒（§8.5 耦合）**：[budget_aware_prompt_assembler.rb:58] 整塊放/丟
   `file_context`。迴圈把它養大，某圈撐爆 8K → 整塊（含剛載入的檔）被丟 → 模型再發 `load_file` →
   無限迴圈。**前端 `MAX_CONTINUATIONS` + resolved set + per-file cap** 是 §8.5 的 per-file cap 落地前
   的安全網。
2. **path 安全（最關鍵）**：現況 reader 無收斂（[file-read-service.ts:20]）；B3 讓「模型指名的讀取」
   自動回灌 LLM。§3 的 realpath 邊界是硬防線，獨立於 guard 分數之外。
3. **延遲累加**：N 次續傳 ＝ N 次 round-trip；N 必小（2～3）。
4. **成本**：多次 LLM 呼叫吃學生 quota；以去重 + cap 控制，並在評估 §8 量測實際分布。
5. **與 compression 的順序**：穩定**依賴** §8.5 的 `file_context` 結構化 / per-file cap 先落地。

---

## 7. 具體改動清單

**後端（本 repo）— 零程式改動。** 契約（[tutor_chat.rb](../app/application/requests/tutor_chat.rb)）
`file_context` 為 optional string；`derive_verdict`（[run_tutor_chat.rb:176]）只需 prompt 不變即 match。
（可選）Phase 0 server log：記本次 request 是否含 `load_file`、`file_context` token 量，供量測 loop 深度/成本。

**前端（MindyCLI_demo）— 主要工作：**
| # | 檔案 | 改動 |
|---|---|---|
| 1 | `tyla/src/application/use-cases/execute-tutor-use-case.ts` | `callGateway()` 包成 §2 續傳迴圈；`load_file` 由 driver 消費、不再進 `dispatchActions` 終端；`buildFileContext` 每 turn 一次 + append loaded 區段；累加 usage |
| 2 | 新增 path-confinement helper（與 `FileReadService` 同層） | §3 的 `realpath` 邊界解析 + 絕對/UNC/traversal 拒絕，回傳 `{ok, canonicalPath, content?}` 或 `{ok:false, reason}` |
| 3 | `tyla/src/application/services/file-read-service.ts` | 改為收斂於傳入 root（或由 helper 包裹）；分離出 token-cap 量測供 driver 統一施加 |
| 4 | binary / text 嗅探 + PDF raw-byte 預過濾 | 置於 helper 或 driver；text-only 規則 6 |
| 5 | 常數：`MAX_CONTINUATIONS`、`FILE_CONTEXT_PER_FILE_TOKEN_CAP`、`FILE_CONTEXT_TURN_TOKEN_CAP` | 命名常數，便於 Phase 0 校準 |
| 6 | TUI 事件：`continuation` / load marker 顯示 | 讓學生看見「自動載入 X 後續傳」的過程（可選但利於 demo/論文敘事） |

**不需動：** `tutor-actions.ts`（contract 不變）、`tutor-chat-gateway.send()` 簽章
（已收 `fileContext`，[tutor-chat-gateway.ts:40-45]）。`edit_file` 直接讀磁碟（[execute-tutor-use-case.ts:209]），
與 `file_context` 如何裁切無關 → load 後的 edit 必可運作。

---

## 8. 待定值（Phase 0 校準）

1. `MAX_CONTINUATIONS`：暫定 **3**（評估 §11 留待量測）。
2. `FILE_CONTEXT_PER_FILE_TOKEN_CAP`：暫定 **~1.5k tokens**。
3. `FILE_CONTEXT_TURN_TOKEN_CAP`：暫定 **~3k tokens**（或 `headroom − base` 自適應）。
4. within-boundary deny-list 是否啟用（`.env` / `.git/` / `.ssh`）——defense-in-depth，預設可先不開。

---

## 9. 測試計畫（對齊評估 §8）

- **單元**：path helper——相對 OK、絕對拒、`..` 跳脫拒、symlink 跳脫拒、Windows drive/UNC 拒、
  realpath 收斂正確。
- **單元**：cap——純文字超 cap 以 marker 拒；PDF 抽取後超 cap 拒；binary 拒。
- **迴圈**：`load A → edit A` 兩圈成功；重複 `load A` 去重不耗 iteration；unavailable A 後再請求 A
  轉終端；`load + edit` 同回採 load 優先（新檔）/ edit 直走（已解析）。
- **終止**：達 `MAX_CONTINUATIONS` 仍要 load → 停止 + 回饋「已達載入上限」。
- **對照組（評估 §8）**：A（手動下一回合）vs B3（自動續傳）vs full-preload，量任務成功率 / loop 深度 /
  額外 LLM 呼叫與 token / 端到端延遲。

---

## 10. 階段

- **Phase 0（量測，零風險）**：後端加 log；收一批對話量「多少 turn 真的需要 read→edit」「loop 多深」，
  定 §8 的待定值。
- **Phase 1（B3 最小實作）**：§7 前端改動 + §3 path 邊界 + §4 cap/dedup；前置＝§8.5 的 `file_context`
  結構化 / per-file cap。產出 §9 對照數據。
- **Phase 2（可選研究變體）**：B1 backend-as-agent（僅當論文需「後端就是 agent」敘事且 Phase 0 顯示
  loop 夠常見/夠深）。
