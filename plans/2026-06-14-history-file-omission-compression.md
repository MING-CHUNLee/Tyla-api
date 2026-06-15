# History 檔案省略壓縮（File-Omission History Compression）— 評估

**Date:** 2026-06-14
**Status:** 評估保留 / 落點已改後端（2026-06-15 轉向 Option C，見下）。本文的訊號分類、placeholder
措辭、中性 edit 措辭、contract 保命、角色配對不變量、CE 框架**全部沿用**——僅執行端由前端搬到後端。
**Scope:** 多輪對話時，前端如何把一個已完成 turn 序列化成送給後端的 `history`
條目——保留「使用者問過什麼 / 模型看過哪些檔 / 模型改過什麼」，但**省略檔案內容**，
以降低 token 與注意力稀釋。後端 `POST /api/v1/tutor_chats` 預期**零程式改動**。
**直接延伸 / 相關：**
- [2026-06-15-option-c-backend-owned-history-compression.md](./2026-06-15-option-c-backend-owned-history-compression.md)
  — **後續取代本文落點結論**：同一目標改採後端組裝（Option C）。本文 §2「為什麼前端做」的前提
  （後端收不到素材）在 Option C 透過擴 contract 翻轉；§3–§4 的序列化規格被原樣移植進後端 value object。
- [2026-06-06-prompt-compression-mechanism.md](./2026-06-06-prompt-compression-mechanism.md)
  — rolling-summary 壓縮機制；本案是其互補的**前置**手段（先讓 history 不膨脹，才更少觸發 summary）。
- [2026-06-07-b3-frontend-continuation-driver.md](./2026-06-07-b3-frontend-continuation-driver.md)
  — 前端是 `history` / `file_context` 的組裝方；本案落點同在前端 `execute-tutor-use-case.ts`。
- [2026-06-11-hybrid-lazy-solution-implementation.md](./2026-06-11-hybrid-lazy-solution-implementation.md)
  — just-in-time 載入哲學一致：留識別碼、需要時再取。
- 參考 Anthropic, *Effective context engineering for AI agents*（下文以〔CE〕標注）。

---

## 0. TL;DR

1. **這是前端工作，後端不動。** 後端
   [`RunTutorChat`](../app/application/services/tutor_chat/run_tutor_chat.rb) 只把 `history`
   原封 trim 後丟給 LLM，**從不重建 history**；而且它收到的 history 只有
   `[{role, content}]`（[tutor_chat.rb:17-20](../app/application/requests/tutor_chat.rb#L17-L20)），
   拿不到範例裡的 `apiLogs` / `actions` / `file_context`。因此「把檔案內容換成 placeholder」
   只能在**前端把 session → history 序列化時**做。
2. **`file_context` 本來就不在 history。** 它是 current-turn 的獨立 channel；第二輪帶第二輪自己的
   `file_context`。所以「remove files from history」的真義是：**合成 assistant turn 時，別把當時看過的
   檔案內容塞進 `content`**，只留「看過 hw2.R、內容已省略、可 load_file 再取」的敘事。
   框架：**history＝意圖/行動的敘事；file_context＝當前檔案真相**，兩者不重複〔CE〕。
3. **草案未處理、會出錯的點：**
   - **assistant `content` 不能空。** Contract 是 `required(:content).filled(:string)`
     （[tutor_chat.rb:19](../app/application/requests/tutor_chat.rb#L19)），空字串 turn 直接 `400`。
     範例第一輪 `assistantMessage: ""`（純 edit_file、無 prose）就是這個情況——所以「合成 assistant
     摘要」不是選配，是**讓 action-only turn 能進 history 的必要條件**。
   - **proposed vs applied 目前判不出來 → 用中性措辭**（§3.3 ⚠️ 修正）。前端 tutor turn 的
     `fileChanges` 恆空，無法判定 edit 是否被套用；edit 序列化成「Suggested editing line 8: X → Y」
     不主張套用狀態，把真相交給下一輪 live `file_context` ＋ 系統 prompt 仲裁。
   - **placeholder 措辭不能用 "Loaded"**（§4.3）：那是 tool 的 live-狀態保留字，會誘導模型跳過
     `load_file` → 被 gate 攔截白繞一輪。改用「Previously inspected … call load_file」。
   - **`userMessage` 不能無條件逐字**（§3.4）：學生貼整檔會繞過整個壓縮，須 strip 貼入 code。
   - **execute_script 結果未持久化**（§6.6 修正）：前端 r_exec 結果只 emit 不入 turn，故 history 無法附
     錯誤 tail；要保留錯誤情境需先做持久化前置（非本案）。
   - **角色須成對**（§3.5）：Anthropic 首則須 user 且嚴格交替，pair-or-skip 是不變量。
4. **此方案是 deterministic、近零成本**（純模板，不呼叫 LLM），與 2026-06-06 的 rolling summary
   正交互補：它先讓每個 turn 不膨脹，rolling summary 才更少被觸發。

---

## 1. 目標與範例拆解

### 1.1 DEV 目標（原話）

> In conversation history, remove all FILES (just let LLM know that file(s) are removed; can
> ask again). 第二輪只需帶第一輪的：**使用者要求過什麼 / LLM 知道過什麼內容 / LLM 改過什麼**；
> 細節不需要，但回報錯誤時 LLM 至少知道過往發生什麼事。

### 1.2 範例 turn（節錄三個有訊號的欄位）

```
userMessage : "In @hw2.R, I want to calculate the quartiles ... Please fix it directly for me."
file_context: "### hw2.R\n 1| ...\n 8| quartiles_d123 <- quantile(d123, probs = c(0.25, 0.50, 0.75))\n ..."  (整檔)
actions     : edit_file hw2.R { start_line: 8,
                                search:  "...probs = c(0.25, 0.50, 0.75))",
                                replace: "...probs = c(0.25, 0.5, 0.75))" }
assistantMessage: ""            ← 純 action、無 prose
fileChanges     : []            ← 注意：實際套用為空（提議尚未 apply）
```

### 1.3 三類要保留的訊號（與成本）

| 訊號 | 來源 | 保留形式 | token 成本 |
|---|---|---|---|
| 使用者要求過什麼 | `userMessage` | **保留意圖；但貼入的大段 code 要 strip**（見 §3.4） | 低 |
| LLM 看過哪些檔 | 當時的 `file_context` 的 `### path` 標頭 | **只留路徑 + 「內容已省略，可再取」**，**丟內容** | 近零 |
| LLM 改過/提議什麼 | `fileChanges`（優先）或 `actions` | **逐字保留 search/replace + 行號**（小、決定性高）〔CE〕 | 低 |

〔CE〕原則對照：保留「問題 / 決定 / 出現過的檔名函式名」、丟棄「冗餘的 tool/file 輸出」——
本表正是它的 deterministic 落地。

> **注意：`userMessage` 不是無條件逐字保留。** 它保留的是**意圖**，不是學生貼進聊天框的整支檔案。
> 最常見的膨脹來源之一正是「把整段/整檔 code 貼進 prompt」——若逐字保留，本案對 token / 注意力的
> 改善會被這條路徑吃掉。`userMessage` 須走輕量 strip（§3.4）：偵測大段 code block / `N| ` 區塊 →
> 截斷或換 placeholder，與 file-omission 同調。

---

## 2. 職責邊界：為什麼是前端做

- 後端 [run_tutor_chat.rb:198-211](../app/application/services/tutor_chat/run_tutor_chat.rb#L198-L211)
  把 `params[:history]` 原封交給 assembler；
  [budget_aware_prompt_assembler.rb:131-148](../app/application/prompts/builders/budget_aware_prompt_assembler.rb#L131-L148)
  只做 newest-first **token trim**，把每個 turn 當**不透明字串**估算，**不解析、不重建內容**。
- 後端 contract 只收 `[{role, content}]`——它**手上沒有** `apiLogs` / `actions` / 當時的
  `file_context`，物理上無法重建這份壓縮敘事。
- 這與既有的 **manifest 責任分工**一致：course materials = 後端；student workspace / `file_context`
  = 前端。history 的內容字串既然由前端組裝，壓縮也歸前端。
- 結論：**前端在 turn 完成、要組下一輪 `history` 時，把該 turn 序列化成壓縮條目**。後端零改動，
  既有 budget trim、gates、warnings 全部不受影響。

> **資料來源已確認（2026-06-14）。** 前端 session 檔
> （`.tyla/sessions/session-*.json`）已記錄完整 `apiLogs`（含 tutor request 的 `prompt` /
> `file_context`、tutor response 的 `actions`）＋ turn 層的 `fileChanges`。這正是壓縮的**素材來源**。
> 關鍵分清兩件事：`apiLogs` 是**前端 session 的素材**，用來壓；**送去後端的仍只有 `[{role, content}]`**——
> `apiLogs` 不上線。資料流：**前端讀自己 session 的 apiLogs → 壓成 `[{role, content}]` → 才 POST**。

> **唯一的後端可選後盾**：若擔心舊前端仍把整包 `file_context` 灌進 `content`，可在後端加一個
> **防禦性 strip**（偵測 `### path` + `N| ` 區塊、替換成 placeholder）。但這是 nice-to-have，
> 不是本案主線，且要小心別誤刪學生真的貼在 prompt 裡的程式碼。預設**不做**，靠前端正確組裝即可。

---

## 3. 三個關鍵正確性考量（草案缺的部分）

### 3.1 `file_context` 不在 history —「remove files」的真正語意

current-turn 的 `file_context` 是**獨立欄位**，不會進 history（見 §2）。所以第一輪的 `file_context`
在第二輪本來就「消失」了——模型第二輪只看到第二輪的 `file_context`。

因此本案不是「從 history 刪掉 file_context」（它不在那），而是：**前端合成 assistant/user turn 的
`content` 時，不要把檔案內容寫進去**，改放 placeholder。框架要清楚：

- **history** 回答「**之前發生了什麼**」（使用者問了、模型看了哪些檔、改了什麼）——敘事。
- **file_context** 回答「**檔案現在長怎樣**」——當前真相，每輪重送最新版。

把檔案內容複製進 history 是雙重浪費：既膨脹 token，又可能與當前 `file_context` 不一致（stale）。
**省略內容正是對的**〔CE〕：最便宜的 token 是沒送出去的那個。

### 3.2 assistant `content` 不能是空字串（contract 硬限制）

[tutor_chat.rb:19](../app/application/requests/tutor_chat.rb#L19) 是 `required(:content).filled(:string)`。
範例第一輪 `assistantMessage: ""`（純 edit_file、無 prose）若原樣放進 history：

- 整個 request 會 **`400 bad_request`**（`history[i].content` must be filled），或
- 前端為了避開 400 而**丟掉這個 assistant turn** → 模型完全不知道自己上一輪做過 edit。

兩者都壞。**所以「合成 assistant 摘要」是必要條件，不是優化**：action-only turn 必須被合成成一段
非空的、描述「我（提議）改了什麼」的文字，history 才能既合法又保留行動記憶。

### 3.3 「提議」vs「已套用」——忠實度

範例 `fileChanges: []` 且 `outputs: []`：edit 是**提議**，前端的 approval gate 還沒套用
（前端 session 用 `apiLogs`=提議、`fileChanges`=實際套用 兩個欄位區分）。

若 history 寫「我已把 line 8 的 probs 改成 c(0.25, 0.5, 0.75)」，但第二輪 `file_context` 顯示 line 8
還是舊的 → **模型看到自打臉的矛盾**，可能重複提議或困惑。正解：

- 以 **`fileChanges`（實際套用）** 當權威來源描述「已改」。
- `apiLogs[tutor.response].actions`（**提議**）裡被拒絕 / 未套用的 → 寫成「我提議…（尚未套用）」或省略。
- **⚠️ 修正（2026-06-15，讀前端碼後）：proposed-vs-applied 目前在前端 tutor 路徑上判不出來。**
  原以為「session 有 `apiLogs`（提議）＋ `fileChanges`（已套用），比對即可」，但前端 tutor turn 由
  `agent-service.ts:286` 建立時 **fileChanges/outputs 硬傳 `[]`**，approve/reject 只發事件、不寫回 turn。
  故 `fileChanges` 恆空、判不出套用狀態。**落地建議改走「中性措辭」**：edit 序列化成
  「Suggested editing line 8: X → Y」**不主張套用與否**，把「改了沒」交給下一輪 live `file_context`（權威）
  ＋ 下方那句系統 prompt 仲裁。若要忠實 applied/proposed，需先在前端持久化 approve/reject（獨立前置，
  非本案）。細節見前端落地文件 `MindyCLI_demo/plans/2026-06-15-history-file-omission-serialization.md` §3.3。

> **更深一層的 staleness（§3.3 沒蓋到）：已套用後又被學生手動改回。** history 寫 "Edited"，但第二輪
> `file_context` 的該行又回到舊內容 → 一樣自打臉。proposed-vs-applied 只解決「套用當下」的忠實度，
> 解不了「事後被改」。對策不是在序列化端推斷（前端無法保證），而是**讓 live `file_context` 永遠是最終
> 仲裁**：在系統 prompt 明示「history 為過往敘事；與當前 `file_context` 衝突時一律以 file_context 為準」。
> 這是後端唯一的一行 prompt 文案改動（`TutorSystemPrompt`），不是邏輯改動。

### 3.4 `userMessage` 也要 strip 貼入的大段 code（草案缺）

§1.3 表已修正：`userMessage` 保留**意圖**而非逐字整檔。理由：學生把整支 R 檔貼進聊天框是常態，
逐字保留會讓本案對 rolling-summary 觸發率（§5）的改善失效。落地：

- 偵測 `userMessage` 內的 fenced code block（```` ``` ````）或連續 `N| ` 行區塊。
- 超過門檻（暫定 > 後述 `PASTE_CAP`）→ 截斷並標注 `[pasted code omitted; ask to re-share if needed]`，
  與 file-omission placeholder 同調。
- **意圖文字（散文）一律保留**——只壓貼入的 code，不壓問句。

### 3.5 角色配對是 Anthropic 的硬不變量

後端 [anthropic_client.rb:23-26](../app/infrastructure/llm/anthropic_client.rb#L23-L26) 把 history 直接映射成
`messages` 再接 current user_message；Anthropic 要求**首則為 user 且嚴格交替**。本案每個 turn 必須恰好
push **一對** user/assistant（§4.6 的 pair-or-skip 不是優化，是不變量）。

> **既有隱患（非本案造成，但本案是修它的好時機）**：後端 trim 是**逐條** newest-first
> （[budget_aware_prompt_assembler.rb:137](../app/application/prompts/builders/budget_aware_prompt_assembler.rb#L137)），
> 非逐對；理論上可裁出「以 assistant 開頭」的 history → Anthropic 400。本案讓 history 變成工整的成對結構，
> 適合順手把 trim 粒度改成「逐對」。

---

## 4. `serializeTurnToHistory(turn)` 規格

維持 contract 不變：輸出仍是 `[{role, content}]`。本節定義「一個完成的 session turn → 一對
user/assistant 條目」的 deterministic 函式，前端可照此實作。

### 4.1 簽章與常數

```ts
// 輸入：session 的一個 turn（含 userMessage / assistantMessage / fileChanges / outputs / apiLogs）
// 輸出：要 append 進下一輪 history 的條目（恰一對；degenerate turn 見 §4.6）
function serializeTurnToHistory(turn): Array<{ role: 'user' | 'assistant', content: string }>

const PROSE_CAP   = 600;   // assistant prose 字元上限，超過截斷加「…」
const PATCH_CAP   = 400;   // 單一 search/replace 字元上限，超過截斷加「…」
const SCRIPT_CAP  = 200;   // execute_script code 摘要字元上限
const PASTE_CAP   = 200;   // userMessage 內貼入 code 區塊上限（§3.4），超過換 placeholder
// （ERROR_TAIL_CAP 已移除：execute_script 結果未持久化，§6.6 修正。）
// 所有文案用英文，對齊系統 prompt 語言。
// 截斷一律以「字元」為單位但須避免切斷多位元組字元 / 切進 ``` fence——用安全截斷工具。
```

### 4.2 Step 0 — 把 turn 的多筆 apiLogs 收斂成「終端 tutor 交換」

一個 turn 在**前端 session** 可能有多筆 tutor request/response（**僅 B3 續傳**；hybrid lazy 是後端單
HTTP 內部、不入前端 apiLogs，見 §6.7）。先收斂：

```
tutorLogs   = turn.apiLogs.filter(l => l.source === 'tutor')
reqLogs     = tutorLogs.filter(l => l.direction === 'request')
respLogs    = tutorLogs.filter(l => l.direction === 'response')

prompt      = turn.userMessage                       // 該 turn 不變；fallback: reqLogs[0].payload.prompt
seenPaths   = unique( reqLogs.flatMap(r => extractHeaderPaths(r.payload.file_context)) )  // union 去重
terminal    = respLogs[respLogs.length - 1]?.payload  // 終端那次回應：取它的 content + actions
prose       = terminal?.content ?? turn.assistantMessage
actions     = terminal?.actions ?? []
```

`extractHeaderPaths(fileContext)`：抓所有 `^### (.+)$` 行的路徑（即 §workspace-edit-gate 用的
`### <relative path>` 標頭）。範例 `file_context` → `["hw2.R"]`。**只取標頭、丟掉所有 `N| ` 內容行**。
**只掃 `file_context`，不掃 `workspace_overview`**：後者是並列的獨立 payload 欄位（內容如
`R scripts (.R): hw2.R`），目前無 `###` 標頭故不會誤抓，但仍須明確只把 `file_context` 餵進
`extractHeaderPaths`，以免日後 overview 改格式時靜默誤命中（§6.8 格式耦合的同一道防線）。

**換行相容（LF 與 CRLF 都要支援）**：file_context 在 Linux 是 LF、Windows 是 CRLF。JS 的 `.`
會匹配 `\r`，故 `^### (.+)$` 在 CRLF 檔頭（`### Hw2.Rmd\r\n`）會把路徑抓成 `"Hw2.Rmd\r"`（尾隨 CR）。
extractHeaderPaths 須去尾 CR——用 `^### (.+?)\r?$`（multiline）或抓出後 `path.replace(/\r$/, '').trim()`，
讓 LF（無 CR）與 CRLF（一個 CR）一致通過。後端 [strip_section_headings](../app/application/prompts/builders/budget_aware_prompt_assembler.rb#L155)
用 `lines.grep_v(/\A##[^#]/)` 只看行首、`.join` 保留原換行，本就 LF/CRLF 皆安全；不一致風險只在前端這條。

> B3 續傳的中間回應（只 `load_file`、尚未作答）**不寫進敘事**（§6.7）——只看終端回應。`seenPaths`
> 取 union 是因為續傳會累積載入多個檔，全都「看過」了。

### 4.3 Step 1 — user 條目

```
content = stripPastedCode(prompt)                    // §3.4：壓掉貼入的大段 code，保留意圖
if (seenPaths.length > 0)
    content += "\n\n[Previously inspected last turn (contents not included now; "
             + "call load_file to see them again): " + seenPaths.join(", ") + "]"
push({ role: 'user', content })
```

- placeholder **帶路徑 + 可取回提示**，對齊 §1.1 原話「can ask again」與 just-in-time〔CE〕。
- **措辭避開 tool 保留字**：系統 prompt 的 `edit_file` / `load_file` 用 **"loaded" / "live" / "shown"**
  專指「**現在**就在 Student Workspace (live) 的檔」（[run_tutor_chat.rb:43-49](../app/application/services/tutor_chat/run_tutor_chat.rb#L43-L49)）。
  若 placeholder 寫「Loaded last turn」，模型可能誤判 hw2.R **現在是 loaded 狀態** → 直接 `edit_file`
  跳過 `load_file` → 被 [WorkspaceEditGate](../app/application/services/tutor_chat/run_tutor_chat.rb#L339) 攔下
  改寫成 load_file、回 `edit_file_redirected`，白繞一輪。故改用 **"Previously inspected … call load_file
  to see them again"**，明示「**過去看過、現在未載入**」。
- 語意是**過去快照已省略**，不是宣稱「現在拿不到」——下一輪 live `file_context` 仍可能重送該檔的最新版，
  兩者不衝突（§3.1：history＝敘事，file_context＝當前真相）。
- `stripPastedCode` 見 §3.4：對 `prompt` 內的 fenced code / `N| ` 區塊套 `PASTE_CAP`。

### 4.4 Step 2 — assistant 條目（各 action type 渲染）

```
lines = []
if (prose && prose.trim()) lines.push( truncate(prose.trim(), PROSE_CAP) )
for (a of actions) lines.push( renderAction(a) )   // 路 A：不看 fileChanges（§3.3 ⚠️）
content = lines.join("\n")
if (!content.trim()) content = "(No actionable reply.)"   // §4.6 contract 保命
push({ role: 'assistant', content })
```

`renderAction(a)`：

> **⚠️ 此節的 `fileChanges` 比對與 error-tail 已被前端碼推翻（2026-06-15）——以前端落地文件
> `MindyCLI_demo/plans/2026-06-15-history-file-omission-serialization.md` §3.3/§5 的「路 A 中性措辭」為準。**
> 下表保留原構想供對照，但實作請勿查 `fileChanges`、勿寫 error tail。

| type | 渲染（修正後 = 路 A） | 備註 |
|---|---|---|
| `edit_file` | 每個 patch 一段（見下），**中性措辭** | 不查 `fileChanges`（恆空，§3.3 ⚠️）；不寫 applied/not-applied |
| `load_file` | `"Requested the contents of \`<path>\`."` | 終端才會出現（如被 redirect）；中間圈不渲染 |
| `execute_script` | `"Suggested a demo script: \`<truncate(code, SCRIPT_CAP)>\`"` | read-only；**結果不寫**（前端未持久化 r_exec 輸出，§6.6 修正） |
| 其他/未知 | 略過 | 防呆 |

`edit_file` 每個 patch（路 A：中性措辭、不主張套用狀態）：

```
// 單行 patch → 內嵌箭頭；多行 → 採 -/+ diff block（較可讀、無歧義）
body    = isSingleLine(patch.search, patch.replace)
            ? "`" + truncate(patch.search, PATCH_CAP) + "` → `" + truncate(patch.replace, PATCH_CAP) + "`"
            : "\n- " + truncate(patch.search, PATCH_CAP) + "\n+ " + truncate(patch.replace, PATCH_CAP)
line = `Suggested editing \`${a.path}\` (line ${patch.start_line}): ${body}`
```

> **~~`fileChanges` 比對~~（已作廢，§3.3 ⚠️）**：前端 tutor turn 的 `fileChanges` 恆空、approve/reject
> 不入 turn，無法判定套用狀態。路 A 不做比對、不分 applied/proposed。

### 4.5 worked example（範例 turn 1 → round 2 的 history，路 A）

```jsonc
[
  { "role": "user",
    "content": "In @hw2.R, I want to calculate the quartiles (25th, 50th, and 75th percentiles), but the probs I used seem incorrect. Please fix it directly for me.\n\n[Previously inspected last turn (contents not included now; call load_file to see them again): hw2.R]" },
  { "role": "assistant",
    "content": "Suggested editing `hw2.R` (line 8): `quartiles_d123 <- quantile(d123, probs = c(0.25, 0.50, 0.75))` → `quartiles_d123 <- quantile(d123, probs = c(0.25, 0.5, 0.75))`" }
]
```

（assistant prose 為空 → 純 edit 敘事，中性措辭、非空 → 滿足 contract。是否真的套用交給下一輪 live `file_context`。）

### 4.6 degenerate turn

- prose 空 **且** 無可渲染 action → assistant content 退回 `"(No actionable reply.)"`（保證非空，§3.2）。
  正常情況不會發生：後端 `FALLBACK_PROSE`
  （[run_tutor_chat.rb:37-38](../app/application/services/tutor_chat/run_tutor_chat.rb#L37-L38)）已保證終端
  回應非空。
- 若連 `userMessage` 都空（理論上不該有）→ 跳過整個 turn，不 push。

---

## 5. 與既有壓縮機制的關係

| | 本案（file-omission 序列化） | 2026-06-06 rolling summary |
|---|---|---|
| 時機 | **每個 turn 完成時**就壓 | history **溢出 budget 時**才壓 |
| 成本 | **0 次 LLM 呼叫**（deterministic 模板） | 多 1 次 LLM 呼叫 |
| 對象 | 單一 turn 的檔案內容 → placeholder | 一批舊 turns → 語意摘要 |
| 落點 | **前端** | 後端 `HistorySummarizer`（collaborator） |
| 關係 | **前置 / 互補**：先讓每 turn 不膨脹 | 仍處理「turn 數太多」的長尾 |

兩者不衝突：本案砍掉「單 turn 內的檔案 bloat」，rolling summary 砍掉「turn 數累積」。先做本案，
能**大幅降低 rolling summary 的觸發率**（甚至在 demo 規模下可能就不需要 summary），因為最肥的
file_context 不再被複製進 history。

---

## 6. 風險與邊角

1. **`edit_file` 的 exact-search 不受影響。** history 不會被 patch（只有 current `file_context`
   會），所以把 search/replace 放進 history 純為敘事、無 exact-match 風險。
   參見 [2026-06-04-response-design-challenges-report.md](./2026-06-04-response-design-challenges-report.md) Case 1。
2. **stale / 矛盾（§3.3）** 是最主要風險：必須 approval-aware，否則 history 與 `file_context` 互咬。
3. **後端 trim 仍會丟舊 turn**（[budget_aware_prompt_assembler.rb:137](../app/application/prompts/builders/budget_aware_prompt_assembler.rb#L137)）：
   壓縮後每 turn 更小 → 同 budget 下能留更多 turn，與 trim 正向協同。被丟仍會回
   `history_truncated` warning，行為不變。
4. **Tokenizer 是 heuristic**（chars/3.5）：壓縮率 ≠ token 節省率，需實測，與 2026-06-06 §6 同。
5. **隱私**：同一批資料、更少內容外送；無新風險。檔案內容本來每輪都在 `file_context` 送，
   本案只是**不再額外複製一份進 history**。
6. **execute_script 輸出**：§4.4 `renderAction` 只摘 code（`SCRIPT_CAP`），不寫執行結果。
   **⚠️ 修正（2026-06-15）**：原本想「錯誤輸出留 tail」以對齊 §1.1「回報錯誤時 LLM 至少知道發生什麼」，
   但前端 r_exec 結果只 `emit('tool_result_r_exec')` 後即丟、**不入 turn**（`turn.outputs` 對 tutor 恆空），
   故 history 取不到 stderr。要保留錯誤情境須先在前端持久化 r_exec 結果（獨立前置，非本案）。目前**不寫**。
7. **一個 turn 可能有多筆 tutor `apiLogs`——但來源只有 B3 續傳，不含 hybrid lazy。** B3 續傳迴圈
   （`load_file` → 前端重發，**跨 HTTP**）會讓同一 student turn 在**前端 session** 出現多筆 tutor
   request/response。**hybrid lazy 的 round1+round2 不算**：它整段在**後端單一 HTTP request 內**完成
   （[tutor_mini_loop](../app/application/services/tutor_chat/run_tutor_chat.rb#L186-L196)），且 `load_reference`
   「never reaches the client」——前端 session 對 hybrid lazy 只會看到**一個** DTO，apiLogs 裡**找不到**
   round1。實作者勿去 session 找不存在的 hybrid round1 log。序列化時把整個 turn 收斂成**一對**
   user/assistant：prompt 取該 turn 的（不變），actions 取**終端那次 response**（中間的 `load_file`
   不寫進敘事），edits 以 `fileChanges` 為準。
8. **`### <path>` 檔頭格式 = 跨 repo 明文約定（非合約）**：`extractHeaderPaths` 抓 `^### (.+)$`，依賴前端
   file_context 產生器永遠用這個檔頭格式。此格式現為**四方共同依賴**：(a) 後端 gates 的 regex
   （`RedundantLoadGate` / `WorkspaceEditGate` / `EditPatchContentGate`）、(b) 後端
   [strip_section_headings](../app/application/prompts/builders/budget_aware_prompt_assembler.rb#L155)
   （只剝 `## `、刻意保留 `###`）、(c) 後端 guide 的 `### path` 語義
   （[2026-06-14-live-section-heading-shadow.md](./2026-06-14-live-section-heading-shadow.md) §2B）、
   (d) 本案前端 `extractHeaderPaths`（§4.2）。**約定內容**：`### <relative path>` ＝恰三個 `#` ＋一個空格
   ＋ workspace 相對路徑，自成一行（**LF 或 CRLF 結尾皆可**，見 §4.2 去尾 CR）；`## `（兩井號）保留給前端
   組裝用的 section 標籤，所有 consumer 一律 strip／忽略。建議前後端共用一個檔頭常數＋**兩端各自測試固定**，
   避免 file_context 改格式時 `extractHeaderPaths` 靜默漏抓（seenPaths 變空 → placeholder 整條消失）。
   反向 cross-link 見 shadow §2B（guide 語義）與 §6（MindyCLI 清理勿動 `###`）。**落地規格**（後端抽
   `FileContextHeader` 共用常數 ＋ 前後端 spec 固定點）見
   [2026-06-15-shared-header-constant-and-format-tests.md](./2026-06-15-shared-header-constant-and-format-tests.md)。

---

## 7. 落點與改動清單

**後端（本 repo）— 邏輯零改動，僅一行 prompt 文案（可選但建議）：**
- contract、assembler、gates、warnings 全部不動。（可選的防禦性 strip 見 §2 引言，預設不做。）
- **唯一建議改動**：在 `TutorSystemPrompt` 加一句「history 為過往敘事；與當前 `file_context` 衝突時
  以 file_context 為準」（§3.3 staleness 後盾）。純文案，無邏輯。
- **可順手做（非本案必須）**：把 [trim_history](../app/application/prompts/builders/budget_aware_prompt_assembler.rb#L131-L148)
  從逐條改逐對，消除「history 以 assistant 開頭 → Anthropic 400」的既有隱患（§3.5）。

**前端（MindyCLI_demo）— 主要工作：**
- 在組裝下一輪 `history` 的地方（session → `[{role, content}]` 的序列化），實作 §4 的
  `serializeTurnToHistory(turn)`（Step 0 收斂多 apiLog → Step 1 user 條目 → Step 2 assistant 條目）。
- 實作 `extractHeaderPaths`（抓 `### path`、丟 `N| ` 內容）、`appliesPatch`（依前端 `fileChanges`
  實際 schema 比對，判定 applied vs not-applied）。
- 實作 `stripPastedCode`（§3.4：壓 `userMessage` 內貼入的 code）與 execute_script 錯誤 tail（§4.4）。
- placeholder 措辭用 §4.3 的 **"Previously inspected … call load_file"**，勿用 "Loaded/live/shown"。
- 維持 §4.6 pair-or-skip 不變量（Anthropic 首則須 user 且嚴格交替，§3.5）。
- 校準 §4.1 常數（`PROSE_CAP` / `PATCH_CAP` / `SCRIPT_CAP` / `PASTE_CAP` / `ERROR_TAIL_CAP`）。

---

## 8. 待決定（§4 規格已收斂大部分）

**§4 已定：** placeholder 文案（§4.3）、自然語句敘事（§4.4）、search/replace 截斷策略（`PATCH_CAP`，
多數小 patch 等於全保留）、`load_file` 渲染（終端才寫，§4.4 表）、execute_script 只摘 code 不寫 output。

**剩餘：**
1. §4.1 四個 cap 的**實際值**（`PROSE_CAP=600` / `PATCH_CAP=400` / `SCRIPT_CAP=200` /
   `PASTE_CAP=200` 為暫定，需實測校準）。（ERROR_TAIL_CAP 已移除，§6.6。）
2. ~~`fileChanges` schema → appliesPatch~~ **已作廢**：tutor turn 的 `fileChanges` 恆空（§3.3 ⚠️），
   路 A 不比對。若日後要忠實 applied/proposed，先在前端持久化 approve/reject（獨立前置）。
3. `apiLogs` schema **已確認**（`debug.log` / session JSON，2026-06-15）：tutor request 確有
   `file_context`（另含 `history`/`prompt`/`workspace_overview`）、response 確有 `actions`——`edit_file`
   為 `patches[]{start_line, search, replace}`、`execute_script` 為 `{type, code}`（無 patches）。
   **execute_script 的 output/stderr 不落在 tutor apiLogs 任何欄位**：response 只帶模型**提議的 `code`**，
   執行結果不回寫（前端 r_exec `emit` 後即丟、`outputs:[]`，§6.6）→ §4.4 error-tail **連潛在素材來源都不存在、
   確定不做**。此點**已無未取樣項、非阻塞**。
4. `### <path>` 檔頭格式：前端 file_context 產生器與 `extractHeaderPaths` 的 regex 須共用同一約定
   （建議抽成共用常數＋測試固定，§6.8 格式耦合）。
5. 是否要做 §2 的後端防禦性 strip 後盾（預設否）。
6. 是否採納後端那一行 staleness 仲裁文案（§3.3）與 trim 逐對化（§3.5）。
7. **Phase 0 量測（建議設為必做）**：log 壓縮前/後的 history token，驗證對 rolling-summary 觸發率的
   影響（§5）。tokenizer 是 heuristic（chars/3.5，§6.4），壓縮率 ≠ token 節省率，需實測背書。
