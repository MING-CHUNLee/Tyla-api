# Persona 測試計畫 — 如何測不同 `TUTOR_PERSONA`(三層 tutor)

**Date:** 2026-06-22
**狀態:** 草案(可執行,待第 0 節前提先補)
**相關:**
- [2026-06-17-ms3-tutor-mode-tiers.md](./2026-06-17-ms3-tutor-mode-tiers.md)(三層設計、工具閘門、§八 對照訊號表——本計畫的「要觀察什麼」直接引用該節)

---

## 〇、先修正:兩個阻斷點(沒處理前測不了)

### 0.1 fixtures 放錯層(或:要先決定 persona 佈局)

> **已定案(2026-06-22):選 (A) 每作業佈局,且已完成。** `tutor-solver` / `tutor-feynman` / `tutor-socratic` 三份已就位於 `spec/fixtures/assignments/CSDS-HW2/tutors/`(各含 `TUTOR.md`、frontmatter `name:` 正確、各一段 `## Refusal Message`),與既有 `tutor-guide` 並列。**殘留待清:** `spec/fixtures/tutors/` 還留有 `default` / `solver` / `tutor-guide`(舊變體與重複檔)——非 MS3 三層所需,確認後可整個刪除。

- **現況(歷史記錄):** 新 persona 原被放到 `spec/fixtures/tutors/<persona>/`(git `?? spec/fixtures/tutors/`,未追蹤)。
- **程式實際讀 / MS3 canonical:** `spec/fixtures/assignments/CSDS-HW2/tutors/<persona>/TUTOR.md`([tutor_persona_loader.rb:7-10](../app/infrastructure/filesystem/tutor_chat/tutor_persona_loader.rb#L7-L10)),目前只有 `tutor-guide`。
- **兩條路(擇一,先定):**
  - **(A) 維持每作業佈局**(現行 canonical 不變):把三份移到 `spec/fixtures/assignments/CSDS-HW2/tutors/`。
    ```sh
    # tier1=tutor-solver / tier2=tutor-feynman / tier3=tutor-socratic
    git mv spec/fixtures/tutors/tutor-solver   spec/fixtures/assignments/CSDS-HW2/tutors/tutor-solver
    git mv spec/fixtures/tutors/tutor-feynman  spec/fixtures/assignments/CSDS-HW2/tutors/tutor-feynman
    git mv spec/fixtures/tutors/tutor-socratic spec/fixtures/assignments/CSDS-HW2/tutors/tutor-socratic
    ```
  - **(B) 改成全域佈局**(教學法與作業無關——前瞻 refactor):canonical 改指 `spec/fixtures/tutors/<persona>/`,`assignment` / `solution` / `student-file` 仍按 `project_id` 走 `.../CSDS-HW2/`。需同步改 resolver 的路徑常數與 MS3 plan §7.1.1 的「canonical 來源」。
- **判準:** MS3 只需要能切換,(A) 改動最小、與現有 loader 一致,**建議先 (A) 跑完 MS3**;(B) 留待正式版(避免一個作業複製三份 TUTOR.md)再做。

> 不論 (A)(B),`tutor-guide` 維持原處不刪——它是 refusal/loader spec 的既有依賴,改名/退役按 MS3 plan §6.1 另行處理。

### 0.2 選擇機制尚未實作(env 目前無作用)

`TUTOR_PERSONA` / `TutorPersonaResolver` 還不存在;loader 寫死 `tutor-guide`、忽略 key。**本計畫的 Layer 1/2 都以 MS3 plan §7.1.1(resolver)、§7.2(profile 串入)、§7.3(prose 白名單過濾)已落地為前提。** 在那之前,只能測到「永遠 tutor-guide」。

**對測試友善的一個實作要求(寫進 resolver 時請遵守):**
`TutorPersonaResolver.call(persona_key)` 設計成**純函式**——key 由參數傳入,resolver 不自己讀 ENV。讀 `ENV['TUTOR_PERSONA']` 的動作集中在 `run_tutor_chat` 的**單一 seam**(`persona_key_for(params) = ENV.fetch('TUTOR_PERSONA', 'tier3')` — **缺值 fail-closed 退 tier3,不退 tier1**;未知值由 resolver `raise`,見 MS3 §7.1.1)。好處:
- spec 可直接 `resolver.call('tier3')` 斷言,不必碰 ENV;
- 實驗腳本可**直接傳 key 迴圈三層**,不必重啟 server(見 §三 Option A)。

---

## 一、測試分兩層(各自證明不同的事)

| 層 | 跑法 | 證明什麼 | 需要真 LLM? |
|---|---|---|---|
| **Layer 1 — 自動化 spec** | `rake spec`(minitest,stub LLM) | **結構保證**:每個 persona 送出的 tools、注入旗標、refusal 同源、prose 動作被白名單清空——確定性、可進 CI | ✗(stub) |
| **Layer 2 — 實機對照實驗** | 腳本 / HTTP,真 key | **對話差異本身**(MS3 §八 對照表):三層產生可觀察的不同對話與動作 | ✓ |

Layer 1 對應 MS3 賣點裡的「**結構性**」;Layer 2 對應「不同對話」的**展示證據**。兩者都要。

---

## 二、Layer 1:自動化 spec(結構保證,無 LLM)

沿用 [run_tutor_chat_spec.rb](../spec/application/services/run_tutor_chat_spec.rb) 既有骨架(in-memory sqlite + stub LLM 用 `define_singleton_method(:send_prompt)` 記錄收到的 kwargs)。關鍵:**stub 的 `send_prompt` 把 `tools:` 參數錄下來**,就能斷言「該 persona 送了哪些工具」。

### 2.1 每個 persona 要斷言的結構訊號

| 斷言 | tier1(solver) | tier2(feynman) | tier3(socratic) | 出處 |
|---|---|---|---|---|
| round-1 送出的 `tools` 名單 | `[load_file, edit_file, execute_script, load_reference]` | `[load_file, load_reference]` | `[]`(整個 tools key 不送) | profile.tools(§7.1) |
| system_prompt 含 workspace/行號 guide | ✓ | ✓ | ✗ | inject_workspace(§7.2) |
| system_prompt 含 `COURSE_MATERIALS_MANIFEST` | ✓ | ✓ | ✗ | inject_reference(§7.2) |
| refusal 文字來源 | tutor-solver 的 `## Refusal Message` | tutor-feynman 的 | tutor-socratic 的 | resolver 同源(§7.1.1) |
| **prose 吐 `<actions>` 假動作後,終端 `actions`** | 照白名單留 | edit/execute 被丟掉 | **強制 `[]`** | prose 白名單過濾(§7.3) |
| tier3 不觸發 round 2(即使 prose 喊 load_reference) | — | — | round 數=1 | profile flag 短路(§7.3) |

### 2.2 必寫的兩支新 spec

- `spec/infrastructure/filesystem/tutor_chat/tutor_persona_resolver_spec.rb` — 純函式:`call('tier3')` 回 `(persona_text 含 socratic、refusal 來自 socratic、profile.tools == [])`;`call('tier1')` 回四工具;**未知 key → `raise`**(fail-closed,已定案 — MS3 §7.1.1;**不**靜默退 tier1)。
- 擴充 `run_tutor_chat_spec.rb` — 對每個 persona key:
  1. stub LLM,跑一次,斷言 `send_prompt` 收到的 `tools:` 名單(上表第 1 列)。
  2. 讓 stub 回一段**含 `<actions>[{"type":"edit_file",...}]</actions>` 的 prose**,斷言 tier3 終端 `actions == []`、tier2 不含 edit/execute(§7.3 白名單)。
  3. 讓 stub 的 prose 喊 `load_reference`,斷言 tier3 **不**進 round 2(`send_prompt` 只被呼叫一次、無 `reference_loaded` warning)。

### 2.3 怎麼在 spec 指定 persona

優先 **直接傳 key 給 resolver**(純函式好測)。若要測 `run_tutor_chat` 端到端讀 ENV 的 seam,用 minitest 把那個 seam stub 掉,或在 example 內 `ENV['TUTOR_PERSONA'] = 'tier3'` 後 `ensure` 還原——**不要**依賴 ENV 殘留跨 example。

---

## 三、Layer 2:實機對照實驗(真 LLM,MS3 §八)

### 3.0 一次「問 tutor」其實是兩步(guard → tutor)

`/tutor_chats` 需要前一次 `/guard_checks` 的 `guard_log_id`,且 [derive_verdict](../app/application/services/tutor_chat/run_tutor_chat.rb#L383-L387) 會比對 **guard 當時存的 prompt 必須與本次 prompt 完全一致**,且 verdict ∈ {done, unavailable}(attack 機率沒過門檻才會真的呼叫 tutor)。所以流程固定為:

1. `POST /api/v1/guard_checks` { course_id, project_id, student_id, prompt } → 取回 `log_id`(= guard_log_id)。
2. `POST /api/v1/tutor_chats` { …同上…, guard_log_id, prompt(**逐字相同**), workspace_overview, file_context? } → tutor 回應。

兩個請求都帶 header:`X-LLM-Key`(必填)、`X-LLM-Provider`、`X-LLM-Model`、`X-LLM-Endpoint`(選填)。

### 3.1 兩種跑法

**Option A —— 直接呼叫 service(建議,免 server、免重啟)。**
仿 [scripts/phase0_caps_measurement.rb](../scripts/phase0_caps_measurement.rb) 的 in-process 寫法:一支腳本裡 `for key in %w[tier1 tier2 tier3]`,**每圈直接把 key 傳給 resolver / service**,固定同一份輸入,把回應 dump 成 JSON。因為 key 是參數、不靠 ENV,**三層在同一次腳本執行內跑完,不必重啟任何東西**,順序也確定。这是收 §八 對照表最省事的路。

**Option B —— 走真 HTTP(端到端,含 DB + route)。**
更貼近正式環境,但 `TUTOR_PERSONA` 是 **process-global** → **一台 server 只能一種 persona** → 換 persona 要**重啟**。因此腳本必須**序列化**(起一台→打 guard+tutor→殺掉→換 env→再起),不能並行。Windows PowerShell:

```powershell
$env:TUTOR_PERSONA = 'tier3'
bundle exec rake run:api          # puma config.ru -p 9292(見 Rakefile run:api)
# 另一個視窗 / 腳本:
$body = @{ course_id='CSDS'; project_id='HW2'; student_id='stu-1'; prompt='我的 summarize() 回傳值不對,幫我看一下。' } | ConvertTo-Json
$g = Invoke-RestMethod -Method Post -Uri http://localhost:9292/api/v1/guard_checks `
      -Headers @{ 'X-LLM-Key'=$env:OPENAI_API_KEY; 'Content-Type'='application/json' } -Body $body
# 用 $g.log_id 當 guard_log_id,prompt 必須逐字相同
```

> 切 persona 之間務必**重啟 server**;否則改了 `$env:TUTOR_PERSONA` 也不會生效(舊程序已凍結舊值)。

### 3.2 固定夾具(對齊 MS3 §八 已定案)

- 焦點檔(例 `analysis.R`)**只放 `workspace_overview`(檔名清單),不預載 `file_context`** —— 讓 `load_file` 成為 tier2 vs tier3 的結構性訊號(理由見 MS3 §八)。
- 三層用**完全相同**的 request body(只有 server 的 persona 不同)。
- 用**乾淨首輪(空 history)**,順帶避開 history channel 漏 workspace 給 tier3(MS3 §7.3 漏洞三)。

### 3.3 收什麼訊號

直接引用 **MS3 §八 的訊號分級**:
- **主(硬):** `actions[]` 是否出現 `edit_file` / `execute_script`(只該在 tier1)。
- **次(依賴 D6):** `load_file` 是否出現(tier2 有、tier3 無)。
- **prose(soft,只輔證):** 是否引用具體行號/檔名;`warnings`(如 `reference_loaded`)。
逐一存進對照表的一欄。

---

## 四、自動化 harness(一鍵跑出對照表)

放 `scripts/persona_compare.rb`(Option A 為主):

```
固定 INPUT = { prompt, workspace_overview(含 analysis.R), file_context: nil }
results = {}
%w[tier1 tier2 tier3].each do |key|
  reply = 直接以 key 解析 persona + 跑 mini-loop(stub 掉 guard:直接放行)
  results[key] = {
    tools_sent:  reply 送出的工具名單,
    action_types: reply.actions.map { type },
    has_edit:    reply.actions.any? { edit_file },
    cites_lineno: reply.content =~ /行|line \d+/ ? true : false,   # 粗略,soft 訊號
    warnings:    reply.warnings,
    content:     reply.content
  }
end
印成 markdown 表 + 落 JSON 存證
```

注意:
- Option A 要**繞過 guard 的真 LLM 呼叫**(否則每層多燒一次 guard token)——in-process 可直接給一個放行的 verdict,或 seed 一筆 guard log。
- 若改 Option B 版的 harness,迴圈內務必「起/殺 server」序列化(§3.1),且每層等 server ready 再打。
- 真 LLM **不可逐字重現** → harness 斷言**結構訊號**(主/次),不比對逐字 prose;prose 只存檔人工看。

---

## 五、坑(checklist)

- [ ] fixtures 在 canonical 路徑(§0.1 (A) 或 (B) 已定),且三份都在。
- [ ] resolver + env seam 已實作(§0.2);resolver 為純函式、可傳 key。
- [ ] **process-global**:Option B 換 persona 一定重啟;harness 序列化、勿並行。
- [ ] `guard_log_id` 對應的 guard prompt 與 tutor prompt **逐字相同**,否則 derive_verdict 視為 forbidden、不呼叫 tutor。
- [ ] guard 的 `attack_probability` 要在門檻內(done/unavailable),不然走 refusal 路、收不到對話。
- [ ] tier3 的「不引用行號」是 **soft**(MS3 §7.3 漏洞二)——只量測幻覺頻率,不要當硬性 pass/fail。
- [ ] 真 LLM 不可重現 → 看結構訊號,不比對逐字。

---

## 六、驗收

- **Layer 1:** `rake spec` 全綠,§2.1 表每列都有對應斷言(尤其 tier3 `tools:[]` + prose 假動作被清空 + 不進 round 2)。
- **Layer 2:** `scripts/persona_compare.rb` 產出 MS3 §八 那張對照表,且**主訊號**(edit/execute 只在 tier1)在多次重跑下穩定重現——這就是論文要的「不同 TUTOR.md → 不同對話、結構性可重現」的證據。
