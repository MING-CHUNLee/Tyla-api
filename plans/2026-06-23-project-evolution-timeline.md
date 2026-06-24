# Tyla 專案演變時間軸與關鍵決策 / Project Evolution Timeline & Key Decisions

**Date:** 2026-06-23
**Author view:** Research-through-Design (RtD) + Senior Engineering
**Scope:** `Tyla-api` 後端的演變脈絡 —— 從「單一 guard 記錄端點」演進為「具人格分層、agentic 動作、安全閘門、預算感知的 AI 家教後端」。
**用途:** 給論文敘事與工程回顧用。每個決策都標註**類型**、**理由**、**留下的取捨**。
**資料來源:** `plans/` 33 份設計記錄 + git 提交歷史(2026-05-20 → 2026-06-23)。

> **RtD 視角的一句話 / One-line RtD framing:**
> 這個專案的核心不是「寫一個 LLM 包裝層」,而是一連串**「prompt 軟約束失敗 → 改用結構性硬保證」**的設計迭代。每一次重大決策幾乎都源於一個觀測到的失敗(action 不發、迴圈爆掉、解答外洩、429 被誤報),而解法的共同哲學是:**把可靠性從「勸模型」搬到「API 層 / 程式結構」。**
> The project's spine is a repeated design move: *observe a failure of prompt-level soft constraints → replace it with a structural guarantee.* Reliability migrates from "persuading the model" to "the transport layer / code structure."

---

## 一、專案是什麼 / What the System Is

Tyla 是一個給「CS 資料科學作業(CSDS-HW2)」用的 AI 家教後端 API。核心流程:

```
學生 prompt + workspace 檔案 + 對話歷史
   │
   ▼
[Guard 安全閘門]  LLM-as-judge 評 attack_probability ≥ 0.7 → 擋下(不呼叫 tutor)
   │
   ▼
[Tutor 編排]  載入 persona(TUTOR.md) + 作業 + 參考解答 + workspace,組 prompt(預算感知)
   │
   ▼
[LLM 呼叫]  native tool_use → 回 content(散文) + actions[](edit_file / execute_script / load_file / load_reference)
   │
   ▼
[結構性 gates]  過濾幻影/冗餘/越界動作 → 回標準化 response(status / usage / warnings)
```

**技術骨架 / Tech spine:** Ruby、Roda(route)、dry-monads(ROP)、dry-validation(contract)、Roar(representer)、Sequel(ORM)、Minitest。DDD 分層(domain / application / infrastructure / presentation)。雙 LLM provider(OpenAI-相容含 GitHub Models、Anthropic)。

---

## 二、時間軸總覽 / Timeline at a Glance

| 階段 Phase | 期間 Dates | 主題 Theme(中) | Theme (EN) | 代表里程碑 |
|---|---|---|---|---|
| **P1** | 05-20 → 05-22 | 後端化 + DDD 分層 | Server-side migration + DDD layering | guard/tutor 移到後端;`/tutor_chats` 誕生 |
| **P2** | 05-27 → 05-29 | 合約標準化 + Token 預算 | Response standardization + token budget | `status` enum;`BudgetAwarePromptAssembler`;guard token 加總 |
| **P3** | 06-03 → 06-08 | Agentic 動作 + 可靠性 | Agentic actions + reliability | native tool_use;`actions[]`;action reliability 報告;B3 規劃 |
| **P4** | 06-11 → 06-15 | 結構性閘門 + Lazy context | Structural gates + lazy loading | line-number 契約;`load_reference`;三道 gate;Option C history 壓縮 |
| **P5** | 06-16 → 06-18 | 用量/限流訊號 | Usage & rate-limit signals | `session_limit_reached`;429 透傳;`provider_rate_limited` |
| **P6** | 06-17 → 06-23 | Persona 能力分層(MS3) | Per-persona capability tiers | `PersonaProfile` + resolver;雙 channel 工具白名單;Feynman 改名 |

---

## 三、決策類型分類圖例 / Decision Type Legend

| 圖示 | 類型(中) | Type (EN) | 判準 |
|---|---|---|---|
| 🏛️ | 架構 | Architecture | 分層、職責邊界、狀態歸屬、機制選型 |
| 🛡️ | 安全 | Safety / Security | guard、洩題、key 處理、權限、fail-closed |
| 🎓 | 教學設計 | Pedagogical | persona、教學法、能力階梯、faded worked solution |
| 📜 | API 合約 | API contract | request/response schema、status 碼、向後相容 |
| 💰 | 成本/效能 | Cost / Performance | token 預算、壓縮、lazy loading、快取 |
| 🔧 | 可靠性 | Reliability | action 觸發、結構性 gate、迴圈終止 |
| 🔬 | 研究方法 | Research method | 量測先行、對照實驗、誠實揭露 limitation |

---

## 四、逐階段演變與關鍵決策 / Phase-by-Phase Evolution

### P1 — 後端化與 DDD 分層 (2026-05-20 → 05-22)

**情境 / Context:** 原本只有 `POST /api/v1/prompt_logs`(CLI 記錄 guard 決策),guard 與 tutor policy 都在前端。決定**把守門與編排全部搬到後端,後端成為唯一的 gate**。

| # | 🏷️ | 決策 Decision | 理由 Why | 取捨 Trade-off |
|---|---|---|---|---|
| 1.1 | 🏛️🛡️ | 前端 Guard 移除,後端為唯一守門 / Remove frontend guard; backend is sole gate | 守門邏輯不能放在學生可改的 client | 每回合多一次 LLM judge 呼叫 |
| 1.2 | 🛡️ | LLM key 走 header `X-LLM-Provider`/`X-LLM-Key`,永不寫 DB / Key pass-through via headers, never persisted | key 是學生自帶(GitHub Student Pack),不該存 | 需 `KeyScrubber` middleware 防洩漏到 log/error |
| 1.3 | 🛡️ | Guard 門檻 domain 定義 `AttackPolicy::THRESHOLD = 0.7`,單一來源 / Threshold centralized in domain | 政策常數不可在各層重複 | — |
| 1.4 | 🛡️ | Guard 失敗 **fail-open**(judge 不可用 → 仍呼叫 tutor,記 warning) / Fail-open on judge unavailability | V1 可用性優先;攻擊被偵測時仍硬擋 | 留 `STRICT_MODE` fail-closed 為後續 |
| 1.5 | 🏛️ | 拒絕訊息**模板化**,不做第二次 LLM 呼叫 / Templated refusal, no 2nd LLM call | 省成本;且讓模型生成拒絕有被 jailbreak 風險 | 拒絕語較固定 |
| 1.6 | 🏛️ | 全 DDD 分層 + dry-monads ROP;prompt 留在 MD 檔,Ruby 只當薄 loader / Full DDD + prompts as MD files | 可維護、可測、prompt 與程式分離 | 樣板較多 |
| 1.7 | 🏛️ | PromptLog 重構為 Entity/Repository/Request/Representer,並寫成 inline `SKILL.md` 活範例 / Refactor to DDD with inline SKILL.md examples | 讓架構規範就近可讀(給人與 AI) | — |

> **RtD note:** P1 確立了整個專案的「**結構先於 prompt**」價值觀 —— guard 門檻是 domain 常數、拒絕是模板、loader 是薄包裝。後面所有可靠性決策都是這個價值觀的延伸。

---

### P2 — 合約標準化與 Token 預算 (2026-05-27 → 05-29)

**情境 / Context:** 教授會議拍板三個 issue。核心張力:**HTTP 傳輸層**與**應用層語意**該不該耦合。

| # | 🏷️ | 決策 Decision | 理由 Why | 取捨 Trade-off |
|---|---|---|---|---|
| 2.1 | 📜 | 用 `status` 字串 enum(`done`/`forbidden`/`unavailable`/`error`)取代 `allowed: bool` / Unified status enum replaces boolean | 要分類學生 prompt 走哪條分支,布林不夠 | 前後端要同步改 |
| 2.2 | 📜🛡️ | **雙層解耦**:HTTP 碼(傳輸)與 body `status`(應用語意)獨立;`forbidden` 仍回 **HTTP 200** / Decouple HTTP code from body status | client 從 HTTP 碼看不出異常(收集學生 prompt 用) | `forbidden` + 200 的反直覺需 doc 說明 |
| 2.3 | 📜 | 缺 `X-LLM-Key` 從 401 改 **403** / 401 → 403 for missing key | 非 session 認證,是權限失敗;401 會誤導 client 重認證 | — |
| 2.4 | 💰 | 前端**不做** token 計算/裁切,全部後端負責 / Backend owns all token trimming | 單一真相源;client 不該管 context window | 前端送完整 history,後端靜默裁 |
| 2.5 | 💰🏛️ | 用 `BudgetAwarePromptAssembler` 取代固定 `MAX_HISTORY_TURNS=10` 裁切 / Budget-aware assembler replaces fixed cutoff | 固定回合數無視實際 token 大小 | 計畫的 `HistoryTrimmer` 拆分最後沒做(合併進 assembler) |
| 2.6 | 💰 | Context 組裝**嚴格優先序**:persona > 作業 > 解答 > 學生檔 > history(history 最後填、newest-first) / Strict priority assembly order | 預算不足時丟低優先 | 學生檔可能被丟 |
| 2.7 | 📜💰 | guard + tutor token **加總成單一 `usage`**;`forbidden` 改回報 guard token(不再 null) / Sum guard+tutor into one usage | 學生看一次互動總花費;DB 不存 token | `forbidden` 合約再變一次 |
| 2.8 | 🔬 | quota 剩餘**不追蹤不顯示**;只報 per-request usage / Don't track remaining quota | 學生同把 key 會在系統外用,無法得知真實剩餘 | StatusBar 只顯示當回合 |

> **設計教訓 / Lesson:** 「兩個都叫 status」的命名衝突(HTTP 403 vs body `forbidden`)被**刻意保留**(教授要求),靠「讀哪一層」區分。這是 RtD 裡「術語承載設計意圖」的例子。

---

### P3 — Agentic 動作與可靠性 (2026-06-03 → 06-08)

**情境 / Context:** tutor 從「純對話」變「agentic」—— 能回 `actions[]`(改檔/跑碼/讀檔)。這引爆了整個專案**最關鍵的可靠性危機**。

#### P3-a 動作可靠性危機(`actions` 幾乎永遠是 `[]`)

| # | 🏷️ | 決策 Decision | 理由 Why | 取捨 Trade-off |
|---|---|---|---|---|
| 3.1 | 🔧 | **放棄** prompt 要求模型自行序列化 `<actions>` XML / Abandon prose-appended XML actions | RLHF 模型在自然結尾就停手,從不 append 結構塊;**prompt 加壓無效** | — |
| 3.2 | 🔧🏛️ | 改用 **API-native function calling(tool_use)**,單一 shared schema 雙 provider 適配 / Migrate to native tool_use, one shared schema | 序列化從「模型的記性」搬到「傳輸層」,stop-generation 問題根除 | 保留 XML parser 當 fallback |
| 3.3 | 🔧 | 工具觸發條件改寫成**學生意圖**(非模型自評)+ 禁止「要不要我幫你…?」確認反射 / Triggers keyed to student intent, ban confirmation reflex | 「學生是否要求」是 transcript 客觀事實;「我在做什麼」模型可自我說服 | — |
| 3.4 | 🛡️🔧 | Guard 加「Legitimate Requests (≤0.10)」白名單,把「對自己檔案的合法動作」與「萃取攻擊」分開 / Teach guard to distinguish sanctioned actions | 鼓勵 tutor 行動會讓 guard 過度封鎖正常請求 | 需重新校準 guard 分數 |

> **本階段最大 RtD 洞見 / The pivotal insight:**
> **「不要叫模型在散文後自我序列化結構輸出」**,以及其對稱推論 ——
> 既然 prompt 管不動 tool-calling,那麼(a)要可靠**觸發**動作得靠 native channel,(b)要可靠**禁止**動作只能靠 API 層 `tools: []`(不能靠 prompt 寫「禁止」)。
> 這條教訓在 P6 的 persona 工具閘門被**反向**重用 —— 見決策 6.x。
> **可靠性與安全是同一條 pipeline 的兩端**:鼓勵 tutor 行動 ⇄ 必須教 guard 認得這些行動為合法,單調一邊就會悄悄抵銷另一邊。

#### P3-b 合約對齊與架構決策

| # | 🏷️ | 決策 Decision | 理由 Why |
|---|---|---|---|
| 3.5 | 📜🛡️ | 要求 `guard_log_id`,後端對 DB 驗證(取代 guard re-run) / Require guard_log_id, verify against DB | 不重跑 guard,信任已記錄的決策 |
| 3.6 | 🏛️ | `file_context` workspace slot + `actions[]` 解析進 contract / Add file_context slot + actions parsing | 把學生 workspace 結構化進 prompt |
| 3.7 | 🏛️ | tutor_chat service 抽成 monadic steps,退役 client 端 `CreatePromptLog` / Extract monadic steps | ROP railway 可讀、可測 |

#### P3-c B3 規劃:agentic loop 的歸屬(2026-06-07/08)

| # | 🏷️ | 決策 Decision | 理由 Why | 取捨 Trade-off |
|---|---|---|---|---|
| 3.8 | 🏛️ | agentic loop 選 **B3(前端驅動續傳)**,淘汰 B2(雙向 callback 破壞 stateless)、B1(後端 mini-agent)留作 Phase 2 研究變體 / Choose frontend-driven continuation | 後端近零改動、維持 stateless;迴圈住前端 driver | 每圈繞回後端(換取 guard 注入 + 驗證) |
| 3.9 | 🛡️ | B3 安全採 **workspace boundary**(realpath 收斂),保護的是**學生自己的機器**(.env/.ssh)非課程機密 / Workspace boundary via realpath | 課程解答在 server,`load_file` 物理上洩不出去 | 需修 symlink/Windows 絕對路徑/per-file cap |
| 3.10 | 🔧 | `MAX_CONTINUATIONS`(2~3)是迴圈**硬終止不變式**,成本由去重+cap 負責(兩者職責不混) / Hard iteration cap as loop invariant | 終止與成本是兩件事 | — |

---

### P4 — 結構性閘門與 Lazy Context (2026-06-11 → 06-15)

**情境 / Context:** agentic 能力上線後,真實 log 暴露一連串新失敗:模型對已載入檔重複 `load_file`(無窮迴圈)、edit patch 對不上、解答每回合都白塞進 prompt。解法清一色是**結構性 gate**。

| # | 🏷️ | 決策 Decision | 解決什麼 Problem solved | 取捨 / 已知邊界 |
|---|---|---|---|---|
| 4.1 | 📜🔧 | live workspace 加 **line-number 契約**(`N\| ` 前綴),`edit_file` 用 `start_line` 錨定 / Line-number contract + start_line anchoring | patch 模糊匹配不可靠 | 模型可能幻覺行號 → 需 gate |
| 4.2 | 🔧 | `EditPatchNormalizer` + `EditPatchContentGate`:patch 內容對不上 live → 改寫成 `load_file` 自癒 / Content-mismatch self-heal | 模型用 stale snapshot 改檔 | content gate 自己會產生 reload(潛在迴圈) |
| 4.3 | 🔧 | `RedundantLoadGate`:對已在 `file_context` 的 path 的 `load_file` → 丟棄(結構性終止) / Structurally break load_file loop | 模型重複請求已載入檔 → 前後端無終止點 | budget 截斷致 `### header` 消失時失效 → 退守前端 round cap |
| 4.4 | 🔧 | gate 排序:`RedundantLoadGate` 必須排在 `EditPatchContentGate` **之前**(否則殺掉 content gate 的合法 reload) / Strict gate ordering | 跨 gate 互動 | 需回歸測試鎖住 |
| 4.5 | 🔧 | 「actions 被清空且 prose 空」→ 注入 fallback prose,**永不回空回合** / Never return empty content+actions | 修迴圈的副作用正好是空回合 | — |
| 4.6 | 💰🛡️ | **Hybrid lazy 解答**:解答平常不載入,模型 call `load_reference` 才透過 **re-assemble round 2** 注入(不走 tool_result,避免重寫兩個 client) / Lazy reference via re-assemble | 解答約 2.3K token,多數回合用不到 | **未定案,待量測**(調閱率 >50% 反而更貴) |
| 4.7 | 🛡️ | round 2 把 `load_reference` 從工具拿掉 → 終止是**結構性保證**(物理上不能再要);解答內容**永不回傳 client**(只多 `warnings: reference_loaded`) / Structural termination + no leak | 不靠 prompt 勸模型停 | round 1 prose 被丟棄(已知代價) |
| 4.8 | 💰🏛️ | **History 壓縮改後端(Option C)**:前端送富結構 `session_turns`,後端 `HistoryTurnSerializer` deterministic 壓縮(保留意圖/看過哪些檔,**省略檔案內容**) / Backend-owned compression | 壓縮是 prompt-engineering,本就該與 budget/gate/summary 同住後端;放前端會橫跨兩 repo | wire payload 略大;需維持舊 `history` 路徑 |
| 4.9 | 🏛️ | 後端「做壓縮」**不等於**「變有狀態」:每回合用前端送的 `session_turns` 即時重算,無 DB/schema / Stateless recompute, not stateful | 延續 stateless 決策 | 重複摘要舊內容(換零 schema) |
| 4.10 | 🏛️ | 兩段壓縮合流同一 assembler:Stage 1 deterministic 省略 → Stage 2 LLM rolling summary 摘要溢出尾段 / Two-stage compression funnel | harness 決定何時壓(deterministic)、model 只負責怎麼摘要 | rolling summary 尚未實作 |

> **量測背書 / Measurement (Phase 0, 06-15):** 壓縮後單一 turn 由 naive 3053 tok 降到 **291 tok(小 90%)**;8K 通道下 history 容量由 **0 → 9 turn**。caps 維持 600/400/200/200。
> **RtD note:** P4 把專案的「結構性哲學」推到極致 —— 連「迴圈會不會停」「解答會不會洩」都不靠 prompt,而是讓壞情況在**程式結構上不可能發生**。`workspace_edit_gate.rb` 檔頭那句「gpt-4o demonstrably ignores soft constraints」成了反覆引用的設計信條。

---

### P5 — 用量與限流訊號 (2026-06-16 → 06-18)

**情境 / Context:** 教授要「MAX_USAGE」提示。團隊把它拆成三軸,並**有意識地砍掉一軸**。

| # | 🏷️ | 決策 Decision | 理由 Why | 取捨 / 邊界 |
|---|---|---|---|---|
| 5.1 | 📜 | **(A)** `session_limit_reached`:input 逼近通道視窗 → 提示「開新對話」(主要訊號) / Per-request context signal | 不改合約/DB,用真實 `input_tokens` 比視窗 | 已上線、保留 |
| 5.2 | 🛡️📜 | **(C1)** 把 429 從 `LlmError::Upstream` 拆出 → 回正確 **HTTP 429 + Retry-After** / Distinguish 429 from generic 502 | 429 被誤報成 502,前端可能盲目重打、更快撞限流 | 獨立正確性修復,先做 |
| 5.3 | 🏛️🛡️ | **(C2)** 通用透傳所有 `*ratelimit*` header(**不寫死任一家 schema**)→ 逼近門檻發 `provider_rate_limited` 軟警告 / Schema-agnostic rate-limit passthrough | OpenAI/Anthropic/GitHub 欄位命名全不同 | 門檻待 C3 實測校準 |
| 5.4 | 🔬 | **(C3)** debug log 記 header,先量 GitHub Models 真實欄位再定門檻 / Measure before guessing | 與其猜不如量一次 | 實測:`renewalperiod=60` → per_minute |
| 5.5 | 🎯📜 | **(B) 對話累計額度:有意識地不做** / Deliberately NOT building conversation-level quota | GitHub 免費層**無**「每段對話累計 token」這種限制;(B)要付 migration+session_id 代價卻只為合成配額 | 產品端若要求計費再做 |
| 5.6 | 🛡️ | (A) 與 (C) 使用者動作**相反**,前端必須分流:(A)→開新對話、(C)→等待退避 / A and C imply opposite actions | 混成一句會給 (C) 錯誤建議(開新對話對 rate 窗口無效) | 文案/handler 出口都要分開 |
| 5.7 | 🔬 | (C) 量的是**帳號 rate 窗口**(週期重置),**永不**標成 conversation-level / Never mislabel C as conversation scope | scope taxonomy 誠實:per_request / provider_account / conversation(永不發) | — |

> **部署事實 / Deployment fact:** 每位學生各自一把 key → (C) 訊號乾淨、可直接對該生提示「你的金鑰快用完了」,不必 hedge。

---

### P6 — Persona 能力分層 / MS3 (2026-06-17 → 06-23)

**情境 / Context:** MS3 要證明「不同 `TUTOR.md` 產生**可觀察、可量測**的不同對話」。盤點發現:現有 4 份 TUTOR.md **只換皮沒換骨** —— `TOOLS` 寫死無條件傳給所有 persona,socratic 模式仍握著 `edit_file`。

| # | 🏷️ | 決策 Decision | 理由 Why | 取捨 / 邊界 |
|---|---|---|---|---|
| 6.1 | 🎓🔧 | **兩個槓桿**:工具閘門(結構性硬約束)+ TUTOR.md(prompt 軟約束),缺一只能換皮 / Two levers: tool gate + prompt | 光靠 prompt = 換皮;閘門 + prompt = 換骨 | — |
| 6.2 | 🛡️🔧 | 三層**單調遞減**能力階梯:Tutor1(四工具全開)⊃ Tutor2(只 load)⊃ Tutor3(`tools: []`) / Monotone capability ladder | 對照組乾淨、論文敘事清楚 | — |
| 6.3 | 🛡️🔧 | **P3 教訓的反向應用**:既然 prompt 管不動 tool-calling,要保證 Tutor3 絕不 edit 唯一可靠法是 API 層 `tools: []`(不能在 prompt 寫「禁止」) / Inverse of the 3.x lesson | prompt 寫「Forbidden」會重蹈 06-04 覆轍 | 必須保留 native tool_use + 無條件傳「該 persona 的」工具 |
| 6.4 | 🛡️🔧 | 工具白名單必須**同時治理兩條 channel**:native tool_use **與** prose-parsed `<actions>` fallback / Whitelist governs BOTH channels | 否則 prose 會把被閘掉的工具重新放回 `actions[]` | tier3 native 永遠空 → 每次走 prose 分支,必須過濾 |
| 6.5 | 🏛️ | `PersonaProfile`(最小形狀:`tools[]` + `inject_workspace` + `inject_reference`)+ `TutorPersonaResolver` 統一 persona/refusal 載入 / Minimal profile + unified resolver | 原本 persona/refusal 兩個各自寫死同路徑的 loader;persona 可切換後 refusal 必須同源 | — |
| 6.6 | 🛡️ | persona 選擇權在 **server/課程設定**,不開成 request 欄位;MS3 階段用 env `TUTOR_PERSONA` / Server-side persona selection | 學生若可自選會挑 full agentic 繞過教學設計 | env 是 process-global → 切 persona 要重啟 |
| 6.7 | 🛡️ | 未知 key → `raise`(部署 bug 大聲炸);缺值 → **fail-closed 退最受限 tier3**,**絕不** fail-open 到 tier1 / Fail-closed to tier3, never to tier1 | 一個 typo 不該把四工具權限發給學生 | — |
| 6.8 | 🎓🔬 | 整條階梯 = **Fading Worked Solution 梯度**(meta-框架,不塞進單一 tutor);Tutor2 採**純 Feynman**(讀碼+要學生講回來) / Whole ladder as faded-worked-solution gradient | read/no-read 由教學法本身決定(Feynman 需讀碼、Socratic 不需) | 跨層差異須歸因於**整個 mode bundle**,非教學法單獨 |
| 6.9 | 🔧 | TOOL_USE_GUIDE 從 monolith 拆成 **per-tool 片段**,依 `profile.tools` 組裝(本案最大工作量) / Split tool guide into per-tool fragments | tier2 收到全 monolith 會被叫去 call 它沒有的工具 | — |
| 6.10 | 🔬 | tier3「看不到檔」是**動作層結構性、認知層 soft**:`tools:[]` 硬保證不出動作,但擋不住散文編造行號 → 當 limitation 誠實揭露 + 量測幻覺頻率 / Action-layer hard, cognition-layer soft | 對稱於 P3「prompt 管不動模型行為」 | prose 軸訊號只能當輔證 |
| 6.11 | 🔬 | 對照實驗:固定學生輸入對三 persona 重放,焦點檔**只放 overview 不預載 file_context**(讓 `load_file` 成為 tier2/tier3 的結構性區分訊號) / Controlled replay experiment | 預載則 tier2/tier3 在 actions 軸都退化成「無 actions」,區分線垮 | 把 tier2 押在 D6(可靠呼叫 `load_file`)上 |

> **訊號分三級(避免過度宣稱)/ Three-tier evidence grading:**
> - **主硬訊號:** `edit/execute` 只可能出現在 Tutor1(工具閘門保證,不依賴任何模型行為)。
> - **次訊號(依賴 D6):** `load_file` 出不出現(tier2 應叫、tier3 不能)—— 若 tier2 漏叫,那是一個 finding(脆弱性),不是實驗失敗。
> - **prose 軸(soft):** 是否引用行號 —— 純 prompt 約束、無結構後盾,只能輔證。
>
> **進度(至 06-23):** Layer 1 全綠(385 tests);per-persona tool tiers 已 commit(`2072181`);Layer 2 對照實驗待真 key 跑出主訊號穩定率。

---

## 五、橫貫主題:反覆出現的設計模式 / Cross-Cutting Patterns

| 模式 Pattern | 體現 Decisions | 一句話 |
|---|---|---|
| **結構 > prompt 勸說** Structure over persuasion | 1.1, 3.2, 4.3, 4.7, 6.3, 6.4 | 失敗的軟約束一律升級成結構性硬保證 |
| **stateless 不可破** Statelessness preserved | 3.8, 4.9, 5.5 | 寧可每回合重算,不引入 DB 對話狀態 |
| **可靠性 ⇄ 安全 耦合** Reliability-safety coupling | 3.3↔3.4, 4.7, 6.4 | 調一端必須同時調另一端 |
| **量測先行** Measure before deciding | 2.8, 4.6, 5.4, 6.10, 6.11 | 不確定的數值(調閱率/門檻/幻覺率)先量再定 |
| **fail-closed 安全預設** Fail-closed defaults | 1.4(例外 fail-open), 6.7 | 缺值退最受限,絕不發更多權限 |
| **向後相容並存** Backward-compatible coexistence | 2.1, 4.8, 5.3 | 新欄位 optional、舊路徑保留到前端切換完成 |
| **單一真相源** Single source of truth | 1.3, 2.4, 6.4, 6.5 | 政策常數/裁切/白名單/loader 都收斂成一處 |

---

## 六、給論文的敘事建議 / Narrative Suggestions for the Paper

1. **主線故事 / Spine:** 用「軟約束失敗 → 結構性硬保證」串起整篇 —— 這是一個 RtD 專案最乾淨的 through-line,每個失敗都有真實 log 背書(action `[]`、load_file ∞ 迴圈、429 誤報)。
2. **對稱性 / Symmetry:** P3 的教訓(prompt 管不動 tool-calling → under-calling)在 P6 被**反向重用**(→ 要禁用工具只能靠 `tools:[]`)。這個「同一條教訓、兩個方向」是很強的論證結構。
3. **誠實揭露 / Honest limitations:** tier3 的「動作層硬、認知層 soft」、hybrid lazy 的品質靜默劣化賭注、tier2 的 D6 脆弱性 —— 這些**主動標註的邊界**正是 RtD 嚴謹度的體現,不要藏。
4. **能力階梯即教學梯度 / Ladder as pedagogy:** Tutor1→2→3 = fully worked → partial → fully faded,若課程讓學生依序使用,就字面上成為一條 faded-worked-solution 學習軌跡 —— 把工程分層直接接到教學理論。
5. **取捨的可追溯性 / Traceability:** 每個決策的 `plans/` 文件都記了「待定 → 定案」的過程(D1~D8 等),適合當論文附錄的 decision log。

---

## 附錄:設計記錄索引 / Appendix: Design Record Index

| 階段 | 文件 |
|---|---|
| P1 | `2026-05-20-promptlog-ddd-refactor.md`、`2026-05-20-tutor-orchestration-backend.md`、`2026-05-21-tutor-chat-api.md`、`2026-05-22-loader-infrastructure-refactor.md` |
| P2 | `2026-05-27-meeting-decisions.md`、`2026-05-27-issue-1-api-response-standardization.md`、`2026-05-28-token-budget-algorithm.md`、`2026-05-28-issue-3-guard-token-aggregation.md` |
| P3 | `2026-06-03-agentic-tutor-backend.md`、`2026-06-03-guard-checks-contract-alignment.md`、`2026-06-04-tutor-chats-contract-alignment.md`、`2026-06-04-action-reliability-issue.md`、`2026-06-04-response-design-challenges-report.md`、`2026-06-06-prompt-compression-mechanism.md`、`2026-06-07-backend-agentic-loop-evaluation.md`、`2026-06-07-b3-frontend-continuation-driver.md`、`2026-06-07-b3-implementation-steps.md`、`2026-06-08-plan-decisions-summary.md` |
| P4 | `2026-06-11-lazy-context-loading-evaluation.md`、`2026-06-11-hybrid-lazy-solution-implementation.md`、`2026-06-12-hybrid-lazy-solution-tldr.md`、`2026-06-13-edit-file-line-anchor.md`、`2026-06-13-load-file-loop.md`、`2026-06-14-history-file-omission-compression.md`、`2026-06-14-live-section-heading-shadow.md`、`2026-06-15-shared-header-constant-and-format-tests.md`、`2026-06-15-option-c-backend-owned-history-compression.md` |
| P5 | `2026-06-16-session-token-limit-signal.md`、`2026-06-16-max-usage-end-conversation.md`、`2026-06-18-provider-rate-limit-passthrough.md` |
| P6 | `2026-06-17-ms3-tutor-mode-tiers.md`、`2026-06-17-tutor-feynman-rename-todo.md`、`2026-06-22-persona-testing-plan.md`、`2026-06-23-manual-persona-testing-checklist.md`、`2026-06-23-edit-patch-content-gate-loop-breaker.md` |
