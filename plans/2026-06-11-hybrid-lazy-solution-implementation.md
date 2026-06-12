# Hybrid Lazy Loading — Codebase 實作分析與設計缺陷

**Date:** 2026-06-11
**Status:** 實作分析（codebase review 完成；含設計缺陷誠實盤點，未定案）
**前置文件：** [2026-06-11-lazy-context-loading-evaluation.md](./2026-06-11-lazy-context-loading-evaluation.md)（§4 hybrid 方案）

> Hybrid 摘要：persona + assignment + **manifest** eager；
> **solution lazy、server 端解析**（新 tool `load_reference`，內容永不回傳 client）；
> workspace files 照 B3（前端，本文不動）。

---

## 1. Codebase 盤點 — 影響設計的五個事實

實作前 review 了會被牽動的每個元件，以下五點直接決定架構選擇：

### 1.1 兩個 LLM client 都丟棄 tool call id → 標準 tool_result 續傳做不到（不重做 client 的話）

- `anthropic_client.rb:66-68`：tool_use block 被壓平成 `{'type' => name, ...input}`，
  **`id` 直接丟棄**。Anthropic 的 tool_result 續傳必須帶 `tool_use_id`。
- `openai_client.rb:81-87`：同樣丟 `tc['id']`（OpenAI 需 `tool_call_id`）。
- `LlmResponse`（`llm_response.rb`）只有 `content / usage / tool_calls` 三欄，無處放 id。
- history 格式是純 `{role, content}` 字串（兩個 client 的 `send_prompt` 都這樣 map），
  **無法承載「assistant turn 內含 tool_use block」的結構化訊息**——
  標準續傳要求把上一輪 assistant 訊息（含 tool_use）原樣回放。

→ 做「教科書式 tool_result loop」需要：`LlmResponse` 加 id、history 改結構化、
兩個 client 的訊息組裝全部重寫。**改動半徑太大，Phase 1 不走這條**（見 §2）。

### 1.2 Assembler 把 assignment + solution 黏成一塊 → 必須先拆開

`budget_aware_prompt_assembler.rb:84` 把兩者合成 `composed_solution` 再傳給
`TutorSystemPrompt.build(solution_text:)`。Hybrid 要求 assignment 永遠在、
solution 條件式注入，**這條黏合線是第一刀**。

好消息：`tutor_system_prompt.rb:38` 的 `solution_text` 本來就是條件渲染
（`unless blank?`）——builder 端**零改動**就支援「無 solution」的組裝。

### 1.3 `extract_reply` 把所有 tool_calls 原樣回傳 client → `load_reference` 必須被攔下

`run_tutor_chat.rb:189-195`：`tool_calls.any?` → 全數變成 response 的 `actions`。
若不攔截，`load_reference` 會像今天的 `load_file` 一樣流到前端——
前端 driver 解析不了（不在 workspace），但更糟的是**這個 tool 的存在本身
就告訴學生「有解答檔可以要」**。server 端 tool 必須 server 端消費，
終端 actions 裡永遠過濾掉。

### 1.4 `usage` 是單次呼叫語意 → mini-loop 要加總

`ok_outcome`（`run_tutor_chat.rb:218-232`）直接用 `reply.usage`。
兩輪呼叫後必須回傳 Σ（`input_tokens`、`output_tokens` 各自相加），
且 `doc/api_tutor_chats.md` 的 usage 語意要改寫成「本回合所有 tutor 呼叫之和」。

### 1.5 `warnings` 欄位已存在且 optional → 觀測訊號有現成載體

`tutor_chat_representer.rb`：`warnings` nil 時整欄省略。
加一個 `'reference_loaded'` 訊號（供 CLI 顯示 + Phase 0 量測）**零 contract 風險**。

---

## 2. 核心架構決策：Re-assemble 續傳（不走 tool_result）

### 決策

Round 1 的 reply 含 `load_reference` 時，後端**不送 tool_result**，而是：

1. 用 `include_solution: true` **重新組裝** system prompt（solution 注入）；
2. 從 tools 陣列**移除 `load_reference`**；
3. 以**同一組** user_message + history 重呼叫一次 LLM；
4. Round 2 的 reply 即終端結果。

```
Round 1: system = persona + assignment + manifest        tools = [edit, exec, load_file, load_reference]
            │ reply 含 load_reference?
            ├─ 否 → 終端（與今日行為差 = 省 solution tokens）
            └─ 是 ↓
Round 2: system = persona + assignment + manifest + solution   tools = [edit, exec, load_file]
            └─ 永遠終端（load_reference 物理上不可再呼叫）
```

### 理由

| 考量 | Re-assemble | tool_result loop |
|---|---|---|
| client 改動 | **零**（`send_prompt` 簽章不變） | `LlmResponse`+history+兩 client 全重寫（§1.1） |
| 終止保證 | **結構性**（round 2 無此 tool，非靠 prompt 勸） | 靠 max-iteration 計數 |
| solution 放置位置 | system prompt（與今日同一位置、同一套 persona 管制） | tool_result 在 user turn——模型對 system prompt 的服從性高於 user turn 內容，洩題管制更弱 |
| 與既有設計一致性 | 同 B3 哲學（同 prompt 重發、加大 context） | 引入第二種續傳正規化 |
| 缺點 | round 1 的 output（含可能的 prose）整段丟棄 | 保留完整 reasoning 軌跡 |

tool_result loop 列為 Phase 2 研究變體（若論文需要「標準 agentic loop」敘事），
與 B1 同籃。

### 與 guard 的互動：零改動

mini-loop 整個發生在 `request_tutor_reply` 一步之內，guard_log 驗證
（`derive_verdict`）在 loop 之前已完成一次，round 2 不重驗——
與 B3「prompt 不變 → verdict 沿用」同一邏輯，且這裡連 HTTP 邊界都沒跨。

---

## 3. Step-by-Step 實作

### Step 1 — 拆開 assignment / solution，assembler 加 `include_solution:`

`budget_aware_prompt_assembler.rb`：

```ruby
def self.call(persona:, assignment:, solution:, student_file:, history:,
              user_prompt:, endpoint:, file_context: nil, include_solution: false)
  base_tokens =
    Values::Tokenizer.estimate(persona) +
    Values::Tokenizer.estimate(assignment) +
    (include_solution ? Values::Tokenizer.estimate(solution) : 0) +
    Values::Tokenizer.estimate(user_prompt) +
    FORMATTING_OVERHEAD
  # ...
  system_prompt = TutorSystemPrompt.build(
    policy_text:   persona,
    assignment_text: assignment,                            # 新參數（見下）
    solution_text: include_solution ? solution : nil,       # blank? → 區段消失
    context_files: included_files,
    live_context:  live_context
  )
```

要點：
- **solution 在 round 2 是 mandatory**（模型明確要了），擠壓的是 droppable
  （workspace/history），不是反過來。
- 預算單調性：round 2 base = 今日 base（persona+assignment+solution+prompt）。
  **今日放得下的 prompt，round 2 必放得下** → 不產生新的 413 路徑。
  round 1 base 比今日**少** ~2.3K tokens → overflow 風險只降不升。
- `:84` 的 `composed_solution` 黏合刪除，`TutorSystemPrompt.build` 增加
  `assignment_text:` 參數獨立渲染 `## Assignment` 區段。

### Step 2 — `TutorSystemPrompt`：manifest 區段 + tool guide 更新

`tutor_system_prompt.rb`：

```ruby
COURSE_MATERIALS_MANIFEST = <<~MANIFEST.strip
  ## Available Course Materials
  - `reference_solution` — instructor's reference solution for this assignment.
    Not loaded by default. Call `load_reference` to consult it BEFORE advising on
    how to structure, improve, or verify the student's work.
MANIFEST
```

- **這份 manifest 只列「課程素材」，不列學生 workspace 檔——manifest 的責任歸屬（S1）**：
  後端有固定的 on-disk loader（`SolutionLoader` 等），**知道**課程素材有哪些，所以列得出來，
  還能用 `load_reference` 的 `input_schema` `enum`（見 Step 3）當白名單杜絕路徑幻覺。
  學生 workspace 相反——後端碰不到學生本機檔案系統、**無法列舉**，那份「可用檔案清單」
  只能由**前端**組進 `file_context`（`## Project Context` 區塊），對應的 lazy 續傳走 B3 前端
  driver、用自由字串路徑的 `load_file`，**不在本案範圍**。
  → 本案後端**只新增課程素材這半邊的 manifest**；workspace 的 S1 是前端（MindyCLI_demo / B3）的事。
- manifest **永遠渲染**（eager），緊接 assignment 區段之後。
- solution 已注入時（round 2），manifest 換成一行
  「`reference_solution` is included below」——明示已滿足，
  避免模型在 prose 裡向學生說「我去調閱解答」這種洩漏存在感的話術。
- `TOOL_USE_GUIDE` 加一行：
  `Call load_reference when the question concerns how to approach, structure,
  improve, or check the homework. Do NOT call it for purely logistical questions
  (deadlines, submission format).`
  ——這行就是 evaluation 文件 Scenario 1 vs 2 的分流器：**分流邏輯活在
  prompt 指引，不在後端程式**（遵守「不加分類器」決策）。

### Step 3 — `RunTutorChat`：tool 定義 + bounded mini-loop

**Tool 定義**（`TOOLS` 增加第四項；用 enum 杜絕路徑幻覺，也順便當 schema 級白名單）：

```ruby
{
  name: 'load_reference',
  description: 'Load an instructor course material into your context. ' \
               'Resolved by the server; the material itself is never shown to the student verbatim.',
  input_schema: {
    type: 'object',
    properties: {
      name: { type: 'string', enum: ['reference_solution'] }
    },
    required: %w[name]
  }
}
```

**`request_tutor_reply` 改為兩輪上界的 loop**（sketch）：

```ruby
def request_tutor_reply(credentials, params)
  llm = Infrastructure::LlmClient.for(**credentials_slice)

  assembled = yield_assemble(params, include_solution: false)     # round 1
  reply     = call_llm(llm, assembled, params, tools: TOOLS)

  if wants_reference?(reply)
    assembled = yield_assemble(params, include_solution: true)    # round 2
    round2    = call_llm(llm, assembled, params,
                         tools: TOOLS.reject { |t| t[:name] == 'load_reference' })
    reply     = round2.with(usage: sum_usage(reply.usage, round2.usage))
    @reference_loaded = true                                      # → warnings
  end
  Success([reply, assembled])
end

def wants_reference?(reply)
  actions = reply.tool_calls.any? ? reply.tool_calls
                                  : Values::TutorReplyParser.call(reply.content).last
  actions.any? { |a| (a['type'] || a[:type]) == 'load_reference' }
end
```

要點：
- **檢測必須覆蓋兩條解析路徑**（native tool_calls 與 XML fallback，§1.3 的
  `extract_reply` 雙分支）——非 tool_use provider 走 XML 也能觸發續傳。
- round 1 含 `load_reference` + `edit_file` 同回 → **load 優先、edit 丟棄**
  （round 2 重決），鏡像 B3 §4.5。實作上 round 1 reply 整個不進終端，自然成立。
- `assemble_prompt` 與 `request_tutor_reply` 的呼叫順序在 `call` 裡要重排：
  組裝移進 loop（現為兩個獨立 step）。`overflow?` 檢查兩輪都要做。
- 終端前防禦性過濾：`actions.reject { type == 'load_reference' }`
  （round 2 結構上不可能出現，但 XML fallback 是自由文字、模型可幻覺）。

### Step 4 — outcome / 文件

- `ok_outcome`：`warnings << 'reference_loaded' if @reference_loaded`。
- `doc/api_tutor_chats.md`：usage 語意改「Σ 本回合 tutor 呼叫」；
  warnings 枚舉加 `reference_loaded`；明示 `load_reference` 永不出現在 actions。
- （Phase 0 量測）log 一行：round 數、是否 reference_loaded、兩輪 input_tokens。

### Step 5 — Specs

| 檔案 | 案例 |
|---|---|
| `budget_aware_prompt_assembler_spec.rb` | `include_solution: false` → base 無 solution tokens、prompt 無 `## Reference Solution`；`true` → 兩者皆在；round 2 base 與今日相等（迴歸保證） |
| `tutor_system_prompt_spec.rb` | manifest 永遠在；solution 注入時 manifest 換已載入版；assignment 獨立區段 |
| `run_tutor_chat_spec.rb` | (a) 不請求 → 1 次呼叫、無 warning；(b) 請求 → 2 次呼叫、round 2 tools 無 `load_reference`、usage = Σ、warnings 含 `reference_loaded`；(c) round 1 `load_reference`+`edit_file` → edit 不外洩、round 2 重決；(d) XML fallback 含 `<actions>[{"type":"load_reference"}]</actions>` 也觸發續傳；(e) 終端 actions 永無 `load_reference`（含幻覺注入 case）；(f) round 2 upstream timeout → 既有 `:upstream_timeout` failure 路徑 |

---

## 4. 設計缺陷盤點（誠實版）

### D1（最大缺陷）：跨 turn 無 stickiness — 後端 stateless 撞牆

Solution 只活在 round 2 的 system prompt，**不進 history、不回傳 client**。
下一個 user turn 後端從零組裝 → 模型必須**再次** `load_reference` →
改作業型的多輪對話**每一輪都付兩次 LLM 呼叫**。對話越深，hybrid 相對
eager 的成本優勢越被吃掉，甚至反超。

| 選項 | 代價 |
|---|---|
| A. 接受重請求（Phase 1） | 每輪 +1 呼叫；round 1 很便宜（無 solution 的 prompt + 一個 tool call 的 output），可量測後再說 |
| B. client 回送 `reference_requested: true` optional param（吃到 `warnings: reference_loaded` 後） | 改 request contract（向後相容）；且形同 client 可**無條件索取 solution 注入**——但注入只進 server 端 prompt、不回傳，洩題面不變，可接受 |
| C. 後端從 history 嗅探上輪是否載過 | 脆弱（history 是 client 提供的自由文字，可偽造可誤判），**否決** |

**Phase 1 定 A，Phase 0 量「同一對話內重複載入率」後決定是否上 B。**

### D2：模型「該要不要」= 品質迴歸風險（hybrid 的本質賭注）

今日 solution 永遠在場，tutor 的建議**永遠有 ground truth**。Hybrid 後，
模型若直接憑常識回答「怎麼寫比較好」而不調閱 solution，回答品質
**靜默劣化**——學生看不出差別，論文評測看得出。這不是 bug，是 lazy loading
的固有代價；唯一防線是 Step 2 的 manifest 措辭 + Phase 0 用
evaluation set 對比 eager/hybrid 的回答品質。**若劣化顯著，hybrid 應僅作為
論文的對照組而非 production 預設。**

### D3：模型「不該要也要」= 成本反轉

反向風險：tool description 寫得太誘人，模型每輪都調閱 → 每輪固定兩次呼叫，
**比 eager 更貴**（eager 一次呼叫多付 2.3K input tokens；兩次呼叫 = 重付整個
base ~2-3K + 兩次 output）。粗算損益平衡點：**調閱率 > ~50% 時 hybrid 開始虧**。
CSDS 家教場景的真實調閱率是多少，沒人知道——**這就是 Phase 0 必須先量的數字**，
也是 evaluation 文件 §4 把實作排在量測之後的原因。

### D4：round 1 的 prose 被丟棄 — 可能丟掉有價值的部分回答

模型常在 tool call 前先寫一段 prose（「我看一下參考解答…」或甚至先給一半答案）。
Re-assemble 設計下這段全丟。通常是好事（半成品答案本來就不該給學生），
但若模型把**完整回答 + 順手調閱**放在同一輪，我們丟掉了一個本可終端的好回答、
多付一輪。無解（不回放 round 1 就無法保留），記錄為已知代價。

### D5：延遲上界翻倍，疊上 B3 是乘法

單請求最壞 = 2 × READ_TIMEOUT(30s)。再疊 B3 前端 `MAX_CONTINUATIONS=3`：
一個 user turn 最壞 **8 次 LLM 呼叫**（4 個 HTTP 請求 × 各 2 輪）。
機率低（需要每圈都同時觸發兩種載入）但存在。緩解：
- 前端 HTTP client timeout 必須 > 兩輪上界（查 `MindyCLI_demo` 的 gateway timeout 設定——**跨 repo 行動項**）；
- Phase 0 log 量真實分布；
- 若要硬上界，可規定「B3 續傳輪（file_context 已含 `## Files Loaded On Request`）
  不再提供 `load_reference`」——但這會讓「載學生檔後才發現需要對照解答」的
  正當路徑斷掉，**暫不採用**，列為校準選項。

### D6：兩輪間 system prompt 前綴不穩 — 未來上 prompt caching 會痛

Solution 注入點在 prompt 中段（assignment 之後、workspace 之前），
round 1/round 2 的共同前綴只到 manifest 為止。目前無 caching、無影響；
若未來上 Anthropic prompt caching，應把 solution 區段移到**可快取前綴之後**
（或單獨 cache breakpoint）。現在記下，免得未來踩。

### D7：`load_reference` 的存在向模型暴露「有解答」— 但不向學生

Tool 定義只進 LLM API payload，不進 response；manifest 同理（在 system prompt，
不回傳）。唯一外洩面是 `warnings: ['reference_loaded']` ——學生會知道
「這次 tutor 查了參考資料」。評估：無害（不含內容），且對論文 demo 是加分
（可解釋性）。若在意，把 warning 改成只進 server log。

### D8：與 HistorySummarizer（compression 計畫）改同一批檔案

兩案都動 `budget_aware_prompt_assembler.rb` / `run_tutor_chat.rb` /
`tutor_system_prompt.rb`。**先做本案再做 compression**（本案縮小 round 1 base，
等於送給 history 更多預算，compression 的觸發率下降，校準值會變）——
或反序但 `SUMMARY_TOKEN_CAP` 校準要重跑。兩案不可並行開發同檔。

---

## 5. 建議提交順序（每步獨立綠燈）

| # | 內容 | 依賴 |
|---|---|---|
| 1 | `TutorSystemPrompt`：`assignment_text:` 參數 + manifest 常數 + guide 更新（+ spec） | 無 |
| 2 | Assembler：拆 `composed_solution`、加 `include_solution:`（+ spec，含 round-2-base == 今日 base 的迴歸斷言） | 1 |
| 3 | `RunTutorChat`：`load_reference` tool + mini-loop + usage Σ + warnings + actions 過濾（+ spec） | 2 |
| 4 | `doc/api_tutor_chats.md` 更新 + Phase 0 量測 log | 3 |
| 5 | （跨 repo）確認前端 gateway timeout 承受兩輪；CLI 渲染 `reference_loaded` warning | 3 |

---

## 6. 驗收清單

- [ ] Round 1 prompt 不含 solution；round 2 含且 base ≤ 今日 base（無新 413 路徑）
- [ ] Round 2 tools 不含 `load_reference`（結構性終止）
- [ ] 終端 actions 永無 `load_reference`（含 XML 幻覺 case）
- [ ] Solution 內容在任何 response 欄位都不出現（grep spec 斷言）
- [ ] usage = Σ 兩輪；`reference_loaded` warning 正確出現/省略
- [ ] XML fallback provider 也能觸發續傳
- [ ] 不請求 reference 的回合 = 單次呼叫（成本基線成立）
- [ ] guard 路徑零改動（forbidden 回合不進 loop、不付 tutor 成本）
- [ ] Phase 0 log：round 數 / 調閱率 / token 分布（D1、D3 的決策數據）
