# Token Budget Algorithm — Sub-plan for Issue 2

> **Date:** 2026-05-28
> **Parent plan:** [2026-05-27-meeting-decisions.md](2026-05-27-meeting-decisions.md) §Issue 2
> **Scope:** Replace fixed-cutoff trimming (`MAX_HISTORY_TURNS = 10`, `MAX_FILE_LINES = 200`)
> with a budget-aware algorithm that owns all LLM-input trimming on the backend.

---

## 1. Feasibility assessment

### What already exists (assets we can reuse)

| Asset | Location | Reusable for token budget? |
|---|---|---|
| `Prompts::TutorSystemPrompt.build` | [tutor_system_prompt.rb:6-16](../app/application/prompts/builders/tutor_system_prompt.rb#L6-L16) | ✅ Keeps responsibility for **composing**; we change only what it receives. |
| `Prompts::TutorSystemPrompt.truncate_history` | [tutor_system_prompt.rb:18-23](../app/application/prompts/builders/tutor_system_prompt.rb#L18-L23) | ❌ Replace — turn-count cutoff is the wrong shape. |
| `Prompts::TutorSystemPrompt.format_file` per-file truncation | [tutor_system_prompt.rb:25-33](../app/application/prompts/builders/tutor_system_prompt.rb#L25-L33) | ❌ Replace — per-file line cap is not budget-aware. |
| `Values::PayloadLimits` | [payload_limits.rb:5-12](../app/domain/values/payload_limits.rb#L5-L12) | ⚠️ Demote `MAX_HISTORY_TURNS` and `MAX_FILE_LINES`; keep byte caps as transport-layer safety. |
| OpenAI / Anthropic clients accept `model:` | [openai_client.rb:13-19](../app/infrastructure/llm/openai_client.rb#L13-L19), [anthropic_client.rb:13-20](../app/infrastructure/llm/anthropic_client.rb#L13-L20) | ✅ Model is already known per request — we can key the budget table off it. |
| `usage.input_tokens` returned by both clients | [openai_client.rb:59-62](../app/infrastructure/llm/openai_client.rb#L59-L62), [anthropic_client.rb:65-68](../app/infrastructure/llm/anthropic_client.rb#L65-L68) | ❌ Post-call only — useless for pre-call budgeting; still useful for calibrating our heuristic. |
| Loaders for the four "always-loaded" artefacts | [student_file_loader.rb](../app/infrastructure/filesystem/tutor_chat/student_file_loader.rb), `tutor_persona_loader.rb`, `assignment_loader.rb`, `solution_loader.rb` | ✅ All return plain strings — easy to measure before composition. |

### What's missing (gaps confirmed by code reading)

1. **No tokenizer of any kind.** Gemfile carries no `tiktoken_ruby`, no `tokenizers`, nothing
   that approximates an LLM tokenizer ([Gemfile:1-63](../Gemfile#L1-L63)).
2. **No per-model context-window table.** `OpenAiClient::DEFAULT_MODEL = 'gpt-4o-mini'`
   and `AnthropicClient::DEFAULT_MODEL = 'claude-sonnet-4-6'` are the only model
   constants in the codebase.
3. **Legacy orchestration path is dead code.**
   `HandleTutorChat` → `TutorOrchestrator` exists in
   [handle_tutor_chat.rb](../app/application/services/tutor_chat/handle_tutor_chat.rb) and
   [tutor_orchestrator.rb](../app/application/services/tutor_chat/tutor_orchestrator.rb),
   but **no controller calls `HandleTutorChat`** — verified by grep across `app/`
   and `config/`. The only callers are the two spec files. This path also still
   uses the old `truncate_history` at [tutor_orchestrator.rb:26](../app/application/services/tutor_chat/tutor_orchestrator.rb#L26)
   and ships an obsolete status vocabulary (`ok`/`refused`, pre-Issue-1).
   **Decision (this plan):** delete the legacy path entirely instead of
   maintaining two parallel prompt-assembly paths.
4. **`Request::TutorChat` duplicates `MAX_HISTORY_BYTES`.** A literal `500_000`
   lives at [tutor_chat.rb:9](../app/application/requests/tutor_chat.rb#L9) instead of
   referencing `Values::PayloadLimits::MAX_HISTORY_BYTES` (`512_000`). Pre-existing
   inconsistency; flagging because the new plan touches the same area.

### Verdict

Feasible with **moderate scope**. The cleanest cut is:

- One new domain value object (per-model budget table).
- One new application service (budget-aware assembler) that absorbs both the
  history trimmer and the student-file dropper.
- **One** service call site (`RunTutorChat`) updated to call the new assembler.
- The old `truncate_history` and `format_file`-with-line-cap behaviours deleted.
- Legacy `HandleTutorChat` / `TutorOrchestrator` path deleted along with its
  unique dependencies (`RateLimiter`, `PolicyLoader`, `SolutionLoader.load_stub`,
  `TutorChatInput`, `TutorChatResult`).

No native dependencies, no schema changes, no migration concerns.

---

## 2. Tokenizer choice (blocker resolution)

**Decision: character-count heuristic for v1, behind a `Domain::Tokenizer` seam.**

| Option | Pro | Con | Verdict |
|---|---|---|---|
| `chars / 4` heuristic | Zero dependencies; works in Windows/Linux/macOS; instant; deterministic in tests. | Underestimates CJK / code (~2.5 chars/token); overestimates whitespace-heavy English. | ✅ v1 — fast to ship, behind a seam so v2 can swap in. |
| `tiktoken_ruby` | Accurate for OpenAI BPE; matches `usage.input_tokens` within ~1 %. | Native extension; build complications on Windows (our dev env is win32); only covers OpenAI families. | ❌ v1; reconsider once we have logged drift data. |
| `tokenizers` (HF) | Universal. | ~50 MB on disk; loads model files; overkill. | ❌ |

**Calibration plan:** every reply already carries `usage.input_tokens`. If
drift is suspected post-deploy, drop a temporary `warn` line emitting
`estimated / usage.input_tokens` and grep a sample of logs — **no DB columns,
no permanent structured logging**. Revisit `CHARS_PER_TOKEN` (currently **3.5**,
slightly over-reserving for mixed English + CJK + R code) once data is in hand.

> **Why a seam matters:** if we hard-code `text.length / 4` into
> `BudgetAwarePromptAssembler`, swapping to `tiktoken` later means changing
> every call site. A `Tokenizer.estimate(text, model:)` indirection costs one
> file and isolates the change.

---

## 3. Budget source — per-channel, not per-model

### Why the framing changed

The primary deployment target is **students using GitHub Models** with a PAT
obtained via the GitHub Student Developer Pack. Per
[docs.github.com/.../prototyping-with-ai-models](https://docs.github.com/en/github-models/use-github-models/prototyping-with-ai-models#rate-limits),
the binding constraint is **not** the underlying model's native context window —
it is GitHub's per-request token cap, which is uniform across Low/High tier
models on Copilot Free / Pro:

| Plan | Low-tier input | Low-tier output | High-tier input | High-tier output |
|---|---|---|---|---|
| Copilot Free | **8 000** | **4 000** | **8 000** | **4 000** |
| Copilot Pro | **8 000** | **4 000** | **8 000** | **4 000** |
| Copilot Business | 8 000 | 4 000 | 8 000 | 4 000 |
| Copilot Enterprise | 8 000 | 8 000 | 16 000 | 8 000 |

(Free/Pro additionally cap at 15 req/min, 150 req/day for Low tier and
10 req/min, 50 req/day for High tier — relevant for rate-limit middleware,
not for the token budget itself.)

For comparison, the same models accessed via the providers' **own** APIs:

| Channel | Native input window | Recommended output reservation |
|---|---|---|
| OpenAI direct (`api.openai.com`) | 128 000 | 4 096 |
| Anthropic direct (`api.anthropic.com`) | 200 000 | 4 096 |
| GitHub Models (Free/Pro) | **8 000** | **4 000** |
| GitHub Models (Enterprise) | 16 000 | 8 000 |

Same `gpt-4o-mini` model, **15× difference** in usable input budget depending
on how the user authenticates. The budget must therefore key off the **request
channel**, not the model name.

### Reality-check against actual fixtures

Using `chars / 3.5` on the CSDS-HW2 fixture:

| Item | Bytes | Estimated tokens |
|---|---|---|
| Persona (`TUTOR.md`) | 1 547 | ~440 |
| Assignment | 5 192 | ~1 480 |
| Reference solution | 9 241 | ~2 640 |
| Student WIP file | 9 241 | ~2 640 |
| User prompt (typical) | ~700 | ~200 |
| Formatting overhead | — | ~200 |
| **Subtotal (1–3 + prompt + overhead)** | | **~5 000** |

Against the GitHub Models 8 000 input cap:
- After items 1–3 + prompt: ~3 000 tokens remaining.
- Including the student file (~2 640) leaves ~350 tokens for history —
  **less than one turn**.
- Dropping the student file leaves ~3 000 tokens, fitting roughly **3–5
  history turns** at typical lengths.

**Implication for the algorithm:** dropping the student file is the *expected*
behaviour on GitHub Models, not an edge case. The existing
`MAX_HISTORY_TURNS = 10` cap is meaningless here — even on Anthropic-direct
(200 K input) it's fine, but on GitHub Models it's mathematically impossible
to fit 10 turns alongside the persona + assignment + solution.

### Storage location

`app/domain/values/token_budget.rb` — frozen lookup table keyed by channel.
Channel is derived from `endpoint` (sniffed in `TokenBudget.for(...)`) rather
than passed in by callers — keeps the wiring small.

### Table (v1)

Channel detection is **host-based** (parse the URI and compare `host`) rather
than substring-regex over the full URL. Host comparison is anchored by
construction — no `evil.example.com.models.github.ai` shenanigans, no
trailing-slash gotchas. GitHub Models is matched **first**; native provider
endpoints fall through automatically.

```ruby
CHANNELS = {
  github_models_free: { input: 8_000,   output: 4_000,
                        hosts: %w[models.inference.ai.azure.com models.github.ai] },
  openai_direct:      { input: 128_000, output: 4_096,
                        hosts: %w[api.openai.com] },
  anthropic_direct:   { input: 200_000, output: 4_096,
                        hosts: %w[api.anthropic.com] },
  unknown:            { input: 8_000,   output: 4_000, hosts: [] }  # safest fallback
}.freeze
```

Match order: `github_models_free` → `openai_direct` → `anthropic_direct` → `unknown`.
Our current deployment hits `models.inference.ai.azure.com` (GitHub Models),
so the GitHub branch is the hot path; native-provider hosts are supported
automatically when a student switches keys.

**Fallback rationale:** when the endpoint doesn't match a known channel, fall
back to the **GitHub Models limits** rather than the larger provider-direct
limits. Students are the primary user; an unknown endpoint is more likely a
misconfigured GitHub Models proxy than a self-hosted vLLM with a 128 K window.
False-narrow is recoverable (some history gets dropped); false-wide causes a
hard 400 from the provider.

### Lookup contract

```ruby
budget = Values::TokenBudget.for(endpoint: headers['HTTP_X_LLM_ENDPOINT'])
budget.input_token_limit    # => 8_000
budget.output_reservation   # => 4_000
budget.channel              # => :github_models_free (for logging)
```

**`output_reservation` is enforced in this PR.** Both
[OpenAiClient#send_prompt](../app/infrastructure/llm/openai_client.rb#L21-L31)
and the Anthropic equivalent gain a `max_tokens:` parameter; `RunTutorChat`
passes `budget.output_reservation` through. Without this, the budget
arithmetic is incomplete: the provider could generate beyond our
reservation and either (a) exceed GitHub Models' output cap (hard 400) or
(b) silently shrink the *effective* input budget on retry. See §5 edited
files and §6 Step 5.

### Out of scope for v1

- **Reasoning-model specialized tiers** (o1, o3, gpt-5, DeepSeek-R1, Grok-3):
  GitHub Models lists distinct rate-limit tables for these. They mostly differ
  in req/min and req/day, not in per-request token caps, but we have not
  verified the token cap is identical. When we add support for any of these
  models, extend the table; until then they fall to the `:unknown` 8 K bucket
  which is safe.
- **Per-plan detection** (Free vs Pro vs Business vs Enterprise): all
  Free/Pro/Business share the same 8 K cap, so the only meaningful split is
  Enterprise (16 K). We do not currently know which plan a student is on, and
  there is no header that tells us. Defaulting to 8 K is conservative;
  Enterprise users get slightly under-utilised capacity until we add a
  `X-LLM-Tier` header or env var.

---

## 4. Algorithm

```
Inputs:
  persona, assignment, solution  : String (mandatory, always included)
  student_file                   : { path:, content: } (droppable)
  history                        : [{ role:, content: }, ...] (newest at end)
  endpoint                       : String (used to pick channel — GitHub Models / direct / unknown)

1. budget   = Values::TokenBudget.for(endpoint: endpoint).input_token_limit
2. base     = estimate(persona) + estimate(assignment) + estimate(solution)
              + estimate(current user prompt)             # IMPORTANT: count it
              + FORMATTING_OVERHEAD                       # headers, separators
3. if base > budget
     return Result.error(:context_overflow)               # surfaces as `status: error`
4. remaining = budget - base
5. if estimate(student_file.content) <= remaining
     include student_file
     remaining -= estimate(student_file.content)
   else
     drop student_file                                    # whole-file drop, no per-line truncation
6. selected = []
   walk history from newest to oldest:
     turn_tokens = estimate(turn.content) + ROLE_OVERHEAD
     break if turn_tokens > remaining
     selected.unshift(turn)                               # preserve chronological order
     remaining -= turn_tokens
7. return composed prompt + selected history
```

### Constants (in `BudgetAwarePromptAssembler`)

```ruby
FORMATTING_OVERHEAD = 200  # markdown separators, section headers, fenced blocks
ROLE_OVERHEAD       = 4    # per-message wrapper tokens (matches OpenAI's "every message has 4")
```

### Edge cases the algorithm must handle

| Case | Behaviour |
|---|---|
| `history` nil or empty | `selected = []`, no error. |
| Single history turn larger than remaining budget | Drop it; do not split a turn. |
| `student_file.content` empty | Treat as absent — no overhead. |
| `persona + assignment + solution + prompt > budget` | Return `Failure[:context_overflow, ...]` → mapped to **HTTP 413 Payload Too Large** (`SERVICE_FAILURE_STATUS[:context_overflow] = 413` in `api.rb`). With GitHub Models' 8 K cap, this is realistic if an assignment is unusually long; the response should tell the student to start a new conversation. 413 is correct semantically — the request is well-formed but exceeds a size limit — and distinguishes this from 502 (upstream failure) and 422 (validation error). |
| Unknown / unrecognised endpoint | Fallback channel (GitHub Models limits — 8 K input); `warn` line; processing continues. |

### What we deliberately do NOT do

- **No per-file line truncation.** A partial student file is misleading
  context. Drop the whole file or include the whole file.
- **No "smart" turn truncation.** Mid-turn slicing changes the semantics of
  a message. Keep or drop, never split.
- **No "skip-past-large-turn" walk.** Step 6 uses `break`, not `next`: as
  soon as one turn doesn't fit, we stop and drop everything older too.
  Rationale: contiguous recent context preserves conversational coherence;
  cherry-picking smaller older turns over a skipped huge one produces a
  visibly broken dialogue ("jumpy" history) for marginal token savings.
  Locked by spec — see §6 Step 6.
- **No telemetry in response.** Per Issue 1, "client cannot detect anomalies."
  We log trimming server-side only.

### Composition note (assembler ↔ TutorSystemPrompt.build)

`TutorSystemPrompt.build`'s signature stays unchanged
(`policy_text:, solution_text:, context_files:`). The assembler **internally**
concatenates `"## Assignment\n#{assignment}\n\n## Reference Solution\n#{solution}"`
into `solution_text` before calling `build`. This keeps `build` a pure
composer with no knowledge of where its inputs came from, while letting the
assembler measure `assignment` and `solution` separately for the budget
arithmetic. The current logic at [run_tutor_chat.rb:50](../app/application/services/tutor_chat/run_tutor_chat.rb#L50)
moves verbatim into the assembler.

---

## 5. Architecture — files to create / edit / delete

### New files

| Path | Responsibility |
|---|---|
| `app/domain/values/token_budget.rb` | Per-**channel** input/output token budget table; `Values::TokenBudget.for(endpoint:)`. |
| `app/domain/values/tokenizer.rb` | `Values::Tokenizer.estimate(text)` — `chars / 3.5` heuristic; one seam, one method. Namespace matches existing `app/domain/values/*` files (all use `Tyla::Values::*`). |
| `app/application/prompts/builders/budget_aware_prompt_assembler.rb` | The algorithm in §4. Returns a struct `{ system_prompt:, history:, dropped: { student_file?, history_turns_dropped } }`. |
| `spec/domain/values/token_budget_spec.rb` | Table coverage + unknown-model fallback. |
| `spec/domain/values/tokenizer_spec.rb` | Heuristic boundaries. |
| `spec/application/prompts/builders/budget_aware_prompt_assembler_spec.rb` | The two specs the parent plan requires, plus the edge cases in §4. |

### Edited files

| Path | Change |
|---|---|
| [app/application/prompts/builders/tutor_system_prompt.rb](../app/application/prompts/builders/tutor_system_prompt.rb) | Delete `truncate_history`. Simplify `format_file` to render full content (no per-file cap). Keep `build` as the pure composer — signature unchanged; assembler combines `assignment + solution` before calling. |
| [app/application/services/tutor_chat/run_tutor_chat.rb](../app/application/services/tutor_chat/run_tutor_chat.rb#L43-L58) | Replace lines 43–58 with one `BudgetAwarePromptAssembler.call(...)`; pass `endpoint` (already resolved at line 24); pass `assembled.max_tokens` into `llm.send_prompt`; map `:context_overflow` Failure. |
| [app/infrastructure/llm/openai_client.rb](../app/infrastructure/llm/openai_client.rb#L21-L31) | `send_prompt` gains `max_tokens:` keyword; included in JSON body alongside `model`/`messages`. |
| [app/infrastructure/llm/anthropic_client.rb](../app/infrastructure/llm/anthropic_client.rb) | Same `max_tokens:` plumb-through (Anthropic Messages API requires `max_tokens`; if it was hard-coded before, switch to the passed value). |
| [config/api.rb](../config/api.rb) | Add `:context_overflow => 413` to the `SERVICE_FAILURE_STATUS` map. |
| [app/domain/values/payload_limits.rb](../app/domain/values/payload_limits.rb) | Remove `MAX_HISTORY_TURNS` and `MAX_FILE_LINES`. Keep `MAX_CONTEXT_FILES_BYTES` and `MAX_HISTORY_BYTES` — they remain as transport-layer caps (DoS protection), distinct from the LLM token budget. |
| [spec/domain/values/payload_limits_spec.rb](../spec/domain/values/payload_limits_spec.rb) | Drop the two tests for the deleted constants. |
| [spec/application/prompts/builders/tutor_system_prompt_spec.rb](../spec/application/prompts/builders/tutor_system_prompt_spec.rb) | Drop `.truncate_history` describe block; drop the `MAX_FILE_LINES` truncation test. |

### Deleted files (legacy `HandleTutorChat` path)

Verified zero non-spec callers via `grep -rn "HandleTutorChat\|TutorOrchestrator\|TutorChatInput\|TutorChatResult" app/ config/`.

| Path | Reason |
|---|---|
| [app/application/services/tutor_chat/handle_tutor_chat.rb](../app/application/services/tutor_chat/handle_tutor_chat.rb) | No controller calls it; superseded by `RunTutorChat`. |
| [app/application/services/tutor_chat/tutor_orchestrator.rb](../app/application/services/tutor_chat/tutor_orchestrator.rb) | Only `HandleTutorChat` instantiates it. |
| [app/application/services/tutor_chat/tutor_chat_input.rb](../app/application/services/tutor_chat/tutor_chat_input.rb) | Only used by `HandleTutorChat` + its spec. |
| [app/application/services/tutor_chat/tutor_chat_result.rb](../app/application/services/tutor_chat/tutor_chat_result.rb) | Only returned by `TutorOrchestrator`. Replaced by inline `:done`/`:forbidden`/`:unavailable` tuples in `RunTutorChat`. |
| [app/application/services/guard/rate_limiter.rb](../app/application/services/guard/rate_limiter.rb) | Only `HandleTutorChat` uses it. `RunTutorChat` does not rate-limit (out of scope; revisit separately if needed). |
| [app/infrastructure/filesystem/tutor_chat/policy_loader.rb](../app/infrastructure/filesystem/tutor_chat/policy_loader.rb) | Mode-keyed loader; only `HandleTutorChat` instantiates. `RunTutorChat` uses the per-project `TutorPersonaLoader` instead. |
| [spec/application/services/handle_tutor_chat_spec.rb](../spec/application/services/handle_tutor_chat_spec.rb) | Tests deleted class. |
| [spec/application/services/tutor_orchestrator_spec.rb](../spec/application/services/tutor_orchestrator_spec.rb) | Tests deleted class. The two history/file-truncation tests it contained are re-created against `BudgetAwarePromptAssembler`. |
| [spec/application/services/rate_limiter_spec.rb](../spec/application/services/rate_limiter_spec.rb) | Tests deleted class. |
| [spec/infrastructure/filesystem/tutor_chat/policy_loader_spec.rb](../spec/infrastructure/filesystem/tutor_chat/policy_loader_spec.rb) | Tests deleted class. |

### Trimmed (partial deletions inside surviving files)

| Path | Change |
|---|---|
| [app/infrastructure/filesystem/tutor_chat/solution_loader.rb](../app/infrastructure/filesystem/tutor_chat/solution_loader.rb#L18-L21) | Delete `self.load_stub` (only `TutorOrchestrator` called it). Class itself stays — `RunTutorChat` uses `self.load(project_id)`. |
| [spec/infrastructure/filesystem/tutor_chat/tutor_chat_loaders_spec.rb:44-46](../spec/infrastructure/filesystem/tutor_chat/tutor_chat_loaders_spec.rb#L44-L46) | Delete the one `load_stub` test. |

### Stale comment cleanup (one-liners, low risk)

These mention deleted classes and will mislead future readers:

- [app/domain/entities/prompt_log.rb:18](../app/domain/entities/prompt_log.rb#L18) — "The pending-row workflow (see HandleTutorChat)…" → rewrite to reference `RunTutorChat` (or remove if the pending-row workflow itself is gone — verify before edit).
- [app/infrastructure/database/repositories/prompt_logs.rb:21](../app/infrastructure/database/repositories/prompt_logs.rb#L21) — same.
- [app/infrastructure/database/repositories/SKILL.md:47](../app/infrastructure/database/repositories/SKILL.md#L47) — same.
- [app/infrastructure/filesystem/tutor_chat/tutor_persona_loader.rb:7](../app/infrastructure/filesystem/tutor_chat/tutor_persona_loader.rb#L7) — "PolicyLoader (used by HandleTutorChat)…" → delete the comment.
- [app/application/services/SKILL.md:202](../app/application/services/SKILL.md#L202) — file-tree comment for `tutor_orchestrator.rb` → remove the entry.

### Not touched

- `app/domain/policy/attack_policy.rb` — confirmed centralized, no change.
- `app/infrastructure/llm/*` — clients are model-agnostic at the budget layer.
- `app/domain/values/refusal_templates.rb` — still used by `run_guard_check.rb:67`
  (`RefusalTemplates.for` without args). The mode-keyed branch becomes
  unreachable after `TutorOrchestrator` deletion, but simplifying that is
  a small follow-up, not gating.
- `app/application/requests/tutor_chat.rb` — the `MAX_HISTORY_BYTES = 500_000`
  inline literal duplication is a pre-existing issue; **out of scope** for this
  plan. File a follow-up if desired.

---

## 6. Implementation steps (in merge order)

Each step is independently testable and reviewable.

### Step 0 — Delete the legacy path

Do this **first**, before any new code lands. Rationale: shrinks the surface
the new assembler has to reason about, eliminates the risk that the new
trimmer is wired into one path and not the other, and makes the new-code
diff in later steps small and focused.

Actions (single commit):

1. Delete the 10 files listed under §5 "Deleted files".
2. Delete `SolutionLoader.load_stub` ([solution_loader.rb:18-21](../app/infrastructure/filesystem/tutor_chat/solution_loader.rb#L18-L21))
   and its one test in `tutor_chat_loaders_spec.rb`.
3. Clean the 5 stale comments listed under §5 "Stale comment cleanup".
4. Run `bundle exec rake test` — expect only the deletion-related specs to be
   removed; no other test should regress. If `RunTutorChat`'s spec passes,
   production behaviour is unchanged.

Verification gate: `grep -rn "HandleTutorChat\|TutorOrchestrator\|TutorChatInput\|TutorChatResult\|RateLimiter\|PolicyLoader\|load_stub" app/ spec/ config/` returns empty.

### Step 1 — Tokenizer seam

Create `app/domain/values/tokenizer.rb`:

```ruby
module Tyla
  module Values
    module Tokenizer
      CHARS_PER_TOKEN = 3.5

      def self.estimate(text)
        return 0 if text.nil? || text.empty?
        (text.length / CHARS_PER_TOKEN).ceil
      end
    end
  end
end
```

Spec: empty/nil → 0; `'a' * 35` → 10; idempotent across calls.

### Step 2 — TokenBudget value object

Create `app/domain/values/token_budget.rb`. Frozen `CHANNELS` hash (see §3)
+ `Values::TokenBudget.for(endpoint:)` class method that parses the URI,
compares `host` against each channel's `hosts:` allowlist in declared
order (GitHub Models first), and falls back to `:unknown` on no match or
nil/unparseable endpoint. Returns a small struct exposing
`input_token_limit`, `output_reservation`, and `channel` (for logs).

### Step 3 — BudgetAwarePromptAssembler

Create `app/application/prompts/builders/budget_aware_prompt_assembler.rb`.
This is the only file with the algorithm logic. It depends on
`Values::Tokenizer`, `Values::TokenBudget`, and `Prompts::TutorSystemPrompt.build`.
Internally it concatenates `"## Assignment\n…\n\n## Reference Solution\n…"`
into `solution_text` before calling `build` — `build`'s signature is
unchanged. Return value:

```ruby
Result = Struct.new(:system_prompt, :history, :max_tokens,
                    :student_file_dropped, :history_turns_dropped, :overflow?,
                    keyword_init: true)
```

- `max_tokens` carries `budget.output_reservation` through to the caller so
  `RunTutorChat` can pass it to `llm.send_prompt`.
- `overflow?` is true when persona+assignment+solution+prompt already exceed
  budget. Callers map this to `Failure[:context_overflow, …]` → **HTTP 413**.

### Step 4 — Simplify `TutorSystemPrompt`

Delete `truncate_history` and the per-file cap branch inside `format_file`.
Builder becomes a pure composer with no truncation knowledge.

### Step 5 — Wire into `RunTutorChat` + LLM clients

**5a. LLM clients accept `max_tokens:`**

- [openai_client.rb:21](../app/infrastructure/llm/openai_client.rb#L21): add
  `max_tokens:` keyword arg; include in JSON body alongside `model` and
  `messages`.
- [anthropic_client.rb](../app/infrastructure/llm/anthropic_client.rb): same.
  (Anthropic's Messages API already requires `max_tokens`; if a constant is
  in use, switch to the passed value.)

**5b. `RunTutorChat` calls the assembler and forwards `max_tokens`**

Replace [run_tutor_chat.rb:43-58](../app/application/services/tutor_chat/run_tutor_chat.rb#L43-L58):

```ruby
assembled = Prompts::BudgetAwarePromptAssembler.call(
  persona:      Infrastructure::Filesystem::TutorPersonaLoader.load(params[:project_id]),
  assignment:   Infrastructure::Filesystem::AssignmentLoader.load(params[:project_id]),
  solution:     Infrastructure::Filesystem::SolutionLoader.load(params[:project_id]),
  student_file: { path:    Infrastructure::Filesystem::StudentFileLoader::FILENAME,
                  content: Infrastructure::Filesystem::StudentFileLoader.load(params[:project_id]) },
  history:      params[:history],
  user_prompt:  params[:prompt],
  endpoint:     endpoint
)

return Failure[:context_overflow, 'prompt exceeds model context window'] if assembled.overflow?

llm_reply = llm.send_prompt(
  system_prompt: assembled.system_prompt,
  user_message:  params[:prompt],
  history:       assembled.history,
  max_tokens:    assembled.max_tokens
)
```

`endpoint` is already resolved at [run_tutor_chat.rb:24](../app/application/services/tutor_chat/run_tutor_chat.rb#L24)
(`headers['HTTP_X_LLM_ENDPOINT']`). The assembler internally calls
`Values::TokenBudget.for(endpoint: endpoint)` so the channel is derived once.

**5c. Status mapping**

Add `SERVICE_FAILURE_STATUS[:context_overflow] = 413` in `config/api.rb`.
413 (Payload Too Large) is the correct semantic — well-formed request, but
exceeds a size limit. Distinct from 422 (validation) and 502 (upstream).

### Step 6 — Update specs

- Replace deleted tests (see §5 table).
- Add the two specs the parent plan requires:
  - `(a)` History of 50 turns, budget that fits only 6 → assert assembled
    history has 6 turns, newest preserved, chronological order.
  - `(b)` Persona + assignment + solution = 99 % of budget → assert
    `student_file_dropped` is `true` and the student file string is not in
    `system_prompt`.
- Add edge cases:
  - Single history turn larger than remaining budget at position N (newest→oldest walk) → **all turns at position N and older are dropped** (locks the `break` semantics from §4).
  - Unknown endpoint → fallback channel (`:unknown`, 8 K), processing succeeds.
  - Overflow on items 1–4 → `overflow?` true, no LLM call, controller returns 413.
  - `assembled.max_tokens` is forwarded to `llm.send_prompt` (assert with a stubbed client).
  - `Values::TokenBudget.for(endpoint: 'https://models.inference.ai.azure.com/...')` → `channel == :github_models_free` (our actual deployment).
  - `Values::TokenBudget.for(endpoint: 'https://api.openai.com/...')` → `channel == :openai_direct` (native-key fall-through).

---

## 7. Risks & open items

| Risk | Mitigation |
|---|---|
| Heuristic under-estimates for code-heavy R/Markdown → LLM rejects with 400. | Conservative `CHARS_PER_TOKEN = 3.5` plus 4 K output reservation (now actually enforced as `max_tokens` per Step 5a) gives ~6 % headroom. Spot-check post-deploy via temporary `warn`. **Higher impact on GitHub Models channel** — under an 8 K cap, a 5 % under-estimate is 400 tokens, large enough to push a request over the limit. Consider tightening to 3.2 if drift is observed. |
| Provider rejects our `max_tokens` (e.g. some reasoning models require a higher floor). | 4 K is within published limits for every channel in the table; only impact would be wasted output capacity on Enterprise (8 K available). If a reasoning-model tier is added to the table, set its `output` accordingly. |
| GitHub Models reasoning-model tiers (o1/o3/gpt-5/DeepSeek-R1/Grok-3) might cap differently from 8 K. | Out of scope for v1; falls back to `:unknown` (8 K) until verified. Add channels when we add support for any of these models. |
| Endpoint sniffing misclassifies a future GitHub Models proxy URL. | Fallback channel is also 8 K, so misclassification produces conservative behaviour, not a 400. |
| Deleting the legacy path removes a class someone else was about to wire up. | grep showed zero non-spec callers as of 2026-05-27; before merging Step 0, re-run the grep on `main` and check open PRs for any new reference. |
| Removing `RateLimiter` drops the only per-student request-rate protection. | `RunTutorChat` never had rate limiting to begin with — this is a *loss of dormant capability*, not a regression. If/when rate limiting is needed, re-introduce it at the controller layer or as middleware, not bolted onto a service. |
| Pre-existing duplication: `Request::TutorChat::MAX_HISTORY_BYTES = 500_000` vs `Values::PayloadLimits::MAX_HISTORY_BYTES = 512_000`. | Out of scope; flagged for a follow-up PR. |
| Tokenizer change later breaks reproducibility of historical prompt logs. | Logs already store the raw prompt — the heuristic only affects what we send forward, not what we record. Acceptable. |

---

## 8. TODO mapping (back to Issue 2)

| Parent TODO | This plan covers it via |
|---|---|
| Write `2026-05-28-token-budget-algorithm.md` + resolve tokenizer blocker | This document; §2. |
| Implement `Domain::TokenBudget` value object | §6 Step 2. |
| Replace `MAX_HISTORY_TURNS` cutoff with budget-aware trimmer (newest-first); extract to `Prompts::HistoryTrimmer` | §6 Steps 3–4. **Naming deviation:** absorbed into `BudgetAwarePromptAssembler` rather than a standalone `HistoryTrimmer` — see note below. |
| Replace per-file `MAX_FILE_LINES = 200` cap with whole-file dropping | §4 step 5; §6 Step 4. |
| Specs (a) and (b) | §6 Step 6. |
| (added by this sub-plan) Delete legacy `HandleTutorChat`/`TutorOrchestrator` path | §6 Step 0. |

> **Naming deviation rationale:** the parent TODO suggests `Prompts::HistoryTrimmer`,
> but history trimming and student-file dropping share the same `remaining`
> budget. Splitting them into two classes would either (a) duplicate the budget
> arithmetic or (b) require an awkward two-pass coordinator. One assembler
> with both responsibilities is simpler. If clarity demands, the internal
> methods can be named `#trim_history` and `#fit_student_file`.

---

## 9. Out of scope for this sub-plan

- `/guard_checks` response shape (Issue 1 open question #1).
- `forbidden` content source — Socratic redirect vs. `RefusalTemplates`
  (Issue 1 open question #3).
- Swapping the heuristic for `tiktoken_ruby` (gated on post-deploy calibration data).
- Front-end work (TUI consumption of `usage`) — already covered in Issue 3.
