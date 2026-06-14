# Round 2 仍對已載入檔案發出 `load_file`：`## Files Loaded On Request` 標頭遮蔽了 `## Student Workspace (live)`

**Date:** 2026-06-14
**Status:** 設計定案，待實作
**相關文件：**
- 前序計畫（加了 `RedundantLoadGate` + 改了 `WORKSPACE_OVERVIEW_GUIDE`）：`plans/2026-06-13-load-file-loop.md`
- 注入組裝邏輯：`app/application/prompts/builders/budget_aware_prompt_assembler.rb:86-89`
- System prompt builder：`app/application/prompts/builders/tutor_system_prompt.rb:97-109`

> **一句話：** 前端送來的 `file_context` 開頭是 `## Files Loaded On Request`（`##` 二階標頭）。Assembler 直接把它塞進 `## Student Workspace (live)\n#{live_context}` ——
> 結果 system prompt 裡出現了 **兩個並列的 `##` 標頭**，`## Student Workspace (live)` 與 `## Files Loaded On Request` 成了**兄弟節點（sibling headings）**，Markdown 語義上 live section 一行內容都沒有。
> 模型掃描「Student Workspace (live)」看不到任何檔案，轉而看 overview，決定再 `load_file` 一次。
> `RedundantLoadGate` 截住了（2026-06-13 的成果），但結果是 FALLBACK_PROSE，學生拿不到 Hw2.Rmd 的修改。
> **修法：** 在 assembler 把 `file_context` 送入 `live_context` 前，濾掉所有 `## ` 行（保留 `### path` 行）。

---

## 0. 觸發事件（2026-06-14 觀測，真實 log）

學生 prompt：
```
Please help me fix the quartile settings in @hw2.R, and also check and correct
the skewness of d123 in Question 1 of Hw2.Rmd.
```

| log | round | file_context 內容 | 模型 actions | gate 結果 |
|---|---|---|---|---|
| 140 | 1 | `### hw2.R`（@-mention 帶入） | `edit_file hw2.R` ✓、`load_file Hw2.Rmd` ✓（未載入） | 全通過 |
| 141 | 2 | `## Files Loaded On Request` → `### hw2.R` + `### Hw2.Rmd`（**兩檔已完整載入**） | `load_file Hw2.Rmd`（應該直接 `edit_file`） | RedundantLoadGate 丟棄 → actions=[] → FALLBACK_PROSE |

**round 2 的期望行為**：模型看到 Hw2.Rmd 已載入 → 直接 `edit_file Hw2.Rmd` 修 skewness。
**實際行為**：模型未認出 Hw2.Rmd 已在 live section → 發出 `load_file Hw2.Rmd` → gate 截斷 → 學生拿到 FALLBACK_PROSE，沒有任何修改。

---

## 1. Root cause：同階 `##` 標頭讓 live section 看起來是空的

### 1.1 system prompt 的實際渲染結果

`tutor_system_prompt.rb:103`：
```ruby
parts << "## Student Workspace (live)\n#{live_context}" << LINE_NUMBER_GUIDE
```

`budget_aware_prompt_assembler.rb:89`：
```ruby
live_context = file_context   # 直接賦值，不做任何處理
```

前端送來的 `file_context`（round 2）：
```
## Files Loaded On Request
### hw2.R
 1| 
 2| set.seed(789)
...
### Hw2.Rmd
  1| ---
  2| title: "Hw2"
...
```

因此 system prompt 裡實際渲染的結果是：
```markdown
## Student Workspace (live)
## Files Loaded On Request          ← 與 live 同為 ## 二階，成為兄弟節點
### hw2.R
 1| ...
### Hw2.Rmd
  1| ...
```

### 1.2 模型視角：`## Student Workspace (live)` 是空的

Markdown 結構語義（也是 LLM 的 heading 理解方式）：
- `## Student Workspace (live)` — 這個節點的內容：**空**（緊接著就是另一個 `##` 兄弟標頭）
- `## Files Loaded On Request` — 一個獨立的平行 section，裡面才有 `### hw2.R` 和 `### Hw2.Rmd`

`WORKSPACE_OVERVIEW_GUIDE` 說「The 'Student Workspace (live)' section is the source of truth」，
`load_file` tool description 說「its contents arrive next turn in 'Student Workspace (live)'」——
但模型檢查 `## Student Workspace (live)` 時什麼都看不到。它的結論：Hw2.Rmd 沒有載入 → `load_file Hw2.Rmd`。

### 1.3 2026-06-13 Decision B 為什麼沒有修好

`WORKSPACE_OVERVIEW_GUIDE` 的改寫是對的：拿掉了「their contents are NOT loaded」的謊言，改說「live section 是 source of truth」。但這個指令的前提是模型能找到 live section——而模型找到的是一個空的 section。Prompt steering 的邏輯沒問題，但依賴的地基（section 有內容）不成立，所以沒有效果。

### 1.4 附帶觀察：`## File Contents`（@-mention）的問題

前序計畫（log 133/134）觀測到 `file_context` 可能還有 `## File Contents` → `### hw2.R` 的前段（@-mention 帶入的舊格式），使同一檔案在 live section 下出現兩個 `##` 子標頭。本次 log 141 的 `file_context` 已只有 `## Files Loaded On Request` 一段（可能 MindyCLI 在中間某個版本合併了），但問題依然存在。無論前端有幾個 `## ` 區段，問題都一樣：`##` 標頭出現在 live_context 裡就會污染 live section 的語義。

---

## 2. 修法選項

### A（後端，優先）：在 assembler 注入前濾掉所有 `## ` 行

**位置**：`budget_aware_prompt_assembler.rb:89`，`live_context = file_context` 改成：
```ruby
live_context = strip_section_headings(file_context)
```

新增私有方法：
```ruby
def self.strip_section_headings(fc)
  fc.to_s.lines.reject { |l| l.match?(/\A##[^#]/) }.join
end
private_class_method :strip_section_headings
```

邏輯：移除所有以 `##`（但不是 `###`）開頭的行。

**安全性分析**：
- 保留：`### hw2.R`、`### Hw2.Rmd`（triple-hash file headers，gate 依賴的格式）
- 保留：` 1| ## Question 2`（行號前綴後的 `##`，regex 不匹配 `/\A##/`）
- 移除：`## Files Loaded On Request`、`## File Contents`（frontend 組裝用的 section label，對模型無意義）
- 空值安全：`fc.to_s` 處理 nil

**渲染後效果**：
```markdown
## Student Workspace (live)
### hw2.R
 1| 
 2| set.seed(789)
...
### Hw2.Rmd
  1| ---
...
```
模型掃描 `## Student Workspace (live)` 即可直接看到 `### Hw2.Rmd`——與 `WORKSPACE_OVERVIEW_GUIDE` 和 tool description 的指引完全對齊。

### B（後端，輔助）：加強 `WORKSPACE_OVERVIEW_GUIDE` 的 `### path` 語義

目前 guide 說「check the 'Student Workspace (live)' section」，修後可補一句使 `### path` 格式明確成為判斷標準：

```
A file is loaded when its `### filename` header followed by numbered lines
(e.g., `1| ...`) appears in the "Student Workspace (live)" section.
```

這讓模型的判斷從「找到 section 名稱」變成「找到 `### path` 格式」，更具體、不依賴 heading 的 scope。

**注意**：A 修好後 B 不是必需的，但可以加固。兩者是獨立的，可以同步實作。

### C（前端，跨 repo，延後）：MindyCLI 不送 `## ` section 標頭

從根本上讓前端送出的 `file_context` 只有 `### path` 行和內容，不含 `## ` 標頭。

**缺點**：跨 repo（MindyCLI）；需要協調；後端 A 已可獨立修掉問題。
**建議**：A 先上線，C 作為 MindyCLI 清理工作列入 backlog。

---

## 3. 決策

| # | 決策 | 選擇 | 理由 |
|---|---|---|---|
| A | 哪裡修 | 後端 `budget_aware_prompt_assembler.rb`，strip_section_headings | 不需跨 repo；assembler 本來就是 frontend raw → assembled context 的邊界 |
| B | 要不要同時加強 guide | 是，加一行 `### path` 語義 | 成本低；讓修法有兩層防線（結構 + 語言），不只依賴結構 |
| C | gate 要不要調整 | 否 | `RedundantLoadGate` 依賴 `### path` regex，A 修完後 `### path` 仍在，gate 邏輯完全不變 |
| D | FALLBACK_PROSE 還要留著嗎 | 是 | 是最後的防線；A 修完後出現機率會大幅降低，但邊緣案例仍可能發生（gate 永遠有可能 drop actions） |
| E | 前端 history threading | 暫不動 | round 2 帶空 history 是 B3 agentic loop 的設計，需要更大的架構討論；A 修完後 round 2 應可直接 edit_file，history 空不再是問題 |

---

## 4. 實作範圍

### 4.1 後端修改（本 repo）

**`app/application/prompts/builders/budget_aware_prompt_assembler.rb`**
- 第 89 行 `live_context = file_context` 改為 `live_context = strip_section_headings(file_context)`
- 新增私有方法 `strip_section_headings`（見 §2 A）

**`app/application/prompts/builders/tutor_system_prompt.rb`**
- `WORKSPACE_OVERVIEW_GUIDE` 補一行 `### path` 語義說明（見 §2 B）

### 4.2 新增/修改 spec

**`spec/application/prompts/builders/budget_aware_prompt_assembler_spec.rb`**（修改）
- 新增 case：`file_context` 含 `## Files Loaded On Request` heading → `live_context` 內只剩 `### path` 行（heading 被濾掉）
- 新增 case：`file_context` 含多個 `##` 段（`## File Contents` + `## Files Loaded On Request`）→ 兩個 `##` 行都被移除
- 新增 case：`file_context` 無 `##` heading（純 `### path` 開頭）→ 原樣保留（regression 測試）
- 確認：`### hw2.R` 行不被濾除（triple-hash 保留）
- 確認：行號前綴的 `## ` 內容不被濾除（` 1| ## Question 2` 格式）

**`spec/application/prompts/builders/tutor_system_prompt_spec.rb`**（修改）
- 已有 `live_context: 'LIVE_WORKSPACE_BLOCK'` 的 spec，不需動
- 新增 case（可選）：`live_context` 包含 `### path` header → system prompt 裡 `## Student Workspace (live)` 下直接出現 `### path`（驗證無其他 `##` 干擾）

**`spec/application/services/run_tutor_chat_spec.rb`**（修改，可選）
- 新增整合 spec：round 2 模擬（`file_context` 含 `## Files Loaded On Request` + `### Hw2.Rmd`，模型回 `edit_file Hw2.Rmd`）→ 驗證 edit 被接受，無 `redundant_load_dropped`

### 4.3 不需動的部分

- `RedundantLoadGate`：`### path` regex 不受影響
- `WorkspaceEditGate`、`EditPatchContentGate`：同上
- `TOOL_USE_GUIDE`：已說「Student Workspace (live) section with 'N| '」，A 修完後語義正確

---

## 5. 建議提交順序（每步獨立綠燈）

### Step 1：assembler strip + unit spec（核心修法）

**改動**：
- `budget_aware_prompt_assembler.rb`：加 `strip_section_headings`，`live_context = strip_section_headings(file_context)`
- `spec/application/prompts/builders/budget_aware_prompt_assembler_spec.rb`：4 個新 case（含 regression）

**驗證**：`bundle exec ruby -Ispec spec/application/prompts/builders/budget_aware_prompt_assembler_spec.rb`

---

### Step 2：guide 加強 `### path` 語義 + spec

**改動**：
- `tutor_system_prompt.rb`：`WORKSPACE_OVERVIEW_GUIDE` 補 `### path` 語義行
- `spec/application/prompts/builders/tutor_system_prompt_spec.rb`：更新 overview guide spec（驗證新語句存在）

**驗證**：`bundle exec ruby -Ispec spec/application/prompts/builders/tutor_system_prompt_spec.rb`

---

### Step 3：全套跑一次（可選整合 spec）

**驗證**：`bundle exec rake test` 確認 0 failures

---

## 6. 跨 repo 後續（MindyCLI，不阻擋本次上線）

| 工作項 | 說明 |
|---|---|
| C（清理）| MindyCLI 送出的 `file_context` 移除 `## Files Loaded On Request`、`## File Contents` 等 `##` 標頭，只送 `### path` + 內容 |
| @-mention dedup | 前序計畫 §8 step 6 C：@-mention 路徑納入 `resolved` set，避免同一檔案出現兩次 `## ` 段 |

兩項皆為清理性質（後端 A 修完後已不影響正確性），MindyCLI 可擇期清理。

---

## 7. 驗收標準

1. `budget_aware_prompt_assembler_spec.rb` 新增的 4 個 case 全綠
2. `tutor_system_prompt_spec.rb` 新增 spec 綠，舊 spec 不迴歸
3. 手動確認（或整合 spec）：round 2 request 帶 `## Files Loaded On Request\n### Hw2.Rmd\n...` 的 `file_context`，模型回 `edit_file Hw2.Rmd` → 不觸發 `redundant_load_dropped` warning
4. `bundle exec rake test` 0 failures, 0 errors
5. `bundle exec rubocop` zero net-new offenses
