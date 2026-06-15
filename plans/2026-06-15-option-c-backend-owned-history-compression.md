# Option C — 後端擁有 History 壓縮（Backend-Owned File-Omission Compression）

**Date:** 2026-06-15
**Status:** 提案 / 設計中（採後端方向；取代 06-14 評估的前端落點結論）
**Scope:** 把「把一個完成的對話 turn 壓成送進 LLM 的 history 條目——保留意圖／看過哪些檔／
改過什麼,但**省略檔案內容**」這件事,從**前端序列化**改成**後端組裝**。前端改送**富結構的
session turn**;後端新增一個 deterministic 序列化器,在既有 budget/trim 之前把它壓成
`[{role, content}]`。`anthropic_client` 零改、gates 零改。

**直接取代 / 相關:**
- [2026-06-14-history-file-omission-compression.md](./2026-06-14-history-file-omission-compression.md)
  — 同一目標的**前端落點**評估(Option A/B)。本案改採 Option C(後端落點)。該文的訊號分類
  (§1.3)、placeholder 措辭(§4.3)、中性 edit 措辭(§3.3 ⚠️ 路 A)、contract 保命
  (§3.2)、角色配對不變量(§3.5)、CE 框架**全部沿用**——只是**執行端從前端搬到後端**。
- [2026-06-06-prompt-compression-mechanism.md](./2026-06-06-prompt-compression-mechanism.md)
  — rolling summary(`HistorySummarizer`,**尚未實作**)。本案讓兩段壓縮**同住後端 assembler**,
  形成「deterministic 逐 turn 壓縮 → LLM 摘要溢出尾段」的單一漏斗(§5)。
- [2026-06-15-shared-header-constant-and-format-tests.md](./2026-06-15-shared-header-constant-and-format-tests.md)
  — `### path` 共用常數。本案 `HistoryTurnSerializer` **新增為 `FileContextHeader` 的 consumer**
  (解析每輪 headers-only 區塊,§3);讀側全收斂後端共用常數,前端只寫不讀(消除 §6.8 的前端獨立 parser)。
- 參考 Anthropic, *Effective context engineering for AI agents*(下文〔CE〕)。

---

## 0. TL;DR

1. **為什麼從前端改後端:壓縮是 prompt-engineering,而 prompt-engineering 本來就全在後端。**
   system prompt、budget、trim、三道 gates、(規劃中的)rolling summary 都在後端。把
   file-omission 壓縮放前端會讓「壓 history 的政策」橫跨兩個 repo / 兩種語言。06-14 之所以選
   前端,**唯一**理由是「無損、帶路徑 placeholder 的素材只在前端 session」——那是 **contract
   的後果,不是物理定律**。Option C 動 contract,把素材送上來,壓縮政策就能回到它該在的地方。
2. **後端要長三樣東西**(都小、都純):
   - **contract 加一個 optional `session_turns`**(富結構;舊的 `history` 仍收,向後相容)。
   - **新 value object `Values::HistoryTurnSerializer`**(把 06-14 §4 的 `serializeTurnToHistory`
     原樣移植成 Ruby:placeholder、caps、中性 edit 措辭、contract 保命、pair-or-skip)。
   - **assembler 在 trim 之前**呼叫序列化器,把 `session_turns` 壓成 `[{role, content}]`,其餘
     pipeline(trim → system prompt → send)完全不變。
3. **接點乾淨,因為後端已有半成品**:
   - `### path` 抽取邏輯**已存在**於 [redundant_load_gate.rb:34](../app/domain/values/redundant_load_gate.rb#L34)
     / [workspace_edit_gate.rb:30](../app/domain/values/workspace_edit_gate.rb#L30) 的 `loaded_paths`
     ——本案**直接重用**(經共用常數 `FileContextHeader`):前端每輪送 headers-only 區塊,後端解析出
     `seen_paths`(§3,決定走純後端解析,Option A)。
   - `anthropic_client` 仍只收 `{role, content}`([anthropic_client.rb:23-25](../app/infrastructure/llm/anthropic_client.rb#L23-L25)),
     序列化器在 `assembled.history` 之前塌回該形狀 → **client 零改**。
   - trim([budget_aware_prompt_assembler.rb:131-148](../app/application/prompts/builders/budget_aware_prompt_assembler.rb#L131-L148))
     收到的已是壓縮後的成對 turn → 同 budget 留更多 turn;且後端現在自己造成對結構,可**順手把
     trim 改逐對**,消掉「history 以 assistant 開頭 → Anthropic 400」的既有隱患(06-14 §3.5)。
   - rolling summary 尚未實作 → 本案先落地,summarizer 之後接在**同一 assembler**的溢出尾段(§5)。
4. **無狀態不破。** 後端仍不持久化對話:每回合用前端送來的 `session_turns` **即時重算**,
   無 DB、無 schema,延續 2026-06-06 決策 2。後端變「更會組 prompt」,但**沒變有狀態**。
5. **取捨(誠實版)**:wire payload 比「前端送壓好的字串」略大(多 actions + headers-only 區塊,但遠小於
   送原始 file_context);要維持 `history` 舊路徑直到前端切換完成;後端多一個 value object 與
   assembler 分支。換來的是**單一壓縮歸屬 + 多 client 一致 + 與 rolling summary 自然合流**。

---

## 1. 職責邊界:為什麼這次是後端做(對照 06-14 §2)

06-14 §2 的論證是「後端**收不到**素材,所以只能前端做」。那是對的——**在當時 contract 下**。
本案的前提改變:**我們願意動 contract 把素材送上來**,於是論證翻轉:

| | 前端做(06-14) | **後端做(本案 Option C)** |
|---|---|---|
| 壓縮政策所在地 | 前端 `execute-tutor-use-case.ts` | **後端 assembler,與 trim/gates/summary 同處** |
| 與 rolling summary | 跨 repo:前端壓 + 後端摘 | **同一 pipeline 兩段式(§5)** |
| 多 client 一致性 | 各 client 自行壓(plan 自承要後端「防禦性 strip」後盾) | **後端是收口點,天然一致** |
| `### path` 耦合 | 前端 `extractHeaderPaths` 為四方依賴之一(§6.8) | **讀側全收斂到後端共用常數** `FileContextHeader`(gates + serializer);前端只**寫** header、**不**新增 parser(§3.2) |
| 後端狀態 | 無 | **仍無**(逐回合重算,§0-4) |
| 改動量 | 前端多、後端近零 | **後端多、前端反而更少**(前端只轉發 session,不實作 §4 序列化器) |

關鍵釐清:**「後端做」不等於「後端變有狀態」。** 後端不存對話;它每回合拿前端送的
`session_turns` 重算壓縮敘事。素材的**所有權**(system of record)仍在前端 session,後端只是
**消費它來組 prompt**——這正是它對 `file_context` / `workspace_overview` 已經在做的事。

〔CE〕對齊不變:history＝意圖/行動的敘事;file_context＝當前檔案真相;最便宜的 token 是沒送出去的。
差別只在「組裝這份敘事」的程式碼住哪一端。

---

## 2. Contract schema 怎麼擴

### 2.1 現況

[tutor_chat.rb:17-20](../app/application/requests/tutor_chat.rb#L17-L20):

```ruby
optional(:history).array(:hash) do
  required(:role).filled(:string)
  required(:content).filled(:string)
end
```

`history` 是**已壓好**的 `[{role, content}]`——前端已經做完壓縮才送。Option C 要的是**未壓的素材**。

### 2.2 新增 `session_turns`(與 `history` 並存,向後相容)

不改 `history`(舊 client 繼續送壓好的條目),**新增**一個 optional 富結構欄位:

```ruby
optional(:session_turns).array(:hash) do
  required(:prompt).filled(:string)         # 使用者該 turn 的意圖原文(後端會 stripPastedCode)
  optional(:prose).maybe(:string)           # 終端 assistant 散文;action-only turn 為空/缺(後端補 contract 保命)
  optional(:context_headers).maybe(:string) # 該 turn file_context 的 headers-only 區塊(只 `### path` 行、無內容);後端解析(§3)
  optional(:actions).array(:hash)           # 終端 tutor response 的 actions(下方 schema)
end
```

`actions` 的逐元素形狀沿用後端**現有** action 約定(見 [run_tutor_chat.rb TOOLS](../app/application/services/tutor_chat/run_tutor_chat.rb#L40-L113)
與 [anthropic_client.rb:66-68](../app/infrastructure/llm/anthropic_client.rb#L66-L68) 的 `{'type'=>name}.merge(input)`):

```
edit_file      → { type:'edit_file', path:'…', patches:[{ start_line:Int, search:'…', replace:'…' }] }
execute_script → { type:'execute_script', code:'…' }
load_file      → { type:'load_file', path:'…' }
```

dry-validation 端只驗到 `array(:hash)`(寬鬆);逐元素正規化交給 `HistoryTurnSerializer`(§4),
與既有 [EditPatchNormalizer](../app/domain/values/edit_patch_normalizer.rb) 同風格(value 層做 string/symbol key 容錯)。

### 2.3 大小上界

`MAX_HISTORY_BYTES = 500_000`([tutor_chat.rb:9](../app/application/requests/tutor_chat.rb#L9))目前只算 `history`。
新增一條 rule:`session_turns.to_json.bytesize` 也納入同一上界(或各自上界)。因為 `session_turns`
**不含 file_context 內容**(只含 headers-only 路徑行 + 小 patches),payload 比「把整檔灌進 content」**小**,
500KB 預期充裕;Phase 0 量測後再定。**刻意不送原始歷史 file_context**——那會把要省的 bloat 又搬上線,
且會撞 byte cap(§6.2)。

> **Phase 0 結論(2026-06-15)**:壓縮後單一 turn ≈ **291 tok ≈ 約 1 KB** wire(§9);500KB 上界
> 容得下數百個 turn,**綽綽有餘**。建議 `session_turns` 與 `history` **共用同一 500KB 上界**(不另立),
> 因 session_turns 結構上就比舊 `history` 小,共用 cap 既簡單又安全 → 收斂 §8-2。

### 2.4 選擇邏輯(assembler 入口)

```
有 session_turns → 走 Option C:逐 turn 序列化 → 壓成 [{role,content}] → 餵進既有 trim
否則(舊 client)  → 走今天的路:history 原樣餵進 trim
```

兩條路最後都產出 `[{role, content}]`,**trim 以下完全共用**。前端切換完成後可移除舊路徑(獨立清理)。

---

## 3. `seen_paths` 怎麼來:純後端解析(決定 2026-06-15,Option A)

### 3.1 兩個可分離的轉換

- **T1 = 抽路徑**:從某 turn 的 context 抓 `### path` 標頭,得到「該輪看過哪些檔」。
- **T2 = 序列化政策**:placeholder 措辭、caps、中性 edit 措辭、contract 保命、pair-or-skip。

06-14 §4 幾乎整章都是 **T2**(真正的「壓縮智慧」),Option C 把 **T2 全搬後端**。**T1 也搬後端**:
「什麼算 seen」這個定義本身就是壓縮商業邏輯,該與 T2 同處後端,不外包給 client。

### 3.2 落地:前端送 headers-only 區塊,後端 `FileContextHeader.paths` 解析

每個 session turn 附一個 **headers-only 區塊**——就是該輪 file_context **只留 `### path` 標頭行、
剝掉所有 `N| ` 內容行**的版本。後端在 `HistoryTurnSerializer` 內用共用常數
[`FileContextHeader.paths`](./2026-06-15-shared-header-constant-and-format-tests.md)(gates 已在用的同一個)
解析出 `seen_paths`。理由:

- **business logic 全後端**:「什麼算 seen」= 該輪 context 出現的 `### path` 集合,定義與解析都在後端;
  前端只**轉發事實**(它這輪 context 有哪些檔),不持有任何壓縮政策。
- **不送內容、不搬 bloat**:headers-only 區塊只有路徑行(每檔約一行),payload 仍小、不撞 byte cap(§2.3);
  相對「送整包歷史 file_context 讓後端抽」省掉內容上傳。
- **語意正確**:`seen` 取自 context 的 `### path` 集合(= 模型實際看到的檔),而非前端的「load 動作清單」
  ——兩者在 lazy-loading 下會分歧(檔前幾輪 load、後幾輪仍在 context)。用 header 集合才忠實。
- **單一 reader**:解析重用 gates 的 `FileContextHeader`,**不新增 parser**。06-14 §6.8 原本擔心的
  「前端第 4 個獨立 `extractHeaderPaths`」**不會出現**——前端只**寫** `### path`(它本來就是 file_context
  的產生者),**讀**全部集中在後端共用常數(gates 解析當前 turn + serializer 解析歷史 turn)。

> **為何不是「前端送 load 清單」**:那把「什麼算 seen」的定義外包給 client,且 load 清單 ≠ context
> 出現集合(上方語意正確點)。**為何不是「送整包 file_context 給後端抽」**:會把要省的內容 bloat 又
> 搬上線、撞 byte cap。headers-only 區塊是兩者交集:後端持有定義與解析,wire 只付路徑。

---

## 4. 後端要長出的東西

### 4.1 `Values::HistoryTurnSerializer`(新檔,核心)

`app/domain/values/history_turn_serializer.rb`,與 gates / `EditPatchNormalizer` 同層、同風格
(pure module、`self.call`、string/symbol key 容錯、`private_class_method`)。

```ruby
# 輸入:一個 session turn hash(§2.2 的 prompt/prose/context_headers/actions)
# 輸出:要 append 進 history 的條目(恰一對 user/assistant;degenerate turn 見下)
HistoryTurnSerializer.call(turn) -> [{ role:, content: }, ...]
```

常數(沿用 06-14 §4.1,**Phase 0 已量測校準 2026-06-15,維持暫定值**;量測見 §9 與
[scripts/phase0_caps_measurement.rb](../scripts/phase0_caps_measurement.rb)):

```
PROSE_CAP  = 600    # assistant 散文字元上限(=172 tok)。留決定/意圖、丟長篇;>600 邊際收益遞減
PATCH_CAP  = 400    # 單一 search/replace 字元上限(=115 tok)。單行 patch 實測 ~61 字元→全保留,只裁罕見大 patch
SCRIPT_CAP = 200    # execute_script code 摘要上限(=58 tok)。code 為「提議」、可 re-run,故刻意有損保留意圖
PASTE_CAP  = 200    # prompt 內貼入 code 區塊上限(stripPastedCode)。砍掉最大宗的 prompt 膨脹源(整塊貼 code)
# ERROR_TAIL_CAP 不存在:execute_script 輸出未持久化,後端也拿不到(06-14 §6.6)。
```

**Step 1 — user 條目**(移植 06-14 §4.3):

```
seen_paths = FileContextHeader.paths(turn.context_headers).to_a   # 後端解析 headers-only 區塊(§3.2)
content    = strip_pasted_code(turn.prompt)                       # PASTE_CAP:壓貼入 code,保留意圖
if seen_paths.any?
  content += "\n\n[Previously inspected last turn (contents not included now; " \
             "call load_file to see them again): #{seen_paths.join(', ')}]"
push role:'user', content:
```

- 措辭**避開 tool 保留字**(不可用 "Loaded/live/shown",否則模型以為檔現在 loaded → 跳過
  `load_file` → 被 [WorkspaceEditGate](../app/domain/values/workspace_edit_gate.rb) 攔成 `edit_file_redirected`,
  白繞一輪)。用 "Previously inspected … call load_file"(06-14 §4.3 已論證)。

**Step 2 — assistant 條目**(移植 06-14 §4.4,**路 A 中性措辭**):

```
lines = []
lines << truncate(prose.strip, PROSE_CAP) if prose && !prose.strip.empty?
actions.each { |a| lines << render_action(a) }              # 不查 fileChanges(恆空,06-14 §3.3 ⚠️)
content = lines.join("\n")
content = "(No actionable reply.)" if content.strip.empty?  # contract 保命(06-14 §3.2)
push role:'assistant', content:
```

`render_action`:

| type | 渲染(中性、不主張套用狀態) |
|---|---|
| `edit_file` | 每個 patch:`Suggested editing \`<path>\` (line <start_line>): <body>`;單行→內嵌箭頭,多行→`-/+` diff;`search`/`replace` 各套 `PATCH_CAP` |
| `execute_script` | `Suggested a demo script: \`<truncate(code, SCRIPT_CAP)>\``(read-only;**不寫執行結果**,06-14 §6.6) |
| `load_file` | `Requested the contents of \`<path>\`.`(僅終端會出現) |
| 其他/未知 | 略過(防呆) |

**degenerate turn**:prose 空且無可渲染 action → assistant content 退回 `"(No actionable reply.)"`
(保證非空);連 prompt 都空 → 跳過整個 turn,不 push(維持 pair-or-skip 不變量)。

> **為何中性措辭**:前端 tutor turn 的 `fileChanges` 恆空、approve/reject 不入 turn,**判不出
> 套用狀態**(06-14 §3.3 ⚠️)。Option C 收到的 `actions` 是**提議**,故一律寫 "Suggested …",
> 把「改了沒」交給下一輪 live `file_context`(權威)+ §6 系統 prompt 仲裁。日後若前端持久化
> approve/reject,可在 `session_turns.actions[]` 加 `applied:` 旗標,序列化器升級措辭——乾淨擴充點。

### 4.2 `strip_pasted_code`

私有 helper(或獨立小 value object)。偵測 prompt 內的 fenced code block(```` ``` ````)或連續
`N| ` 行區塊,超過 `PASTE_CAP` → 截斷並標 `[pasted code omitted; ask to re-share if needed]`;
**散文(意圖)一律保留**(06-14 §3.4)。截斷須避免切進多位元組字元 / 切斷 ``` fence。

### 4.3 assembler 整合點

[budget_aware_prompt_assembler.rb](../app/application/prompts/builders/budget_aware_prompt_assembler.rb)
`call` 新增 optional `session_turns:` 參數,在 `trim_history` **之前**塌平:

```ruby
history =
  if session_turns&.any?
    session_turns.flat_map { |t| Values::HistoryTurnSerializer.call(t) }
  else
    history   # 舊路徑
  end
selected, dropped = trim_history(history, remaining)   # 既有邏輯,完全不動
```

- 序列化在 trim **之前** → trim 估的是壓縮後成本 → 同 budget 留更多 turn。
- `RunTutorChat#assemble_prompt`([run_tutor_chat.rb:198-211](../app/application/services/tutor_chat/run_tutor_chat.rb#L198-L211))
  多傳一個 `session_turns: params[:session_turns]`。其餘 ROP railway、warnings、mini-loop 全不動。
- `history_truncated` warning 行為不變(壓縮後更少觸發)。

---

## 5. 跟既有 gates / trim / rolling-summary 怎麼接

### 5.1 gates(三道):正交,零改

`RedundantLoadGate` / `WorkspaceEditGate` / `EditPatchContentGate` 全作用在**當前 turn** 的
`file_context` + 當前 `actions`(見 [apply_gates](../app/application/services/tutor_chat/run_tutor_chat.rb#L335-L344)),
**不碰 history**。Option C 只改 history 的組裝,與 gates 無交集。`### path` 的解析現由 gates(當前 turn
的 `file_context`)與 `HistoryTurnSerializer`(歷史 turn 的 headers-only 區塊)**共用同一個
`FileContextHeader`**(§3.2):同源、無重複實作,正是 [shared-header 常數](./2026-06-15-shared-header-constant-and-format-tests.md)的目的。

### 5.2 trim:不動 + 一個順手修

- trim 收到的已是 `[{role, content}]`(序列化器塌平後)→ [trim_history](../app/application/prompts/builders/budget_aware_prompt_assembler.rb#L131-L148)
  **一行不改**即可運作。
- **順手修(本案可納入)**:現行 trim 是**逐條** newest-first([line 137](../app/application/prompts/builders/budget_aware_prompt_assembler.rb#L137)),
  理論上能裁出「以 assistant 開頭」的 history → Anthropic 400(06-14 §3.5)。Option C 既然由後端
  造**工整成對**結構,把 trim 粒度改逐對是自然延伸,順手消除這個既有隱患。(06-14 把它列為「可順手做」,
  在前端方案下後端碰不到;Option C 下它**就在手邊**。)

### 5.3 rolling summary:兩段壓縮合流到同一 assembler

`HistorySummarizer`(2026-06-06,**尚未實作**)規劃為 assembler 注入的 collaborator:history 溢出
budget 時,把被擠掉的舊 turns 用 LLM 摘要成一段。Option C 讓兩段壓縮**同住 assembler**,順序天然:

```
session_turns
  → [Stage 1: HistoryTurnSerializer]  deterministic、0 LLM 呼叫、逐 turn 省略檔案內容
  → [trim_history(逐對)]              newest-first 收 verbatim 壓縮對
  → 溢出? → [Stage 2: HistorySummarizer] LLM 摘要被擠掉的最舊尾段(2026-06-06 §4 step3)
```

這正是 2026-06-06 §3.1 的「harness 決定何時/壓什麼(deterministic)、model 只負責怎麼摘要」原則:
Stage 1 是 harness 的 deterministic 省略,Stage 2 是 model 的語意摘要。**Option C 讓兩者在同一處
composition,而非橫跨 repo 邊界**——這是相對前端方案最強的架構收益。

落地次序:**Stage 1 先做(本案)**,因為它 0 成本且大幅降低 Stage 2 觸發率(最肥的 file_context 不再
進 history);`HistorySummarizer` 之後**獨立**接上,接點是 assembler 內 trim 後的「溢出尾段」,
與序列化器無耦合。兩者的 cap(`PROSE_CAP`/`PATCH_CAP` ↔ `SUMMARY_TOKEN_CAP`)在各自 Phase 0 一起校準。

### 5.4 system prompt:一行 staleness 仲裁(沿用 06-14 §3.3)

在 [TutorSystemPrompt](../app/application/prompts/builders/tutor_system_prompt.rb)(`TOOL_USE_GUIDE`
或新增一小段)加一句:「history 為過往敘事;與當前 `file_context` 衝突時一律以 file_context 為準」。
解決「提議/已套用」與「事後被學生改回」的 staleness——序列化端用中性措辭(§4.1),system prompt 定
仲裁權。後端本來就擁有 system prompt,Option C 下這句更名正言順(敘事現在是後端自己造的)。

---

## 6. 風險與邊角

1. **向後相容**:`session_turns` 與 `history` 並存,舊 client 不受影響(§2.4)。前端切換前後端都要能跑。
2. **Wire payload**:`session_turns` 比壓好的字串略大(多 actions + headers-only 區塊),但**遠小於**送
   原始 file_context;byte cap 納管(§2.3)。**送 headers-only、不送內容**是硬規則(否則撞 cap、搬 bloat)。
3. **無狀態**:逐回合重算,後端不存對話(§0-4);與 2026-06-06 決策 2 一致。代價是重算,換零 schema。
4. **proposed vs applied**:`fileChanges` 恆空 → 中性措辭(§4.1);非本案能解,留 `applied:` 擴充點。
5. **execute_script 輸出**:前端 r_exec 結果不入 turn、後端也拿不到 → **不寫 error tail**(06-14 §6.6)。
   `session_turns.actions` 的 `execute_script` 只帶提議的 `code`。
6. **B3 續傳的多 apiLog 收斂**:一個 student turn 可能有多筆 tutor request/response(僅 B3 續傳;
   hybrid lazy 在後端單 HTTP 內、不入前端 session,06-14 §6.7)。**收斂責任在前端**:前端送
   `session_turns` 時就該把一個 turn 收斂成「prompt + 終端 prose/actions + headers-only 區塊(各輪
   header union)」,後端序列化器只處理已收斂的單一 turn。(這是前端**唯一**保留的整理工作,遠輕於原 §4。)
7. **Tokenizer 是 heuristic**(chars/3.5):壓縮率 ≠ token 節省率,需 Phase 0 實測(同 2026-06-06 §6)。
8. **隱私**:同批資料、更少內容外送;無新風險(檔案內容本就每輪在 `file_context` 送,本案只是不再
   複製進 history)。

---

## 7. 落點與改動清單

**後端(本 repo)— 主要工作:**
- `app/application/requests/tutor_chat.rb`:加 optional `session_turns`(§2.2)+ byte rule(§2.3)。
- `app/domain/values/history_turn_serializer.rb`(新):移植 06-14 §4 的 §4.1 序列化(+ `strip_pasted_code`);
  解析 `context_headers` 用共用常數 `FileContextHeader.paths` → **依賴 [shared-header 落地](./2026-06-15-shared-header-constant-and-format-tests.md)先行**。
- `app/application/prompts/builders/budget_aware_prompt_assembler.rb`:`call` 加 `session_turns:`,
  trim 前塌平(§4.3);**順手**把 `trim_history` 改逐對(§5.2)。
- `app/application/services/tutor_chat/run_tutor_chat.rb`:`assemble_prompt` 多傳 `session_turns:`。
- `app/application/prompts/builders/tutor_system_prompt.rb`:加 staleness 仲裁一句(§5.4)。
- spec:`HistoryTurnSerializer` 單測(各 action type / caps / degenerate / pair-or-skip)、assembler
  整合測(session_turns → 壓縮 → trim)、contract 測(session_turns 形狀 + byte cap)。
- **不動**:`anthropic_client`、三道 gates、controller、routes、DB。

**前端(MindyCLI_demo)— 大幅縮編(相對 06-14):**
- **不再實作** `serializeTurnToHistory` / `extractHeaderPaths` / `stripPastedCode` / 中性措辭——全進後端。
- 改為:組下一輪請求時,把每個完成 turn **收斂**成 `session_turns` 條目(prompt、終端 prose、
  終端 actions、該輪 **headers-only 區塊**;B3 續傳 header union 見 §6-6),改送 `session_turns` 取代
  `history`。前端只**寫** `### path` 標頭(它本來就是 file_context 產生者),**不**解析——解析在後端。
- 過渡期可同時送 `history`(舊)直到後端 `session_turns` 路徑驗證完成。

**rolling summary(2026-06-06,獨立後續):** 本案落地後,`HistorySummarizer` 接 assembler 溢出尾段(§5.3)。

---

## 8. 待決定

1. ~~§4.1 四個 cap 實際值~~ **✓ Phase 0 已校準(2026-06-15):維持 600/400/200/200**(§9 量測背書)。
2. ~~`session_turns` 與 `history` 共用 byte cap 還是各自~~ **✓ 共用同一 500KB**(壓縮後 turn ≈1KB,§2.3 / §9)。
3. ~~`seen_paths` 走原生清單 vs 後端抽~~ **✓ 已定(2026-06-15):純後端解析(Option A)**——前端送
   headers-only 區塊,後端 `FileContextHeader.paths` 解析(§3,最貼「business logic 全後端」)。
4. 是否本案就把 trim 改逐對(§5.2;建議是,隱患就在手邊)。
5. system prompt staleness 仲裁文案是否納入(§5.4;建議是)。
6. ~~**Phase 0 量測(建議必做)**~~ **✓ 已執行(§9)**:壓縮後 turn 比 naive 小 **90%**,8K 通道下
   history 容量由 **0→9 turn**,直接降 rolling-summary 觸發率(§5.3)。
7. 前端切換完成後,何時移除後端舊 `history` 路徑(§2.4)。

---

## 9. Phase 0 量測結果(2026-06-15)

**怎麼跑**:[scripts/phase0_caps_measurement.rb](../scripts/phase0_caps_measurement.rb)(standalone,
require 真實後端 `Tokenizer`,讀真實 fixtures + 前端 session JSON)。§8.6 要的是**可重跑**的
「log 壓縮前/後 token」,故落成腳本而非一次性計算——日後累積更多真實 session 即可重跑覆核。

**資料誠實版(重要)**:前端 session 目前**只有 1 個 turn、0 筆 apiLogs/file_context/actions**
(on-disk schema 僅 `userMessage`/`assistantMessage`/`fileChanges`/`outputs`)。故:
- PROSE/PASTE 以**唯一一則真實 assistant 回答**為樣本;
- PATCH/SCRIPT 以**作業 fixtures 的真實 R code/patch 形狀**為樣本(無真實 tutor edit 可取)。
- **統計力不足**:下列數值是「被量測背書的合理預設」,待真實多輪 tutor session(含 apiLogs)捕獲後**覆核**。

**關鍵量測(8K GitHub-Models 通道 = 學生 demo 的綁定預算)**:

| 項目 | 量測值 | 涵義 |
|---|---|---|
| base round 1(persona+assignment+prompt+overhead) | 2187 tok → 剩 5813 | history 的可用空間 |
| live `file_context`(hw2.R 載入) | 3012 tok(10539 字元) | 載一個檔就吃掉 ~3K |
| base round 2(+solution, hybrid lazy) | 4748 tok → 載 file_context 後 **history 只剩 240 tok** | 緊張通道 |
| **naive past turn**(file_context 灌進 content) | **3053 tok** | round 1 連 **1 個**都放不下 → summary 幾乎必觸發 |
| **compressed past turn**(本案,600/400 caps) | **291 tok(小 90%)** | round 1 可放 **9 個**、round 2 仍受 240 限制 |

**逐 cap 敏感度**:

- **PROSE_CAP=600**:唯一真實回答 1940 字元/555 tok;cap 600 留 172 tok、省 383。>600(800/1000)
  每提高只多救 ~57–114 tok 的舊 turn 散文,**邊際遞減**;<600(400)過度截斷意圖。**維持 600**。
- **PATCH_CAP=400**:worked-example 單行 patch 僅 **61 字元/18 tok ≪ 400 → 全保留**(最高價值、最低成本
  的訊號,§1.3);只在罕見大型多行 patch 才咬。**維持 400**。
- **SCRIPT_CAP=200 / PASTE_CAP=200**:真實 R code block 中位數 676 字元、最大 1235;cap 200 對 16/16
  皆截斷至 ~58 tok。這是**刻意有損**:script 是「提議的 demo」、paste 是學生貼入的整塊 code,兩者價值在
  **意圖識別**而非逐字(逐字可 re-run / re-share 取回)。若 reviewer 想至少看見整塊首段,可放寬到 300
  (仍 16/16 截斷、留 ~86 tok);**預設維持 200**(它砍掉最大宗 prompt 膨脹源)。

**caveat**:tokenizer 是 heuristic(chars/3.5,§6.7),上述為估計;char-based cap 對 char-based
tokenizer 線性對應,故**相對**的前/後比較與 cap 排序內部一致。絕對值待真實 `usage.input_tokens` 覆核。

---

## 10. 實作步驟(依依賴順序,每步獨立綠燈)

依賴鏈:**A(`FileContextHeader`)→ B(`HistoryTurnSerializer`)→ D(assembler)→ E(接線)**。
C(contract)可與 B 並行。每步收尾都跑 `bundle exec rake test` 該段相關 spec 綠燈、`bundle exec rubocop`
zero net-new(注意 [rubocop-windows-crlf](../memory):`-a` 改行尾,事後重新正規化 LF)。

### Phase A — 地基:`FileContextHeader`(前置,serializer 依賴它)

> 即 [shared-header plan §4 step 1–2](./2026-06-15-shared-header-constant-and-format-tests.md#L196)。
> Option C 的 §B 解析 `context_headers` 完全靠這個常數,**故必須先落地**。

- **A1.** 新增 [app/domain/values/file_context_header.rb](../app/domain/values/file_context_header.rb)
  (`.paths` / `.normalize` / `.line`)+ `spec/domain/values/file_context_header_spec.rb`(F1–F10,
  含 **CRLF parity F7**——serializer 會吃到 CRLF headers-only 區塊)。
- **A2.** 三 gate 遷移到共用常數,跑既有 gate spec 確認**行為零變更**。
- **驗收**:`file_context_header_spec` 全綠;既有 gate spec 全綠(去重不改行為)。

### Phase B — 核心:`HistoryTurnSerializer` + spec

- **B1.** 新增 [app/domain/values/history_turn_serializer.rb](../app/domain/values/history_turn_serializer.rb)
  (pure module、`self.call`、string/symbol key 容錯、`private_class_method`;body 見 §4.1):
  - 常數 `PROSE_CAP=600 / PATCH_CAP=400 / SCRIPT_CAP=200 / PASTE_CAP=200`(§9 已校準)。
  - `self.call(turn)` → Step 1 user 條目 + Step 2 assistant 條目 → `[{role:, content:}, ...]`。
  - `seen_paths = FileContextHeader.paths(val(turn,'context_headers')).to_a`(§3.2;**唯一**讀側依賴 A)。
  - 私有 helper:`strip_pasted_code`(§4.2)、`render_action`(§4.1 表)、`truncate`(避免切多位元組/切斷 ``` fence)。
  - **不**碰 `fileChanges`、**不**寫 execute_script 輸出(§4.1/§6.6)。
- **B2.** 新增 `spec/domain/values/history_turn_serializer_spec.rb`(Minitest spec-style):

  | # | case | 斷言要點 |
  |---|---|---|
  | S1 | 完整 turn | user + assistant 一對;assistant 含 prose + 各 action 行 |
  | S2 | seen_paths placeholder | `context_headers` 有 `### a.R` → user 尾含 "Previously inspected … call load_file … a.R";措辭**不含** Loaded/live/shown |
  | S3 | **CRLF headers-only** | `### a.R\r\n…` → seen_paths 含 `a.R`(**無尾隨 `\r`**;證明走 `FileContextHeader`) |
  | S4 | caps 截斷 | prose>600 / patch>400 / script>200 / paste>200 各被截;單行小 patch(~61 字元)全保留 |
  | S5 | edit_file 中性措辭 | 渲染 "Suggested editing `<path>` (line N): …";**不**主張已套用 |
  | S6 | degenerate(action-only) | prose 空、無可渲染 action → assistant = `"(No actionable reply.)"`(非空保命) |
  | S7 | empty turn | prompt 空 → 整 turn skip,不 push(pair-or-skip 不變量) |
  | S8 | key 風格容錯 | string-keyed 與 symbol-keyed turn 結果一致 |

- **驗收**:S1–S8 全綠;與 gates / `EditPatchNormalizer` 同風格通過 rubocop。

### Phase C — contract(可與 B 並行)

- **C1.** [tutor_chat.rb](../app/application/requests/tutor_chat.rb):加 optional `session_turns`
  (§2.2,逐元素只驗到 `array(:hash)`)+ byte rule:`session_turns.to_json.bytesize` 納入
  **同一** `MAX_HISTORY_BYTES = 500_000`(§2.3/§8-2 已定共用)。
- **C2.** contract spec:`session_turns` 形狀接受(prompt 必填、其餘 optional)、缺 prompt 拒絕、
  超 byte cap 拒絕、**舊 `history`-only 請求仍通過**(向後相容)。
- **驗收**:新舊兩種 payload 都過 contract;byte cap 對 session_turns 生效。

### Phase D — assembler 整合

- **D1.** [budget_aware_prompt_assembler.rb](../app/application/prompts/builders/budget_aware_prompt_assembler.rb)
  `call` 加 optional `session_turns:`,在 [trim_history](../app/application/prompts/builders/budget_aware_prompt_assembler.rb#L131-L148)
  **之前**:`session_turns&.any? ? session_turns.flat_map { Values::HistoryTurnSerializer.call(_1) } : history`(§4.3)。
- **D2.(順手,可獨立 commit)** `trim_history` 改**逐對**裁切,消除「history 以 assistant 開頭 → Anthropic 400」隱患
  (§5.2;§8-4 建議做)。若想縮 PR,可拆成 D 之後的獨立步。
- **D3.** assembler spec:(a) 有 `session_turns` → 序列化→trim 後是 `[{role,content}]` 成對;
  (b) 無 `session_turns` → 走舊 `history` 路徑迴歸不變;(c) 序列化在 trim 前 → 同 budget 容更多 turn。
- **驗收**:兩條路徑都產出 `[{role,content}]`;舊路徑零迴歸。

### Phase E — 接線 + system prompt

- **E1.** [run_tutor_chat.rb](../app/application/services/tutor_chat/run_tutor_chat.rb#L198-L211)
  `assemble_prompt` 多傳 `session_turns: params[:session_turns]`;其餘 ROP railway / warnings / mini-loop 不動。
- **E2.** [tutor_system_prompt.rb](../app/application/prompts/builders/tutor_system_prompt.rb):加一句 staleness 仲裁
  (§5.4:「history 為過往敘事;與當前 `file_context` 衝突一律以 file_context 為準」)。
- **E3.** integration spec:`session_turns` 進來 → 壓縮敘事進 prompt;既有 run_tutor_chat spec 迴歸;
  `history_truncated` warning 行為不變。
- **驗收**:end-to-end(contract→assemble→send)走 `session_turns` 成功;舊 `history` 仍可走。

### Phase F — 驗收與守線

- 全套 `bundle exec rake test` 0 failures;`bundle exec rubocop` zero net-new(CRLF 重正規化)。
- **零改確認**:`anthropic_client`(仍只收 `{role,content}`)、三道 gates、controller、routes、DB
  皆未動(§7「不動」清單)。
- 前端(MindyCLI)切換 `session_turns` 為**獨立後續**(§7;過渡期可同送舊 `history`)。
  rolling summary(`HistorySummarizer`)接 assembler 溢出尾段,亦為獨立後續(§5.3)。

### 依賴與並行一覽

```
A(FileContextHeader)──▶ B(HistoryTurnSerializer)──▶ D(assembler)──▶ E(接線/system prompt)──▶ F(驗收)
                                  ▲
            C(contract)───────────┘   (C 可與 B 並行;D 需要 B,E 需要 D)
```

最小可驗證里程碑:**A+B 綠燈**即代表「壓縮智慧」可單元驗證(不依賴 contract/assembler);
**C+D 綠燈**代表後端能端到端吃 `session_turns`;E 把它接進正式請求路徑。
