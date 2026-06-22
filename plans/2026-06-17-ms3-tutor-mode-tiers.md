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
   *Why:* prompt 的「Forbidden」是軟約束,模型仍可能吐 tool call;工具白名單是硬約束,物理上做不到。**這正是 §2.1 reliability 教訓的必然推論——既然 prompt 管不動 tool-calling,能力差異就只能靠白名單,不能靠 prompt。**
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
| eager 注入 reference solution(round 2) | ✓ | ✓ | ✗ |
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
- **單一變數,實驗乾淨** —— 一台 tutor 一個招牌教學法,觀察到的對話差異可直接歸因於教學法,不被混血稀釋。
- 逆向工程(讀碼回推理解)其實已被 Feynman 的「讀碼 + 講回來」涵蓋,不需另立為獨立支柱。

**已知邊界(睜眼接受):** Feynman 是**診斷型**(找理解缺口),非**前進型**(推進寫碼)。學生「懂了但仍不會寫」時純 Feynman 會卡——這是刻意保留的教學邊界。是否加「淡化範例」當釋壓閥見 §9 D7(暫定不加,以保純度)。

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

每份維持既有 schema:`Role / Allowed / Forbidden / Enforcement / Refusal Message`,Tutor 2 額外加 `Pedagogy` 段描述 Feynman 的「要學生講回來 → 在缺口處探問」迴圈。

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

| Profile | tools | inject_workspace | inject_reference |
|---|---|:---:|:---:|
| tier1 | `[load_file, edit_file, execute_script, load_reference]` | ✓ | ✓ |
| tier2 | `[load_file, load_reference]` | ✓ | ✓ |
| tier3 | `[]` | ✗ | ✗ |

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

**選擇鍵 `persona_key` 從哪來(§7.4 安全前提):** request contract 沒有此欄、loader 忽略 `project_id`。MS3 實驗階段以 **env var(`TUTOR_PERSONA`,預設 tier1)** 當選擇鍵最小可行,**不**開成 request 欄位(學生不可自選)。正式由課程設定(server 端 project→persona 映射)接手。

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
| `run_tutor_chat.rb` | `tutor_mini_loop` 改用 `profile.tools`;ROUND2 由 `profile.tools - load_reference` **動態推導**(刪全域 `ROUND2_TOOLS`);**profile 無 `load_reference` 時整段跳過 round 2**(以 profile flag 短路,不靠 prose 判斷,§7.3);`forbidden_outcome` 與 `assemble_prompt` 共用同一個 PersonaResolution | 小 |
| `tutor_system_prompt.rb` | §7.1.2:TOOL_USE_GUIDE 拆 per-tool 片段、依 `profile.tools` 組裝,`tools == []` 不渲染;`build` 收 profile,`inject_reference=false` 不渲染 manifest、`inject_workspace=false` 不渲染 workspace/行號 guide。**tier2 不再被指示去 edit/execute**(它沒有那些片段) | **中(本案最大工作量)** |
| `budget_aware_prompt_assembler.rb` | `call` 收 profile;`inject_workspace=false`(tier3)時跳過 overview / file_context / fixture student file 注入,並把 profile 一路傳給 `TutorSystemPrompt.build` | 小 |
| 三份 TUTOR.md 定稿內容 | 落到 canonical fixtures `spec/fixtures/assignments/CSDS-HW2/tutors/<persona>/`(tier1=`tutor-solver`、tier2=`tutor-feynman`、tier3=`tutor-socratic`)——目前 fixtures 只有 `tutor-guide`,**三個目錄都要建/補齊** | 小 |
| transport(兩個 client) | **零**(§7.0 已支援空 tools) | — |

### 7.3 與既有 mini-loop 的互動(注意點)

- **Tutor 3 無工具的解答外洩風險(必須以 profile flag 短路)** → tier3 `tools:[]`,模型無法用 native tool_use call `load_reference`。但 `wants_reference?`([run_tutor_chat.rb:280-287](../app/application/services/tutor_chat/run_tutor_chat.rb#L280-L287))在沒有 native tool_calls 時**會 fallback 去解析 prose**(`TutorReplyParser`);只要 tier3 模型在散文裡吐出像 `load_reference` 的字樣,就會觸發 round 2 → [run_tutor_chat.rb:204](../app/application/services/tutor_chat/run_tutor_chat.rb#L204) `include_solution: true`,**把解答注入給看不到檔的 tier3**。
  - **修法:** round-2 的 gate 必須是 `profile.tools.include?('load_reference')` 的**布林短路,放在 `wants_reference?` 之前**;不能只靠 `tools.empty?`,因為 prose parser 照跑。`profile` 不含 `load_reference` → `tutor_mini_loop` 直接 `finish_loop([round1])`,連 `wants_reference?` 都不呼叫。
- **Tutor 2 保留 `load_reference`** → round 2 把解答注入 tutor 自己的 context 強化指引,但 manifest 規定「never shown verbatim」,符合「不逐字外洩」。其 ROUND2 工具 = `profile.tools - load_reference` = `[load_file]`(由 profile 動態推導,**非**全域 `ROUND2_TOOLS` 常數——後者刪除)。
- Tutor 3 若仍渲染 `COURSE_MATERIALS_MANIFEST`(叫它 call load_reference)會變謊言 → 隨 `inject_reference=false` 一起關掉。

### 7.4 persona 選擇權(安全)

persona 由 **server 端 / 課程設定**決定,**不**開成 request 參數讓學生選——否則學生可挑「full agentic」繞過教學設計。MS3 實驗階段以 **env var `TUTOR_PERSONA`(預設 tier1)** 當 `persona_key`(§7.1.1),由 `TutorPersonaResolver` 解析;正式由課程設定的 project→persona 映射接手。選擇鍵**不**進 request contract。

---

## 八、如何展示「slightly different conversations」(實驗設計)

固定一組學生輸入,對三個 persona 重放**完全相同**的 request,收集回應與動作,做對照表。

**範例 prompt:**「我的 `summarize()` 回傳值不對,幫我看一下。」(workspace 已含 `analysis.R`)

| 觀察訊號 | Tutor 1 | Tutor 2 | Tutor 3 |
|---|---|---|---|
| `actions[]` 出現的工具 | `load_file` → `edit_file`(+ 可能 `execute_script`) | 只有 `load_file`(讀),**無 edit/execute** | **無 actions** |
| 內容風格 | 直接給修好的程式碼 | 要學生用自己的話講回自己的碼、在缺口處追問 | 蘇格拉底提問,結尾必有問句 |
| 是否提及具體行號/檔案 | 是 | 是(讀得到,針對其碼提問) | **否**(看不到檔) |
| 解答揭露程度 | 完整(answer-first 錨點) | 不直接給修法(靠探問逼出理解) | 不揭露(fully faded) |

**可量測的硬訊號(系統已具備):**
- `actions` 陣列裡的 `type` 分佈(edit/execute 只該出現在 Tutor 1)。
- `warnings`(如 `reference_loaded`)。
- 回應是否含 `edit_file` patch / R code block。

→ 這張表就是論文裡「不同 TUTOR.md 產生不同對話」的直接證據,且差異是**結構性、可重現**的,不是語氣巧合。

---

## 九、待定決策(需確認)

| # | 問題 | 暫定 | 備選 |
|---|---|---|---|
| D1 | Tutor 2 是否保留 `load_reference`? | **保留(已定案)**。澄清:`load_reference` 載入的是**參考解答** `solutions/Hw2.Rmd`(答案),**非** assignment;assignment 由 `AssignmentLoader` 永遠注入(mandatory base),任何 tutor 都有,故「理解這門課」已被保證。保留 load_reference 的真正理由是讓 Feynman 探問**對準正確解**(manifest 規定不逐字外洩) | 拿掉 → Tutor 2 只靠學生檔,更純但探問較無依據 |
| D2 | Tutor 3 是否完全不注入 assignment 以外的東西? | 只給 persona + assignment(+ domain) | 也給 workspace_overview 但禁用 |
| D3 | Tutor 1 主對照組用 `default` 還是 `solver`? | **以 `solver` 為底演進成「更 agentic」(已定案)**:四工具全開 + 自主串 load→edit→execute 的 lazy-load 迴圈 + 主動 `load_reference` 自驗 + 不問確認;**移除過時的 `[THOUGHT]/[ACTION]/[ANSWER]` 文字標記**(與 native tool_use 衝突) | `default`(寫檔前出示 diff 求確認)留作溫和變體 |
| D4 | persona 選擇機制 | **MS3 先用 env var `TUTOR_PERSONA`(預設 tier1)當 `persona_key`,由 `TutorPersonaResolver` 解析(§7.1.1);不進 request contract**。正式版交課程設定(server 端 project→persona) | — |
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
