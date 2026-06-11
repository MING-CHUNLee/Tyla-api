# B3 前端續傳驅動器 — Step-by-Step 實作計畫

**Date:** 2026-06-07
**Status:** 實作藍圖（codebase review 完成，依此逐步落地）
**Scope:** 把 [2026-06-07-b3-frontend-continuation-driver.md](./2026-06-07-b3-frontend-continuation-driver.md)
的設計決策落成可寫的程式步驟。**後端（本 repo）零程式改動**（僅一行可選的 Phase 0 log）；
主要工作在前端 `MindyCLI_demo/tyla`。

> 前端 repo：`C:\Users\Mindy\OneDrive - NTHU\paper\project\MindyCLI_demo`
> 主要落點：`tyla/src/application/use-cases/execute-tutor-use-case.ts`
> 設計來源：`b3-frontend-continuation-driver.md`（決策）、`backend-agentic-loop-evaluation.md`（§3/§4 選定 B3）

---

## 0. 這份文件相對前兩份的定位

- `backend-agentic-loop-evaluation.md` = **為什麼是 B3**（架構選型）。
- `b3-frontend-continuation-driver.md` = **B3 的設計決策與不變式**（要做成什麼樣）。
- **本文 = 怎麼把它寫出來**（檔案、函式、迴圈、測試、提交順序）。

我重新 review 了兩個 repo。**結論：B3 的前置安全/預算基礎建設已經做完了**，缺的是「迴圈本身」。
下面 §1 是盤點，§2 是設計文件沒明寫、但實作一定會踩到的點（這就是你問的「有沒有遺漏」）。

---

## 1. 現況盤點 — 已完成 vs 仍缺

### ✅ 已完成的前置（review 後確認，毋需重做）

| 元件 | 狀態 | 檔案 |
|---|---|---|
| **PathConfinement**（§3 安全硬防線：realpath 邊界、絕對/UNC/`\\?\` 拒、`path.relative` 收斂、symlink、穩定 failure code、fs 可注入） | **完成且有完整單元測試** | `tyla/src/domain/policies/path-confinement.ts`、`tests/unit/domain/path-confinement.test.ts` |
| **FileContextBudget**（§4 per-file + per-turn token cap、`take()` 截斷、`skipMarker()` 拒絕） | **完成** | `tyla/src/application/services/file-context-budget.ts` |
| base 自動讀檔已套用該預算（gap-list §C） | **完成且有測試** | `execute-tutor-use-case.ts:285`、`readFiles()`、`tests/.../execute-tutor-use-case.test.ts:231` |
| 常數 `PER_FILE_TOKEN_CAP=1200`、`PER_TURN_FILE_CONTEXT_TOKEN_CAP=2200` | **完成**（值待 Phase 0 校準） | `execute-tutor-use-case.ts:32-33` |
| `IFileSystem.realpath` / `readBuffer` | **存在** | `tyla/src/domain/types/file-system.ts` |
| FileReadService 已收斂於 root（委派 PathConfinement） | **完成** | `tyla/src/application/services/file-read-service.ts` |
| 後端 contract `file_context` optional string、guard 以 `prompt` 不變 match | **完成**（零改動） | `app/application/requests/tutor_chat.rb:21`、`run_tutor_chat.rb:177` |

→ 設計文件 §7 清單裡的 #2（path helper）、#3（confinement）、#5（caps）**已落地**。
B3 plan §3 整章（安全模型）已是現成程式碼。

### ❌ 仍缺（本文要做的）

| # | 缺口 | 對應設計 |
|---|---|---|
| G1 | **續傳迴圈本身** — `callGateway()` 仍是「單次 send + 終端 dispatch」 | b3 §2 |
| G2 | **`load_file` 仍被當終端 action** — `dispatchLoadFile()` 讀檔→印出→死路（Baseline A） | b3 §0.1、§7#1 |
| G3 | **預算實例只活在 `buildFileContext` 內** — base 與續傳載入無法共用同一 per-turn pool | b3 §4.6/§4.7 |
| G4 | **resolved set（去重 + 終止判斷）不存在** | b3 §4.7 |
| G5 | **append-only `## Files Loaded On Request` 區段**不存在 | b3 §2、§4.6 |
| G6 | **`MAX_CONTINUATIONS` 常數 + 硬終止**不存在 | b3 §4.4 |
| G7 | **統一施 cap 的「載入解析器」**不存在（confine→sniff→PDF→token cap→block/marker 集中一處） | b3 §4.2 |
| G8 | **binary/text 嗅探（NUL / UTF-8 比例）整個 codebase 都沒有** | b3 §4.1（規則 6） |
| G9 | **跨圈 usage 累加** | b3 §7#1 |
| G10 | **載入失敗/超 cap 的 model-facing marker**（叫模型停止重問） | b3 §4.7、風險 1 |
| G11 | TUI `continuation` 事件（可選，利於 demo/論文） | b3 §7#6 |
| G12 | 迴圈 + 解析器測試 | b3 §9 |

---

## 2. 五項修正（review 發現 → 定案）

這五點是 codebase review 後發現、設計文件沒明寫、但實作一定踩到的。**每點已定案**，格式為
「問題 → 修正（定案）→ 落點 Step」，落點對應 §4。

### 2.1 `pdf_read` 繞過 PathConfinement → driver 自行收斂

**問題：** `pdf-read-tool.ts:42` 用 `path.resolve(filePath)`（相對 cwd、**無 root 收斂**），且只有 100k char cap。
今天 `dispatchLoadFile()`（`execute-tutor-use-case.ts:270`）把 `.pdf` 路由到 `pdf_read` ——
所以 **`load_file` 載一個 `.pdf` 現在是不收斂的**。B3 會把模型指名的讀取自動回灌 LLM，這是活的 exfiltration 風險。

**修正（定案）：** `load_file` 一律**不經 `pdf_read` 工具解析路徑**。改由 `ContinuationFileLoader` 先
`PathConfinement.resolveWithinRoot(root, requested)` 收斂，**只把 canonical 路徑**交給共用的
`extractPdfText(buffer)`（Step 2b）抽文字；PDF 與一般檔走同一條 confine → cap 路徑。
`PdfReadTool`（ReAct/ask 用）維持現狀、不動。

**落點：** Step 2（解析器）、Step 2b（抽出共用 extractor）。

### 2.2 `dispatchLoadFile()` → 刪除（不留未收斂後門）

**問題：** G2 後 `load_file` 由 driver 消費；若僅「攔截」卻保留 `dispatchActions` 的
`case 'load_file'`（`execute-tutor-use-case.ts:206`）與 `dispatchLoadFile()`（`:269-274`），
未來重構可能讓 `load_file` 又掉回那條**未收斂、100k char cap、整檔印出**的舊路。

**修正（定案）：** 刪 `case 'load_file'` 與整個 `dispatchLoadFile()`。終端 `dispatchActions` 只剩
`edit_file`/`execute_script`。`TutorAction`/`isTutorAction` 的 `load_file` 型別**保留**
（後端仍回傳、driver 消費）。driver 進終端前再以 `.filter(a => a.type !== 'load_file')` 保險一次。

**落點：** Step 5。

### 2.3 預算實例提升到 turn scope（base 與 load 共用同一 pool）

**問題：** `FileContextBudget` 在 `buildFileContext()` 內 `new`（`:285`）、用完即丟 →
base 讀檔與續傳載入無法共用同一 per-turn pool（b3 §4.6/§4.7：載入預算 = headroom − base）。

**修正（定案）：** `new FileContextBudget(...)` 上移到 `callGateway()`，作參數傳入
`buildFileContext(instruction, budget)` 與 `loader.resolve(root, path, budget)`。整個 turn 一個 budget 實例。

**附帶風險（Phase 0 校準）：** base fallback 若讀 5 個大檔吃光 2200 pool，續傳第 0 圈即 `skipMarker` →
迴圈當圈終止。這是**設計接受的優雅退場**（marker 叫模型停手、不無限迴圈），但要量；若常餓死，
再拆成獨立 `BASE_CAP` + `LOAD_CAP`（見 §7 校準）。

**落點：** Step 3 + Step 4。

### 2.4 binary 嗅探（codebase 完全沒有）

**問題：** `FileReadService.read()` 只看 char 數（`isContentEditable`，`agent-file-policy.ts:79`），
不 sniff binary；副檔名白名單 `isFilenameEditable` **根本沒被 read 路徑呼叫**。`.dat`/`.png`
會被當亂碼 UTF-8 塞進 context。

**修正（定案）：** 新增 `isProbablyText(buf)`（Step 1，domain policy）：NUL byte 即判 binary、
控制字元比例 > 30% 判 binary。解析器對非 PDF 檔先 `readBuffer` → `isProbablyText` →
否則回 `unsupported type (binary)` marker，通過才 `toString('utf8')`。**不靠 `file_read`**。

**落點：** Step 1 + Step 2。

### 2.5 resolved set 的 key 二分（失敗時無 realpath）

**問題：** b3 §4.7 說 unavailable 也用 realpath 當 key，但 `not-found`/`escape`/`absolute`/`empty`
**算不出 canonical realpath**（realpath 會 throw）。

**修正（定案）：** key 二分 —— **confine 成功 → `canonicalPath`；confine 失敗 →
`unresolved:<reason>:<trim 後原字串>`**。兩者皆寫進 `resolved` set，故「重複請同一壞路徑」也去重、不耗 iteration。

**落點：** Step 2（`LoadResolution.key`）、Step 4（`resolved.has(r.key)`）。

---

## 3. 後端（本 repo）：要不要改？— **不改**（一行可選 log）

review 確認 b3 §7「後端零改動」成立：
- `file_context` 已是 `optional(:file_context).filled(:string)`（`tutor_chat.rb:21`）—— 續傳塞得下。
- `derive_verdict` 只要 `guard_log.prompt == params[:prompt]`（`run_tutor_chat.rb:177`）—— 續傳 prompt 不變 → verdict 續用、guard 不重跑、無法繞過。
- `load_file` 已是 `TOOLS` 之一（`run_tutor_chat.rb:57`）、原封回傳。

**（可選）Phase 0 量測 log**：在 `RunTutorChat#request_tutor_reply` 回傳前，記一行
「本 request 的 `file_context` token 估計 + reply 是否含 `load_file` tool_call」，供量測 loop 深度/成本
（b3 §8、§10 Phase 0）。零風險、純觀測。若要做，用既有 `Values::Tokenizer.estimate(params[:file_context])`
即可，不動任何控制流。

---

## 4. 前端：Step-by-Step 實作

> 下列程式為**藍圖 sketch**（標明意圖與簽章），實作時對齊周邊既有風格（檔頭註解、命名、discriminated union）。

### Step 1 — 新增 text/binary 嗅探（domain policy）

**新檔** `tyla/src/domain/policies/text-content-policy.ts`（與 `path-confinement.ts`、`agent-file-policy.ts` 同層）。

```ts
/** 取樣 buffer 前段判斷是否為「文字可讀」。NUL byte 即判 binary；
 *  控制字元（除 \t\n\r）+ 無效 UTF-8 比例過高亦判 binary。 */
const SNIFF_BYTES = 8_000;
const NONTEXT_RATIO_LIMIT = 0.3;

export function isProbablyText(buf: Buffer): boolean {
  const n = Math.min(buf.length, SNIFF_BYTES);
  if (n === 0) return true;                 // 空檔當文字
  let suspicious = 0;
  for (let i = 0; i < n; i++) {
    const b = buf[i];
    if (b === 0) return false;              // NUL → 必為 binary
    const isControl = b < 0x09 || (b > 0x0d && b < 0x20);
    if (isControl) suspicious++;
  }
  return suspicious / n <= NONTEXT_RATIO_LIMIT;
}
```

**單元測試** `tests/unit/domain/text-content-policy.test.ts`：純文字 true、含 NUL false、高控制字元比例 false、空檔 true。

### Step 2 — 新增「續傳載入解析器」（application service，G7+G8+G10 集中地）

**新檔** `tyla/src/application/services/continuation-file-loader.ts`。
**唯一真相源**：confine → sniff/PDF → **統一 token cap** → 回 `{ key, ok, block }`。
不重用 `FileReadService`（那條是 ask/ReAct 的 100k-char 政策，刻意與 B3 的 token cap 分離，見其檔頭註解）；
直接組合 `PathConfinement` + `FileContextBudget` + Step 1 嗅探。

```ts
export interface LoadResolution {
  key: string;        // 去重 key：成功=canonicalPath；失敗=`unresolved:<reason>:<req>`（§2.5）
  ok: boolean;        // true=內容載入；false=unavailable/unsupported/超 cap
  block: string;      // 已含標籤的內容區塊，或 model-facing marker（§4.10）—— 直接 append
}

const MAX_PDF_BYTES = 5_000_000;   // PDF 抽取昂貴 → 先做便宜 raw-byte 預過濾（b3 §4.2）

export class ContinuationFileLoader {
  constructor(
    private readonly fileSystem: IFileSystem,
    private readonly confinement: PathConfinement,        // 注入，便於測試
    private readonly extractPdf: (buf: Buffer) => Promise<string>, // 見 Step 2b
  ) {}

  async resolve(root: string, requested: string, budget: FileContextBudget): Promise<LoadResolution> {
    const c = this.confinement.resolveWithinRoot(root, requested);
    if (!c.ok) {
      const key = `unresolved:${c.reason}:${requested.trim()}`;
      return { key, ok: false, block: marker(requested, `unavailable (${c.reason})`) };
    }
    const label = path.basename(c.canonicalPath);
    if (budget.isExhausted()) {
      return { key: c.canonicalPath, ok: false, block: budget.skipMarker(label) };
    }
    const buf = this.fileSystem.readBuffer(c.canonicalPath);
    const isPdf = path.extname(c.canonicalPath).toLowerCase() === '.pdf';

    if (isPdf) {
      if (buf.length > MAX_PDF_BYTES) return { key: c.canonicalPath, ok: false, block: marker(label, 'unavailable (pdf too large)') };
      let text: string;
      try { text = await this.extractPdf(buf); }
      catch { return { key: c.canonicalPath, ok: false, block: marker(label, 'unavailable (pdf parse failed)') }; }
      if (!text.trim()) return { key: c.canonicalPath, ok: false, block: marker(label, 'unavailable (no extractable text)') };
      return { key: c.canonicalPath, ok: true, block: budget.take(label, text) };
    }

    if (!isProbablyText(buf)) return { key: c.canonicalPath, ok: false, block: marker(label, 'unsupported type (binary)') };
    return { key: c.canonicalPath, ok: true, block: budget.take(label, buf.toString('utf8')) };
  }
}

function marker(label: string, why: string): string {
  return `### ${label}\n[${why} — do not request this file again]\n\n`;  // §4.10 停止訊號
}
```

**Step 2b — 抽出共用 PDF 抽取器（DRY）**：把 `pdf-read-tool.ts` 內 pdf-parse v2 的
`new PDFParse({data}) → getText() → destroy()` 生命週期抽成
`tyla/src/infrastructure/pdf/pdf-text-extractor.ts` 的 `extractPdfText(buf): Promise<string>`，
讓 `PdfReadTool` 與 `ContinuationFileLoader` **共用同一支**（避免兩處 pdf-parse 寫法漂移）。
`PdfReadTool` 改呼叫它、保留自己的 100k-char 對外行為；loader 走 budget token cap。

### Step 3 — 把 FileContextBudget 提升到 turn scope（G3）

`execute-tutor-use-case.ts`：
1. `buildFileContext(instruction)` 簽章改為 `buildFileContext(instruction, budget: FileContextBudget)`，
   **刪掉**其內 `:285` 的 `new FileContextBudget(...)`，改用傳入的 `budget`。
2. 由 `callGateway()` 建立唯一實例並傳入（見 Step 4）。

### Step 4 — `callGateway()` 改成 §2 續傳迴圈（G1+G4+G5+G6+G9）

把現有 `:151-187`（tutor call → dispatch → return）改成有界迴圈。guard 段（`:127-149`）**不動**。

```ts
// guard 成功後：
const budget = new FileContextBudget(PER_FILE_TOKEN_CAP, PER_TURN_FILE_CONTEXT_TOKEN_CAP);
const baseContext = await this.buildFileContext(instruction, budget);   // Step 3
const resolved = new Map<string, 'loaded' | 'unavailable'>();
const loadedBlocks: string[] = [];
let usage = toTurnUsage(guard.usage);                                   // 累加起點

for (let i = 0; ; i++) {
  const fileContext = loadedBlocks.length
    ? `${baseContext}\n\n## Files Loaded On Request\n${loadedBlocks.join('\n')}`   // append-only
    : baseContext;

  this.deps.emit('phase_start', { phase: 'tutor', description: i === 0 ? 'Calling tutor API' : `Continuation ${i}` });
  let result;
  try { result = await this.deps.tutorChatGateway.send(instruction, history, guard.logId, fileContext); }
  catch (error) { return this.failTutor('tutor', error); }
  usage = addUsage(usage, toTurnUsage(result.usage));

  // forbidden / error：照現況回傳（usage 已含 guard + 本圈）
  if (result.status === 'forbidden') { /* 同 :160-166，return {content, usage} */ }
  if (result.status === 'error')     { /* 同 :167-172，return {content, usage} */ }
  if (result.guardSkipped) this.deps.emit('status_update', { warning: 'tutor: guard credential accepted under fail-open' });

  // 蒐集「可行（新的、尚未解析）」load_file
  const loads = result.actions.filter((a): a is Extract<TutorAction,{type:'load_file'}> => a.type === 'load_file');
  let madeProgress = false;
  if (i < MAX_CONTINUATIONS) {
    for (const a of loads) {
      const r = await this.loader.resolve(this.deps.directory, a.path, budget);
      if (resolved.has(r.key)) continue;                 // 去重 → no-op、不耗 iteration（§4.5/§4.7）
      resolved.set(r.key, r.ok ? 'loaded' : 'unavailable');
      loadedBlocks.push(r.block);                         // 內容區塊 或 marker
      madeProgress = true;
    }
  } else if (loads.some(a => !resolved.has(/* 對應 key */))) {
    this.deps.emit('status_update', { warning: '已達載入上限（MAX_CONTINUATIONS），停止自動續傳' });
  }

  if (madeProgress) {                                     // 載到新檔 → load 優先、延後 edit（§4.5）
    this.deps.emit('continuation', { iteration: i + 1, loaded: [...resolved.keys()] });
    continue;                                             // 重發 POST：同 prompt/history/guardLogId、加大 file_context
  }

  // 終端 turn：emit 文字 + dispatch（load_file 已被 driver 消費，過濾掉）
  this.deps.emit('text_output', { content: result.content });
  this.deps.emit('phase_end', { phase: 'tutor', success: true });
  await this.dispatchActions(result.actions.filter(a => a.type !== 'load_file'));
  return { content: result.content, usage };
}
```

要點：
- **guard 與 buildFileContext 各跑一次**；只有 `tutorChatGateway.send` 每圈重跑（b3 §4.7）。
- **終止三保險**：去重（madeProgress=false → 終端）、`MAX_CONTINUATIONS` 硬上界、cap 耗盡→marker。
- `loader` 在 constructor 建好一次（`new ContinuationFileLoader(this.fileSystem, new PathConfinement(this.fileSystem), extractPdfText)`）。

### Step 5 — `load_file` 退出終端 dispatch（G2，含 §2.2 死碼）

`execute-tutor-use-case.ts`：
- 刪 `dispatchActions` 內 `case 'load_file': await this.dispatchLoadFile(action); break;`（`:206`）。
- 刪整個 `dispatchLoadFile()`（`:269-274`）。
- `TutorAction` 型別與 `isTutorAction`（`tutor-actions.ts`）**保留** `load_file`（後端仍會回傳；driver 消費它）。
- 確認 `dispatchActions` 只剩 `edit_file`/`execute_script`，且只在終端被呼叫。

### Step 6 — 常數（G6）

`execute-tutor-use-case.ts` 頂部加：
```ts
const MAX_CONTINUATIONS = 3;   // 硬終止不變式（b3 §4.4、§8）；Phase 0 後可降到 2
```
既有 `PER_FILE_TOKEN_CAP=1200`、`PER_TURN_FILE_CONTEXT_TOKEN_CAP=2200` 維持（Phase 0 校準）。

### Step 7 —（可選）TUI `continuation` 事件（G11）

1. `agent-service.ts` 的 `AgentEvent` discriminated union 加一支：
   `| { type: 'continuation'; data: { iteration: number; loaded: string[] } }`。
2. `tui/presentation/event-mapper.ts` 加 `case 'continuation':`，回
   `makeMessage('status', \`自動載入 ${data.loaded.length} 個檔案後續傳（第 ${data.iteration} 圈）\`)`。
   （`default: return {}` 已存在，不加也不會 crash —— 但加了 demo/論文敘事更清楚。）

---

## 5. 測試計畫（對齊 b3 §9，G12）

| 層級 | 檔案 | 案例 |
|---|---|---|
| 嗅探 | `tests/unit/domain/text-content-policy.test.ts` | 文字 true、NUL false、高控制字元 false、空檔 true |
| 解析器 | `tests/unit/application/continuation-file-loader.test.ts` | confine 失敗→marker+`unresolved:` key；純文字超 cap→`take` 截斷；PDF 抽取後超 cap→截斷；PDF 過大→預過濾 marker；binary→unsupported marker；budget 耗盡→skipMarker |
| 迴圈 | 擴充 `tests/unit/application/execute-tutor-use-case.test.ts` | (a) `load A → edit A` 兩圈成功；(b) 重複 `load A` 去重、不耗 iteration、不重複 append；(c) `unavailable A` 後再請求 A → 轉終端；(d) `load+edit` 同回採 load 優先（新檔）/ edit 直走（已解析）；(e) 達 `MAX_CONTINUATIONS` 仍要 load → 停止 + emit「已達載入上限」；(f) 跨圈 usage = guard + Σ tutor |

既有測試的 mock registry/gateway 模式（`makeOptionB` / `makeReadRegistry`）可直接沿用；
解析器以 mock `IFileSystem`（仿 path-confinement.test.ts 的注入式 realpath）+ mock `extractPdf` 測。

---

## 6. 建議提交順序（每步可獨立綠燈）

1. **Step 1**（text-content-policy + 測試）—— 葉節點、無依賴。
2. **Step 2b**（抽出 `extractPdfText`，`PdfReadTool` 改用）—— 純重構，既有 PDF 測試不變。
3. **Step 2**（ContinuationFileLoader + 測試）—— 依賴 1、2b。
4. **Step 3**（budget 提升到 turn scope）—— 小重構，既有 §C 預算測試應仍綠。
5. **Step 4 + Step 5 + Step 6**（迴圈 + 刪死碼 + 常數）—— B3 核心，一起提交、配迴圈測試。
6. **Step 7**（TUI 事件）—— 可選，最後。
7.（可選）後端 Phase 0 log —— 獨立小 PR。

---

## 7. 風險與校準（Phase 0 要量的）

- **base 餓死續傳載入（§2.3）**：shared per-turn pool 若被 base 吃光，續傳第 0 圈即 skipMarker。
  先保持單一 pool（符合既有設計註解）；Phase 0 量「base 用掉多少 / 載入還剩多少」，若常餓死 → 拆 base/load 兩額度。
- **whole-or-drop 自我中毒（b3 §6 風險 1）**：後端 `budget_aware_prompt_assembler.rb:58` 對 `file_context`
  整塊放/丟。per-file + per-turn cap + `MAX_CONTINUATIONS` 是 §8.5 per-file cap 落地前的安全網——
  **caps 的校準必須讓 base+loaded 穩定 < 後端 ~8K**，否則某圈整塊被丟 → 模型重發 load_file。
- **`MAX_CONTINUATIONS` 值**：暫定 3；Phase 0 看 loop 深度分布後可降 2。
- **延遲/成本**：N 圈 = N 次 round-trip + N 筆 quota；去重 + cap 控制，§8 量實際分布。

---

## 8. 驗收清單

- [ ] `load_file` 不再進終端 dispatch；`dispatchLoadFile()` 已刪（§2.2）。
- [ ] PDF 載入路徑經 PathConfinement 收斂（不再走 `pdf_read` 的 cwd resolve，§2.1）。
- [ ] binary 檔以 marker 拒絕、不進 context（§2.4）。
- [ ] resolved set 對「成功/失敗」皆去重，失敗 key 用 `unresolved:`（§2.5）。
- [ ] base 讀檔與續傳載入共用同一 `FileContextBudget`（§2.3）。
- [ ] `load A → edit A` 在單一 user turn 內自動完成（B3 體驗成立）。
- [ ] 達 `MAX_CONTINUATIONS` 必終止，並回饋使用者。
- [ ] 跨圈 usage 正確累加（guard + Σ tutor）。
- [ ] 後端零程式改動（除可選 Phase 0 log）。
- [ ] §5 測試全綠。
