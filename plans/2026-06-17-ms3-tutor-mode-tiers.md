# DEV MS 3 — 多層 Tutor 服務模式(不同 TUTOR.md → 不同對話)

**Date:** 2026-06-17
**狀態:** 討論中(設計決策草案,尚未實作)
**相關:**
- [2026-06-03-agentic-tutor-backend.md](./2026-06-03-agentic-tutor-backend.md)
- [2026-06-08-plan-decisions-summary.md](./2026-06-08-plan-decisions-summary.md)
- [2026-06-13-load-file-loop.md](./2026-06-13-load-file-loop.md)
- 現有 persona:[app/application/prompts/tutors/](../app/application/prompts/tutors/)

---

## 一、目標(MS3 原文)

> Check that different `Tutor.md` will produce slightly different conversations.
> - **Tutor 1**:full agentic coding assistant
> - **Tutor 2**:Can read files and guide coding but cannot edit/execute code
> - **Tutor 3 (socratic?)**:Cannot even read files — can only answer assignment/domain questions

目標是**證明**:同一份學生輸入,換不同 TUTOR.md,會產生**可觀察、可量測**的不同對話與不同行為(動作),而不只是語氣差異。

---

## 二、現況盤點(實作關鍵事實)

| 事實 | 證據 | 對 MS3 的影響 |
|---|---|---|
| `TOOLS` 寫死、**無條件**傳給 LLM(刻意,非疏漏) | [run_tutor_chat.rb:50-127](../app/application/services/tutor_chat/run_tutor_chat.rb#L50-L127)、`request_tutor_reply` 永遠收 `TOOLS` / `ROUND2_TOOLS`;來由見 [2026-06-04-action-reliability-issue.md](./2026-06-04-action-reliability-issue.md) | **副作用**是 persona 之間能力無差異(只有 prompt 在變);但「無條件傳」本身是為解 action reliability(見 §2.1),**必須保留** |
| persona loader 永遠載入 `tutor-guide` fixture | [tutor_persona_loader.rb](../app/infrastructure/filesystem/tutor_chat/tutor_persona_loader.rb)(忽略 `project_id`) | 目前根本無法切換 persona |
| **TUTOR.md 的唯一載入來源是 fixtures** | 程式碼只讀 `spec/fixtures/assignments/CSDS-HW2/tutors/<persona>/TUTOR.md`([tutor_persona_loader.rb:7-10](../app/infrastructure/filesystem/tutor_chat/tutor_persona_loader.rb#L7-L10)) | 三份新 persona 的定稿內容**必須放進 fixtures 對應 `<persona>/` 目錄**才會被載入生效 |
| **persona / refusal 由兩個各自寫死同一路徑的 module 分別載入** | [tutor_persona_loader.rb:7-13](../app/infrastructure/filesystem/tutor_chat/tutor_persona_loader.rb#L7-L13) + [refusal_loader.rb:10-23](../app/infrastructure/filesystem/tutor_chat/refusal_loader.rb#L10-L23) | persona 一旦可切換,**refusal 必須與 persona 同源**;兩條平行硬路徑無法保證 → 須收斂成單一 resolver(§7.1.1) |
| request contract 無 `mode` / `persona` 欄位 | [tutor_chat.rb](../app/application/requests/tutor_chat.rb) | persona 由 server 端決定(課程設定),非學生選 |
| prompt 組裝假設工具/workspace 都存在 | `TutorSystemPrompt` 的 `TOOL_USE_GUIDE` / `WORKSPACE_*_GUIDE` 無條件附加 | Tutor 3 不能渲染「call load_reference」這類指示(會變謊言) |

**核心結論:現有 4 份 TUTOR.md 只是換皮,沒換骨。** MS3 若只改 prompt,socratic 模式仍握著 `edit_file`,無法做出硬性、可信的差異。

### 2.1 為什麼 TOOLS 是「無條件傳」的(action reliability 歷史)

來源:[2026-06-04-action-reliability-issue.md](./2026-06-04-action-reliability-issue.md)。當時 `actions` 幾乎永遠是 `[]`,根因是 **LLM 會忘記/選擇不呼叫工具**:

1. XML 時代:模型說完「Let me apply...」「Would you like me to...」就停手,從不輸出 `<actions>` block。→ 改用 **API-native function calling**(tool_use),並把 tools **永遠**送出(移除 `provider == 'anthropic'` 條件)。
2. 補丁 v2:就算 tools 送了,模型仍可能不呼叫。→ 把 `TOOL_USE_GUIDE` 觸發條件從「模型行為」改為「**學生意圖**」+ 禁止問確認 + 直接執行,逼模型呼叫。

那份 plan 的失敗嘗試表得出一條關鍵教訓:

> **用 prompt 指令控制模型「要不要呼叫工具」是不可靠的。**

**這條教訓對 MS3 的雙向意義:**

- reliability 問題的方向是 **under-calling(該叫沒叫)**;MS3 工具閘門的方向是 **拿掉不該有的工具**。兩者正交——**不可能「忘記呼叫一個不存在的工具」**,所以工具閘門天生免疫於 reliability 問題。
- 反過來推:既然 prompt 管不動 tool-calling,那麼**要保證 Tutor 3 絕不 edit/execute,唯一可靠的方法就是 API 層 `tools: []`**。在 prompt 寫「不准改檔」會重蹈 2026-06-04 的覆轍(一樣是用 prompt 控制 tool 行為,只是方向相反)。
- **必須保留的性質**:native function calling + 對「該 persona 的 tools」永遠無條件傳送。MS3 只改「無條件傳的**內容**」(改成 per-persona 白名單),**不**把 tools 改回可選/條件傳送。

---

## 三、核心設計:兩個槓桿

要做出「真正不同的對話」,必須同時動兩個槓桿:

1. **工具閘門(結構性保證)** — 每個 persona 一份 tool 白名單,在 API 層就決定模型握有哪些工具。
   *Why:* prompt 的「Forbidden」是軟約束,模型仍可能吐 tool call;工具白名單是硬約束,物理上做不到。**這正是 §2.1 reliability 教訓的必然推論——既然 prompt 管不動 tool-calling,能力差異就只能靠白名單,不能靠 prompt。** **但「物理上做不到」只在 native tool_use channel 成立:回應沒有 native tool_calls 時,系統會 fallback 去 prose-parse(`<actions>` block),這條 channel 不受白名單管。白名單要當真正的硬約束,必須同時治理這兩條 channel(§7.3)——否則 prose 會把被閘掉的工具重新放回 `actions[]`。**
2. **TUTOR.md 內容(prompt)** — persona / Allowed / Forbidden / 教學法,決定**怎麼用**手上的工具與**對話風格**。

> 光靠 prompt = 換皮;工具閘門 + prompt = 換骨。MS3 要的是換骨。

---

## 四、三層能力階梯

| 能力 | Tutor 1 全 agentic | Tutor 2 read & guide | Tutor 3 socratic |
|---|:---:|:---:|:---:|
| `load_file`(讀學生 workspace 檔) | ✓ | ✓ | ✗ |
| `load_reference`(讀 instructor 解答進 tutor context) | ✓ | ✓(不逐字外洩) | ✗ |
| `edit_file`(改學生檔) | ✓ | **✗** | ✗ |
| `execute_script`(跑 R) | ✓ | **✗** | ✗ |
| 注入 `file_context` / `workspace_overview` | ✓ | ✓ | **✗** |
| lazy 注入 reference solution(模型 call load_reference → round 2) | ✓ | ✓ | ✗ |
| 教學法基調 | Execution-First(交付答案) | **Feynman**(讀碼 + 要學生講回來) | Socratic 純提問 |
| 工具白名單 | `[load_file, edit_file, execute_script, load_reference]` | `[load_file, load_reference]` | `[]` |

**設計原則:能力是「單調遞減」的階梯**(Tutor 3 ⊂ Tutor 2 ⊂ Tutor 1),這讓對照組乾淨、論文敘事清楚。

### 4.1 整條階梯 = Fading Worked Solution 梯度(meta-框架)

把三台 tutor 當「一個整體」看,Tutor 1 → 2 → 3 就是一條揭露程度遞減的 **faded worked solution** 梯度:

```
Tutor 1            Tutor 2            Tutor 3
完整答案     →     讀碼 + 探問   →    純提問不給答案
(fully worked)     (partial)          (fully faded)
揭露最多 ←───────────────────────────→ 揭露最少
```

- **Tutor 1 = answer-first 錨點**(fully worked example):直接交付答案。注意這是 answer-**delivery**——本身不含 fading/研讀/遷移,單看**不算**完整的 Answer-First *Learning*,只是這條梯度的「最揭露」端。
- **Tutor 3 = fully faded 端**:完全不揭露,純提問。
- 「Fading / Answer-First」是**整條階梯的 meta-框架,不塞進任何單一 tutor**。經典 fading 是同一學生「隨時間」淡化;此處是「跨模式」淡化,結構上類比——**若老師在課程中讓學生依序 Tutor 1 → 2 → 3,它就字面上成為一條 faded-worked-solution 學習軌跡。**

---

## 五、Tutor 2 教學法:純 Feynman Technique

「Can read files and guide coding but cannot edit/execute」對應的角色 = **pair-programming 的 navigator**:看得到學生的真實程式碼(read),唯一輸出是話語,學生始終是唯一的 driver。Tutor 2 採**單一招牌教學法:Feynman Technique**(不混血)。

**核心動作:** 要學生把自己的程式碼用白話「講回來」,tutor 拿學生的解釋對照**真實程式碼**,理解缺口浮現之處就是指導點。例:「用你自己的話說第 14 行那個迴圈在做什麼」→「那 `total` 第一輪跑完是多少?跟你預期一樣嗎?」

**為什麼是 Feynman(而非混血或逆向工程):**
- **Feynman 本質上需要讀到學生的程式碼** —— 必須拿學生的解釋對照真實碼才找得到缺口。這讓「Tutor 2 能讀檔、Tutor 3 不能」的能力階梯**由教學法本身決定**,而非任意切分;Socratic 就題目提問,不需看檔。read/no-read 因此是有原則的對應(這是論文裡乾淨的論證)。
- **單一變數,實驗乾淨** —— 一台 tutor 一個招牌教學法,**該 tutor 內部**的對話特徵不被混血稀釋,可乾淨歸因於那個教學法。**但跨層比較要小心歸因:** tier1↔tier2↔tier3 的對話差異應歸因於**整個 mode bundle(工具白名單 + prompt),不是教學法單獨**——因為兩個槓桿(§3)是綁在一起動的(換工具又換 prompt),把跨層差異說成「純教學法造成」會過度宣稱。論文敘事:層間差異 = mode 差異;教學法乾淨度的論證限於「單一 tutor 不混血」。
- 逆向工程(讀碼回推理解)其實已被 Feynman 的「讀碼 + 講回來」涵蓋,不需另立為獨立支柱。

**已知邊界(睜眼接受):** Feynman 是**診斷型**(找理解缺口),非**前進型**(推進寫碼)。學生「懂了但仍不會寫」時純 Feynman 會卡——這是刻意保留的教學邊界。是否加「淡化範例」當釋壓閥見 §9 D7(暫定不加,以保純度)。

**結構脆弱性(三層中風險最高):** tier2 的 Feynman **結構上依賴**「tutor 讀得到學生的碼」,而讀碼必須靠模型自己呼叫 `load_file`——但 §2.1 說 prompt 管不動 tool-calling。三層裡只有 tier2「不呼叫就垮」:tier1 不讀也能硬掰交付、tier3 不需要讀,唯獨 tier2 沒讀到碼就無從對照,會退化成憑空亂猜或意外變成 socratic(與 tier3 撞臉)。這是 go/no-go 風險最高的一層(量測見 §9 D6);救法(前端預載 `file_context`)又與 §八 的 t2/t3 區分線互相牽制——預載了就沒 `load_file` 訊號。

> 對照記憶:Tutor 1 直接幫你改檔+跑;Tutor 2 看著你的檔、要你把它講回來、在你卡住處探問,你動手;Tutor 3 連你的檔都看不到,只就題目/領域用蘇格拉底法提問。

---

## 六、三個 persona 的 TUTOR.md 對應與大綱

現有檔案 → 三層映射:

| 層級 | 採用/演進自 | 需要的調整 |
|---|---|---|
| Tutor 1 | `solver/TUTOR.md`(Execution-First;含過時的 `[THOUGHT]/[ACTION]/[ANSWER]` 標記) | **演進為「更 agentic」**:四工具全開、鼓勵自主串 load→edit→execute 的 lazy-load 迴圈、主動 `load_reference` 自驗、不問確認;**移除 `[ACTION {...}]` 文字標記**(native tool_use 已取代,留著會衝突) |
| Tutor 2 | `tutor-guide/` → **改名 `tutor-feynman/`**(現為 hint-first 三段提示) | **重寫**:read-only navigator + **純 Feynman**(要學生講回自己的碼);Forbidden 明列「不得 edit_file / execute_script」「不得直接給完整修法」;Allowed 含 load_file 讀檔後就學生的解釋探問 |
| Tutor 3 | `tutor-socratic/TUTOR.md`(現已 never-reveal + 每句結尾提問) | **補框架**:明示「你看不到任何學生檔,只能就 assignment/domain 回答」;Forbidden 含「不得引用具體行號/檔案內容」 |

> MS3 主對照組 Tutor 1 用 `solver` 演進版(更 agentic);`default/TUTOR.md`(寫檔前出示 diff 求確認)較不 agentic,留作溫和變體。

每份維持既有 schema:`Role / Allowed / Forbidden / Pedagogy / Enforcement / Refusal Message`——**三份皆含 `Pedagogy` 段**(Tutor 1 述 Execution-First lazy-load 迴圈、Tutor 2 述 Feynman 的「要學生講回來 → 在缺口處探問」迴圈、Tutor 3 述 Socratic elenchus 四步)。

> **Refusal 標題的後綴差異(已知,resolver 須容忍):** Tutor 1 用 `## Refusal Message`(會被 guard 擋下時逐字吐出);Tutor 2 / Tutor 3 刻意用 `## Refusal Message Example`——`Example` 後綴是有意保留的語意標記(該段對純對話型 tutor 是「示範語氣」而非逐字訊息)。**代價:** 既有 [refusal_loader.rb:19](../app/infrastructure/filesystem/tutor_chat/refusal_loader.rb#L19) 的 regex `^## Refusal Message\s*\n` 配不到帶後綴的標題(會 `raise Errno::ENOENT`),目前沒爆只因 loader 寫死讀 `tutor-guide`。§7.1.1 的 resolver 接管後,**抽取 regex 必須改成容忍標題後綴**(見該節)。

> **`## Refusal Message[ Example]` 一段、兩個消費者(別把兩條路徑混為一談):**
> - **(a) guard 擋下路徑(固定、刻意不呼叫模型):** verdict=`:forbidden` 時 [run_tutor_chat.rb:156](../app/application/services/tutor_chat/run_tutor_chat.rb#L156) 直接 `forbidden_outcome`、`tutor_mini_loop` 完全不跑,由 `RefusalLoader` 讀此段**逐字**吐回。固定字串是**刻意**的——guard gate 的存在意義就是在判定攻擊時不花 LLM call、不把攻擊輸入餵給 tutor 模型;且 §2.1「prompt 管不動模型行為」的對稱反面是:讓模型自己生成拒絕,就有被 jailbreak 成**不拒絕**的風險。persona 語氣不靠模型也拿得到——resolver 讓 refusal 與 persona 同源(§7.1.1),socratic persona 的固定拒絕語天生就是 socratic 口吻。
> - **(b) 正常對話婉拒路徑(動態、本就由 LLM 生成):** socratic 不直接給答案、feynman 不給完整修法,這類拒絕**不經 `forbidden_outcome`、不是固定字串**,而是模型在 prose 自行講出、隨問題不同而不同(§7.5 末句)。因 `persona_text` = TUTOR.md 全文整份進系統提示(§7.1.1),模型看得到 `## Refusal Message Example` 並拿它當**語氣範例**。
> - **結論:** 「讓 LLM 動態回拒絕」對路徑 (b) 本就成立,不需改動；路徑 (a) 刻意保持固定,**不**改成模型生成。`Example` 後綴正是在標記「此段對純對話型 tutor 主要是 (b) 的語氣範例」,但 (a) 仍會逐字取用它作為 guard-block 的回應。

### 6.1 改名:`tutor-guide` → `tutor-feynman`(與 `tutor-socratic` 對稱)

Tutor 2 的 persona 資料夾由 `tutor-guide` 改名為 **`tutor-feynman`**,讓教學型 tutor 都以「教學法即名稱」命名(`tutor-feynman` / `tutor-socratic`)。

**前提確認:`tutor-guide` 不是 load-bearing 的 mode key。** `RefusalTemplates.for(_mode = nil)` 的 mode 參數被忽略([refusal_templates.rb:14](../app/domain/values/refusal_templates.rb#L14)),request contract 也沒有 `mode` 欄位——2026-05-20 計畫的 mode 白名單 / PolicyLoader 從未落地。所以改名只是檔案移動 + 少數 hardcoded 路徑,**沒有邏輯白名單要動**。

**改名清單(blast radius):**

| 類型 | 位置 | 動作 |
|---|---|---|
| 實際被載入的檔 | `spec/fixtures/assignments/CSDS-HW2/tutors/tutor-guide/TUTOR.md` | 移到 `.../tutors/tutor-feynman/TUTOR.md`(內容同時改寫為純 Feynman) |
| 草稿庫副本 | `app/application/prompts/tutors/tutor-guide/TUTOR.md` | 同上改名 + 改寫 |
| frontmatter | 兩檔的 `name: tutor-guide` | → `name: tutor-feynman` |
| hardcoded 路徑 ×3 | `tutor_persona_loader.rb:8`、`refusal_loader.rb:11`、`scripts/phase0_caps_measurement.rb:124` | 更新路徑(MS3 persona 選擇機制落地後,前兩者會被 PersonaProfile 取代) |
| spec ×3 | `tutor_chat_loaders_spec.rb:33`(描述字串)、`guard_agent_spec.rb:53`、`refusal_templates_spec.rb:17`(後兩者 mode 字串純裝飾) | 更新字串 |
| API 文件 | `doc/api_tutor_chats.md:457` | 更新路徑 |
| 歷史 plans | 多份 2026-05 計畫 | **不動**(歷史記錄) |

**執行時機:** 與 §5 的 Tutor 2 內容改寫**綁在一起做**——反正檔案要重寫,移動 + 改名 + 改內容一次完成,避免「先 churn 再 rewrite」。

---

## 七、架構改動點

### 7.0 可行性已驗證:transport 層免改,改動集中在 `tutor_mini_loop`

「帶與不帶/帶哪些 tools」**不需要新機制**——2026-06-04 把 `tools` 做成可選參數時就已支援空陣列與子集:

- Anthropic:[anthropic_client.rb:34](../app/infrastructure/llm/anthropic_client.rb#L34) `body[:tools] = tools if tools.any?` — 空陣列 → 整個 `tools` key 不送。
- OpenAI:[openai_client.rb:30](../app/infrastructure/llm/openai_client.rb#L30) `payload[:tools] = openai_tools(tools) if tools.any?` — 同上;子集則 `tools.map` 逐一轉換。
- 兩家 API 都接受「不帶 tools 欄位」(= 純對話),空 tools 不會報錯。

決定「送什麼」的點只有兩個,其中一個已參數化:

- [run_tutor_chat.rb:231-244](../app/application/services/tutor_chat/run_tutor_chat.rb#L231-L244) `request_tutor_reply` — **已收 `tools` 參數並原封轉給 `send_prompt`,不用改**。
- [run_tutor_chat.rb:197-207](../app/application/services/tutor_chat/run_tutor_chat.rb#L197-L207) `tutor_mini_loop` — **寫死**傳 `TOOLS` / `ROUND2_TOOLS`。

> **結論:核心改動就只有 `tutor_mini_loop` 一處——把寫死的 `TOOLS` 換成「依 persona 決定的陣列」。** 其餘(client、`request_tutor_reply`、gates)全部沿用。

### 7.1 PersonaProfile(最小形狀)

不需要大抽象。Profile 本質上只是「餵給 `tutor_mini_loop` 一個 tools 陣列 + 餵給 builder 幾個 boolean」:

```
PersonaProfile = (
  tools:             [...]    # round-1 工具陣列;round-2 由此 reject load_reference 推導
  inject_workspace:  bool     # builder 是否渲染 workspace + 行號/overview guide
  inject_reference:  bool     # 是否渲染 COURSE_MATERIALS_MANIFEST(lazy solution)
)
```

`tool_use_lines` 不另立欄位——TOOL_USE_GUIDE 的渲染由 `tools` 陣列**推導**(只描述 profile 真正持有的工具),不需手動列舉。

| Profile | fixtures 目錄 | tools | inject_workspace | inject_reference |
|---|---|---|:---:|:---:|
| tier1 | `tutor-solver` | `[load_file, edit_file, execute_script, load_reference]` | ✓ | ✓ |
| tier2 | `tutor-feynman` | `[load_file, load_reference]` | ✓ | ✓ |
| tier3 | `tutor-socratic` | `[]` | ✗ | ✗ |

> resolver 須持有**兩張**對照:`persona_key → fixtures 目錄`(讀哪份 TUTOR.md)與 `persona_key → profile`(上表)。canonical 目錄是 `tutor-solver`(**非**草稿庫殘留的 `solver` / `default`)。

### 7.1.1 PersonaResolver:統一兩個寫死路徑 + 選擇鍵(落地前提)

**現況不優雅:** persona 文字與 refusal 文字由**兩個各自 hardcode 同一路徑**的 module 分別載入——[tutor_persona_loader.rb:7-13](../app/infrastructure/filesystem/tutor_chat/tutor_persona_loader.rb#L7-L13) 與 [refusal_loader.rb:10-23](../app/infrastructure/filesystem/tutor_chat/refusal_loader.rb#L10-L23),且都忽略 `project_id`、寫死指向 `tutor-guide`。persona 一旦可切換,refusal **必須與 persona 同源**(否則出現「socratic 人格卻吐 solver 拒絕語」),兩條獨立硬路徑無法保證這件事。

**Canonical 來源(已定案,唯一):** 執行期只讀 `spec/fixtures/assignments/CSDS-HW2/tutors/<persona>/TUTOR.md`。三份新 persona 的**定稿內容必須落在此**,程式碼才看得到。

**做法:** 把兩個 loader 收斂為單一 `TutorPersonaResolver`,一次解析出 persona 三件套:

```
PersonaResolution = (
  persona_text:  String           # TUTOR.md 全文(沿用現行載入語意)
  refusal:       String           # 同一檔的 "## Refusal Message" 段
  profile:       PersonaProfile    # §7.1 的 tools / inject_* 三欄
)
```

- 入口:`TutorPersonaResolver.call(persona_key)` → 依 key 選 `<persona>/` 目錄,讀同一檔解析三者。
- `RefusalLoader` / `TutorPersonaLoader` 退役為 resolver 薄包裝(或刪除),消除平行硬路徑。
- `run_tutor_chat.rb` 的 `assemble_prompt` 與 `forbidden_outcome` 改用**同一個** resolution,而非各自呼叫兩個 loader。
- key → profile 對照表(tier1/2/3)寫死於 resolver 內。

**選擇鍵 `persona_key` 從哪來(§7.4 安全前提):** request contract 沒有此欄、loader 忽略 `project_id`。MS3 實驗階段以 **env var `TUTOR_PERSONA`** 當選擇鍵最小可行,**不**開成 request 欄位(學生不可自選)。正式由課程設定(server 端 project→persona 映射)接手。

**未知 / 缺值一律 fail-closed(安全,絕不退 tier1):**
- `TutorPersonaResolver.call(persona_key)` 是純函式:收到**有值但不在 `{tier1,tier2,tier3}`** 的 key → **`raise`**(typo / 部署 bug 應大聲炸在部署期,不可靜默放行)。
- env seam `persona_key_for`(§7.5)**缺值** → 退到**最受限的 tier3**(`ENV.fetch('TUTOR_PERSONA', 'tier3')`),fail-closed 讓 server 能開機但不發全工具權限。
- **絕不** fail-open 到 tier1(full agentic)——否則一個 typo 或漏設就把四工具權限發給學生,違反 §7.4。

### 7.1.2 TOOL_USE_GUIDE 必須拆成 per-tool 片段(本案最大工作量)

§7.1 說 TOOL_USE_GUIDE「由 tools 陣列推導,不手動列舉」——但現況 [tutor_system_prompt.rb:44-53](../app/application/prompts/builders/tutor_system_prompt.rb#L44-L53) 是**一整塊 frozen string,把四個工具的指示焊死在一起**,且 [tutor_system_prompt.rb:91](../app/application/prompts/builders/tutor_system_prompt.rb#L91) **無條件 append**。tier2 若照單收下,系統提示會叫它 call `edit_file`/`execute_script`(它根本沒有這些工具),與 persona 的 Forbidden 自相矛盾。

**所以這不是「推導一行」就好,而是要把 monolith 拆成「每工具一段」可組裝的片段:**

```
TOOL_GUIDE_FRAGMENTS = {
  'edit_file'      => "Call `edit_file` ONLY when ...",
  'execute_script' => "Call `execute_script` when ...",
  'load_file'      => "Call `load_file` when ...",
  'load_reference' => "Call `load_reference` when ...",
}
# 共通結尾(別問確認 / 沒工具就別 call / history vs live 真相)只在「至少有一個工具」時附上
```

- `build` 依 `profile.tools` 取對應片段組出 guide;`tools == []`(tier3)→ **整段 TOOL_USE_GUIDE 不渲染**。
- WORKSPACE_OVERVIEW_GUIDE / LINE_NUMBER_GUIDE 維持現行「有 workspace 才渲染」;tier3 `inject_workspace=false` 連 workspace 區塊都不進來(§7.2),自然不渲染。

> 這格才是 plan 原標「中」裡**真正的工作量**——是實作重點,別當成 §7.2 表中其他列的「極小/小」。

### 7.2 落點

| 檔案 | 改動 | 量 |
|---|---|---|
| `tutor_persona_resolver.rb`(新檔) | §7.1.1:依 `persona_key`(env `TUTOR_PERSONA`)解析出 `persona_text` + `refusal` + `profile`;key→profile 對照表(tier1/2/3)寫死於此 | 小 |
| `tutor_persona_loader.rb` / `refusal_loader.rb` | 退役為 resolver 薄包裝(或刪除),消除兩條平行硬路徑;順帶解掉「refusal 與 persona 不同源」風險 | 小 |
| `run_tutor_chat.rb` | `tutor_mini_loop` 改用 `profile.tools`;ROUND2 由 `profile.tools - load_reference` **動態推導**(刪全域 `ROUND2_TOOLS`);**profile 無 `load_reference` 時整段跳過 round 2**(以 profile flag 短路,不靠 prose 判斷,§7.3);**`extract_reply` 的 prose-parsed actions 以 `profile` 工具白名單過濾**(tier3 `tools:[]` → `actions` 強制為 `[]`,§7.3);`forbidden_outcome` 與 `assemble_prompt` 共用同一個 PersonaResolution | 小 |
| `tutor_system_prompt.rb` | §7.1.2:TOOL_USE_GUIDE 拆 per-tool 片段、依 `profile.tools` 組裝,`tools == []` 不渲染;`build` 收 profile,`inject_reference=false` 不渲染 manifest、`inject_workspace=false` 不渲染 workspace/行號 guide。**tier2 不再被指示去 edit/execute**(它沒有那些片段) | **中(本案最大工作量)** |
| `budget_aware_prompt_assembler.rb` | `call` 收 profile;`inject_workspace=false`(tier3)時跳過 overview / file_context / fixture student file 注入,並把 profile 一路傳給 `TutorSystemPrompt.build`;**`inject_workspace=false` 時 `build_history` 還要剝掉 `session_turns` 的 `context_headers`**(否則檔名經 history channel 漏給 tier3——§7.3 漏洞三) | 小 |
| 三份 TUTOR.md 定稿內容 | 落到 canonical fixtures `spec/fixtures/assignments/CSDS-HW2/tutors/<persona>/`(tier1=`tutor-solver`、tier2=`tutor-feynman`、tier3=`tutor-socratic`)——目前 fixtures 只有 `tutor-guide`,**三個目錄都要建/補齊** | 小 |
| transport(兩個 client) | **零**(§7.0 已支援空 tools) | — |

### 7.3 與既有 mini-loop 的互動(注意點)

**根因(白名單只治理 native channel):** §3 槓桿一賣的「工具白名單 = 物理上做不到」只在 **native tool_use** 成立。系統有**第二條 action channel**:回應沒有 native tool_calls 時,`extract_reply` 與 `wants_reference?` 都會 fallback 去 prose-parse(`TutorReplyParser` 認 `<actions>[...]</actions>` JSON block)。**對 tier3(`tools:[]`)而言 native tool_calls 永遠為空,所以這兩處每次都走 prose 分支**——白名單在 native 層擋掉的工具,prose 可以原封放回去。下面兩個症狀是同一個根因,**必須兩處都治**,白名單才真的是硬約束。

- **症狀一:解答外洩(round-2 觸發,以 profile flag 短路)** → tier3 模型只要在散文吐出像 `load_reference` 的 `<actions>` block,`wants_reference?`([run_tutor_chat.rb:345-352](../app/application/services/tutor_chat/run_tutor_chat.rb#L345-L352))就回 true → 觸發 round 2 → [run_tutor_chat.rb:223](../app/application/services/tutor_chat/run_tutor_chat.rb#L223) `include_solution: true`,**把解答注入給看不到檔的 tier3**。
  - **修法:** round-2 的 gate 必須是 `profile.tools.include?('load_reference')` 的**布林短路,放在 `wants_reference?` 之前**;不能只靠 `tools.empty?`,因為 prose parser 照跑。`profile` 不含 `load_reference` → `tutor_mini_loop` 直接 `finish_loop([round1])`,連 `wants_reference?` 都不呼叫。
- **症狀二:幻影動作(終端抽取,以白名單過濾 prose-parsed actions)** → [extract_reply](../app/application/services/tutor_chat/run_tutor_chat.rb#L409-L419) 對 tier3 永遠走 prose 分支;若 socratic 模型在散文吐出 `<actions>[{"type":"edit_file",...}]</actions>`,就會生出一個**非空 `actions[]`**,直接打破 §八 表中「Tutor 3:無 actions」這個最硬的訊號。tier2 同理可被塞回 `edit_file`/`execute_script`。
  - **修法:** prose-parse 後、進 `EditPatchNormalizer` / `apply_gates` 之前,**用 `profile` 的工具名集合過濾 actions**(`actions.select { |a| profile.tool_names.include?(action_type(a)) }`,其中 `tool_names = profile.tools.map { |t| t[:name] }`)。這讓白名單**同時權威於兩條 channel**,是 §3 槓桿一的誠實實作:tier3(空集合)→ `actions` 強制為 `[]`;tier2 → `edit_file`/`execute_script` 一律丟掉。native 分支本就只拿得到 profile 的工具,過濾對它是 no-op,故此規則對兩分支統一套用即可。`load_reference` 仍由既有 [run_tutor_chat.rb:415](../app/application/services/tutor_chat/run_tutor_chat.rb#L415) 的 server-side reject 處理(它在白名單內、但對 client 不可外洩),兩者不衝突。
- **Tutor 2 保留 `load_reference`** → round 2 把解答注入 tutor 自己的 context 強化指引,但 manifest 規定「never shown verbatim」,符合「不逐字外洩」。其 ROUND2 工具 = `profile.tools - load_reference` = `[load_file]`(由 profile 動態推導,**非**全域 `ROUND2_TOOLS` 常數——後者刪除)。
- Tutor 3 若仍渲染 `COURSE_MATERIALS_MANIFEST`(叫它 call load_reference)會變謊言 → 隨 `inject_reference=false` 一起關掉。

**漏洞三:tier3 隔離的另一條漏口——history channel(可修)。** `inject_workspace=false` 只關掉**system-prompt** 裡的 workspace 區塊;但 history 是經 `BudgetAwarePromptAssembler.build_history` → `HistoryTurnSerializer` **獨立組裝、不受該 flag 管**。`session_turns` 的 `context_headers` 會被攤成「`[Previously inspected last turn ... : <paths>]`」塞進 user content([history_turn_serializer.rb:25-30](../app/domain/values/history_turn_serializer.rb#L25-L30)),**把檔名漏給看不到檔的 tier3**;若 history 還混進 tier1/2 的 `load_file`/`edit_file`/`execute_script` 動作,連行號、edit diff、R code 也會經 [render_action](../app/domain/values/history_turn_serializer.rb#L67-L111) 一起漏進來。

- **修法(設計):** `inject_workspace=false` 時,`build_history` 前先剝掉 `context_headers`(丟掉 seen_paths 註記),確保 tier3 的 history 不帶任何 workspace 參照(§7.2 budget_aware 列)。
- **§八 實驗夾具:** 對照表用**乾淨首輪(空 history)**,本就避開此漏;但這只保護實驗,不保護正式多輪 tier3 會話——設計層的剝除仍要做。

**漏洞二:殘餘(filter 補不掉,睜眼接受)——prose content channel。** §7.3 上面的白名單只擋得住 prose 裡的**動作**(`<actions>` block);它擋**不**住模型在散文**編造內容**(「你第 14 行的 `total`…」)。`tools:[]` 是**動作層**的硬保證,但「tier3 不引用行號、不假裝看到碼」純粹是 `tutor-socratic` 的 Forbidden prompt 約束、**無結構後盾**——這正是 §2.1「prompt 管不動 tool 行為」的**對稱反面**:prompt 一樣管不動模型「不要假裝看到」。

> 結論:tier3 的「看不到檔」是**動作層結構性、認知層 soft**。建議當**已知邊界**接受,並量測 tier3 在 prose 幻覺行號/檔案內容的頻率,當論文的 limitation 誠實揭露(對應 §八 prose 軸訊號只能當輔證)。

### 7.4 persona 選擇權(安全)

persona 由 **server 端 / 課程設定**決定,**不**開成 request 參數讓學生選——否則學生可挑「full agentic」繞過教學設計。MS3 實驗階段以 **env var `TUTOR_PERSONA`** 當 `persona_key`(§7.1.1),由 `TutorPersonaResolver` 解析;缺值 fail-closed 退 tier3、未知值 raise(§7.1.1),**絕不退 tier1**。正式由課程設定的 project→persona 映射接手。選擇鍵**不**進 request contract。

### 7.5 實作注意事項(易漏的小坑)

- **`env TUTOR_PERSONA` 是 process-global——一台 server 只能是一種 persona。** env var 在 server 啟動時讀一次、整個程序所有請求共用(seam 為 `persona_key_for = ENV.fetch('TUTOR_PERSONA', 'tier3')`——**缺值 fail-closed 退 tier3、未知值 raise**,§7.1.1)。所以一個跑著的 server 永遠只回同一種 persona;**§八 對照實驗要切 persona 必須改 env + 重啟**(或開三台),不能讓同一程序這個請求當 tier1、下個當 tier3。persona 也因此與 `project_id` 脫鉤(同一 project 拿到的是 server env 指定的 persona)。將來改「課程設定(project→persona)」是另一套機制,resolver 入口會從 `persona_key` 變 `project_id`,介面要再改一次。
- **兩套 refusal 互不相干,§7.1.1 只收斂其中一套。** guard 端(`/guard_checks` 判攻擊)用 `RefusalTemplates.for`——3 句寫死通用語**隨機抽一句**、與 persona 無關([run_guard_check.rb:66](../app/application/services/guard/run_guard_check.rb#L66));tutor 端 `forbidden_outcome` 用 `RefusalLoader.load` 讀 TUTOR.md 的 `## Refusal Message`([run_tutor_chat.rb:446](../app/application/services/tutor_chat/run_tutor_chat.rb#L446))。resolver **只統一後者**,不碰 guard 的隨機通用語(沒問題,但要寫清範圍:攻擊拒絕語不會配合 socratic 口吻)。另注意:`## Refusal Message` 只用在「被 guard 擋下」這條路;persona 在**正常對話中**的拒絕(如 socratic 不直接給答案)是寫在 TUTOR.md 正文、由模型自己講出——不經 RefusalLoader。
- **`profile` 兩次 assemble 都要傳。** `tutor_mini_loop` 的 `assemble_prompt` 被呼叫兩次——round 1([run_tutor_chat.rb:217](../app/application/services/tutor_chat/run_tutor_chat.rb#L217))與 round 2([run_tutor_chat.rb:223](../app/application/services/tutor_chat/run_tutor_chat.rb#L223),模型 call 了 load_reference 才走到)。新的 `profile`(`inject_workspace` / `inject_reference`)**兩次都要接**;tier2 會走到 round 2(它有 load_reference),round 2 若漏傳 profile,該輪 workspace / manifest 會用預設旗標重組、與 round 1 不一致。

---

## 八、如何展示「slightly different conversations」(實驗設計)

固定一組學生輸入,對三個 persona 重放**完全相同**的 request,收集回應與動作,做對照表。

**固定夾具(已定案——焦點檔只放 `workspace_overview`,不預載 `file_context`):** 學生焦點檔(例 `analysis.R`)**只列在 `workspace_overview`(檔名清單,無內容),不放進 `file_context`(已載入的行號內容)**。理由:這樣 `load_file` 才能成為 tier2 vs tier3 的**結構性區分訊號**——tier1/tier2 想看碼必須 `load_file`(會出現在 `actions[]`),tier3 無此工具(永遠不出現)。若改成預載 `file_context`,tier2 不需 `load_file`,它與 tier3 在 actions 軸上**都退化成「無 actions」**,只剩 prose 差異(soft),區分線就垮了。代價:這把 tier2 押在 D6(模型是否可靠呼叫 `load_file`)上——而 D6 本來就是要量測的(見下方訊號分級)。

**範例 prompt:**「我的 `summarize()` 回傳值不對,幫我看一下。」(`analysis.R` 僅見於 overview,未預載 file_context)

| 觀察訊號 | Tutor 1 | Tutor 2 | Tutor 3 |
|---|---|---|---|
| `actions[]` 出現的工具 | `load_file` → `edit_file`(+ 可能 `execute_script`) | 只有 `load_file`(讀),**無 edit/execute** | **無 actions** |
| 內容風格 | 直接給修好的程式碼 | 要學生用自己的話講回自己的碼、在缺口處追問 | 蘇格拉底提問,結尾必有問句 |
| 是否提及具體行號/檔案 | 是 | 是(讀得到,針對其碼提問) | **否**(看不到檔) |
| 解答揭露程度 | 完整(answer-first 錨點) | 不直接給修法(靠探問逼出理解) | 不揭露(fully faded) |

**訊號分三級(避免過度宣稱,據實標註強度):**
- **主區分訊號(硬,工具閘門保證、與焦點檔放哪及 D6 都無關):** `edit_file` / `execute_script` 只可能出現在 Tutor 1。tier2/tier3 物理上沒有這兩個工具,且 prose 幻影已被 §7.3 白名單過濾擋掉,所以「tier1 交付可執行的修改 vs tier2/tier3 不交付」是**最穩的證據**——這條成立不依賴任何模型行為。
- **次區分訊號(t2 vs t3,依賴 D6):** `load_file` 出不出現。在「焦點檔只放 overview」的夾具下,tier2 應 `load_file`、tier3 不會;但這押在模型可靠呼叫 `load_file` 上(D6)。**若量測顯示 tier2 漏叫,那是一個 finding(tier2 脆弱性),不是實驗失敗**——照實回報,並退而以主訊號 + prose 差異佐證。
- **prose 軸訊號(soft,只能當輔證):** 「是否引用具體行號/檔案」區分 t2/t3。但 tier3「不引用行號」是純 prompt 約束、**無結構後盾**(prompt 擋不住模型在散文編造行號——§2.1「prompt 管不動 tool 行為」的對稱反面),故只能輔證,不能當硬證。

**可量測的硬訊號(系統已具備):**
- `actions` 陣列裡的 `type` 分佈(edit/execute 只該出現在 Tutor 1;經 §7.3 白名單過濾後 tier3 必為空)。
- `warnings`(如 `reference_loaded`)。
- 回應是否含 `edit_file` patch / R code block。

→ 這張表就是論文裡「不同 TUTOR.md 產生不同對話」的直接證據;其中**主區分訊號**是**結構性、可重現**的,不是語氣巧合,次/prose 訊號則據實標註其依賴(D6)與邊界(soft)。

---

## 九、待定決策(需確認)

| # | 問題 | 暫定 | 備選 |
|---|---|---|---|
| D1 | Tutor 2 是否保留 `load_reference`? | **保留(已定案)**。澄清:`load_reference` 載入的是**參考解答** `solutions/Hw2.Rmd`(答案),**非** assignment;assignment 由 `AssignmentLoader` 永遠注入(mandatory base),任何 tutor 都有,故「理解這門課」已被保證。保留 load_reference 的真正理由是讓 Feynman 探問**對準正確解**(manifest 規定不逐字外洩) | 拿掉 → Tutor 2 只靠學生檔,更純但探問較無依據 |
| D2 | Tutor 3 是否完全不注入 assignment 以外的東西? | **已被 §7.1 定案為不注入**:tier3 `inject_workspace=false`,只給 persona + assignment(+ domain) | ~~也給 workspace_overview 但禁用~~——選此即把 §7.3 漏洞三(history channel 漏檔名)重新打開,且與 §7.1 `inject_workspace=false` 抵觸,故不採 |
| D3 | Tutor 1 主對照組用 `default` 還是 `solver`? | **以 `solver` 為底演進成「更 agentic」(已定案)**:四工具全開 + 自主串 load→edit→execute 的 lazy-load 迴圈 + 主動 `load_reference` 自驗 + 不問確認;**移除過時的 `[THOUGHT]/[ACTION]/[ANSWER]` 文字標記**(與 native tool_use 衝突) | `default`(寫檔前出示 diff 求確認)留作溫和變體 |
| D4 | persona 選擇機制 | **MS3 先用 env var `TUTOR_PERSONA` 當 `persona_key`,由 `TutorPersonaResolver` 解析(§7.1.1);不進 request contract**。**fail-closed**:缺值退 tier3、未知值 raise,絕不退 tier1(§7.1.1 / §7.4)。正式版交課程設定(server 端 project→persona) | — |
| D5 | 是否需要 request 帶 `mode` 供前端顯示(非授權)? | 不急 | 之後做 UI 標示 |
| D6 | Tutor 2 會不會「忘記先 `load_file` 就憑空猜」(§2.1 的 under-calling)? | 沿用現行 intent-based `TOOL_USE_GUIDE` 推 load_file,先量測 | 若量測仍會猜 → 考慮 `tool_choice` 強制,或前端在第一輪預載學生焦點檔 |
| D7 | Tutor 2 純 Feynman 卡住時(學生懂了仍不會寫),是否容許「淡化範例」當釋壓閥? | **不容許**,保持純 Feynman 變數乾淨(§5 已知邊界) | 容許 → 對話更實用但變數混血;或留待使用者測試顯示挫折後再加 |

---

## 十、建議下一步

1. ~~D1/D3/D4 已定案~~(D1 保留 load_reference；D3 以 solver 演進;D4 用 env `TUTOR_PERSONA`)。剩 D2/D5 可隨實作定,D6/D7 待量測。
2. **三份 TUTOR.md 定稿並落到 canonical fixtures** `spec/fixtures/assignments/CSDS-HW2/tutors/<persona>/`(tier1=`tutor-solver`、tier2=`tutor-feynman`、tier3=`tutor-socratic`)——草稿已在 `app/application/prompts/tutors/`,需搬入 fixtures 才會被載入。
3. **實作 `TutorPersonaResolver`(§7.1.1)**:統一 persona/refusal 載入 + `persona_key`→`PersonaProfile`;退役 `tutor_persona_loader` / `refusal_loader`。
4. **TOOL_USE_GUIDE 拆 per-tool 片段(§7.1.2)** + `tutor_system_prompt` / `budget_aware_prompt_assembler` 接 profile(`inject_workspace` / `inject_reference`)。
5. **`run_tutor_chat` 工具閘門**:`tutor_mini_loop` 用 `profile.tools`、ROUND2 動態推導、round-2 以 profile flag 短路(§7.3);刪 `ROUND2_TOOLS` 常數。
6. 寫對照實驗(§八)當 MS3 驗收證據。

---

## 十一、進度追蹤(To-Do)

> 勾選狀態同步至 2026-06-22。`[x]`=已完成、`[~]`=部分/待驗、`[ ]`=未開始。每項標出對應章節與落點檔。

### Phase 0 — 前置(fixtures / 草稿 / 決策)

- [x] 三份 persona 的 TUTOR.md **草稿**(tier1=`tutor-solver`、tier2=`tutor-feynman`、tier3=`tutor-socratic`)— 在 `app/application/prompts/tutors/`(§6)
- [x] 三份落到 **canonical fixtures** `spec/fixtures/assignments/CSDS-HW2/tutors/<persona>/`(§7.1.1、§10.2)— 三目錄已就位(未追蹤,待 `git add`)
- [x] 清掉殘留 `spec/fixtures/tutors/`(舊 default/solver/tutor-guide 副本)(測試 plan §0.1)
- [x] 決策定案 D1(保留 load_reference)/ D3(以 solver 演進)/ D4(env `TUTOR_PERSONA`)(§9)
- [x] 另立 persona 測試計畫([2026-06-22-persona-testing-plan.md](./2026-06-22-persona-testing-plan.md))
- [x] **內容校稿**:三份 fixtures TUTOR.md 的 `Forbidden` / `Pedagogy` / `## Refusal Message` 與 §4–§6 定義逐項對齊(tier2 純 Feynman、tier3 不引用行號)

### Phase 1 — Resolver + 選擇鍵(§7.1.1、§7.4)

- [x] 新增 `tutor_persona_resolver.rb`:`call(persona_key)` **純函式**(key 由參數傳入、不自讀 ENV — 測試 plan §0.2)→ 回 `Resolution(persona_text, refusal, profile)`;**未知 key → `raise KeyError`**(fail-closed,§7.1.1)。工具定義抽到 `Values::TutorTools`(單一來源)、`Values::PersonaProfile`(Data,含 `tool_names`)
- [x] resolver 內寫死兩張對照表:`persona_key → fixtures 目錄`(`FIXTURE_DIRS`)與 `persona_key → PersonaProfile`(`PROFILES`,tier1/2/3)(§7.1);refusal 抽取 regex 容忍 `## Refusal Message[ Example]` 後綴(§6)
- [x] `run_tutor_chat` 加**單一 env seam** `persona_key_for`(`ENV.fetch('TUTOR_PERSONA', 'tier3')` — **缺值 fail-closed 退 tier3,不退 tier1**,§7.1.1)
- [x] `assemble_prompt` 與 `forbidden_outcome` 改用**同一份** resolution(`resolve_persona` 於 `call` 頂端解析一次、向下傳)(消除兩條平行硬路徑)
- [x] `tutor_persona_loader.rb` / `refusal_loader.rb` **退役(刪除)**(§7.2);`tutor_chat_loaders_spec` / `run_tutor_chat_spec` / `spec_helper` 改引 resolver;新增 `tutor_persona_resolver_spec.rb`(未知 key raise + 三層 tools/inject/refusal 同源)

### Phase 2 — Prompt 組裝串入 profile(§7.1.2、§7.2)

- [x] **(本案最大工作量)** `tutor_system_prompt.rb`:TOOL_USE_GUIDE 拆 per-tool 片段(`TOOL_GUIDE_FRAGMENTS` + `TOOL_GUIDE_COMMON`)、依 `profile.tools` 由 `tool_use_guide` 組裝;`tools == []`(tier3)整段不渲染;全工具集輸出與舊 monolith 逐字相同(tier1 不變)
- [x] `tutor_system_prompt.build` 收 `profile`(optional,nil=舊全開行為):`inject_reference=false` 不渲染 manifest/solution、`inject_workspace=false` 不渲染 workspace/行號 guide
- [x] `budget_aware_prompt_assembler.rb`:`call` 收 `profile`;`inject_workspace=false` 跳過 overview / file_context / fixture student file 注入(釋出預算回 history)並把 profile 傳給 builder

### Phase 3 — 工具閘門 + 雙 channel 白名單(§7.3)

- [x] `tutor_mini_loop` 用 `profile.tools`(取代寫死 `TOOLS`);ROUND2 由 `profile.tools - load_reference` **動態推導**,刪全域 `ROUND2_TOOLS`(連同已無引用的 `TOOLS`)常數
- [x] **round-2 以 profile flag 短路**(症狀一):`profile.tool_names.include?('load_reference')` 為 false → `&&` 短路,直接 `finish_loop`,不呼叫 `wants_reference?`(prose channel 永不讀)
- [x] **prose-parsed actions 過白名單**(症狀二):`extract_reply` 收 `profile`,parse 後以 `profile.tool_names` 過濾 actions(tier3→`[]`、tier2 丟 edit/execute);native 分支為 no-op
- [x] **漏洞三**:`build_history` 在 `inject_workspace=false` 時剝掉 `session_turns` 的 `context_headers`(檔名不經 history 漏給 tier3)
- [x] profile **兩次 assemble 都傳**(`assemble_prompt` 一律帶 `profile: persona.profile`,round-1 + round-2 共用)(§7.5)

### Phase 4 — 測試(對應測試計畫)

- [x] **Layer 1** `tutor_persona_resolver_spec.rb`:`call('tier1'/'tier2'/'tier3')` 斷言 tools/inject 旗標/refusal 同源;**未知 key → raise KeyError**(fail-closed)(測試 plan §2.2)— 4 runs 綠
- [x] **Layer 1** 擴充 `run_tutor_chat_spec.rb`:每 persona 斷言 round-1 送出 tools(tier1 四工具/tier2 唯讀/tier3 `[]`)、prose 假 `<actions>` 被白名單清空(tier3 `actions==[]`、tier2 丟 edit/execute)、tier3 prose `load_reference` **不進 round 2**(`calls.size==1`、無 `reference_loaded`)、tier3 system prompt 無 tool guide/manifest/workspace(測試 plan §2.1)— +7 runs,全套 385 綠
- [x] **Layer 2** `scripts/persona_compare.rb`:Option A in-process 迴圈三層(每圈設 `ENV['TUTOR_PERSONA']`,seam 每次 `call` 重讀 → 免重啟)、seed 放行 guard log 繞過 guard LLM、輸出 §八 markdown 對照表 + 落 `tmp/persona_compare-<ts>.json`;`run!` 以 `$PROGRAM_NAME==__FILE__` 守門可被 stub 煙測(已驗 bootstrap + run_tier + 表 + JSON)。**需真 key 收 §八 證據(Phase 5 驗收)**

### Phase 5 — 待量測 / 待決(不阻擋 MS3 主線)

**量測工具就緒(2026-06-22):** `scripts/persona_compare.rb` 已升級為 **N 次重跑聚合**(`PERSONA_COMPARE_RUNS`,預設 1;§六/D6/幻覺都是「頻率」故需多抽樣)。每層抽 N 次,輸出**命中率表**:`edit/execute hits`(主硬,理想 tier1=ok/ok、tier2=tier3=0)、`load_file hits`(D6,tier2 命中率即量測值)、`cites line# hits`(tier3 prose 幻覺頻率,soft)、`statuses`/`warnings`/`action_types` union;全部樣本 prose 落 `tmp/persona_compare-<ts>.json`。已用 stub LLM 煙測 RUNS=3 聚合路徑(無真呼叫)。**下列三項的數值仍需真 key 實跑收集——無法以 stub 代替。**

- [ ] D6:量測 tier2 是否可靠先 `load_file` 才作答(§9 D6、§五 結構脆弱性)— **工具就緒**(讀 `load_file hits` 該欄);跑法:`$env:X_LLM_KEY=…; $env:PERSONA_COMPARE_RUNS='5'; bundle exec ruby scripts/persona_compare.rb`,需真 key
- [ ] D2(tier3 是否注入 disabled overview)/ D5(request 帶 `mode` 供 UI 顯示)— 隨實作或之後定(§9);**屬決策非量測,不在本次真 key 範圍**
- [ ] 量測並記錄 tier3 在 prose 幻覺行號/檔案內容的頻率,當 limitation 誠實揭露(§7.3 漏洞二)— **工具就緒**(讀 tier3 `cites line# hits` 該欄 + JSON dump 人工複核);需真 key 實跑
- [ ] **驗收**:Layer 1 全綠(✓ 385 runs / 0 fail)+ Layer 2 主訊號(edit/execute 只在 tier1)多次重跑穩定重現(測試 plan §六)— **Layer 1 已綠**;Layer 2 待真 key 以 `PERSONA_COMPARE_RUNS≥5` 跑出主訊號穩定率
