# Continuation Turn 的 `load_file` 重複請求：history note 指令蓋過 live section 規則

**Date:** 2026-06-28
**Status:** 已實作、spec 已更新、全綠
**相關文件：**
- 前輩案（結構性 gate 哲學）：`plans/2026-06-13-load-file-loop.md`（`RedundantLoadGate` + `WORKSPACE_OVERVIEW_GUIDE` 改寫）
- 同份系統 prompt：`app/application/prompts/builders/tutor_system_prompt.rb`
- History 壓縮：`app/domain/values/history_turn_serializer.rb`、`plans/2026-06-15-option-c-backend-owned-history-compression.md`

> **一句話：** 當學生說「sure」（承接上一輪模型「要修嗎？」的提問），後端 Continuation 1 把 `hw2.R` 放進 `file_context`，但 `HistoryTurnSerializer` 序列化上一輪 session_turn 時在 history user 角色訊息裡留下了 **無條件指令** `"call load_file to see them again: hw2.R"`，GPT-4o 跟隨這條指令、**再次**發出 `load_file: hw2.R`（此時 hw2.R 已在 live section），觸發 `RedundantLoadGate`，動作被攔截後模型回傳的 prose 是 `"Let's load the file hw2.R again to inspect the update..."` — 學生收到毫無意義的一句話、沒有 `edit_file`。

---

## 0. 觸發情境（2026-06-28 debug.log 實測）

| 回合 | log_id | 後端收到的 `file_context` | 模型回應 |
|---|---|---|---|
| S3 "What does the deviations_d456 calculation do?" Round 1 | 333 | 無 | `load_file: hw2.R` ✓ 正確 |
| S3 Continuation 1 | 334 | `### hw2.R`（有內容） | prose 解釋 + "Would you like me to fix this error?" ✓ |
| "sure" Round 1 | 336 | **無**（使用者沒有 @-mention） | `load_file: hw2.R` ✓ 正確（live 空，確實需要 load） |
| "sure" Continuation 1 | 337 | `### hw2.R`（前端已載入） | **又是** `load_file: hw2.R` ✗ **BUG**；`RedundantLoadGate` 攔截，`warnings: ["redundant_load_dropped"]`，`content: "Let's load the file hw2.R again..."` |

---

## 1. 根本原因

### 1.1 `HistoryTurnSerializer` 的 history note 是無條件指令

`app/domain/values/history_turn_serializer.rb:28` 將上一輪 `context_headers` 序列化成 history 的 user 訊息附註：

```ruby
# Before（問題版）
content += "\n\n[Previously inspected last turn (contents not included now; " \
           "call load_file to see them again): #{seen_paths.join(', ')}]"
```

這個 note 在**每一個後續 turn** 都出現在 history 裡，無論當前 request 的 `file_context` 是否已把 `hw2.R` 載進 live section。

### 1.2 GPT-4o 跟隨 history 而非 system prompt 規則

在 "sure" Continuation 1 (log 337) 的 assembled prompt 中：

- **History user 訊息**（來自上一輪的 session_turn）：
  ```
  What does the deviations_d456 calculation do?
  [Previously inspected last turn (contents not included now; call load_file to see them again): hw2.R]
  ```
- **System prompt `WORKSPACE_OVERVIEW_GUIDE`**：
  > "If a file you need is ALREADY shown in the 'Student Workspace (live)' section, use it directly — do NOT call load_file for it again."
- **`## Student Workspace (live)` section**：hw2.R 的行號內容（已有）

GPT-4o **選擇跟隨 history 裡的無條件指令** `"call load_file to see them again"`，忽略系統 prompt 的 source-of-truth 規則。這是 gpt-4o 在 history 指令與 system prompt 規則衝突時的已知行為偏好。

### 1.3 為什麼不是 `RedundantLoadGate` 的問題

`RedundantLoadGate` 正確攔截了重複的 `load_file`（`plans/2026-06-13-load-file-loop.md` 實作的結構性保護）。問題在於 gate 攔截後，模型輸出的 prose 是 "Let's load it again..."，而非有意義的 `edit_file` 動作 — 學生還是拿到一個空轉回合。根本解法必須讓模型在 Continuation 1 時就直接做 `edit_file`，而非一再索取已有的檔案。

---

## 2. 決策

| # | 改動 | 層級 | 解決什麼 |
|---|---|---|---|
| **A** | `HistoryTurnSerializer` note 改為**條件式指令**：「只有當 live section 裡沒有這個檔才需要 load_file」 | 後端・prompt / history | 移除 history 裡與 live section 規則衝突的無條件指令，消除觸發 GPT-4o 跟隨 history 的引信 |
| **B** | `LINE_NUMBER_GUIDE` 新增一條「本 section 的檔案已載入，勿重複 load_file，即使 history 曾提及」 | 後端・prompt | 在 live section 旁邊本地強化規則，雙重保險（live section 既是指令出處也是資料出處） |

---

## 3. 改動明細

### 3.1（A）`app/domain/values/history_turn_serializer.rb`

```ruby
# Before
content += "\n\n[Previously inspected last turn (contents not included now; " \
           "call load_file to see them again): #{seen_paths.join(', ')}]"

# After
content += "\n\n[Previously inspected last turn (contents not re-included here; " \
           "call load_file only if not already in the current \"Student Workspace (live)\" section): #{seen_paths.join(', ')}]"
```

關鍵差異：`"call load_file to see them again"` → `"call load_file only if not already in the current 'Student Workspace (live)' section"`。

原版是無條件指令；新版是條件式指令，把 live section 的 source-of-truth 語意帶進 history note，讓 GPT-4o 跟隨的 history 指令和 system prompt 規則方向一致。

### 3.2（B）`app/application/prompts/builders/tutor_system_prompt.rb`

```ruby
# Before
LINE_NUMBER_GUIDE = <<~GUIDE.strip
  ## Workspace Line Numbers
  Every line in the live workspace files is prefixed with its line number ("12| ").
  - In edit_file, set `start_line` to the number shown on the first line you are replacing.
  - Put plain code (NO "N| " prefixes) in both `search` and `replace`.
  - When quoting code in your explanation to the student, omit the prefixes.
GUIDE

# After（新增最後一條）
LINE_NUMBER_GUIDE = <<~GUIDE.strip
  ## Workspace Line Numbers
  Every line in the live workspace files is prefixed with its line number ("12| ").
  - In edit_file, set `start_line` to the number shown on the first line you are replacing.
  - Put plain code (NO "N| " prefixes) in both `search` and `replace`.
  - When quoting code in your explanation to the student, omit the prefixes.
  - Files shown above are loaded for this request. Do NOT call `load_file` for any file already in this section, even if conversation history mentioned doing so.
GUIDE
```

`LINE_NUMBER_GUIDE` 只在 `live_context` 非空時 render（`workspace_parts` 分支），所以這條規則只在 Continuation 1 這種「已有 file_context」的情境下出現，無 false trigger。

---

## 4. Spec 改動

### 4.1 `spec/domain/values/history_turn_serializer_spec.rb`

S2 test 更新：

```ruby
# Before（失敗，因為新 note 含 'live'）
_(user).wont_include 'live'

# After
# 移除 wont_include 'live'
# 新增 must_include 'Student Workspace (live)'  ← 確認有帶 conditional reference
```

原意的 `wont_include 'live'` 是防止 note 帶工具保留字。`"Student Workspace (live)"` 是 section label，不是工具名；新版刻意引用它讓 note 有效，故更新斷言。`wont_include 'Loaded'` 和 `wont_include 'shown'` 仍保留（新 note 同樣不含這兩者）。

---

## 5. 不需要做的事

- **`RedundantLoadGate` 不需要改**：gate 邏輯本身正確，問題是在 gate 攔截後模型行為混亂；本次修法讓模型在 gate 生效前就走正確路徑（`edit_file`）。
- **前端不需要改**：這是 prompt / history 層的問題，純後端修法。
- **`WORKSPACE_OVERVIEW_GUIDE` 不需要再改**：2026-06-13 `load-file-loop.md` 已改寫成 "live is source of truth"。問題在 history note 比 system prompt 更靠近模型的注意力焦點，不是 overview guide 措辭不夠強。

---

## 6. 設計缺陷／風險

- **R1：GPT-4o 仍可能忽視條件式 note。** A + B 雙重保險後風險降低，但 gpt-4o 頑固時後端 `RedundantLoadGate` 的結構性保護（`redundant_load_dropped`）依舊生效、迴圈不會無限轉。最壞情況：模型還是空轉一回合，但不是「load_file 無窮迴圈」（`plans/2026-06-13-load-file-loop.md` 已解）。
- **R2：`LINE_NUMBER_GUIDE` 不覆蓋「無 file_context 的 Round 1」。** 設計正確——Round 1 無 file_context 時，模型確實應該 call `load_file`，不能擋；`LINE_NUMBER_GUIDE` 只在 `live_context` 非空（= Continuation）時 render，不會誤攔 Round 1 的合法 load。
- **R3：history note 措辭較長。** 新 note 比舊版多 ~20 字元，token 影響可忽略（ROLE_OVERHEAD 4 已包住這點 overhead）。

---

## 7. 驗收

- [x] `bundle exec ruby -Ispec spec/domain/values/history_turn_serializer_spec.rb` — 17 tests, 0 failures
- [x] `bundle exec ruby -Ispec spec/application/prompts/builders/tutor_system_prompt_spec.rb` — 全綠
- [x] History note 含「Student Workspace (live)」條件引用，不再是無條件「call load_file」
- [x] `LINE_NUMBER_GUIDE` 新增「即使 history 曾提及，live section 的檔案也不要重複 load」
- [x] S2 spec 更新：移除 `wont_include 'live'`，新增 `must_include 'Student Workspace (live)'`
- [ ] 手動驗證（下次跑 persona 測試）：說 "sure" 後的 Continuation 1 模型直接回 `edit_file`，不再回 `load_file`；debug.log 無 `redundant_load_dropped`
