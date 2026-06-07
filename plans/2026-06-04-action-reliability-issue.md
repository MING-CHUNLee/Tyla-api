# Action Reliability Issue & Migration Plan

**Date:** 2026-06-04
**Status:** Shipped — 2026-06-04（補丁 v2：TOOL_USE_GUIDE 行為修正）

---

## 問題描述

`POST /api/v1/tutor_chats` 回傳的 `actions` 欄位幾乎永遠是空陣列 `[]`，即使 LLM 明確知道要做什麼修改。

---

## 觀察到的症狀（2026-06-04 測試）

### Case 1 — `edit_file` 場景
**Prompt:** "My hw2.R computes quartiles but I accidentally used the wrong probs vector. I have: `quantile(d123, probs = c(0.25, 0.75))`. But I need the 10th, 50th, and 90th percentiles instead. Can you fix it?"

- hw2.R 裡有完整的 `quantile(d123, probs = c(0.25, 0.75))` 這行，search string 明確可用
- LLM 正確說明了要改成 `c(0.1, 0.5, 0.9)`
- LLM 最後說："Let me apply this update in your file." / "I will now generate the required change."
- 實際 `actions: []` — `<actions>` block 從未出現在 raw response 裡

### Case 2 — `execute_script` 場景
**Prompt:** "Can you show me a tiny example with made-up numbers so I can see what 'standardized deviation from the quartile' looks like step by step?"

- LLM 寫了 899 tokens 的數學推導
- 最後說："Would you like me to write an R script to demonstrate this as well?"
- 實際 `actions: []` — 把 `execute_script` 當成「等學生確認才做」

---

## 根本原因

### 直接原因
LLM 在 prose 結尾輸出過渡語句（"Let me apply...", "I will now...", "Would you like..."）後就停止生成，**從未繼續輸出 `<actions>[...]</actions>` block**。

### 根本原因
目前架構要求 LLM 在自然語言 prose 後面，自己記得額外輸出一個結構化的 XML-like block。這件事本質上脆弱：

1. LLM 的 RLHF 訓練讓它傾向在「自然的收尾句」後停止
2. 過渡語句（"Let me apply..."）對 LLM 來說是「回應完成」的信號
3. Prompt instruction 無論多強硬，都在和 LLM 的 stop-generation 傾向對抗

### 已嘗試的 Prompt 修改（均無效）

| 修改 | 效果 |
|---|---|
| 加入 "When the buggy code appears in workspace, prefer `edit_file`" | 無效 |
| 改 "when" → "you MUST end your response with" | 無效，token 數增加但行為不變 |
| 加 few-shot examples（用 hw2.R 相同 code） | 無效，可能讓 LLM 誤把 example 當作答案 |
| 改 few-shot examples 為虛構場景（analysis.R） | 無效 |
| 加 "Do NOT write transitional phrases like 'Let me apply...'" | 無效 |

---

## 實施的解法：API-native Function Calling（雙 provider）

### 核心概念
把 `edit_file` / `execute_script` / `load_file` 定義為 API-level 的 tools（function calling）。LLM 呼叫 tool 是 API 原生機制，不需要 LLM 「記得」輸出特定格式文字，根本解決 stop-generation 問題。

### Provider 涵蓋範圍
GitHub Models 和 OpenAI 使用相同的 API 格式，因此**兩個 provider 都走 function calling**，沒有 fallback 分支。

| Provider | Function Calling 格式 | Actions 來源 |
|---|---|---|
| GitHub Models / OpenAI | OpenAI `tools` format | `choices[0].message.tool_calls` |
| Anthropic | Anthropic `tool_use` blocks | `content[].type == "tool_use"` |
| 其他（無 tool 支援） | — | fallback：`TutorReplyParser` XML |

### 修改的檔案

#### `app/infrastructure/llm/llm_response.rb`
新增 `tool_calls` 欄位（預設 `[]`），讓兩個 client 都能回傳 action 結果：

```ruby
LlmResponse = Data.define(:content, :usage, :tool_calls) do
  def initialize(content:, usage:, tool_calls: [])
    super
  end
end
```

#### `app/infrastructure/llm/anthropic_client.rb`
- `send_prompt` 新增 `tools: []` 參數；非空時加入 request body
- `parse` 分離 `text` blocks（→ `content`）和 `tool_use` blocks（→ `tool_calls`）

```ruby
def send_prompt(system_prompt:, user_message:, history: [], max_tokens: nil, tools: [])
  body[:tools] = tools if tools.any?
  ...
end

# parse 裡
prose      = blocks.select { |b| b['type'] == 'text' }.map { |b| b['text'] }.compact.join
tool_calls = blocks.select { |b| b['type'] == 'tool_use' }.map do |b|
  { 'type' => b['name'] }.merge(b['input'] || {})
end
```

#### `app/infrastructure/llm/openai_client.rb`
- `send_prompt` 新增 `tools: []` 參數
- `openai_tools()` 私有方法：把 shared format（`input_schema:`）轉成 OpenAI wrapper（`{ type: "function", function: { parameters: } }`）
- `parse` 讀 `choices[0].message.tool_calls`，解析 `function.arguments` JSON string

```ruby
def openai_tools(tools)
  tools.map do |t|
    {
      type: 'function',
      function: {
        name:        t[:name],
        description: t[:description],
        parameters:  t[:input_schema]
      }
    }
  end
end

# parse 裡
tool_calls = Array(message['tool_calls']).map do |tc|
  name = tc.dig('function', 'name')
  args = JSON.parse(tc.dig('function', 'arguments') || '{}')
  { 'type' => name }.merge(args)
rescue JSON::ParserError
  nil
end.compact
```

#### `app/application/services/tutor_chat/run_tutor_chat.rb`
- 新增 `TOOLS` 常數（共用 schema，Anthropic `input_schema` 格式，各 client 自行轉換）
- 永遠傳 `tools: TOOLS`（移除舊的 `provider == 'anthropic'` 條件）
- `extract_reply` 方法：有 `tool_calls` 就用，否則 fallback 到 `TutorReplyParser`

```ruby
def extract_reply(llm_reply)
  if llm_reply.tool_calls.any?
    [llm_reply.content, llm_reply.tool_calls]
  else
    Values::TutorReplyParser.call(llm_reply.content)
  end
end
```

#### `app/application/prompts/builders/tutor_system_prompt.rb`
- `ACTIONS_PROTOCOL`（含 XML 格式說明）→ `TOOL_USE_GUIDE`（只有 decision rules）
- Format 指示不再需要，由 API 負責結構化輸出

```
## Tool Use Guide
Call `edit_file` when the code to fix is visible in the student workspace.
Call `execute_script` when showing runnable demo code that does not exist in any file.
Call `load_file` when you need to see a workspace file not provided in context.
If you have no concrete code to act on, or when refusing, do not call any tool.
```

#### Spec 更新
- `anthropic_client_spec.rb`：新增 tool_use response 解析、tools key 出現/不出現測試
- `openai_client_spec.rb`：新增 OpenAI function calling format、tool_calls 解析測試
- `run_tutor_chat_spec.rb`：新增 tool_calls path 測試；`'## Actions Protocol'` → `'## Tool Use Guide'`
- `tutor_system_prompt_spec.rb`：header 和內容斷言對應更新

### 結果
204 tests, 0 failures（含新增的 function calling 測試）。

---

## 補丁 v2：TOOL_USE_GUIDE 行為修正（2026-06-04）

### 問題
實際測試後發現 `actions` 仍為空。debug log 顯示 function calling 本身有效（tools 確實送出），但模型**選擇不呼叫工具**，而是把推導全寫在 prose 裡，最後問 "If you'd like, I can illustrate this step-by-step process in R code for you. Let me know!"

### 診斷
| 問題類型 | XML 時代 | Function Calling 後 |
|---|---|---|
| `edit_file` | 模型說 "Let me apply..." 然後停，忘記輸出 XML | API 層負責，已改善 |
| `execute_script` | 模型說 "Would you like me to..." 然後停 | **本次補丁處理** |

根本原因：`TOOL_USE_GUIDE` 的觸發條件寫的是「when **showing** runnable demo code」——模型判斷自己是在「解釋概念」，不是在「顯示 demo code」，條件不成立，不觸發工具。

### 修正
將 `TOOL_USE_GUIDE` 觸發條件從**模型行為**改為**學生意圖**，並明確禁止確認行為：

```
## Tool Use Guide
Call `edit_file` when the exact code to fix is visible in the student workspace — apply the fix directly without asking first.
Call `execute_script` when the student asks for a demo, example, or step-by-step illustration — provide the R code directly without asking for confirmation first.
Call `load_file` when you need to see a workspace file not provided in context.
Do NOT offer to run code as a follow-up question ("Would you like me to..."). If code would help, call the tool immediately.
If you have no concrete code to act on, or when refusing, do not call any tool.
```

關鍵改動：
1. `execute_script` 觸發條件：「student asks for a demo, example, or illustration」（學生意圖）取代「when showing runnable demo code」（模型行為）
2. `edit_file` 明確加上「without asking first」
3. 新增禁止規則：不得用 "Would you like me to..." 詢問確認

---

## 保留的 fallback

`TutorReplyParser`（XML `<actions>` 解析）保留，作為不支援 function calling 的 provider 的 fallback。當 `llm_reply.tool_calls` 為空時自動走這條路。
