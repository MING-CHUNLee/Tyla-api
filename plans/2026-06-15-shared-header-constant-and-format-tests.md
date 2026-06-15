# `### path` 檔頭格式：抽共用常數 ＋ 前後端測試固定

**Date:** 2026-06-15
**Status:** 規劃（後端 spec 固定點已列；前端跨 repo 待 MindyCLI 接手）
**Scope:** 把散落在三個 gate 的 `### <relative path>` 檔頭約定收斂成**單一 source of truth**，
並在前後端各自加測試把格式釘死。落實
[2026-06-14-history-file-omission-compression.md](./2026-06-14-history-file-omission-compression.md) §6.8
與 [2026-06-14-live-section-heading-shadow.md](./2026-06-14-live-section-heading-shadow.md) §2B/§6 都承諾的
「共用常數＋兩端測試固定」。

---

## 0. 現況盤點（讀碼後，2026-06-15）

### 0.1 `### path` 約定的所有觸點

| 角色 | 位置 | 形式 |
|---|---|---|
| 消費者 gate | [workspace_edit_gate.rb:30](../app/domain/values/workspace_edit_gate.rb#L30) | `HEADER = /^###[ \t]+(\S.*?)[ \t]*$/` |
| 消費者 gate | [redundant_load_gate.rb:34](../app/domain/values/redundant_load_gate.rb#L34) | `HEADER = /^###[ \t]+(\S.*?)[ \t]*$/`（**字面重複**） |
| 消費者 gate | [edit_patch_content_gate.rb:28](../app/domain/values/edit_patch_content_gate.rb#L28) | `HEADER = …`，註解自承 *"same convention as WorkspaceEditGate::HEADER"* |
| 後端生產者 | [tutor_system_prompt.rb:120](../app/application/prompts/builders/tutor_system_prompt.rb#L120) | `"### #{path}\n\`\`\`\n#{content}\n\`\`\`"`（注入 context_files） |
| 後端 strip | [budget_aware_prompt_assembler.rb:155-156](../app/application/prompts/builders/budget_aware_prompt_assembler.rb#L155-L156) | `grep_v(/\A##[^#]/)`——保留 `###`、剝 `## ` |
| 後端 guide 語義 | [tutor_system_prompt.rb:65](../app/application/prompts/builders/tutor_system_prompt.rb#L65) | 散文：「`### filename` header followed by `N\| `…」 |
| 前端生產者（file_context） | MindyCLI file_context 產生器（跨 repo） | `### path` + `N\| ` 行 |
| 前端生產者（headers-only） | MindyCLI session 序列化（Option C，跨 repo） | emit 只含 `### path` 的區塊（剝 `N\| ` body），交後端 `FileContextHeader.paths` 解析 |

### 0.2 兩個關鍵發現（決定設計）

1. **重複的不只 regex，還有 `normalize` 與 `loaded_paths`。** 三個 gate 各自有**字面相同**的
   `normalize(path) = path.to_s.strip.tr('\\', '/').sub(%r{\A\./}, '')`
   （[workspace_edit_gate.rb:103-105](../app/domain/values/workspace_edit_gate.rb#L103-L105)、
   [redundant_load_gate.rb:77-79](../app/domain/values/redundant_load_gate.rb#L77-L79)、
   [edit_patch_content_gate.rb:141-143](../app/domain/values/edit_patch_content_gate.rb#L141-L143)），
   且 `loaded_paths` 抽取邏輯在前兩者完全相同、在第三者內嵌於 `parse_file_context`。

2. **CRLF 安全是靠 `normalize` 的 `.strip`，不是 regex。** `HEADER` 的 `[ \t]*$` **不吃 `\r`**：
   CRLF 檔頭 `### hw2.R\r\n` 的 capture group 其實是 `"hw2.R\r"`（Ruby `.` 匹配 `\r`、`$` 只在 `\n` 前），
   靠下游 `normalize` 的 `.strip` 才把 `\r` 清掉。**含意：共用常數必須把「regex ＋ 路徑萃取」綁在一起出貨**，
   只共用裸 regex 會讓任何新消費者（含前端）重新踩 CRLF 陷阱（compression §4.2 的 `.replace(/\r$/,'')` 是同一道）。

3. **`### path` 是「檔頭行」的約定，不含 body。** 後端生產者用 ` ``` ` fenced body；前端用 `N\| ` 編號 body。
   共用常數**只管檔頭行**，body 格式各自不同是對的（gate 的 `loaded_paths` 也只讀檔頭）。

### 0.3 spec 覆蓋現況（決定固定點落在哪）

| 檔案 | 狀態 |
|---|---|
| `spec/domain/values/redundant_load_gate_spec.rb` | ✅ 有（14 cases，含 normalize，但**無 CRLF 檔頭** case） |
| `spec/domain/values/edit_patch_content_gate_spec.rb` | ✅ 有（CRLF 出現在 body 比對，但**無 CRLF 檔頭**辨識 case） |
| `spec/application/prompts/builders/budget_aware_prompt_assembler_spec.rb` | ✅ 有（shadow §4.2 另加 strip cases） |
| `spec/application/prompts/builders/tutor_system_prompt_spec.rb` | ✅ 有 |
| **`spec/domain/values/workspace_edit_gate_spec.rb`** | ❌ **不存在——最關鍵的 gate（改寫捏造 edit）零覆蓋** |

> 測試框架：**Minitest spec-style**（`describe` / `it` / `_(x).must_equal y`，`require_relative '…/spec_helper'`）。
> 新 spec 一律照此風格。

---

## 1. 設計：共用常數模組

新增 [app/domain/values/file_context_header.rb](../app/domain/values/file_context_header.rb)，
`Tyla::Values::FileContextHeader`——`### path` 檔頭約定的**唯一 source of truth**：

```ruby
# frozen_string_literal: true
module Tyla
  module Values
    # Single source of truth for the `### <relative path>` header that marks a
    # fully-loaded file inside file_context. Consumers: WorkspaceEditGate,
    # RedundantLoadGate, EditPatchContentGate, HistoryTurnSerializer (Option C —
    # parses each past turn's headers-only block). Producer: TutorSystemPrompt.
    #
    # NOTE: HEADER alone is NOT CRLF-complete — a CRLF header's capture group keeps a
    # trailing "\r" (Ruby `.` matches `\r`, `$` only anchors before `\n`). It is removed
    # by `normalize`. ALWAYS read paths via `.paths`/`.normalize`, never the raw capture.
    module FileContextHeader
      HEADER = /^###[ \t]+(\S.*?)[ \t]*$/

      def self.paths(file_context)            # → Set<normalized path>
        file_context.to_s.lines.each_with_object(Set.new) do |line, set|
          m = line.match(HEADER)
          set << normalize(m[1]) if m
        end
      end

      def self.normalize(path)                # fwd slashes, no "./", trimmed (strips CR)
        path.to_s.strip.tr('\\', '/').sub(%r{\A\./}, '')
      end

      def self.line(path) = "### #{path}"      # producer side — keeps prod/consumer in lockstep
    end
  end
end
```

**遷移（行為零變更，純去重）：**
- 三個 gate：刪掉各自的 `HEADER` / `normalize` / `loaded_paths`，改呼叫 `FileContextHeader.{paths,normalize}`。
  EditPatchContentGate 的 `parse_file_context` 保留自己的 `PREFIX`（`N| ` 是 body 約定、非檔頭），
  但檔頭判定與 normalize 改用共用模組。
- 生產者 [tutor_system_prompt.rb:120](../app/application/prompts/builders/tutor_system_prompt.rb#L120)：
  `"### #{path}\n…"` → `"#{FileContextHeader.line(path)}\n…"`。讓「後端產的檔頭」與「gate 讀的檔頭」**同源**。
- `### path` 的 `PREFIX`（`N| ` 編號行）**本案不抽**——它是 body 約定，可列為後續（§5）。

---

## 2. 後端 spec 固定點（本案核心交付）

固定點分三類：**(F) 格式本身**、**(R) gate 行為迴歸＋CRLF 補洞**、**(P) 生產者↔消費者同源**。

### 2.1 〔F〕新增 `spec/domain/values/file_context_header_spec.rb`

格式的權威測試——前端的對應測試（§3）要對齊**同一張表**。

| # | 固定 | 斷言 |
|---|---|---|
| F1 | 基本命中 | `HEADER.match("### hw2.R")[1] == "hw2.R"` |
| F2 | 多空白/tab | `paths("###\t  sub/x.R  \n")` → `Set["sub/x.R"]` |
| F3 | 拒兩井號 | `paths("## File Contents\n")` → `Set[]`（不誤抓 section 標籤） |
| F4 | 拒四井號 | `paths("#### x\n")` → `Set[]` |
| F5 | 拒行內/縮排 | `paths("  ### x\n")` 與 `paths(" 1\| ### x\n")` → `Set[]`（`^` 錨定，防 phantom path） |
| F6 | **LF parity** | `paths("### a.R\n1\| x\n")` → `Set["a.R"]` |
| F7 | **CRLF parity（關鍵）** | `paths("### a.R\r\n1\| x\r\n")` → `Set["a.R"]`（**無尾隨 `\r`**） |
| F8 | 多檔 union | `paths("### a.R\n### b/c.R\n")` → `Set["a.R","b/c.R"]` |
| F9 | normalize 全例 | `normalize("./a\\b.R\r")` → `"a/b.R"`；`"  x  "` → `"x"` |
| F10 | 生產↔消費 round-trip | `paths(FileContextHeader.line("a/b.R") + "\n")` 含 `"a/b.R"` |

### 2.2 〔R/補洞〕新增 `spec/domain/values/workspace_edit_gate_spec.rb`（**目前零覆蓋**）

最關鍵 gate，補齊行為網＋格式 case。照 redundant_load_gate_spec 風格。

| # | 固定 | 斷言要點 |
|---|---|---|
| W1 | 無 `workspace_overview` → inert | 回 `[actions, false]`（v1 @-mention 向後相容） |
| W2 | 已載入路徑的 edit 直接放行 | edit 原樣保留、`redirected=false` |
| W3 | 未載入路徑的 edit → 改寫成 load_file | 回 `[[load_file], true]` |
| W4 | **CRLF 檔頭** `### hw2.R\r\n` 視為已載入 | edit 放行（證明 CRLF 檔頭被正確辨識） |
| W5 | normalize：edit 路徑 `./hw2.R` 對上 `### hw2.R` | 放行、不誤改寫 |
| W6 | 同路徑重複 edit / load 去重塌縮 | 第二筆塌成空 |
| W7 | symbol-keyed 與 string-keyed 等價 | 兩種 key 風格結果一致、改寫後 key 風格鏡像原 action |

### 2.3 〔R〕修改既有 gate spec——補 CRLF 檔頭 case

- `spec/domain/values/redundant_load_gate_spec.rb`：新增 1 case——`ctx` 用 `\r\n` 檔頭
  （`"### hw2.R\r\n1\| x\r\n"`）→ 已載入路徑仍被 drop。（現有 14 case 即為去重後的行為迴歸網。）
- `spec/domain/values/edit_patch_content_gate_spec.rb`：新增 1 case——**CRLF 檔頭**被辨識
  （現有測試覆蓋 CRLF 出現在 *body* 比對，但沒覆蓋 CRLF 出現在 *檔頭行*）。

### 2.4 〔P〕生產者↔消費者同源

- `spec/application/prompts/builders/tutor_system_prompt_spec.rb`：新增 case——帶一個 `context_files`
  build，斷言輸出含 `FileContextHeader.line(path)`，且 `FileContextHeader.paths(output)` 抓得到該 path
  （後端**自己產的**檔頭，必須被 gate 的 regex 讀得到）。
- `spec/application/prompts/builders/budget_aware_prompt_assembler_spec.rb`：在 shadow §4.2 的 strip case 上
  追加交叉斷言——`strip_section_headings` 後 `FileContextHeader.paths(live_context)` **仍**抓得到 `### path`
  （strip 掉 `## ` 不能誤傷 `###`）；並加一個 **CRLF 輸入** strip case（`\r\n` 下 `###` 行完整保留）。

### 2.5 〔R〕cross-gate 迴歸

[redundant_load_gate.rb:31](../app/domain/values/redundant_load_gate.rb#L31) 註解提到的 "cross-gate regression
spec"（多半在 `spec/application/services/run_tutor_chat_spec.rb`）：grep 是否有**硬編** `### ` 字串組 fixture；
有的話改用 `FileContextHeader.line` 組，避免格式漂移時 fixture 與正式碼脫鉤。

### 2.6 後端固定點總表

| 檔案 | 動作 | 數量 |
|---|---|---|
| `spec/domain/values/file_context_header_spec.rb` | 新增 | F1–F10 |
| `spec/domain/values/workspace_edit_gate_spec.rb` | **新增（補洞）** | W1–W7 |
| `spec/domain/values/redundant_load_gate_spec.rb` | 改 | +1 CRLF 檔頭 |
| `spec/domain/values/edit_patch_content_gate_spec.rb` | 改 | +1 CRLF 檔頭 |
| `spec/application/prompts/builders/tutor_system_prompt_spec.rb` | 改 | +1 生產者同源 |
| `spec/application/prompts/builders/budget_aware_prompt_assembler_spec.rb` | 改 | +1 strip↔paths、+1 CRLF strip |
| `spec/application/services/run_tutor_chat_spec.rb` | 視情況改 | fixture 去硬編 |

---

## 3. 前端 spec 固定點（跨 repo，MindyCLI）

**Option A 下前端對 `### path` 是純生產者（writer），不再有 reader。** 原 compression §4.2 的
`extractHeaderPaths` 在 Option C 取消——「什麼算 seen / 解析路徑」全收斂到後端
[Option C §3](./2026-06-15-option-c-backend-owned-history-compression.md)；前端只**emit** headers-only 區塊、
**送路徑事實**。故前端測試從「測 reader」轉為「測 writer：emit 的檔頭必須能被後端 §2.1 的同一張格式表
（F1–F10）解析得到」：

- **headers-only 產生器測試（writer）**：給定「本輪載入 a.R 與 b/c.R」，斷言 emit 的 headers-only 區塊
  經後端格式解析後**恰等於** `{"a.R","b/c.R"}`——重點在 emit 的 `### path` 行與後端 `FileContextHeader.paths`
  對齊：LF/CRLF parity（F6/F7）、不誤帶 `N\| ` body、normalize 一致（F9）、多檔 union（F8）。
- 前端 emit 檔頭時抽一個 `FILE_HEADER` 常數（line 組裝），鏡像後端 `FileContextHeader.line`，**勿散落**。
- placeholder 措辭由後端 serializer 持有（Option C §4.1），前端**不**組裝——前端只送路徑，不送 placeholder。

### 3.1 跨 repo 的「合約測試」（真正把格式釘在兩端之間）

一份**共享 golden fixture**（含 `### a.R` / `### b/c.R`、CRLF 與 LF 混用的 headers-only 區塊），
兩端各釘一半、合起來把格式焊死：

- **後端（reader）**：斷言 `FileContextHeader.paths(golden) == {"a.R","b/c.R"}`（即 §2.1 F-series
  跑在共享 blob 上）。
- **前端（writer）**：斷言 `emitHeadersOnly(["a.R","b/c.R"])` 的 `### ` 行**字面等於** golden 的檔頭行
  ——前端產的檔頭必須正是後端 parser 吃得下的格式。

fixture 字面相同 → 任一端改格式都會在自己那半先紅，避免「靜默漂移」。建議 blob 存成共享
`fixtures/file_context_header.sample`，兩 repo 各自 commit 一份拷貝並在 PR checklist 註明「改動需同步」。

---

## 4. 建議提交順序（每步獨立綠燈）

1. **共用常數 ＋ 其 spec**：新增 `file_context_header.rb` ＋ `file_context_header_spec.rb`（F1–F10）。先有權威格式測試。
2. **三 gate 遷移**：改呼叫共用模組，跑既有 gate spec（含 redundant 14 case）確認**行為零變更**。
3. **補洞 ＋ CRLF case**：新增 `workspace_edit_gate_spec.rb`（W1–W7）、redundant/content 各 +1 CRLF 檔頭。
4. **生產者同源**：`tutor_system_prompt.rb` 改用 `FileContextHeader.line`；加 §2.4 兩個 spec。
5. **cross-gate fixture 去硬編**（§2.5，視 grep 結果）。
6. 全套 `bundle exec rake test` 0 failures；`bundle exec rubocop` zero net-new offenses
   （注意 [rubocop-windows-crlf](../memory)：`-a` 會改寫行尾，事後重新正規化成 LF）。

前端（§3）獨立於 MindyCLI repo 進行，以 §3.1 golden fixture 對齊。

---

## 5. 風險與邊角

1. **去重不得改行為**：第 2 步唯一驗收是既有 gate spec 全綠。三個 `normalize` / `HEADER` 字面相同，
   理論上純機械替換；但 EditPatchContentGate 的 `parse_file_context` 內嵌檔頭判定，遷移時別動到 `PREFIX` 分支。
2. **CRLF 在 `normalize` 不在 regex**——若有人「優化」共用模組改成只回 regex capture、省掉 `.strip`，
   CRLF 檔頭會回歸破。spec F7 與 W4 就是守這條的回歸網。
3. **`PREFIX`（`N| ` body 約定）本案未收斂**：它同樣前後端耦合（EditPatchContentGate、guide line 68、
   前端編號器）。可列為 follow-up「共用 body 常數」，但與 `### path` 正交，勿混入本案擴大 scope。
4. **跨 repo fixture 會漂移**：§3.1 的合約測試只在「兩端 fixture 字面相同」時有效；靠 PR checklist 人工同步，
   非強制。長期解是把 fixture 放進兩 repo 都依賴的共享套件，超出本案。

---

## 6. 與既有計畫的關係

- 本案是 compression §6.8 與 shadow §2B/§6 共同承諾的「共用常數＋兩端測試固定」的**落地規格**。
  兩份計畫的格式耦合段落應回指本檔。
- 是 shadow 主線（assembler strip）與 **Option C 後端 history 壓縮**的共同地基：Option C 的
  [`HistoryTurnSerializer`](./2026-06-15-option-c-backend-owned-history-compression.md) **新增為
  `FileContextHeader.paths` 的 consumer**（解析每輪 headers-only 區塊），故本案應**先於或同步** Option C
  落地。`### path` 約定的**地基硬化**可獨立先行。
  （註：compression 06-14 原規劃的「前端 history 序列化」已由 Option C 取代為後端落點。）
