# edit_file 行號錨點：從「塞進 search 字串」升級為 schema 的 required 欄位

**Date:** 2026-06-13
**Status:** 後端實作完成（§8 step 1–6）；前端 step 5 完成（MindyCLI，2026-06-13）；Phase 2 後端內容驗證完成（2026-06-13）
**相關文件：**
- 行號契約起源：`plans/2026-06-11-hybrid-lazy-solution-implementation.md`、commit `99245…`「add line-number contract for live workspace」
- 「結構性 > prompt 勸說」先例：`plans/2026-06-04-action-reliability-issue.md`、`app/domain/values/workspace_edit_gate.rb` 檔頭註解
- workspace 兩通道契約：`doc/api_tutor_chats.md`「Workspace edit gate」、`plans/2026-06-12-workspace-context-contract-split.md`

> **一句話：** 把「請在 `search` 每行帶 `N| ` 前綴」這個**模型會無視的軟約束**，換成 patch schema 裡一個 **required 的 `start_line` 整數**——行號負責定位（解決重複 code 改錯位置），`search` 回歸純內容負責防呆驗證。前端用「行號當錨點、內容當驗證」套用，不需要重新編號整個檔案。

---

## 0. 觸發事件（2026-06-13 觀測）

一筆真實 log：學生要修 `hw2.R` 的 quartile probs，模型正確回了 `edit_file`，但 `search` 是

```json
{ "search": "quartiles_d123 <- quantile(d123, probs = c(0.1, 0.5, 0.9))",
  "replace": "quartiles_d123 <- quantile(d123, probs = c(0.25, 0.5, 0.75))" }
```

**沒有** `file_context` 裡顯示的 `9| ` 前綴。昨天的契約明明要求帶。這不是個案 bug，是契約的實作方式（純 prompt 軟約束）注定不可靠。

---

## 1. 問題盤點 — 為什麼現在這條契約靠不住

### 1.1 行號契約只活在三個「軟約束」，後端零強制

| 位置 | 內容 | 性質 |
|---|---|---|
| `app/application/prompts/builders/tutor_system_prompt.rb:68-74`（`LINE_NUMBER_GUIDE`） | 「In edit_file `search`, copy the lines verbatim INCLUDING the number prefixes」 | system prompt 文字 |
| `app/application/prompts/builders/tutor_system_prompt.rb:46`（`TOOL_USE_GUIDE`） | 「copy those prefixes verbatim into `search`」 | system prompt 文字（**與 `LINE_NUMBER_GUIDE` 同份 prompt 並存**——`build` 同時 append 兩者） |
| `app/application/services/tutor_chat/run_tutor_chat.rb:49-51`（`edit_file` schema `search` 描述） | 「copied verbatim INCLUDING the leading "N\| " line-number prefixes」 | tool 描述文字 |
| `doc/api_tutor_chats.md:87` | 對前端宣稱 `search` 會帶前綴 | 文件 |

> **務必四處一起改。** `TOOL_USE_GUIDE`（:46）與 `LINE_NUMBER_GUIDE`（:68-74）在**同一份 system prompt 裡同時出現**。若只改後者、留下前者的「copy prefixes verbatim into `search`」，模型會同時讀到兩條矛盾指令——正是本案要消滅的不可靠來源。

`extract_reply`（`run_tutor_chat.rb:294-305`）之後對 actions 只做兩件事：①過濾 `load_reference`、②`WorkspaceEditGate`（path 沒載入 → 改寫成 `load_file`）。**`patches[].search` / `replace` 的內容全程原樣透傳**——gate 只看 path 不碰內容（`workspace_edit_gate.rb`），`TutorReplyParser` 不正規化，representer（`tutor_chat_representer.rb`）直接渲染。沒有任何一處保證前綴存在。

### 1.2 這正是專案自己記取過的教訓

`workspace_edit_gate.rb` 檔頭與 `2026-06-04-action-reliability-issue.md` 都寫過：**「soft constraints, and gpt-4o demonstrably ignores them」**——所以 path-loading 規則做成了結構性 gate。但行號這條**只做成軟約束**，於是重蹈覆轍。

### 1.3 反諷：就算模型乖乖帶了前綴，前端反而更難套

磁碟上的 `hw2.R` **沒有** `N| `（那是前端注入給 LLM 看的顯示前綴）。所以：

- 模型「合規」回 `9| quartiles…` → 在真實檔案裡**匹配不到**，前端得先剝前綴才能套；
- 模型「違規」回 `quartiles…` → **直接可套**。

也就是說，舊契約要模型加一個前端最後還得拆掉的東西。前綴本想換到的好處——(a) 重複 code 消歧義、(b) 證明模型沒幻覺——(a) 因前端要剝而失效、(b) 已被 gate（驗證 path 已載入）涵蓋。

### 1.4 消歧義仍是真需求（不能直接拿掉行號）

但「同一段 code 出現多次、改錯位置」是真實風險。結論不是「拿掉行號」，而是「**讓行號可靠**」。行號該扮演的是**定位錨點**，不是塞進待比對字串裡的雜訊。

---

## 2. 決策

### 決策 A — 行號改成 schema 的 required 整數欄位

```
patches[].search      → 純內容（不帶前綴，可直接拿去比對 / 套用）
patches[].start_line  → required integer，1-based，指向 search 第一行在檔案中的行號
patches[].replace     → 純內容（同今日）
```

多行 patch **不另加 `end_line` / `line_count`**：`search` 本身就帶了 k 行內容，跨度 = `search` 的行數，再加一個欄位是冗餘。`start_line` 指 WHERE，`search` 指 WHAT + 跨度。

#### 為什麼是 schema 欄位，而非「把 prompt 寫更兇」

| 手段 | 可靠性 | 理由 |
|---|---|---|
| prompt/schema 描述要求「字串裡帶前綴」（今日） | 低 | 自由字串內容無從強制；模型憑直覺輸出乾淨 search（log 已證） |
| **required schema 欄位 `start_line`**（本案） | 高 | function-calling 的 `required` 是 **API 結構性強制**——模型不填就不是合法 call。且「填一個整數」比「記得在每一行前面加前綴」單純太多 |

這與 `WorkspaceEditGate` / `load_reference` enum 白名單同一哲學：**structural, not prompt steering**。

### 決策 B — 前端套用演算法：行號當錨點、內容當驗證

| 方案 | 做法 | 取捨 |
|---|---|---|
| (A) 重新編號再字串替換 | 把真實檔案逐行補上與 `file_context` 一致的 `N\| ` → 對帶前綴 search 做字串 replace → 再剝回 | search 帶綴、replace 不帶 → naive 替換會讓該行掉號；且綁死前綴空白寬度（9 行 ` 9\| ` vs 百行 `100\| `）。**否決** |
| **(B) 錨點 + 驗證**（採用） | 解析 `start_line` → 取檔案第 `start_line`…`start_line+k-1` 行 → 與純 `search` 內容比對 → 相符才用 `replace` 換掉那幾行 | 不重編號、不依賴前綴寬度；行號定位（解決重複 code）、內容防呆（檔案變動就拒套，不盲改） |

**關鍵安全性：** (B) 用 `search` 內容做最終驗證，所以即使模型把 `start_line` 填錯（off-by-one、幻覺），內容對不上 → 拒絕套用，**不會靜默改錯行**。行號是「優先定位」，內容是「最後守門」。

---

## 3. 新 wire format（對前端的契約）

```
TutorAction.edit_file =
  { "type": "edit_file",
    "path": string,
    "patches": [ { "start_line": integer,   // 1-based；search 第一行的檔案行號
                   "search":     string,    // 純內容，無 N| 前綴
                   "replace":    string } ] // 純內容，無 N| 前綴
  }
```

- `file_context` 的注入格式**不變**——仍每行帶 `N| `，模型要「看得到」行號才填得出 `start_line`。改的只是模型「回傳」的形狀。
- 向後相容（見 §6）：舊前端收到新 actions 仍可運作（純 search 直接 match，未知的 `start_line` 被忽略），只是少了消歧義。

---

## 4. 後端改動（本 repo）

### 4.1 `run_tutor_chat.rb` — `edit_file` schema（核心）

`TOOLS`（`:32-60`）的 `edit_file`：
- `patches.items.properties` 加 `start_line: { type: 'integer', description: '1-based file line number of the first line of `search`, read from the "N| " prefix shown in the workspace context' }`。
- `required: %w[search replace]` → `%w[start_line search replace]`。
- `search` 描述改：「The exact lines to find, as **plain code WITHOUT** the "N\| " prefixes — copy the content only; put the line number in `start_line`.」
- `edit_file` 頂層 description 同步：拿掉「copy the N\| prefix verbatim」，改成「set `start_line` to the line number shown, and put plain code in `search`」。

### 4.2 `tutor_system_prompt.rb` — `LINE_NUMBER_GUIDE` **與 `TOOL_USE_GUIDE`**（核心）

**(a) `LINE_NUMBER_GUIDE`（`:68-74`）改寫為：**

```
## Workspace Line Numbers
Every line in the live workspace files is prefixed with its line number ("12| ").
- In edit_file, set `start_line` to the number shown on the first line you are replacing.
- Put plain code (NO "N| " prefixes) in both `search` and `replace`.
- When quoting code to the student, omit the prefixes.
```

（仍只掛在 live_context 分支——fixture 分支無行號，維持現狀。）

**(b) `TOOL_USE_GUIDE`（`:46`）同步改——不可漏。** 此常數與 `LINE_NUMBER_GUIDE` 在同份 prompt 並存，現含 `copy those prefixes verbatim into `search``，會與 (a) 直接矛盾。把該句改為：「set `start_line` to the line number shown and put plain code (no "N| " prefix) in `search`」。`never guess line numbers` / `never invent a "N| " prefix` 等防呆語句**保留**。

> spec 連動：`tutor_system_prompt_spec.rb:80-90`（「tightens the tool use guide」）斷言的是 `never guess line numbers`，改措辭不會打到它；但改完仍須重跑確認。

### 4.3 防禦性正規化（建議，小）

模型可能仍把前綴塞進 `search`（舊習慣）。在 `extract_reply` 的共享路徑加一個輕量 `Values::EditPatchNormalizer`（或併進 `WorkspaceEditGate`），對每個 `edit_file` patch：
- 逐行剝掉開頭的 `^\s*\d+\|\s?`，保證送出的 `search`/`replace` 必為純內容；
- 若模型剝出來的首行行號與 `start_line` 都在 → 不衝突即可（不強制相等，前端會驗）。

**這層只保證 wire format 乾淨，不做內容比對**（理由見 §4.4）。覆蓋 native tool_calls 與 XML fallback 兩條路徑（與 `load_reference` 過濾同位置）。

### 4.4 後端內容驗證（Phase 2，可選，預設不做）

後端握有 `file_context`，理論上可拿 `start_line` + `search` 去比對那行內容、對不上就 warn/redirect。**Phase 1 不做**，因為：
- 真正套用的是**前端**，它手上是**即時真實檔案**；後端的 `file_context` 是可能被 budget 截斷／過時的副本。前端的內容驗證（(B)）才是權威守門。
- 後端再驗一次屬冗餘。列為 Phase 2，若 Phase 0 量到「前端拒套率」偏高再評估是否提前到後端攔。

### 4.5 文件 `doc/api_tutor_chats.md`

- `:178-204` 的 `TutorAction` 文法定義加 `start_line`，改 patch 形狀。
- **`:144-149` 的 worked example（`status: "done"` 回應範例）也含舊 patch 形狀**（`{ "search": "mean(x)", "replace": "mean(x, na.rm=TRUE)" }`，無 `start_line`）——一致性要求這份範例同步加 `start_line`，否則文件裡兩處 patch 形狀打架。
- `:87` `file_context` 段落：把「instructs the LLM to copy the prefixes verbatim into `patches[].search`」改成「instructs the LLM to read the prefix into `patches[].start_line` and put plain code in `search`」。
- Actions 規則段補一條：「`search` 是純內容；`start_line`（1-based）定位，前端以行號定位、內容驗證後套用」。

### 4.6 Specs

| 檔案 | 改動 |
|---|---|
| `spec/application/services/run_tutor_chat_spec.rb` | gate 測試（`:464-514`）目前用 `'search' => '69\| old'` → 改為 `{ 'start_line' => 69, 'search' => 'old', 'replace' => 'new' }`；新增「模型把前綴塞進 search → normalizer 剝乾淨」案例；新增「`start_line` 透傳到 actions」斷言 |
| `spec/application/prompts/builders/tutor_system_prompt_spec.rb` | `:99-101` 的 `'INCLUDING the number prefixes'` 斷言 → 改為新措辭（`start_line` / `plain code`）；`## Workspace Line Numbers` 仍在 |
| ~~`spec/infrastructure/llm/{openai,anthropic}_client_spec.rb`~~ | **不用改。** 這兩支 spec 用的是各自合成的迷你 `edit_file` schema（`anthropic_client_spec.rb:47`、`openai_client_spec.rb:45-47`），不是真的 `TOOLS` 常數，不會斷言到 `start_line`。原列為 over-scope，劃除。 |
| （新）`spec/domain/values/edit_patch_normalizer_spec.rb` | 若拆出 normalizer：剝前綴、無前綴不動、多行 patch |

---

## 5. 前端改動（MindyCLI，跨 repo）

> 前端 apply 邏輯不在本 repo；以下是本案要求前端配合的契約與演算法，列為跨 repo 行動項。

1. **`file_context` 維持帶 `N| ` 前綴**（不變）——模型要看得到行號。
2. **套用演算法改 (B)**：
   - 從 patch 讀 `start_line`（1-based）；
   - 取真實檔案第 `start_line` … `start_line + (search 行數) − 1` 行；
   - 與 `search`（純內容）逐行比對，**比對前先正規化行尾**（檔案是 CRLF——見 §7 D3）；
   - 相符 → 用 `replace` 換掉那段；不符 → 拒絕套用並回報（可觸發重新 `load_file`）。
   - **不需要把整個檔案重新編號**。
3. 沿用既有的 diff 預覽 → 人工核可 → 寫檔流程。
4. `start_line` 缺席時（理論上不會，schema required；但 XML fallback 可能）→ 退化為「`search` 內容唯一匹配才套，否則拒絕」。

---

## 6. 遷移順序（後端先，向後相容）

actions 的資料流是 **後端 → 前端**，所以這個 wire format 變更天然好遷移：

1. **後端先上**（本 repo）：開始送 `start_line` + 純 `search`。
   - 舊前端收到也不壞：純 `search` 本來就好 match，未知的 `start_line` 被忽略，只是退回「無消歧義」的舊行為——**與今日（模型常漏前綴）等價**，不是迴歸。
2. **前端後上**（MindyCLI）：實作 (B)，開始吃 `start_line` 做定位 + 內容驗證。

不存在「新前端／舊後端」的破壞情境（前端不送 patch，只收）。

---

## 7. 設計缺陷／風險盤點（誠實版）

- **D1：模型填錯 `start_line`（off-by-one／幻覺）。** 緩解：(B) 以 `search` 內容做最終驗證——行號錯但內容對不上 → 拒套，不靜默改錯。行號是定位、內容是守門。
- **D2：`file_context` 被 budget 丟掉（`file_context_dropped`）→ 模型沒看到行號仍硬編 `start_line`。** 但此時 edit 的 path 多半未載入 → 既有 `WorkspaceEditGate` 已把它 redirect 成 `load_file`。落在現有防線內。
- **D3：CRLF。** 真實檔案是 `\r\n`（log 可見；亦見 memory `rubocop-windows-crlf`）。前端內容比對**必須先正規化行尾**，否則 `search`（可能 `\n`）對不上檔案（`\r\n`）→ 全部拒套。**前端 (B) 的硬性要求**。
- **D4：模型仍把前綴塞進 `search`（舊習慣未改）。** 緩解：§4.3 後端防禦性剝除，保證 wire format 乾淨。
- **D5：1-based vs 0-based 未定義會炸。** 本案定 **1-based**，對齊 `file_context` 顯示的 `N`（第 1 行 = 檔首）。文件與 schema 描述都要明寫。
- **D6：跨 repo 協調。** 前端在 MindyCLI（doc migration order 標 pending）。後端先上、保持相容，前端再跟（§6）。
- **D7：`search` 多行時 `start_line` 只標首行。** 跨度由 `search` 行數決定——若模型把 `search` 行數抓錯（少抄一行），內容驗證會擋下（D1 同一道守門）。

---

## 8. 建議提交順序（每步獨立綠燈）

| # | 內容 | 依賴 |
|---|---|---|
| 1 | `run_tutor_chat.rb`：`edit_file` schema 加 required `start_line`、改 `search` 描述（+ spec） | 無 |
| 2 | `tutor_system_prompt.rb`：`LINE_NUMBER_GUIDE` **與 `TOOL_USE_GUIDE`(:46)** 一起改寫（+ spec 措辭斷言） | 無（可與 1 併） |
| 3 | `EditPatchNormalizer` 防禦性剝前綴 + 接進 `extract_reply`（+ spec；更新 gate 測試的 patch 形狀） | 1 |
| 4 | `doc/api_tutor_chats.md`：`TutorAction` 形狀、`file_context` 段、Actions 規則 | 1-3 |
| 5 | （跨 repo）MindyCLI：套用演算法改 (B)、CRLF 正規化、render 不變 | 1-4 上線後 |
| 6 | （Phase 2，可選）後端用 `file_context` 驗證 `start_line` 內容、不符 warn/redirect | 量測後再定 |

---

## 9. 驗收清單

- [x] `edit_file` schema 的 `patches[]` 含 **required** `start_line`（integer）
- [x] 模型回傳的 `search`/`replace` 在 actions 裡**永遠無 `N| ` 前綴**（含模型硬塞前綴的 case，被 normalizer 剝乾淨）
- [x] `start_line` 原樣透傳到 response 的 actions
- [x] `LINE_NUMBER_GUIDE` **與 `TOOL_USE_GUIDE`** 都不再要求「在 search 帶前綴」，改要求填 `start_line`（同份 prompt 不得殘留矛盾句）
- [x] 文件兩處 patch 形狀（`TutorAction` 文法 + `:144-149` worked example）都帶 `start_line`，無新舊混雜
- [x] gate 測試以新形狀（`start_line` + 純 `search`）通過；gate 行為（path 未載入 → redirect）不受影響
- [x] 文件 `TutorAction` / `file_context` / Actions 規則與新 wire format 一致，明寫 1-based
- [x] 向後相容：請求不帶 `start_line`（XML fallback）時不爆，退化為內容唯一匹配
- [x]（跨 repo）前端 (B) 演算法：行號定位 + CRLF-正規化內容驗證 + 不符拒套
- [x]（Phase 2）後端 `EditPatchContentGate`：`file_context` 快照比對 `search`，不符 → redirect `load_file`；snapshot 不完整行 → 跳過（前端守門）；CRLF 正規化；dedup；13 unit tests 通過
  - MindyCLI `tyla/src/application/use-cases/execute-tutor-use-case.ts` `applyAnchoredPatches`：`start_line` 錨點 → 取同長度切片 → CRLF/trailing-space-loose 逐行驗證 → 相符才 splice、不符 warn 拒套（不靜默改錯行）；anchored 由下而上套用；無 `start_line`（XML fallback）退化為「唯一整行匹配才套，否則拒絕」。`EditPatch` 加 optional `start_line` + `isTutorAction` 驗型；`file_context` 仍帶 `N| `（`addLineNumbers` 不變）；移除已死的 `parseNumberedLines`/`AnchoredLine`；docs/api.md §7 同步。驗證：402 tests passed、`tsc --noEmit` 0 error、build success。
