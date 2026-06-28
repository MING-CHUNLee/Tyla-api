# 計畫：把 PersonaProfile 從 Ruby 寫死改成由 TUTOR.md frontmatter 宣告

**日期：** 2026-06-28
**起因：** 目前 [tutor_persona_resolver.rb](../app/infrastructure/filesystem/tutor_chat/tutor_persona_resolver.rb) 把每個 persona 的能力（工具白名單 + 兩個注入旗標）寫死在 Ruby 的 `PROFILES` 常數，且用 `FIXTURE_DIRS` 把 `tier1/2/3` 對應到資料夾。需求：把這些設定改成**寫在各 `TUTOR.md` 的 YAML frontmatter**，由 resolver 讀檔解析出 `PersonaProfile`。

---

## 一、已定案的兩個設計決定（使用者確認）

1. **frontmatter 放三個欄位**：`tools` + `inject_workspace` + `inject_reference`。Ruby 的 `PROFILES` 常數整個刪除（單一來源 = markdown）。
2. **直接用 persona 名稱選取**：`TUTOR_PERSONA` 環境變數改填**資料夾名/frontmatter 的 `name`**（例如 `tutor-feynman`），resolver 直接讀 `TUTORS_DIR/<name>/TUTOR.md`。`FIXTURE_DIRS` 與 `tier1/2/3` 抽象一併移除。

---

## 二、關鍵技術風險（必讀）

實測四個 fixture 的 frontmatter 丟給 `YAML.safe_load`：

| 檔案 | `YAML.safe_load` 結果 |
|---|---|
| `tutor-feynman/TUTOR.md` | ✅ OK |
| `tutor-guide/TUTOR.md` | ✅ OK |
| `tutor-solver/TUTOR.md` | ❌ `Psych::SyntaxError`（`approach:` 含 `asks: when …`，冒號+空格） |
| `tutor-socratic/TUTOR.md` | ❌ `Psych::SyntaxError`（同類問題） |

> 原因：這些 frontmatter **從來沒被真的當 YAML 解析過**——它只是被原封不動塞進 system prompt（見下方「現況資料流」）。`description:` / `approach:` 是長句自由文字，含「冒號+空格」時 YAML plain scalar 會解析失敗。

**現況資料流**：`resolver` 回傳的 `persona_text` = **整份檔（含 frontmatter）** → 在 [run_tutor_chat.rb:179-194](../app/application/services/tutor_chat/run_tutor_chat.rb#L179-L194) 當 `persona:` 傳進 assembler → 在 [tutor_system_prompt.rb:118](../app/application/prompts/builders/tutor_system_prompt.rb#L118) 當 `policy_text` 放進 prompt 第一段。也就是說**現在 frontmatter 整段會進到 LLM 的 prompt**。

這帶出一個必須拍板的子決定，見第三節。

---

## 三、解析策略（建議 A，附替代 B）

### 建議 A — 只精準解析三個 config key，不動 prose、prompt 改動最小 ✅

不對整段 frontmatter 跑 `YAML.safe_load`，而是只針對我們要的三個鍵做定向解析：

- `tools:` 接 flow 序列 `[load_file, load_reference]`
- `inject_workspace:` / `inject_reference:` 接 `true` / `false`

**優點**
- 完全不碰 `description:` / `approach:` 自由文字 → 不必為了遷就 YAML 去重排版面，避開上面的 `Psych::SyntaxError` 地雷。
- `persona_text` 維持「整份檔」不變 → prompt 內容**逐字不變**，只多出三行 config（對 persona_compare 實驗基線衝擊最小）。
- 工具名走 `TutorTools.named` → 拼錯工具名仍 `raise KeyError`（部署期大聲炸，符合 §7.4 fail-closed）。

**缺點**：不是「完整 YAML」，是針對受控格式的小解析器（但格式固定、夠穩）。

### 替代 B — 真 `YAML.safe_load` + 把 frontmatter 重排成合法 YAML + 從 prompt 剝除 frontmatter

把 `description:`/`approach:` 改寫成 YAML block scalar（`>-`）讓整段合法，`resolver` 用 `YAML.safe_load` 解析，並讓 `persona_text` 只回傳**正文（body）**、不再把 frontmatter 送進 prompt。

**優點**：真 YAML、最乾淨的「frontmatter=設定/中繼資料、body=prompt」分離。
**缺點**：要重排四份檔的 frontmatter；prompt 會少掉現在送進去的 name/description/approach 那段 → **改變 LLM 看到的內容、改變 persona_compare 實驗基線**；要改 resolver_spec 對 `persona_text` 的斷言。

> **本計畫以「建議 A」為預設往下寫。** 若你想要更乾淨的真 YAML 分離（接受實驗基線位移），改採 B，我再調整 resolver 與 fixtures 段落。

---

## 四、逐檔改動（採建議 A）

### 1. `app/infrastructure/filesystem/tutor_chat/tutor_persona_resolver.rb`（核心改寫）

- **刪除** `FIXTURE_DIRS`、`PROFILES` 兩個常數。
- `call(persona_name)`：
  - 先驗證名稱（防路徑穿越）：只允許 `\A[\w-]+\z`，否則 `raise KeyError`。
  - 路徑 = `File.join(TUTORS_DIR, persona_name, 'TUTOR.md')`；檔案不存在 → `raise KeyError`（維持「未知 → 大聲炸」契約，現有 spec 也斷言 `KeyError`）。
  - `persona_text` 仍回整份檔（建議 A）。
  - `profile` 改由 `build_profile(text)` 從 frontmatter 解析。
- 新增定向解析（缺值一律 fail-closed）：
  - `tools` 缺 → `[]`（最受限）。
  - `inject_workspace` / `inject_reference` 非明確 `true` → `false`。

骨架（示意）：

```ruby
FRONTMATTER     = /\A---\s*\n(.*?)\n---\s*\n/m
REFUSAL_SECTION = /^## Refusal Message(?: Example)?\s*\n(.*?)(?=^##\s|\z)/m

def self.call(persona_name)
  raise KeyError, "invalid persona name: #{persona_name.inspect}" unless persona_name.to_s.match?(/\A[\w-]+\z/)

  path = File.join(TUTORS_DIR, persona_name, 'TUTOR.md')
  raise KeyError, "unknown persona: #{persona_name.inspect}" unless File.file?(path)

  text = File.read(path)
  Resolution.new(
    persona_text: text,
    refusal:      extract_refusal(text, persona_name),
    profile:      build_profile(text, persona_name)
  )
end

def self.build_profile(text, persona_name)
  block = text[FRONTMATTER, 1]
  raise Errno::ENOENT, "no frontmatter in #{persona_name}/TUTOR.md" if block.nil?

  Values::PersonaProfile.new(
    tools:            Values::TutorTools.named(parse_tools(block)),
    inject_workspace: parse_bool(block, 'inject_workspace'),
    inject_reference: parse_bool(block, 'inject_reference')
  )
end

def self.parse_tools(block)
  m = block.match(/^tools:\s*\[(.*?)\]\s*$/m)
  return [] if m.nil?

  m[1].split(',').map(&:strip).reject(&:empty?)
end

def self.parse_bool(block, key)
  m = block.match(/^#{Regexp.escape(key)}:\s*(true|false)\b/)
  m ? m[1] == 'true' : false
end
```

`extract_refusal` 維持現狀（regex 容忍 `## Refusal Message[ Example]` 後綴）。

### 2. 四份 `spec/fixtures/assignments/CSDS-HW2/tutors/<name>/TUTOR.md`（補 frontmatter 設定）

在現有 frontmatter（`name`/`description`/`approach` 後、收尾 `---` 前）加三行。**三個現役 persona 必須填入「等於目前 PROFILES 的值」以保證行為不變**：

- `tutor-solver`：`tools: [load_file, edit_file, execute_script, load_reference]` / `inject_workspace: true` / `inject_reference: true`
- `tutor-feynman`：`tools: [load_file, load_reference]` / `inject_workspace: true` / `inject_reference: true`
- `tutor-socratic`：`tools: []` / `inject_workspace: false` / `inject_reference: false`
- `tutor-guide`（原本沒被 `FIXTURE_DIRS` 用到，改名稱選取後**變成可選 persona**）：依其用途自訂；使用者範例給的是 `[load_file, load_reference]`。注意 guide 的正文（Hint-First）目前沒提到任何工具，要嘛給它工具、要嘛 `tools: []`，由你決定。

  > **實際決定（2026-06-28）：tutor-guide 目錄已刪除**（git: `D spec/fixtures/assignments/CSDS-HW2/tutors/tutor-guide/TUTOR.md`），不作為可選 persona。理由：guide 原本就未被 `FIXTURE_DIRS` 啟用、Hint-First 策略無獨立工具需求，不值得維護第四份 persona 檔。`TutorPersonaResolver.call('tutor-guide')` → `KeyError`（符合 fail-closed 契約）。

> 格式提醒：使用者最初寫的 `tool:[load_file load_reference` 不是合法寫法。正確為 `tools: [load_file, load_reference]`（鍵名 `tools` 複數、冒號後空格、逗號分隔、括號閉合）。

### 3. `app/application/services/tutor_chat/run_tutor_chat.rb`（env seam 預設值）

- [run_tutor_chat.rb:98-100](../app/application/services/tutor_chat/run_tutor_chat.rb#L98-L100) `persona_key_for`：
  `ENV.fetch('TUTOR_PERSONA', 'tier3')` → `ENV.fetch('TUTOR_PERSONA', 'tutor-socratic')`（缺值仍 fail-closed 退到最受限 persona）。
- 同步更新 [run_tutor_chat.rb:94-97](../app/application/services/tutor_chat/run_tutor_chat.rb#L94-L97) 註解裡的 `tier3`/`tier1` 字眼為新名稱。

### 4. 受影響的 spec（env 值與 resolver 呼叫由 tier → persona 名）

- `spec/infrastructure/filesystem/tutor_chat/tutor_persona_resolver_spec.rb`：
  `call('tier1'/'tier2'/'tier3')` → `call('tutor-solver'/'tutor-feynman'/'tutor-socratic')`；未知 key 測試 `call('full-agentic')` 仍應 `raise KeyError`（該資料夾不存在，照樣成立）。
- `spec/application/services/run_tutor_chat_spec.rb`：所有 `ENV['TUTOR_PERSONA'] = 'tier1'/'tier2'/'tier3'`（行 131、999、1009、1018、1027、1040、1051、1062）→ 對應 persona 名；before/after hook 的 pin（行 131）同步。內容斷言（solver refusal、`Tutor-Solver Mode`）不變。
- **不需改**：`tutor_system_prompt_spec.rb`、`budget_aware_prompt_assembler_spec.rb` 只是 `it` 描述字串提到 tier，且它們是**直接 new PersonaProfile**、不經 resolver，功能不受影響（要不要把描述字眼改順手再說）。

### 5. `scripts/persona_compare.rb`（對照實驗腳本）

- [persona_compare.rb:100](../scripts/persona_compare.rb#L100) `TIERS = %w[tier1 tier2 tier3]` → `%w[tutor-solver tutor-feynman tutor-socratic]`（[persona_compare.rb:140](../scripts/persona_compare.rb#L140) `ENV['TUTOR_PERSONA'] = key` 自然吃新值）。
- 表頭/欄位標籤若想保留「tier1/2/3」語意可加一個 label map；純註解的 tier 字眼可選擇性更新。

### 6. 文件（會過時，建議一起更新）

- [plans/2026-06-23-manual-persona-testing-checklist.md](./2026-06-23-manual-persona-testing-checklist.md) 明文寫「`$env:TUTOR_PERSONA` 只接受 `tier1/2/3`，填 `tutor-feynman` 會 `KeyError`」——本次改動後**正好相反**（要填 persona 名，填 `tier1` 反而炸）。至少加註，最好更新對照表。
- [plans/2026-06-22-persona-testing-plan.md](./2026-06-22-persona-testing-plan.md)、[plans/2026-06-17-ms3-tutor-mode-tiers.md](./2026-06-17-ms3-tutor-mode-tiers.md) 內 `FIXTURE_DIRS`/`PROFILES`/tier-key 的描述屬歷史紀錄，可不動，但若要保持一致可加一行「2026-06-28 起改為 frontmatter 宣告 + 名稱選取」。

---

## 五、fail-closed 行為對照（驗收要點）

| 情境 | 行為 |
|---|---|
| `TUTOR_PERSONA` 未設 | 退 `tutor-socratic`（最受限：無工具、不注入） |
| `TUTOR_PERSONA` 指向不存在的資料夾 | `raise KeyError`（部署期大聲炸） |
| frontmatter 缺 `tools:` | `tools: []`（最受限） |
| frontmatter 缺 `inject_*:` | `false`（最受限） |
| `tools:` 含拼錯的工具名 | `TutorTools.named` `raise KeyError`（大聲炸，絕不靜默放行） |
| 名稱含 `/` 或 `..` | `raise KeyError`（擋路徑穿越） |

絕不 fail-open 到全工具 persona。

---

## 六、測試 / 驗收

1. `bundle exec rake spec`（或專案慣用指令）全綠，重點看：
   - `tutor_persona_resolver_spec`：三個 persona 的 `tools` / `inject_*` / refusal 同源、未知名稱 `raise KeyError`。
   - `run_tutor_chat_spec`：round-1 送出的工具集（solver 四工具 / feynman 唯讀 / socratic `[]`）、prose 假 `<actions>` 被白名單清空、socratic 不進 round 2、socratic prompt 無 tool guide/manifest/workspace——全部維持綠（因 fixtures 值=舊 PROFILES 值）。
2. 手動健全性：`ruby -ryaml` 不再需要解析整段 frontmatter，但可寫個小檢查確認三 persona 解析出的 profile 等於舊 `PROFILES`。
3. （可選，需真 key）`scripts/persona_compare.rb` 跑一輪，確認主硬訊號（edit/execute 只在 solver）仍穩定——驗證行為等價。

> 注意（記憶提醒）：Windows 上 `rubocop -a` 會把行尾改成 CRLF，動完 autofix 要把改到的檔重新正規化回 LF。

---

## 七、改動規模小結

| 檔案 | 規模 |
|---|---|
| `tutor_persona_resolver.rb` | 中（核心改寫，但邏輯單純） |
| 4 份 `TUTOR.md`（補 frontmatter） | 小 |
| `run_tutor_chat.rb`（預設值 + 註解） | 極小 |
| `tutor_persona_resolver_spec.rb` / `run_tutor_chat_spec.rb` | 小（值替換） |
| `scripts/persona_compare.rb` | 極小 |
| 文件更新 | 小（可選） |

風險集中在「YAML 解析策略」這個子決定（第三節）；採建議 A 時行為與既有 prompt 內容幾乎零位移，遷移最安全。
