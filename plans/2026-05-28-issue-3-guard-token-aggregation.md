# Plan — Issue 3 (Backend slice): Guard-Token Aggregation in `usage` Field

> **Date:** 2026-05-28
> **Status:** DRAFT v1 — open discussion items in §3, ready to execute once resolved
> **Parent decision:** [`2026-05-27-meeting-decisions.md`](./2026-05-27-meeting-decisions.md) §Issue 3
> **Scope (this PR):** Only the `Tyla-api` repo. The TUI work (`MindyCLI_demo/tyla` — gateway validation, event-mapper, `StatusBar.tsx`) is tracked separately and is **out of scope** for this plan.
> **Builds on:** Issue 1 (`status` field, representer, `usage` key on every 2xx body) — already shipped on `main`.

---

## 0. Goal in one sentence

Make the `usage` field on every 2xx `/api/v1/tutor_chats` response report the **sum of guard-LLM + tutor-LLM token counts** for that turn, including the `forbidden` branch (which today returns `usage: null`).

After this PR:

| Status        | `usage` semantics                              | nil ever? |
|---------------|------------------------------------------------|-----------|
| `done`        | guard tokens **+** tutor tokens                | no        |
| `forbidden`   | guard tokens only (tutor never called)         | no        |
| `unavailable` | tutor tokens only (guard fail-open ⇒ unknown†) | no        |
| `error` (non-2xx) | field absent (error envelope, not `Response::TutorChat`) | n/a |

† Edge case: when the guard LLM *responded* but the JSON was malformed, we **do** know its usage and should include it. See §3 / O1.

---

## 1. Verified state of the code today (commit `a3c9a37`)

| Claim from parent doc                                                                                    | Verified? | Notes                                                                                                                                                                                          |
|----------------------------------------------------------------------------------------------------------|-----------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `GuardResult` carries only `probability` and `reason`                                                    | ✓ matches | [guard_result.rb:5-21](../app/domain/values/guard_result.rb#L5-L21) — `attr_reader :reason, :probability`; no `usage`.                                                                          |
| `GuardAgent.check` discards `response.usage`                                                             | ✓ matches | [guard_agent.rb:12-28](../app/application/services/guard/guard_agent.rb#L12-L28) — the `response` is bound, but only `response.content` is used; `response.usage` is never referenced.         |
| `LlmResponse` already has a `usage` field on **every** call (guard + tutor)                              | ✓ matches | [llm_response.rb:5](../app/infrastructure/llm/llm_response.rb#L5) — `Data.define(:content, :usage)`. Both `OpenAiClient#parse` and `AnthropicClient#parse` populate it.                          |
| `RunTutorChat#build_forbidden_response` hard-codes `usage: nil`                                          | ✓ matches | [run_tutor_chat.rb:91-98](../app/application/services/tutor_chat/run_tutor_chat.rb#L91-L98).                                                                                                    |
| `RunTutorChat#build_ok_response` passes through `llm_reply.usage` unchanged (tutor-only)                 | ✓ matches | [run_tutor_chat.rb:100-107](../app/application/services/tutor_chat/run_tutor_chat.rb#L100-L107) — does not consult `guard_result`.                                                              |
| Representer keeps `usage` key with `render_nil: true`                                                    | ✓ matches | [tutor_chat_representer.rb:18](../app/presentation/representers/tutor_chat_representer.rb#L18).                                                                                                 |
| Doc states "`usage` is `null` on `forbidden`"                                                            | ✓ matches | [api_tutor_chats.md:124](../doc/api_tutor_chats.md#L124) and the worked example at [api_tutor_chats.md:138-145](../doc/api_tutor_chats.md#L138-L145).                                            |
| Representer spec asserts `usage` is nil on `forbidden`                                                   | ✓ matches | [tutor_chat_representer_spec.rb:29-38](../spec/presentation/representers/tutor_chat_representer_spec.rb#L29-L38) and the JSON round-trip at [L54-L60](../spec/presentation/representers/tutor_chat_representer_spec.rb#L54-L60). |
| `run_tutor_chat_spec.rb` asserts `dto.usage` is nil on the `forbidden` branch                            | ✓ matches | [run_tutor_chat_spec.rb:150](../spec/application/services/run_tutor_chat_spec.rb#L150).                                                                                                         |
| Guard mock in `run_tutor_chat_spec.rb` returns `usage: {}` (empty hash) for the guard call               | ✓ matches | [run_tutor_chat_spec.rb:66](../spec/application/services/run_tutor_chat_spec.rb#L66) — important: today's spec passes a non-nil empty hash through; we need to decide how the sum handles it.   |
| Real OpenAI / Anthropic clients populate `{ input_tokens:, output_tokens: }`                             | ✓ matches | [openai_client.rb:60-63](../app/infrastructure/llm/openai_client.rb#L60-L63), [anthropic_client.rb:65-68](../app/infrastructure/llm/anthropic_client.rb#L65-L68).                                  |

### Extra findings not in the parent doc

**F1.** The `GuardAgent` rescue block at [guard_agent.rb:25-27](../app/application/services/guard/guard_agent.rb#L25-L27) catches **all** `StandardError`, which means a successful LLM call followed by `JSON.parse` failure (the "guard LLM gave us garbage" case) **loses the usage** we already received. The parent doc treats `unavailable` ⇒ "guard usage unknown" as a blanket rule; reality is more nuanced — see §3 / O1.

**F2.** The current spec's `scripted_llm` returns `usage: {}` (an *empty* hash) for the guard call. After this change the `tutor_usage: { input_tokens: 10, output_tokens: 5 }` test will start emitting `dto.usage[:input_tokens]` = `10` (sum of `nil + 10`) — which means the existing assertion at [run_tutor_chat_spec.rb:129](../spec/application/services/run_tutor_chat_spec.rb#L129) (`must_equal 10`) is *accidentally still correct* only if our sum helper treats nil as 0. Worth pinning explicitly in a spec (see §5).

**F3.** The `dry-monads` flow in `RunTutorChat#call` is already long; introducing a `usage_sum` helper is the cleanest landing spot. A new value object (`Values::TokenUsage`) is tempting but probably overkill — see §3 / O2.

---

## 2. Design — the minimal change set

### 2.1 `Domain::Values::GuardResult` — add `usage`

[`app/domain/values/guard_result.rb`](../app/domain/values/guard_result.rb)

```ruby
module Tyla
  module Values
    class GuardResult
      attr_reader :reason, :probability, :usage   # ← + :usage

      def initialize(allowed: nil, reason:, probability: nil, usage: nil)  # ← + usage:
        @allowed     = allowed
        @reason      = reason
        @probability = probability
        @usage       = usage                       # ← +
      end

      def allowed?
        if @probability
          Values::AttackPolicy.allowed?(@probability[:attack])
        else
          @allowed
        end
      end
    end
  end
end
```

Semantics of `usage`:
- `nil` ⇒ guard call never produced a usable LLM response (network failure, timeout — the only branches where we genuinely don't know).
- Hash `{ input_tokens:, output_tokens: }` ⇒ guard LLM responded; tokens are known even when the verdict JSON was malformed (see O1).

### 2.2 `Services::GuardAgent` — capture usage, even on JSON parse failure

[`app/application/services/guard/guard_agent.rb`](../app/application/services/guard/guard_agent.rb)

Restructure so the `LlmResponse` is bound **before** the parsing block — so when `JSON.parse` raises, we still have the usage in hand.

```ruby
def check(prompt:, mode:)
  response = @llm.send_prompt(
    system_prompt: Prompts::JudgeSystemPrompt.build,
    user_message:  prompt
  )

  begin
    parsed      = JSON.parse(response.content)
    attack_prob = Float(parsed.fetch('attack-probability'))
    evaluation  = parsed.fetch('evaluation')

    Values::GuardResult.new(
      reason:      evaluation,
      probability: { attack: attack_prob },
      usage:       response.usage
    )
  rescue StandardError => e
    warn "[GuardAgent] judge reply unparseable (#{e.class}): #{e.message}"
    Values::GuardResult.new(
      allowed: true,
      reason:  "llm-judge unavailable: #{e.class}",
      usage:   response.usage     # ← we DID get a response; keep its tokens
    )
  end
rescue StandardError => e
  warn "[GuardAgent] judge unavailable (#{e.class}): #{e.message}"
  Values::GuardResult.new(allowed: true, reason: "llm-judge unavailable: #{e.class}")
  # No usage — the network call itself failed
end
```

Why the split rescue: the **outer** `rescue` catches network / `LlmError` raised by `@llm.send_prompt` (truly no usage). The **inner** `rescue` catches `JSON::ParserError`, `KeyError`, `ArgumentError` from `Float(...)` — we *did* talk to the LLM, so we should keep its usage.

**Discussion point** — see §3 / O1.

### 2.3 `Services::RunTutorChat` — sum the two usages

[`app/application/services/tutor_chat/run_tutor_chat.rb`](../app/application/services/tutor_chat/run_tutor_chat.rb)

Two places to touch:

**(a) `build_forbidden_response` — pass guard usage through (drop the `nil`):**

```ruby
if !llm_unavailable && !guard_result.allowed?
  return Success([:forbidden, build_forbidden_response(log.id, params[:project_id], guard_result.usage)])
end
…
def build_forbidden_response(log_id, project_id, guard_usage)
  Response::TutorChat.new(
    log_id:  log_id,
    status:  'forbidden',
    content: Infrastructure::Filesystem::RefusalLoader.load(project_id),
    usage:   guard_usage    # nil only if guard network-failed before deciding `forbidden`
                            # — but that branch is fail-open ⇒ `unavailable`, not `forbidden`,
                            #   so in practice this is always non-nil here.
  )
end
```

**(b) `build_ok_response` — fold guard usage in:**

```ruby
response = build_ok_response(log.id, llm_reply, guard_result, llm_unavailable: llm_unavailable)
…
def build_ok_response(log_id, llm_reply, guard_result, llm_unavailable:)
  Response::TutorChat.new(
    log_id:  log_id,
    status:  llm_unavailable ? 'unavailable' : 'done',
    content: llm_reply.content,
    usage:   usage_sum(guard_result.usage, llm_reply.usage)
  )
end

# Treats nil and missing keys as 0. Returns a hash with both keys
# always present, even if both sides were nil ({ input_tokens: 0, output_tokens: 0 }).
def usage_sum(a, b)
  a ||= {}
  b ||= {}
  {
    input_tokens:  (a[:input_tokens]  || 0) + (b[:input_tokens]  || 0),
    output_tokens: (a[:output_tokens] || 0) + (b[:output_tokens] || 0)
  }
end
```

**Discussion point** — see §3 / O3 on whether `{0, 0}` is preferable to `nil` when both inputs are nil. My recommendation: yes — uniform shape is the whole point of this change.

### 2.4 Representer + DTO — no structural change

[`tutor_chat_representer.rb`](../app/presentation/representers/tutor_chat_representer.rb) — leave `property :usage, render_nil: true` exactly as-is. After this PR, no 2xx path produces `nil`, but `render_nil: true` is a cheap belt-and-braces: if some future edge case slips through, the key remains in the response (matches the "every 2xx response carries `usage`" contract).

`Response::TutorChat` — unchanged. The `usage` slot in the `Data.define` already accepts hash *or* nil.

### 2.5 Doc update — `doc/api_tutor_chats.md`

Two surgical edits:

1. **Tutor reply (`done`) example** at [api_tutor_chats.md:108-117](../doc/api_tutor_chats.md#L108-L117): clarify that `usage` is the **combined guard + tutor** count.

2. **Prompt blocked (`forbidden`) example** at [api_tutor_chats.md:132-145](../doc/api_tutor_chats.md#L132-L145): replace `"usage": null` with the guard-only shape and update the field-table row at [L124](../doc/api_tutor_chats.md#L124) to read:

   > | `usage` | object | Combined token counts for this turn: guard + tutor on `done` / `unavailable`; guard-only on `forbidden`. Always present on 2xx responses. |

3. The `unavailable` example at [api_tutor_chats.md:159-166](../doc/api_tutor_chats.md#L159-L166) is already correct in shape; add a one-line note: *"`usage` reflects tutor tokens only — guard usage is unknown when the guard call fails before responding. If the guard LLM did respond but the verdict was malformed, guard tokens are included."*

---

## 3. Open discussion items (please confirm before I execute)

### O1. Should we preserve guard-LLM usage when the verdict JSON is malformed?

**The case:** Guard LLM returns `HTTP 200` with body `"not-json-at-all"` (the existing fail-open test fixture at [run_tutor_chat_spec.rb:155](../spec/application/services/run_tutor_chat_spec.rb#L155)). Today this maps to `:unavailable`, and per the parent doc "guard usage unknown on `unavailable`". But in reality we do know it — we paid the tokens.

- **Option A (Plan §2.2 above):** Preserve usage on JSON-parse failure; sum with tutor in `unavailable` branch.
  - Pro: most accurate. Students see the real cost of the turn.
  - Pro: trivial to implement (just split the rescue, three extra lines).
  - Con: contradicts the parent doc's simple "unavailable ⇒ tutor-only" rule.

- **Option B:** Always treat `unavailable` as "guard usage unknown" — drop guard usage even when we have it.
  - Pro: simpler invariant; matches the parent doc verbatim.
  - Con: under-reports token consumption.

**My recommendation:** **Option A.** The whole point of this issue is honest cost reporting; throwing away known usage to keep a one-line invariant is the wrong trade.

### O2. Introduce a `Values::TokenUsage` value object, or keep the `{ input_tokens:, output_tokens: }` hash convention?

Currently `usage` is a duck-typed hash flowing through `LlmResponse → GuardResult → Response::TutorChat → Representer`. A value object would:

- Encapsulate the `+` operation (replacing `usage_sum`).
- Make the "missing key = 0" policy a single property of the type rather than scattered defaults.
- Give us a natural spot for the runtime validation the TUI side wants (non-negative ints, sane upper bound) — though that validation is **TUI-side** per the parent doc, so the backend doesn't strictly need it.

**My recommendation:** **Skip for now.** It's three call sites and one sum operation; a value object adds ceremony without earning its keep. Revisit if a third caller of `usage_sum` shows up, or if we add server-side validation.

### O3. When both guard and tutor usage are nil, should `usage` be `{ input_tokens: 0, output_tokens: 0 }` or `nil`?

The only realistic path: guard fail-open + tutor LLM somehow returns nil usage (shouldn't happen with the real clients, but the spec stubs do it).

- **Option A:** `{ input_tokens: 0, output_tokens: 0 }` — uniform shape, key always populated.
- **Option B:** `nil` — honest "we don't know".

**My recommendation:** **Option A.** Matches the "every 2xx response carries `usage`" promise we're trying to lock down; clients (TUI included) can render `0 in / 0 out` without special-casing. Document that `0/0` on `unavailable` means "guard failed, tutor returned no token info".

### O4. Update `evaluation` reason string when guard verdict parsing fails?

Cosmetic, but the new inner-rescue path will emit `"llm-judge unavailable: JSON::ParserError"` rather than the previous `"llm-judge unavailable: JSON::ParserError"` — actually identical because both `JSON.parse` and a network failure raise `StandardError` and we already use `e.class` in the message. The string written to `prompt_logs.evaluation` won't change. ✓ No discussion needed; flagged so reviewers don't get surprised.

### O5. Should `GuardAgent.check` start returning a richer struct (e.g. `usage` and `raw_response`)?

Out of scope — adding `:usage` to `GuardResult` is enough for this PR. Calling that out so we don't slip into a bigger refactor.

---

## 4. File-level change summary

| # | File                                                                                           | Change                                                                                                              | Lines (current) |
|---|------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------|------------------|
| 1 | [`app/domain/values/guard_result.rb`](../app/domain/values/guard_result.rb)                    | Add `usage` attr + ctor kwarg                                                                                       | 5-21              |
| 2 | [`app/application/services/guard/guard_agent.rb`](../app/application/services/guard/guard_agent.rb) | Split rescues; pass `response.usage` into the happy and JSON-parse-fail paths                                       | 12-28             |
| 3 | [`app/application/services/tutor_chat/run_tutor_chat.rb`](../app/application/services/tutor_chat/run_tutor_chat.rb) | `build_forbidden_response` takes guard usage; `build_ok_response` takes `guard_result` and sums; private `usage_sum` helper | 39-40, 91-107 |
| 4 | [`doc/api_tutor_chats.md`](../doc/api_tutor_chats.md)                                          | Update `usage` field-table row, `done`/`forbidden`/`unavailable` examples + one note paragraph                       | 108-166           |
| 5 | [`spec/application/services/guard_agent_spec.rb`](../spec/application/services/guard_agent_spec.rb) | New cases: usage propagated on success; usage propagated on JSON-parse failure; usage nil on network failure         | append            |
| 6 | [`spec/application/services/run_tutor_chat_spec.rb`](../spec/application/services/run_tutor_chat_spec.rb) | Update `done` assertion (sum); update `forbidden` assertion (guard-only, no longer nil); update `unavailable` assertion (Option A behaviour) | 120-163 |
| 7 | [`spec/presentation/representers/tutor_chat_representer_spec.rb`](../spec/presentation/representers/tutor_chat_representer_spec.rb) | Replace the "usage is nil on forbidden" test with a positive case; drop the JSON-null round-trip                  | 29-38, 54-60      |

**No change** to:
- `LlmResponse` (already has `usage`).
- `Representer::TutorChat` (already emits `usage` with `render_nil: true`).
- Route / controller wiring at [`app/application/controllers/api.rb`](../app/application/controllers/api.rb).
- `PromptLog` persistence — guard usage is **not** written to DB (per parent doc Q2: token counts stay request-scoped).
- Any LLM client (`OpenAiClient`, `AnthropicClient`, `LlmClient`).

---

## 5. Test plan (Minitest)

### 5.1 `guard_agent_spec.rb` — three new cases

```ruby
it 'propagates usage from the guard LLM on the happy path' do
  client = stub_llm_with_usage(
    { 'attack-probability' => 0.1, 'evaluation' => 'ok' }.to_json,
    { input_tokens: 80, output_tokens: 12 }
  )
  result = GuardAgent.new(llm_client: client).check(prompt: 'hi', mode: nil)
  _(result.usage).must_equal(input_tokens: 80, output_tokens: 12)
end

it 'preserves usage when the verdict JSON is malformed' do
  client = stub_llm_with_usage('not-json', { input_tokens: 60, output_tokens: 4 })
  result = GuardAgent.new(llm_client: client).check(prompt: 'hi', mode: nil)
  _(result.allowed?).must_equal true            # fail-open
  _(result.usage).must_equal(input_tokens: 60, output_tokens: 4)
end

it 'returns nil usage when the guard LLM call itself raises' do
  agent  = GuardAgent.new(llm_client: raising_llm(RuntimeError, 'connection refused'))
  result = agent.check(prompt: 'hi', mode: nil)
  _(result.usage).must_be_nil
end
```

(`stub_llm_with_usage` = trivial variant of the existing `stub_llm` helper.)

### 5.2 `run_tutor_chat_spec.rb` — adjust three cases, add one

```ruby
# Adjust scripted_llm so the GUARD call also returns a known usage (currently empty {})
def scripted_llm(verdict:, tutor_content: 'tutor reply',
                 guard_usage: { input_tokens: 50, output_tokens: 8 },
                 tutor_usage: { input_tokens: 10, output_tokens: 5 })
  …
  Infrastructure::LlmResponse.new(content: verdict.to_json, usage: guard_usage)
  …
end

it 'allowed path: dto.usage is the sum of guard + tutor tokens' do
  # ... (existing happy path)
  _(dto.usage[:input_tokens]).must_equal  60   # 50 + 10
  _(dto.usage[:output_tokens]).must_equal 13   # 8 + 5
end

it 'forbidden path: dto.usage reflects guard tokens only (no longer nil)' do
  # ... (existing forbidden path)
  _(dto.usage).must_equal(input_tokens: 50, output_tokens: 8)
end

it 'unavailable path: dto.usage sums guard + tutor when the guard LLM responded with garbage' do
  # Option A behaviour — see §3 / O1
  client  = scripted_llm(verdict: 'not-json-at-all', tutor_content: 'fallback')
  outcome = call_with(llm_client: client)
  _, dto  = outcome.value!
  _(dto.status).must_equal 'unavailable'
  _(dto.usage[:input_tokens]).must_equal 60    # guard 50 + tutor 10
end

it 'unavailable path: dto.usage reflects tutor only when the guard call itself raised' do
  # Need a new helper: guard call raises before producing LlmResponse
  client  = raising_guard_then_tutor
  outcome = call_with(llm_client: client)
  _, dto  = outcome.value!
  _(dto.usage[:input_tokens]).must_equal 10    # tutor only; guard usage nil
end
```

### 5.3 `tutor_chat_representer_spec.rb` — flip the forbidden case

```ruby
it 'emits a non-null usage on a forbidden DTO (guard-only tokens)' do
  dto = build_dto(
    status:  'forbidden',
    content: "Let's redirect...",
    usage:   { input_tokens: 80, output_tokens: 12 }
  )
  payload = Tyla::Representer::TutorChat.new(dto).to_hash
  _(payload['usage'][:input_tokens]).must_equal 80
end

# Drop the JSON-null round-trip test (L54-L60) — no production path produces it now.
```

### 5.4 Manual smoke test (optional)

Run `bundle exec rerun rackup` and POST the existing dev fixture; eyeball the `usage` field on `done` to confirm it's strictly larger than the tutor's reported count (i.e. guard contribution is non-zero).

---

## 6. Risks & non-issues

- **Backwards compatibility:** The TUI gateway today does `data.usage?.input_tokens ?? 0` and special-cases `forbidden` to drop usage. After our change, the same gateway code keeps working — it'll just start receiving non-zero numbers on forbidden replies. The TUI-side cleanup (drop the special case) is tracked in the parent doc and is **not** required for this PR to ship.

- **`prompt_logs` schema:** Untouched. Per parent doc Q2, token counts are request-scoped and explicitly not persisted.

- **Cost-double-counting concern:** None. Guard and tutor are two physical LLM calls; the sum is the actual cost.

- **Spec brittleness:** The change to `scripted_llm`'s default `guard_usage` is the main risk — any other test that relied on the implicit `{}` will need a sweep. Grep `scripted_llm` before final PR.

---

## 7. Out of scope (explicit non-goals)

- Anything in `MindyCLI_demo/tyla` (TUI repo). The parent doc has a separate TODO list for that work; this plan deliberately does **not** touch the contract beyond what's documented in `api_tutor_chats.md`.
- Server-side input validation on `usage` (non-negative ints, upper bound). That validation lives on the TUI gateway per parent doc §Issue 3 finding 4.
- Adding `Values::TokenUsage`. See §3 / O2.
- Logging tokens to `prompt_logs`. See parent doc Q2.

---

## 8. Execution checklist (after O1–O3 are confirmed)

- [ ] Edit `guard_result.rb` — add `usage` (kwarg + reader).
- [ ] Edit `guard_agent.rb` — split rescues, pass `response.usage` on both happy + parse-fail paths.
- [ ] Edit `run_tutor_chat.rb` — refactor `build_forbidden_response` / `build_ok_response`; add `usage_sum`.
- [ ] Edit `doc/api_tutor_chats.md` — update field-table row + three examples.
- [ ] Update `guard_agent_spec.rb` — three new cases.
- [ ] Update `run_tutor_chat_spec.rb` — adjust three cases, add the "guard call raised" case.
- [ ] Update `tutor_chat_representer_spec.rb` — flip the forbidden case, drop the JSON-null round-trip.
- [ ] `bundle exec rake test` — green.
- [ ] Manual POST to the dev server, confirm `done.usage` is the sum.
- [ ] Open PR; reference parent doc §Issue 3.
