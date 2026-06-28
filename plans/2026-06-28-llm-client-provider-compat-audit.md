# LLM Client 相容性審查：Provider 路由 + Schema 轉換的缺口與修正

**Date:** 2026-06-28
**Status:** 規劃中（尚未實作）。本文來自 2026-06-28 對 codebase 的完整 review，
確認 provider 路由與 tool schema 轉換的設計合理性，並列出**四個已識別缺口**（依嚴重度排序），
最嚴重的 `max_tokens` vs `max_completion_tokens` 相容性裂縫會讓整個 turn 直接失敗。

**相關程式（被審查的核心路徑）：**
- Provider 路由入口：[llm_client.rb](../app/infrastructure/llm/llm_client.rb)
- OpenAI/GitHub client（schema 轉換點）：[openai_client.rb](../app/infrastructure/llm/openai_client.rb)
- Anthropic client：[anthropic_client.rb](../app/infrastructure/llm/anthropic_client.rb)
- Tool 定義單一真實來源：[tutor_tools.rb](../app/domain/values/tutor_tools.rb)
- Mini-loop 與 tool dispatch：[run_tutor_chat.rb](../app/application/services/tutor_chat/run_tutor_chat.rb)
- Channel / token cap 判定：[token_budget.rb](../app/domain/values/token_budget.rb)

---

## 整體架構（現狀，已正確）

```
tutor_tools.rb
 ├─ EDIT_FILE, EXECUTE_SCRIPT, LOAD_FILE, LOAD_REFERENCE_TOOL
 │   全部使用 Anthropic-canonical 形狀：{ name:, description:, input_schema: }
 │
LlmClient.for(provider:)
 ├─ 'openai'    → OpenAiClient   ← GitHub Models 也走這條（endpoint 換成 azure.com）
 └─ 'anthropic' → AnthropicClient

OpenAiClient#openai_tools(tools)      ← 請求方向：Anthropic形狀 → OpenAI function-calling包裝
  { type: 'function', function: { name:, description:, parameters: input_schema } }

AnthropicClient#send_prompt           ← 請求方向：直接透傳（canonical = Anthropic 原生）

OpenAiClient#parse (tool_calls)       ← 回應方向：choices.message.tool_calls → { 'type'=>name, ...args }
AnthropicClient#parse (tool_calls)    ← 回應方向：content[].tool_use → { 'type'=>name, ...input }
```

**GitHub Models 的「雙重身分」：**
- `provider` 維度 → `openai`（決定 client + schema 轉換）
- `channel` 維度 → 靠 endpoint host 比對 `models.inference.ai.azure.com` / `models.github.ai`
  （[token_budget.rb:14-19](../app/domain/values/token_budget.rb#L14-L19)，決定 8K token cap）

---

## 缺口總表

| 編號 | 嚴重度 | 分類 | 問題 | 影響 |
|---|---|---|---|---|
| **E1** | 🔴 高 | 即時失敗 | `max_tokens` 對 reasoning models 會被拒 | **turn 直接失敗 400**，學生完全無回應 |
| **E2** | 🟠 中 | 靜默失敗 | tool_call JSON parse 失敗後「靜默 drop」 | 模型動作消失、API 層不可見 |
| **E3** | 🟠 中 | 遵循率 | 沒帶 `strict: true` / `additionalProperties: false` | tool args 為 best-effort，巢狀 schema 較易吐壞結構 |
| **E4** | 🟡 低 | 文件 | Canonical schema 選擇、tool_choice / 多輪工具續傳的天花板未記錄 | 後人不知設計決策與限制邊界 |

---

## E1（🔴 高）：`max_tokens` 對 reasoning models 直接失敗

### 問題

[openai_client.rb:29](../app/infrastructure/llm/openai_client.rb#L29)：

```ruby
payload[:max_tokens] = max_tokens unless max_tokens.nil?
```

OpenAI o1 / o3 / o4 / gpt-5 系列（GitHub Models 上**均有提供**）要求改用
`max_completion_tokens`；送 `max_tokens` 會收到：

```
400 — 'max_tokens' is not supported with this model. Use 'max_completion_tokens'.
```

[plan 2026-06-24 §1](2026-06-24-provider-413-input-too-large.md) 已點名 `o1-mini / o3-mini / gpt-5-mini / deepseek-r1` 這些
4K 上限模型學生真的可能選到；一選就整個 turn 失敗（被 `LlmError::Upstream` 吞成 502）。

**連帶問題（同 client、同一批修正）：**
- `messages[0] = { role:'system', ... }` 對 DeepSeek-R1 系列會被忽略或造成非預期輸出
  （官方建議不用 system role，指令全放 user prompt）。
- Reasoning models 有的也**不支援 `tools`**（DeepSeek-R1 早期版本），送了也被拒。

### 修正方案

在 OpenAiClient 維護一張 **model 名稱前綴/集合 → 行為旗標** 的對照，決定：
1. 要用 `max_tokens` 還是 `max_completion_tokens`
2. 要不要送 `tools`（若不支援，直接省略 key）

```ruby
# openai_client.rb（新增 private helpers）

REASONING_MODEL_PATTERN = /\Ao[1-9]|gpt-5|deepseek-r1/i.freeze

def reasoning_model?
  @model && REASONING_MODEL_PATTERN.match?(@model.to_s)
end

def tools_supported?
  # DeepSeek-R1（非 0528+）不支援 tools；o1/o3 早期也不支援。
  # 保守策略：reasoning models 預設不送 tools，
  # 除非 model 名明確包含已知支援 function calling 的版本後綴。
  # 逃生口：Azure 自定義部署名可用 X-LLM-Reasoning: true header override（未來實作）。
  return true unless reasoning_model?
  @model.to_s.downcase.include?('0528') # deepseek-r1-0528 開始支援
  # o3 / o4 / gpt-5 需實測後補 allowlist；目前保守不送
end
```

在 `send_prompt` 建構 payload 時：

```ruby
tokens_key = reasoning_model? ? :max_completion_tokens : :max_tokens
payload[tokens_key] = max_tokens unless max_tokens.nil?
warnings = []
if tools.any?
  if tools_supported?
    payload[:tools] = openai_tools(tools)
  else
    warnings << 'tools_not_supported'  # 靜默省略 tools，XML fallback 可接；前端可觀測
  end
end
# warnings 傳入 LlmResponse（與 E2 的 malformed_tool_calls 共用同一個 response 欄）
```

> **已拍板（2026-06-28）：**
> - **REASONING_MODELS**：改用 regex pattern `REASONING_MODEL_PATTERN = /\Ao[1-9]|gpt-5|deepseek-r1/i`，
>   而非硬寫死名稱清單。Model name 由前端傳入（`LlmClient.for(model:)`），pattern 自動命中
>   `o3-mini`、`o4-preview`、未來 `o5` 等型號，不需每次更新程式碼。
>   逃生口：Azure 自定義部署名可用 `X-LLM-Reasoning: true` header override（未來實作，現在不需要）。
> - **tools 不支援時**：**兩者都做**——靜默省略 tools（XML fallback path 既有可接）＋
>   同時在 `LlmResponse#warnings` 加 `'tools_not_supported'`（零破壞、前端可選擇性顯示）。

### 受影響檔案

| 檔案 | 改動 |
|---|---|
| `app/infrastructure/llm/openai_client.rb` | 新增 `reasoning_model?` / `tools_supported?` helper；`send_prompt` 換 token key + 條件 tools |
| `spec/infrastructure/llm/openai_client_spec.rb` | 補：reasoning model 用 `max_completion_tokens`；不支援 tools 時 key 不出現在 payload |

---

## E2（🟠 中）：tool_call JSON parse 失敗靜默 drop

### 問題

[openai_client.rb:136-138](../app/infrastructure/llm/openai_client.rb#L136-L138)：

```ruby
args = JSON.parse(tc.dig('function', 'arguments') || '{}')
{ 'type' => name }.merge(args)
rescue JSON::ParserError
  nil        # ← 壞掉的 tool_call 直接變 nil、被 .compact 吞掉
end.compact
```

模型本來想做的動作（例如 `edit_file`）就這樣消失。
Service 層有 `FALLBACK_PROSE`（actions 空時補一句話），學生只看到
「我這次沒能自動處理」，**API 無法辨別是 schema 不相容還是模型判斷不行動**。

### 修正方案

**Option A（最小改動）：** parse 失敗時在 `LlmResponse` 上帶一個 `malformed_tool_calls` 計數，
service 在 `ok_outcome` 裡若 > 0 就加一個 `warnings` token（`tool_call_parse_error`）。

**Option B：** 保留壞掉的 entry，加 `{ 'type' => name, '__parse_error' => true }` 並在 gate 層過濾，
讓 parse 失敗可被 debug log 以外的路徑觀測。

**建議採 Option A**（最小侵入，沿用既有 warnings 機制）：

```ruby
# openai_client.rb parse()
parsed_calls, malformed_count = [], 0
Array(message['tool_calls']).each do |tc|
  name = tc.dig('function', 'name')
  args = JSON.parse(tc.dig('function', 'arguments') || '{}')
  parsed_calls << { 'type' => name }.merge(args)
rescue JSON::ParserError
  malformed_count += 1
end

LlmResponse.new(content: content, usage: usage, tool_calls: parsed_calls,
                rate_limit: rate_limit, malformed_tool_calls: malformed_count)
```

```ruby
# llm_response.rb：新增 malformed_tool_calls 欄（預設 0）
# run_tutor_chat.rb ok_outcome：若 reply.malformed_tool_calls.to_i > 0
#   warnings << 'tool_call_parse_error'
```

### 受影響檔案

| 檔案 | 改動 |
|---|---|
| `app/infrastructure/llm/llm_response.rb` | 新增 `malformed_tool_calls` 欄（keyword_init Struct，預設 0）|
| `app/infrastructure/llm/openai_client.rb` | 換成計數式 parse，把 count 送進 LlmResponse |
| `app/application/services/tutor_chat/run_tutor_chat.rb` | `warnings_for` 加 `tool_call_parse_error` 判斷 |
| `spec/infrastructure/llm/openai_client_spec.rb` | 補：壞 JSON arguments → `malformed_tool_calls == 1`，其餘 calls 保留 |
| `spec/application/services/run_tutor_chat_spec.rb` | 補：malformed_tool_calls > 0 → warnings 含 `tool_call_parse_error` |
| `doc/api_tutor_chats.md` | warnings 表加 `tool_call_parse_error` 一列 |

---

## E3（🟠 中）：沒帶 `strict: true` / `additionalProperties: false`

### 問題

OpenAI 要讓 function call 參數**可靠遵循 schema**，需在每個 tool 帶：
```json
{ "type": "function", "function": { ..., "strict": true },
  "parameters": { "additionalProperties": false, ... } }
```
現行 `openai_tools()` 把 `input_schema` 原封不動放進 `parameters`，**沒有補上 strict 旗標**，
所以 tool args 是 best-effort。`edit_file` 這種有巢狀 `patches` 陣列的 schema，
模型偶爾會吐格式不符的結果（patches 缺 start_line、search 帶 "N|" prefix 等——
雖然 `EditPatchNormalizer` 有接部分，但不應靠 normalizer 作為第一道防線）。

### 修正方案

在 `openai_tools()` 轉換時補上 strict mode；同時在 `input_schema` 遞迴加
`additionalProperties: false`（strict mode 的必要條件）：

```ruby
def openai_tools(tools)
  tools.map do |t|
    schema = deep_add_additional_properties(t[:input_schema] || t['input_schema'])
    {
      type: 'function',
      function: {
        name:        t[:name]        || t['name'],
        description: t[:description] || t['description'],
        parameters:  schema,
        strict:      true
      }
    }
  end
end

def deep_add_additional_properties(schema)
  return schema unless schema.is_a?(Hash)
  result = schema.transform_values { |v| deep_add_additional_properties(v) }
  result[:additionalProperties] = false if result[:type] == 'object' || result['type'] == 'object'
  result
end
```

> **注意（需驗證）：**
> - strict mode 要求**所有 `properties` 欄位都列進 `required`**；
>   `EDIT_FILE` 的 `patches` items 只有 `start_line/search/replace`，已 `required`；
>   `path` 也已 `required`。確認 `tutor_tools.rb` 所有 tool 均符合再開啟。
> - GitHub Models / Azure AI 是否完整支援 `strict: true` 需確認。
>   保守方案：用 ENV flag `LLM_TOOLS_STRICT` 控制是否加入（預設 off，確認後 default on）。

### 受影響檔案

| 檔案 | 改動 |
|---|---|
| `app/infrastructure/llm/openai_client.rb` | `openai_tools()` 補 `strict: true`；新增 `deep_add_additional_properties` helper |
| `app/domain/values/tutor_tools.rb` | 確認所有 tool 的 `required` 覆蓋所有 properties（目前應已覆蓋，需驗查） |
| `spec/infrastructure/llm/openai_client_spec.rb` | 補：送出的 payload 中 `tools[].function.strict == true`、`parameters.additionalProperties == false` |

---

## E4（🟡 低）：設計決策未記錄於 doc

以下三點寫進 `doc/` 或在各檔案 header comment 補齊（不需改功能程式碼）：

1. **Canonical schema 為 Anthropic 形狀的原因**（`input_schema` key）：現有 comment 只說
   「Convert from the shared Anthropic-schema format」，但沒解釋為什麼 canonical 選 Anthropic 而非 OpenAI。
   → 補：「因 Anthropic 原生格式更語意化（`input_schema` 明確），且 tool 定義本身不應綁
   任何單一 provider 的包裝格式；OpenAI 的 `parameters` 只是 wire 格式，在邊界轉換。」

2. **tool_choice 尚未支援**：若要「強制呼叫某 tool」，
   OpenAI 是 `{type:"function",function:{name}}`、Anthropic 是 `{type:"tool",name}`；
   兩者格式不同，現有 adapter 沒有這層轉換。`LlmClient` 的 `send_prompt` 介面無 `tool_choice` 參數。
   → 補 doc 說明此天花板。

3. **多輪 tool 續傳（agentic loop）的天花板**：兩 client 都丟棄 `tool_call_id`（`run_tutor_chat.rb:22`
   已有 comment）。mini-loop 用「重組 prompt」代替真正的 `tool_result` 續傳，
   有意識地捨棄 agentic loop 擴展性以換取簡單性。
   → 補 doc 說明：擴成真 agent loop 需 (a) assistant `tool_calls` 回填 + (b) `tool` role message (OpenAI) /
   `tool_result` block (Anthropic)，需做雙路徑 adapter。

### 受影響檔案

| 檔案 | 改動 |
|---|---|
| `app/infrastructure/llm/llm_client.rb` | header comment 補 canonical schema 說明 |
| `app/infrastructure/llm/openai_client.rb` | `openai_tools` comment 補「為何選 Anthropic canonical」 |
| `doc/api_tutor_chats.md` | 補「LLM client 限制」段：tool_choice 未支援 / agentic 天花板 |

---

## 邊界與取捨（此次不做）

- **Anthropic 400-too-large**：Anthropic 對 context 過大回 400 `invalid_request_error`（非 413）；
  現有 `raise_if_input_too_large` 對 Anthropic 是 no-op。本案不處理（同 plan D §9 決策）。
- **per-model token cap 表**：token_budget.rb 對所有 GitHub Models 一律 8K；
  gpt-4.1=16K / o1-mini=4K 的偏差已由 provider-real 413（plan D）作為安全網，本案不填。
- **system role 轉換**（DeepSeek-R1 不建議用 system）：先保守不轉換，觀察是否真的有學生用
  DeepSeek 且出問題；若有，再補一個 per-model system-role 處理 hook。
- **Azure AI envelope 變動**：GitHub Models 的 error body 格式（`tokens_limit_reached`）
  非 OpenAI 官方 contract，plan D 的防禦式解析已 cover；本案不另建 schema validation。

---

## 落地順序建議

```
優先一（本週）：E1 — 避免 reasoning models 整個 turn 直接失敗（最高 ROI）
優先二（本週）：E2 — tool parse 失敗可觀測性（小改、可與 E1 同 PR）
優先三（下週）：E3 — strict mode（需先驗查 tutor_tools.rb required 覆蓋 + GitHub 相容性）
優先四（文件）：E4 — doc 補齊（最後、不阻塞功能）
```

**E1 + E2 可合成一個 PR**（都改 openai_client.rb + 對應 spec）；
**E3 獨立一個 PR**（改動 helper 較侵入，需獨立 review）；
**E4 獨立 doc PR**（零功能風險，可隨時合）。

---

## 落地 Checklist

### E1：Reasoning model `max_tokens` / tools 相容性

- [x] **已拍板**：`REASONING_MODEL_PATTERN = /\Ao[1-9]|gpt-5|deepseek-r1/i` regex（非固定清單，自動 future-proof；o3-mini、o4-preview 等自動命中）
- [x] **已拍板**：tools 不支援時靜默省略 ＋ 同時在 `LlmResponse#warnings` 加 `'tools_not_supported'`（零破壞、前端可觀測）
- [ ] `openai_client.rb`：新增 `REASONING_MODEL_PATTERN` 常數（regex）
- [ ] `openai_client.rb`：新增 `reasoning_model?` private helper（`REASONING_MODEL_PATTERN.match?(@model.to_s)`）
- [ ] `openai_client.rb`：新增 `tools_supported?` private helper（reasoning models 預設 false，deepseek-r1-0528 例外）
- [ ] `openai_client.rb`：`send_prompt` 改用 `tokens_key`（`max_tokens` vs `max_completion_tokens`）
- [ ] `openai_client.rb`：tools 不支援時省略 `payload[:tools]`，並將 `'tools_not_supported'` 加進 warnings 後傳入 `LlmResponse`
- [ ] `spec/infrastructure/llm/openai_client_spec.rb`：reasoning model（model 名含 "o3-mini"）→ payload 有 `max_completion_tokens` 無 `max_tokens`
- [ ] `spec/infrastructure/llm/openai_client_spec.rb`：non-reasoning model → payload 有 `max_tokens` 無 `max_completion_tokens`
- [ ] `spec/infrastructure/llm/openai_client_spec.rb`：deepseek-r1 model → `payload['tools']` 不存在，且 `resp.warnings` 含 `'tools_not_supported'`
- [ ] `spec/infrastructure/llm/openai_client_spec.rb`：deepseek-r1-0528 → tools 有送、warnings 無 `'tools_not_supported'`
- [ ] `bundle exec rake test` 全綠

### E2：tool_call JSON parse 失敗可觀測性

- [ ] `llm_response.rb`：Struct 加 `malformed_tool_calls`（預設 0，`keyword_init: true` 無破壞性）
- [ ] `openai_client.rb`：`parse()` 改為計數式 parse（`malformed_count` 累積、`parsed_calls` 收集）
- [ ] `openai_client.rb`：`LlmResponse.new(...)` 帶入 `malformed_tool_calls: malformed_count`
- [ ] `run_tutor_chat.rb`：`warnings_for` 加 `warnings << 'tool_call_parse_error' if reply.malformed_tool_calls.to_i > 0`
- [ ] `spec/infrastructure/llm/openai_client_spec.rb`：壞 JSON arguments → `resp.malformed_tool_calls == 1`，其餘 valid calls 仍在 `resp.tool_calls`
- [ ] `spec/application/services/run_tutor_chat_spec.rb`：mock LlmResponse 帶 `malformed_tool_calls: 1` → `warnings` 含 `'tool_call_parse_error'`
- [ ] `doc/api_tutor_chats.md`：warnings 表加 `tool_call_parse_error` 列（含語意：哪類模型/情況易發生）
- [ ] `bundle exec rake test` 全綠

### E3：OpenAI strict mode / additionalProperties

- [ ] **前置確認**：`tutor_tools.rb` 所有 4 個 tool 的 `input_schema` → `required` 確實覆蓋所有頂層 properties（逐一 grep 驗查）
- [ ] **前置確認**：`patches` items 的 nested `required: %w[start_line search replace]` 覆蓋所有子 properties
- [ ] **前置確認**：GitHub Models（Azure AI Inference）是否支援 `strict: true`（查文件 or 實測一發）
- [ ] `openai_client.rb`：`openai_tools()` 加 `strict: true` 在 `function:` 層
- [ ] `openai_client.rb`：新增 `deep_add_additional_properties(schema)` helper（遞迴補 `additionalProperties: false`）
- [ ] `openai_client.rb`：`openai_tools()` 改用 deep_add_additional_properties 後的 schema
- [ ] （選配）`ENV['LLM_TOOLS_STRICT']` flag 控制是否啟用（若 GitHub 相容性不確定）
- [ ] `spec/infrastructure/llm/openai_client_spec.rb`：`tools[0].function.strict == true`
- [ ] `spec/infrastructure/llm/openai_client_spec.rb`：`tools[0].function.parameters['additionalProperties'] == false`
- [ ] `spec/infrastructure/llm/openai_client_spec.rb`：巢狀 object（patches items）也有 `additionalProperties: false`
- [ ] `bundle exec rake test` 全綠

### E4：Doc 補齊

- [ ] `llm_client.rb` header comment：補 canonical schema = Anthropic 形狀的設計原因
- [ ] `openai_client.rb` `openai_tools` comment：補「為何選 Anthropic-canonical 而非 OpenAI-canonical」
- [ ] `doc/api_tutor_chats.md`：新增「LLM client 限制」段，說明：
  - [ ] `tool_choice` 尚未支援（兩家格式不同，adapter 無此層）
  - [ ] 多輪 tool 續傳（agentic loop）天花板：丟棄 `tool_call_id`、用重組 prompt 代替
  - [ ] Reasoning models（o1/o3/DeepSeek-R1）的行為差異說明
  - [ ] Azure AI Inference envelope 非 OpenAI 官方 contract 的假設邊界警語
