# `load_file` 無窮迴圈：對已載入檔案重複請求，前後端都沒有終止點

**Date:** 2026-06-13
**Status:** 設計定案，待實作（後端 §4、前端 §5）；2026-06-13 經 review 修正（見 §10）：空轉收尾提到 Phase 1、結構性保證改為條件性陳述、補跨 gate 排序測試與因果驗證項
**相關文件：**
- 「結構性 > prompt 勸說」先例：`plans/2026-06-04-action-reliability-issue.md`、`app/domain/values/workspace_edit_gate.rb` 檔頭註解
- 兩通道 workspace 契約：`plans/2026-06-12-workspace-context-contract-split.md`、`doc/api_tutor_chats.md`「Workspace edit gate」
- 同日姊妹案（也走「結構性 gate」哲學）：`plans/2026-06-13-edit-file-line-anchor.md`
- 前端 apply / load_file 解析：MindyCLI `tyla/src/application/use-cases/execute-tutor-use-case.ts`

> **一句話：** 模型對**已經在 `## Student Workspace (live)` 載入**的檔案重複回 `load_file`，前端忠實讀檔→重送→模型又重請求，**前後端都沒有終止點**，於是無限轉。修法分兩刀：後端加一個**結構性 gate**，丟掉「對已載入 path 的 `load_file`」（`WorkspaceEditGate` 的 `load_file` 對偶，**`file_context` 完整時保證迴圈終止**——若 file_context 被 budget 截斷致 `### header` 消失，退守前端 round cap，見 §6 D4／§7）；同份 system prompt 的 `WORKSPACE_OVERVIEW_GUIDE` 改寫，不再宣稱 live 裡的檔案沒載入（讓模型直接走 `edit_file`，而非空轉）。後端並保證「actions 被清空且無 prose」時不回空回合（決策 E，§6 D1，Phase 1）。前端再補兩個衛生措施：`file_context` append 去重、load_file 迴圈加 round cap（**與後端 gate 同為終止保證的一環，非純備胎**）。

---

## 0. 觸發事件（2026-06-13 觀測，真實 log）

學生 prompt：

```
Please help me fix the quartile settings in @hw2.R, and also check and correct
the skewness of d123 in Question 1 of Hw2.Rmd.
```

| 回合 | 後端收到的 `file_context` | 模型回應 actions |
|---|---|---|
| log 133（round 1） | `## File Contents` → `### hw2.R`（@-mention 帶進來的） | `load_file hw2.R`、`load_file Hw2.Rmd` |
| log 134（round 2） | `## File Contents → ### hw2.R` **＋** `## Files Loaded On Request → ### hw2.R、### Hw2.Rmd`（**兩個都已完整載入、帶行號**） | **又是** `load_file hw2.R`、`load_file Hw2.Rmd` |

round 2 兩個檔案明明都在 `file_context` 裡了，模型卻回了一模一樣的兩個 `load_file`。前端讀檔→重送→模型重請求→∞。**這就是「爆掉」。**

對照：這條迴圈是**前端驅動**的（`doc/api_tutor_chats.md:442`「The CLI keeps resolving `load_file` actions … and re-sending」）。後端唯一的 loop guard（`run_tutor_chat.rb` `tutor_mini_loop`）只管 `load_reference`、兩輪結構性終止；**後端對 `load_file` 無 cap**（前端有 `MAX_CONTINUATIONS = 3` + `resolved` dedup，但 dedup 不涵蓋 @-mention 帶入的 `baseFileContext`，見 §0 末 Step 0 結果）。

附帶觀察到的髒資料：round 2 的 `hw2.R` 同時出現在 `## File Contents` 和 `## Files Loaded On Request` 兩段（前端 append 沒去重）。不是迴圈主因，但放大了 token 浪費也增加模型混淆面。

### Step 0 結果（2026-06-13 已確認）

撈 MindyCLI `execute-tutor-use-case.ts`（`buildContext()`）確認：`file_scan` 無條件執行，掃描結果填入 `workspaceOverview` 並以 `workspaceOverview || undefined` 隨每次請求送出。**觸發當下 `workspace_overview` 確認在場**（`file_scan` 非空即送）。

結論：
- **§1.1 矛盾確實成立**：`WORKSPACE_OVERVIEW_GUIDE` 在 round 1、2 均有 render，「contents are NOT loaded → call `load_file` FIRST」與 live 區已載入的兩檔並存於同一 system prompt。
- **B（prompt 改寫）IS 相關**，應與 A 同波上線（見 §8 調整）。
- **§6 D1 空轉嚴重度**：普通（§1.1 矛盾 + §1.2 無 gate 共同作用，非最尖銳的「無 overview」情境）。

附帶觀察（影響 §8 C/D 優先排序）：
- 前端已存在部分終止保護：`resolved.has(r.key)` 去重（迴圈內已 resolved 的 path 不再 set `madeProgress`）+ `MAX_CONTINUATIONS = 3` hard cap。觸發 scenario 下前端在 round 2 API call 後即結束（`madeProgress = false`），並非真正無限轉，而是浪費 2 次 LLM call、無有效修改。
- **`resolved` 只追蹤 `loadedBlocks`，不涵蓋 `baseFileContext`（@-mention）**：`hw2.R` 因 @-mention 已在 `baseFileContext`，round 1 仍被重複 append 進 `loadedBlocks`（→ 重複 `### hw2.R`）。**C 的核心修法：把 @-mention 路徑也納入去重集合**，使模型在 live 區看到單一、完整的 `### hw2.R`（同時直接降低「巢狀標題讓模型認不出已載入」的混淆，§1.1 C 重新定位）。
- **D 剩餘工作小**：`MAX_CONTINUATIONS` 已存在；剩餘是確保 @-mention 路徑也納入 `resolved`（防 content gate reload 在 @-mention 檔上成環），具體 landing 見 §8 step 6 調整。

---

## 1. 問題盤點 — 模型為什麼一直重請求

兩個互相加強的原因：

### 1.1 Prompt 自相矛盾（軟約束層）

`app/application/prompts/builders/tutor_system_prompt.rb:57-63` 的 `WORKSPACE_OVERVIEW_GUIDE`，只要 request 帶 `workspace_overview` 就**無條件**渲染，並對 overview 列出的**每個**檔案斷言：

```
The files listed above exist in the student's workspace but their contents are NOT loaded.
- To read or edit any of them, call `load_file` with its path FIRST; ...
```

但 `hw2.R`、`Hw2.Rmd` **同時**在 overview 區**和** live 區。overview 那句「contents are NOT loaded → call `load_file` FIRST」直接打臉 live 區的實際內容。兩段在同一份 system prompt 並存（`build` 同時 append overview guide 與 live 區），模型讀到矛盾指令、選擇相信 overview 的「沒載入」。guide 裡**沒有任何一句**告訴模型「已經在 live 區的就跳過、別再 load」。

> **⚠ 待驗證（會影響 B 的相關性，列為 §8 step 0）：** `WORKSPACE_OVERVIEW_GUIDE` 只在 `workspace_overview` 非空時才 render（`tutor_system_prompt.rb:93-95`），且 overview 被 budget **最先丟**（`doc/api_tutor_chats.md:411`）。所以這個矛盾**只在「overview 與 live 同時在場、且都沒被截掉」時才成立**。實作前先撈觸發 log 確認當下 `workspace_overview` 是否在場：**若不在場，1.1 對 trigger 無效，trigger 純由 1.2（無 gate）造成、B 打不到它，§6 D1 的空轉風險更尖銳。** 另一個未列入的可能真因：後端把 `file_context` 包進 `## Student Workspace (live)`，但內層仍是前端的 `## File Contents` / `### hw2.R`（巢狀標題，`doc/api_tutor_chats.md:109/398`）——模型可能因此認不出「`### hw2.R` 在 live 內 = 已載入」。這正是 C 要解的更重要目的（見 §2 C 重新定位），不只是省 token。

### 1.2 沒有結構性的 loop-breaker（強制層）

專案自己記取過的教訓（`workspace_edit_gate.rb:13-18`）：

> **「the … guide and the tightened tool descriptions are soft constraints, and gpt-4o demonstrably ignores them」** — 所以 path-loading 規則做成了結構性 gate。

但現有三道處理（`run_tutor_chat.rb:304-321` 的 `extract_reply` / `apply_gates`）：

1. `load_reference` 過濾
2. `EditPatchNormalizer`（剝 `N| ` 前綴）
3. `WorkspaceEditGate`（`edit_file` 對未載入 path → 改寫 `load_file`）
4. `EditPatchContentGate`（patch 內容對不上 → 改寫 `load_file`）

**沒有任何一道會攔截「對已載入 path 的 `load_file`」。** 冗餘的 `load_file` 原樣透傳給前端，前端忠實再轉一圈。與 1.1 重蹈同一覆轍：行號契約只做軟約束、出事；這裡 load_file 終止也只靠 prompt、同樣出事。

### 1.3 為什麼「只改 prompt」不夠

就算 1.1 改好措辭，gpt-4o 仍可能憑舊習慣重發 `load_file`（同 §1.2 引用的教訓）。**終止必須是結構性的**：檔案一旦在 `file_context` 出現，後端就保證不可能再送出對它的 `load_file`。prompt 改寫負責「讓模型改去做 `edit_file`（productive）」，gate 負責「即使模型不聽話、迴圈也一定停」。兩者分工，缺一不可（見 §6 風險 D1）。

---

## 2. 決策

| # | 改動 | 層級 | 解決什麼 |
|---|---|---|---|
| **A** | 新增 `Values::RedundantLoadGate`：丟掉對「已在 `file_context` 載入」之 path 的 `load_file`（並順手 dedup 同回合重複 path） | 後端・結構性 | `file_context` 完整時保證迴圈終止（§1.2/§1.3）；且**冗餘 load 一回合就消失**，省去「只靠前端 cap 才停」所需的 cap×LLM 往返 token/延遲 |
| **B** | 改寫 `WORKSPACE_OVERVIEW_GUIDE`：live 區是 source of truth；已在 live 的別再 `load_file`、直接用；只對不在 live 的 `load_file` | 後端・prompt | 讓模型改走 `edit_file`，**提高回合有實質產出的機率**（§1.1） |
| **C** | 前端 `file_context` append 去重（同 path 只留一份、就地更新；理想上合併為單一 loaded 段） | 前端・衛生 | 消除 round 2 的 `### hw2.R` 重複；**並讓 live 區已載入檔對模型一目了然**（降低模型認不出「已載入」而重發 load_file，§1.1 待驗證項） |
| **D** | 前端 load_file 解析迴圈加 **round cap**（建議 3）+ 達上限的收尾 | 前端・結構性（兜底） | `file_context` 被截斷致 gate 漏接（§6 D4）、或其他 action 成環時的終止保證——**是終止保證的一環，非純備胎** |
| **E** | 後端：當「全部 actions 被 gate 清空且 prose 為空」→ 注入一句 fallback prose（或保留 round-1 prose），**永不回 `content` 空＋`actions: []`** | 後端・UX | 被修的 trigger（round 2 兩 load 全丟）正好會空轉；保證最壞情況是「一句溫和提示」而非空白回合（§6 D1） |

哲學一致性：A／D 是「structural, not prompt steering」，與 `WorkspaceEditGate`、`load_reference` enum 白名單、`edit_file` 的 `start_line` required 欄位同一路線。

---

## 3. 新 gate 契約（`RedundantLoadGate`）

```
輸入：actions（已過 load_reference 過濾 + EditPatchNormalizer 的混合鍵 hash 陣列）、file_context（字串）
輸出：[gated_actions, dropped?]

規則：
- 對每個 action：
  - 非 load_file → 原樣保留
  - load_file 且 normalize(path) ∈ loaded_paths(file_context) → 丟棄，dropped = true
  - load_file 且 path 本回合已出現過（intra-reply 重複）→ 丟棄第二個起，dropped = true
  - 其餘 load_file（對未載入 path 的合法請求）→ 保留
- loaded_paths / normalize / HEADER 偵測沿用 WorkspaceEditGate 既有實作（### <path> 行首錨點、tr '\\' '/'、去 ./）
```

- **啟用條件：** `file_context` 非空且至少有一個 `### path` header（與 `EditPatchContentGate` 同款 inert 規則）。**不**綁 `workspace_overview`——「丟掉對已載入檔的 load_file」在新舊契約下都恆為正確且安全，無向後相容風險（舊 CLI 的 combined blob 同樣帶 `### path`）。
  - 注意：三道 gate 的啟用開關現在**不一致**——`WorkspaceEditGate` 綁 `workspace_overview`，`EditPatchContentGate` 與本 gate 綁 `file_context`+header。本 gate 刻意對齊 content gate（兩者都對「已載入內容」動作），而非 path gate。實作時在本節留一張對照註解，避免日後踩到「A active／B inert」的組合誤判（§6 D7）。
- **排序：`RedundantLoadGate` 必須排在 `apply_gates` 最前面，關鍵互動是 `EditPatchContentGate`（不是 `WorkspaceEditGate`）：**
  - `WorkspaceEditGate` 只對**未載入** path 產 `load_file`，本來就不在本 gate 射程內（本 gate 只丟已載入 path），不構成風險——這是 trivial case。
  - 真正會打架的是 `EditPatchContentGate`：它**只對已載入 path 動作**，content 對不上時把 `edit_file` 改寫成**對已載入 path 的 `load_file`**（`edit_patch_content_gate.rb:63`）——這正是本 gate 定義的「冗餘 load」。**若本 gate 排在 content gate 之後，會把 content gate 刻意產生的 reload 殺掉、defeat 掉它的 stale-snapshot 自癒。** 所以本 gate 必須在 content gate **之前**：先清模型自己發的冗餘 load，再讓 edit 兩道按需產生（合法的）reload。需有回歸測試鎖住（§4.4）。
  - 副作用誠實揭露：content gate 產出的「對已載入 path 的 reload」本身是一條潛在迴圈（模型幻覺 search → mismatch → reload → 又幻覺），本 gate 不該也不能擋它（擋了就 defeat content gate）；這條只能靠前端 round cap（D）兜底——再次坐實 D 是終止保證的一環。

---

## 4. 後端改動（本 repo）

### 4.1 （A）新增 `app/domain/values/redundant_load_gate.rb`

新 module `Tyla::Values::RedundantLoadGate`，照 `WorkspaceEditGate` 抄骨架：

- `LOAD_FILE = 'load_file'`、`HEADER = /^###[ \t]+(\S.*?)[ \t]*$/`
- `self.call(actions:, file_context:)` → `[gated, dropped?]`
  - `blank?(file_context)` → `[actions, false]`
  - `loaded = loaded_paths(file_context)`；`loaded.empty?` → `[actions, false]`（沒有 `### path` header 視同 inert）
  - 逐 action 過濾：load_file 命中 `loaded` 或 intra-reply 重複 → drop；其餘保留
- 私有 helper：`loaded_paths` / `action_type` / `path_of` / `normalize` / `blank?` 直接對齊 `WorkspaceEditGate`。**註記：本 gate 一進來，同一份 `file_context` 就會被三道 gate 各自 parse 一次（`loaded_paths`／`parse_file_context`）。QPS 低、不阻塞，但既然要新增第三家，建議順手把 `loaded_paths(file_context)` 抽成共用 helper**（三 gate 共享一份 header 偵測），勝過再複製第三份。
- **假設寫死進註解：** 本 gate 只看 `### header` 在不在，視同「該檔已**完整**載入」。此假設依賴前端**整檔載入** load_file（見 memory `manifest-responsibility-split`）。若前端日後改成「載入局部 range」，header 在但內容不全的檔會被本 gate 擋住再載——屆時需改成檢查內容完整度。

> 命名：`RedundantLoadGate`（語意最準）。若偏好與 `WorkspaceEditGate` 對稱，可叫 `WorkspaceLoadGate`；二擇一，spec/註解一致即可。

### 4.2 （A）接進 `run_tutor_chat.rb` 的 `apply_gates`

`run_tutor_chat.rb:315-321` 目前：

```ruby
def apply_gates(actions, params)
  gated, p_redirect = Values::WorkspaceEditGate.call(
    actions: actions, file_context: params[:file_context], workspace_overview: params[:workspace_overview]
  )
  gated, c_redirect = Values::EditPatchContentGate.call(actions: gated, file_context: params[:file_context])
  [gated, p_redirect || c_redirect]
end
```

改為（`RedundantLoadGate` 先跑）：

```ruby
def apply_gates(actions, params)
  gated, l_dropped  = Values::RedundantLoadGate.call(
    actions: actions, file_context: params[:file_context]
  )
  gated, p_redirect = Values::WorkspaceEditGate.call(
    actions: gated, file_context: params[:file_context], workspace_overview: params[:workspace_overview]
  )
  gated, c_redirect = Values::EditPatchContentGate.call(actions: gated, file_context: params[:file_context])
  [gated, p_redirect || c_redirect, l_dropped]
end
```

- `extract_reply`（:304-313）目前回 `[prose, gated, redirected]` **三值**；本案加 `load_dropped` 成**第四值**（`apply_gates` 同步多回一格）。`ok_outcome` 的解構（:345）要一起改成接四值——別誤讀成「第三個」。
- `ok_outcome`（:344-357）把 `load_dropped` 傳進 `warnings_for`。
- `warnings_for`（:361-369）加一條：`warnings << 'redundant_load_dropped' if load_dropped`。
  - 理由：與 `edit_file_redirected` 同款——既是 Phase 0 量測訊號（迴圈發生率），也讓前端能把「actions 變空」正確解讀為「後端攔掉冗餘 load」而非錯誤。representer 既有「nil → 省略欄位」行為照舊。
- （可選）`log_phase0` 也可加印 `load_dropped`，作為 D1（重複 load 率）的 go/no-go 數據。

> `edit_file_redirected` 既有語意是「path/content gate 兩者之一改寫」；`redundant_load_dropped` 是獨立的新旗標，不要併進去（兩者意義不同，混用會讓量測失真）。

### 4.3 （B）改寫 `WORKSPACE_OVERVIEW_GUIDE`

`tutor_system_prompt.rb:57-63` 改為：

```
## Loading Workspace Files
The files listed in the overview exist in the student's workspace; some may already be loaded.
The "Student Workspace (live)" section is the source of truth for what is currently loaded.
- If a file you need is ALREADY shown in the "Student Workspace (live)" section, use it directly — do NOT call `load_file` for it again.
- Only call `load_file` for a file that is NOT yet in the "Student Workspace (live)" section; its numbered contents arrive next turn.
- Only files shown in the "Student Workspace (live)" section carry real line numbers. Never invent or guess a "N| " line-number prefix for a file that is not loaded — not even if the student pasted some of its lines into the chat.
- Do NOT emit `edit_file` for a file that is not in the "Student Workspace (live)" section; `load_file` it first.
```

- 拿掉「their contents are NOT loaded」這個無條件謊言，換成「live 是 source of truth／已在 live 的別再 load」。
- 保留 `## Loading Workspace Files` 標題、`load_file`、`never invent … "N| " prefix`、`Do NOT emit edit_file …` 等既有防呆句——現有 spec（`tutor_system_prompt_spec.rb:47-65`）斷言的是這些字串，措辭改寫不會打到它們。

### 4.4 Specs

| 檔案 | 改動 |
|---|---|
| （新）`spec/domain/values/redundant_load_gate_spec.rb` | ①load_file 命中已載入 path → 丟、dropped=true；②load_file 對未載入 path → 保留、dropped=false；③混合（一個已載入＋一個未載入）→ 只丟已載入那個；④intra-reply 同 path 重複 → 收斂成一；⑤`file_context` 無 `### header` / 空 → inert（原樣、dropped=false）；⑥path normalize（`./hw2.R`、反斜線）對齊；⑦非 load_file action 不受影響 |
| `spec/application/services/run_tutor_chat_spec.rb` | ①`file_context` 已含 `### hw2.R`，模型回 `load_file hw2.R` → `dto.actions` 不含該 load_file、`dto.warnings` 含 `redundant_load_dropped`；②**跨 gate 排序回歸（必加）：`edit_file` 對已載入 path 但 content mismatch → `EditPatchContentGate` 產出 `load_file` → 該 `load_file` 必須存活到 `dto.actions`**（證明 `RedundantLoadGate` 排在前、沒誤殺 content gate 的合法 reload）；回歸：對未載入 path 的 load_file（既有 :194-199 XML fallback 案例）仍透傳、不誤殺 |
| `spec/application/services/run_tutor_chat_spec.rb`（決策 E） | 模型只回冗餘 `load_file`、無 prose → gate 清空後 `dto.content` **非空**（fallback prose／保留 round-1 prose）；斷言永不出現 `content` 空＋`actions: []` 的組合 |
| `spec/application/prompts/builders/tutor_system_prompt_spec.rb` | 既有 :40-66 仍綠（只查標題/`load_file` 字串）。**新增**一條斷言鎖住 B：overview guide 含「use it directly」「do NOT call `load_file` for it again」之類措辭、且 `wont_include 'their contents are NOT loaded'` |

---

## 5. 前端改動（MindyCLI，跨 repo）

> 前端 load_file 解析與 `file_context` 組裝不在本 repo；以下列為跨 repo 行動項，落點約在 `tyla/src/application/use-cases/execute-tutor-use-case.ts`（與 `applyAnchoredPatches` 同檔的 tutor 回合迴圈）。

### 5.1 （C）`file_context` append 去重

- 維護一個「已載入檔案表」以 **normalize 後的 path 為 key**（forward slash、去 `./`），一個 path 只保留一份內容。
- 解析到 `load_file` 時：若該 path 已在表中 → **不重複 append**（理想上配合後端 gate，根本不會再收到這種 action；但前端自身也要冪等）。
- 收斂輸出：`## File Contents`（@-mention）與 `## Files Loaded On Request`（load_file 結果）兩段對同一 path 不得各放一份——同 path 去重（擇一段，或合併為單一「loaded files」段，與後端 `### path` header 偵測相容即可）。
- header 拼字必須與 `workspace_overview` 列出的 path **完全一致**（後端 gate 靠 `### <path>` 精確比對；見 `doc/api_tutor_chats.md:441`）。

### 5.2 （D）load_file 迴圈 round cap

- 給「收到 load_file → 讀檔 → 重送」這條迴圈一個**最大回合數**（建議 3）。
- 達上限仍回 load_file → 停止迴圈，不再無限重送；以目前已載入的 `file_context` 收尾（顯示模型最後的 prose／actions，或提示學生「無法自動載入更多檔案，請重試或手動 @ 檔案」）。
- 與後端 §4 互補：後端 gate 是主防線（冗餘 load 根本送不出來）；round cap 是「任何成環 action（不只 load_file）」的最後保險。
- 可順手把後端新增的 `redundant_load_dropped` warning 納入判斷：收到它即知「模型在重複請求、後端已攔」，可提早收斂。

---

## 6. 設計缺陷／風險盤點（誠實版）

- **D1：只做 A，迴圈會停但回合可能空轉——而且這正是 trigger 的必然結果，不是邊角案例。** 把觸發 log 套上 A：round 2 兩個檔都已載入 → 兩個 `load_file` 全被丟 → `actions = []`；若 prose 也空 → 學生拿到空回合。也就是說，**被修的那個 case，修完的 user-visible 結果就是空回合**。緩解分兩層：(1) B 讓模型看到 live 檔、不被騙「沒載入」，改走 `edit_file`（但 §1.1 待驗證——若 trigger 當下無 overview，B 打不到；且 D2 gpt-4o 可能仍不甩）；(2) **決策 E（提到 Phase 1，不再推 Phase 2）：後端在「actions 被清空且 prose 為空」時注入一句 fallback prose／保留 round-1 prose**，硬性保證最壞情況是「一句溫和提示」而非空白。**A 保證不無限轉，E 保證不空白，B 提高回合有實質產出的機率。**
- **D2：模型即使讀了 B 仍重發 load_file（gpt-4o 頑固）。** 正是 §1.3 的理由——A 結構性兜底，不靠模型聽話。
- **D3：path 拼字不一致導致 gate 漏接。** 後端 `### <path>` 與 action `path` 需可比對；`normalize`（slash/去 `./`/trim）已涵蓋常見差異，但前端必須維持 header 與 overview/action 同款拼法（§5.1）。
- **D4：`file_context` 被 budget 截斷 → 某檔的 `### header` 沒進 snapshot → gate 誤判「未載入」、放行 load_file。誠實版：這不是「可接受的小退化」，而是 A 的結構性保證在此情形下失效。** `workspace_overview` 被 budget 最先丟、其次才 file_context（`doc/api_tutor_chats.md:411`），而 lazy-loading 這套機制存在的理由正是 workspace 檔案大（memory `manifest-responsibility-split`），**大檔＋多檔載入下 header 被截掉的機率不低**。header 一旦消失，原迴圈完整回歸，此時**唯一**的終止點是前端 round cap（D）。結論：**D 不是備胎，是 A 在 budget 壓力下的終止保證本身**——故 §7 的上線節奏要調整（A 與 D 要靠近上線，不能說「前端從容跟進」）。
- **D5：空回合的 UX。** 已升格為**決策 E**（§2）並提到 **Phase 1**（理由見 D1：空轉是 trigger 的必然結果，不該等量測）。後端注入 fallback prose 為主防線；前端再以溫和提示收尾（§5.2）作雙保險。
- **D6：跨 repo 協調。** 後端 §4 可獨立先上（向後相容，見 §7）；但前端 round cap（D）因 D4 屬終止保證的一環，**需與後端靠近上線**，非「後跟即可」。
- **D7：三 gate 啟用開關不一致（§3）。** `WorkspaceEditGate` 綁 `workspace_overview`、content gate 與本 gate 綁 `file_context`+header。各自正確（對的東西不同），但屬維護面 smell；以 §3 的對照註解 ＋ §4.4 的跨 gate 測試共同防回歸。

---

## 7. 遷移順序（後端先，向後相容——但前端 cap 不是「從容跟進」）

1. **後端先上**（本 repo §4）：`RedundantLoadGate` + 決策 E（空轉收尾）+ prompt 改寫。
   - 對舊 CLI 無害：舊 CLI 的 combined blob 同樣帶 `### path`，gate 照樣正確丟冗餘 load；新增的 `redundant_load_dropped` warning 屬未知欄位、舊 CLI 忽略即可。
   - 對新 CLI：`file_context` 完整時迴圈即刻被結構性切斷。
2. **前端緊跟**（MindyCLI §5）：append 去重 + round cap。
   - **修正先前說法：** round cap **不是**「萬一後端失效的備胎」。§6 D4 已說明——`file_context` 被 budget 截斷致 `### header` 消失時，後端 gate 會漏接、原迴圈回歸，此時 round cap 是**唯一**終止點。大檔場景下這並不罕見，故 **A 與 D 應靠近上線**（理想上同一波，至少不要讓「只有後端、沒有前端 cap」的狀態長期存在於大檔使用者手上）。
3. 仍不存在「新前端／舊後端」破壞情境（actions 流向是後端→前端，前端只收不送 patch）。

---

## 8. 建議提交順序（每步獨立綠燈）

| # | 內容 | 依賴 |
|---|---|---|
| 0 | ✅ **完成**：`workspace_overview` 確認在場；§1.1 成立；B IS 相關；空轉普通嚴重度。詳見 §0 末「Step 0 結果」 | 無 |
| 1 | `app/domain/values/redundant_load_gate.rb` + `spec/domain/values/redundant_load_gate_spec.rb`（純 unit，先綠）；順手抽 `loaded_paths` 共用 helper（§4.1） | 無 |
| 2 | `run_tutor_chat.rb`：`apply_gates` 串入 gate（**排最前**，§3）、`extract_reply`/`ok_outcome`/`warnings_for` 接 `redundant_load_dropped`（**四值接線**，§4.2）；+ 整合 spec（含**跨 gate 排序回歸**，§4.4） | 1 |
| 3 | **（決策 E，Phase 1）** `run_tutor_chat.rb`：`ok_outcome` 在「actions 清空且 prose 空」時注入 fallback prose／保留 round-1 prose；+ spec | 2 |
| 4 | `tutor_system_prompt.rb`：`WORKSPACE_OVERVIEW_GUIDE` 改寫（+ spec 新斷言）——**step 0 確認必要；與 1–2 同波** | 無 |
| 5 | `doc/api_tutor_chats.md`：補「`load_file` 冪等／已載入即丟」與 `redundant_load_dropped` warning；Actions/Workspace 段同步 | 1–4 |
| 6 | （跨 repo）MindyCLI：**C 優先**（@-mention 路徑納入去重集合 + 合併單一 loaded 段；解巢狀標題混淆，§1.1 C 重新定位）；**D 剩餘工作小**（`MAX_CONTINUATIONS` 已存在，補 @-mention 路徑進 `resolved` 即可）——**與後端靠近上線（§7）** | 1–5 上線後 |

---

## 9. 驗收清單

- [ ] `RedundantLoadGate`：load_file 命中已載入 path → 丟；未載入 path → 保留；混合只丟已載入；intra-reply 重複收斂
- [ ] gate inert 條件：`file_context` 空 / 無 `### header` → 原樣、`dropped=false`
- [ ] path normalize（`./`、反斜線、trim）對齊 `WorkspaceEditGate`
- [ ] `apply_gates` 中 `RedundantLoadGate` 在 `WorkspaceEditGate` 之前，且不誤殺後者改寫出的 load_file（未載入 path）
- [ ] **`RedundantLoadGate` 在 `EditPatchContentGate` 之前；content gate 對「已載入 path content mismatch」產出的 `load_file` 仍存活到 actions（跨 gate 排序回歸，§4.4）**
- [ ] **（決策 E）模型只回冗餘 load、gate 清空後：`dto.content` 非空，永不出現 `content` 空＋`actions: []`**
- [x] **（§8 step 0）已確認 trigger 當下 `workspace_overview` 是否在場，B 的相關性結論已記錄**（`workspace_overview` 確認在場；§1.1 成立；B IS 相關）
- [ ] 冗餘 load 被丟時 `dto.warnings` 含 `redundant_load_dropped`；乾淨回合不含
- [ ] `WORKSPACE_OVERVIEW_GUIDE` 不再含「their contents are NOT loaded」；含「已在 live 直接用、別再 load」措辭；既有防呆句（never invent prefix / load_file before edit）保留
- [ ] 既有 spec 全綠（`tutor_system_prompt_spec` :40-66、`run_tutor_chat_spec` gate/normalizer 段）
- [ ] 觸發案例回放：round 2 的 `load_file hw2.R/Hw2.Rmd`（均已載入）→ 後端 actions 不再含這兩個 load_file，迴圈結構性終止
- [ ]（跨 repo）前端 `file_context` 同 path 不再重複 append（`### hw2.R` 只一份）
- [ ]（跨 repo）前端 load_file 迴圈 round cap 生效，達上限優雅收尾

---

## 10. Review 修正紀錄（2026-06-13）

資深 review 後對本 plan 的四項實質修正（已就地改入對應章節）：

1. **空轉收尾（決策 E）提到 Phase 1。** 原 §8-6 把「後端注入 fallback prose」列為 Phase 2 可選；但套觸發 log 後發現 round 2 兩個 load 全被丟 → `actions=[]` 是**必然**，空轉就是被修場景的結果，不該等量測。→ 新增決策 E（§2）、改寫 §6 D1/D5、§8 新增 step 3、§4.4 加 spec。
2. **結構性保證改為條件性陳述。** 「後端 gate 保證迴圈一定停」在 `file_context` 被 budget 截斷致 `### header` 消失時失效（§6 D4），而 lazy-loading 正是為大檔存在、此情形不罕見。前端 round cap 因此是**終止保證的一環**，非備胎。→ 改寫一句話摘要、§2 D、§6 D4/D6、§7 上線節奏。
3. **排序 rationale 補上與 `EditPatchContentGate` 的互動 ＋ 跨 gate 回歸測試。** 原文只論證對 `WorkspaceEditGate` 無誤殺（trivial case）；真正關鍵是 content gate 會對**已載入 path** 產 `load_file`，本 gate 必須排在它**之前**以免 defeat 其 stale-snapshot 自癒。→ 改寫 §3、§4.4 spec 表加跨 gate 測試、§9 加驗收項。
4. **因果診斷（§1.1）標為待驗證。** `WORKSPACE_OVERVIEW_GUIDE` 只在 `workspace_overview` 在場時 render，且 overview 被 budget 最先丟；故 1.1 的矛盾未必在 trigger 當下成立。實作前先撈 log 確認（§8 step 0）；並把巢狀標題（`## File Contents` 在 `## Student Workspace (live)` 內）列為可能真因，重新定位 C 的目的。

次要修正：三 gate 啟用開關不一致（§3 對照註解 ＋ §6 D7）、`extract_reply` **第四值**接線（§4.2）、`loaded_paths` 抽共用 helper 與「header＝完整載入」假設寫死（§4.1）。
