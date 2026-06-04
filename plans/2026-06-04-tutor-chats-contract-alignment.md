# Plan — Align `tutor_chats` code with `doc/api_tutor_chats.md` (Partial TARGET)

> **Date:** 2026-06-04
> **Status:** Ready to implement
> **Scope:** Workstream B of [`2026-06-03-agentic-tutor-backend.md`](./2026-06-03-agentic-tutor-backend.md) — make the live `POST /api/v1/tutor_chats` endpoint match the **Partial TARGET** banner in [`doc/api_tutor_chats.md`](../doc/api_tutor_chats.md) (L3-14).
> **Sibling plan (Workstream A, already specced):** [`2026-06-03-guard-checks-contract-alignment.md`](./2026-06-03-guard-checks-contract-alignment.md).
> **Out of scope:** `guard_checks` changes (Workstream A) — that endpoint's status enum is already live and its alignment is tracked in the sibling plan. The `:unauthorized` cleanup (Q-A2) is also out of scope.

---

## 0. Goal

The doc is a **contract-first Partial TARGET**: the `status` enum is already live (shipped
by Issue-1), but three pieces are still **planned** and not yet built. After this plan the
route will match the doc:

1. **`file_context`** request field accepted (NEW) and injected into the system prompt as
   `## Student Workspace (live)`, suppressing the fixture WIP when present.
2. **`actions[]`** response field emitted (NEW) — parsed out of the tutor reply, never
   present on `forbidden`.
3. **Internal guard LLM removed** (CHANGED) — the route no longer re-runs the guard.
   Instead it requires a **`guard_log_id`** and verifies it against the DB (single read,
   no LLM call): the log exists, its derived guard verdict ∈ {`done`, `unavailable`}, and
   its stored `prompt` matches this request's `prompt`. `usage` becomes **tutor-only**.

---

## 1. Gap analysis (verified against HEAD)

| # | Doc requirement | Current code | File |
|---|-----------------|--------------|------|
| T1 | `guard_log_id` is a **required integer**; missing → 400 | Request contract has no `guard_log_id` field | [tutor_chat.rb:11-20](../app/application/requests/tutor_chat.rb#L11-L20) |
| T2 | `file_context` is an **optional string** | Request contract has no `file_context` field | [tutor_chat.rb:11-20](../app/application/requests/tutor_chat.rb#L11-L20) |
| T3 | Route **does not** call the guard LLM; verifies `guard_log_id` against the DB | Builds `GuardAgent` and re-runs the judge every call | [run_tutor_chat.rb:31-40](../app/application/services/tutor_chat/run_tutor_chat.rb#L31-L40) |
| T4 | `forbidden` ⇔ `guard_log_id` missing / verdict `forbidden` / prompt mismatch; tutor not called | `forbidden` ⇔ the *re-run* guard's `attack_probability >= 0.7` | [run_tutor_chat.rb:39-41](../app/application/services/tutor_chat/run_tutor_chat.rb#L39-L41) |
| T5 | `usage` = **tutor-LLM tokens only**; `null` on `forbidden` | Sums guard + tutor usage; `forbidden` carries guard usage | [run_tutor_chat.rb:40,105,109-116](../app/application/services/tutor_chat/run_tutor_chat.rb#L40-L116) |
| T6 | Response carries `actions[]`; `[]`/omitted when none; **never present on `forbidden`** | DTO + representer have no `actions` field | [tutor_chat_representer.rb:8,12-19](../app/presentation/representers/tutor_chat_representer.rb#L8-L19) |
| T7 | `file_context` injected as `## Student Workspace (live)`; **fixture WIP suppressed** when present; participates in the trim | Composer always injects fixture WIP under `## Student Workspace Files`; no live section | [budget_aware_prompt_assembler.rb:46-73](../app/application/prompts/builders/budget_aware_prompt_assembler.rb#L46-L73), [tutor_system_prompt.rb:9-19](../app/application/prompts/builders/tutor_system_prompt.rb#L9-L19) |
| T8 | Tutor system prompt must instruct the LLM to emit an `<actions>…</actions>` block | No actions protocol in any builder | [tutor_system_prompt.rb](../app/application/prompts/builders/tutor_system_prompt.rb) |

**Lookup support needed.** Verifying `guard_log_id` requires fetching one row by primary
key. The repository has `create`, `find_all`, `update`, but **no `find(id)`**
([prompt_logs.rb:6-43](../app/infrastructure/database/repositories/prompt_logs.rb#L6-L43)) — add one.

**Already satisfied (no change):**
- `/guard_checks` already persists the judged `prompt` to `prompt_logs`
  ([run_guard_check.rb:33-43](../app/application/services/guard/run_guard_check.rb#L33-L43)) —
  the §3.3 prerequisite for the prompt-match check (confirmed in the sibling plan §1).
- `forbidden` content already sourced from `RefusalLoader`
  ([run_tutor_chat.rb:95](../app/application/services/tutor_chat/run_tutor_chat.rb#L95)).
- Missing `X-LLM-Key` → `Failure[:forbidden]` → 403
  ([run_tutor_chat.rb:21](../app/application/services/tutor_chat/run_tutor_chat.rb#L21)),
  and the controller already returns 202 only on `:unavailable`, 200 otherwise
  ([api.rb:43-45](../app/application/controllers/api.rb#L43-L45)) — so `forbidden`/`done`
  stay 200 and `unavailable` stays 202 with no controller change.

### 1.1 Deriving the guard verdict from a stored row (key design point)

`prompt_logs` has **no `status` column** — only `attack_probability` (Float, nullable) and
`evaluation` ([prompt_log_orm](../app/infrastructure/database/orm/prompt_log_orm.rb),
[migration 003](../db/migrations/003_promptlog_shape_change.rb)). A guard row's verdict is
therefore *derived*, mirroring how the guard itself decides
([AttackPolicy.THRESHOLD = 0.7](../app/domain/policy/attack_policy.rb#L6),
[RunGuardCheck](../app/application/services/guard/run_guard_check.rb#L31-L50)):

| stored `attack_probability` | derived verdict | tutor_chats action |
|---|---|---|
| `nil` (guard was fail-open / judge unavailable) | `unavailable` | call tutor, `status: unavailable`, **202** |
| `< 0.7` | `done` | call tutor, `status: done`, **200** |
| `>= 0.7` | `forbidden` | refuse, no tutor call, **200** |

`nil ⇔ unavailable` is sound for guard-produced rows: `RunGuardCheck` only stores `nil`
`attack_probability` when `GuardResult#probability` is `nil`, i.e. the judge was unavailable
([run_guard_check.rb:39](../app/application/services/guard/run_guard_check.rb#L39),
[guard_agent.rb:38](../app/application/services/guard/guard_agent.rb#L38)).

> **Design decision D1 — derive, don't add a column.** We derive the verdict from
> `attack_probability` rather than adding a `guard_status` column, to keep this change
> migration-free. See Open Question Q1 for the one edge this leaves (tutor-turn rows also
> deriving a verdict) and why the prompt-match binding makes it safe.

---

## 2. Changes

Ordered roughly by dependency. Code sketches are illustrative — re-verify line numbers
against `HEAD` before editing.

### 2.1 EDIT `app/application/requests/tutor_chat.rb` — accept the two new fields (T1, T2)

```ruby
params do
  required(:course_id).filled(:string)
  required(:project_id).filled(:string)
  required(:student_id).filled(:string)
  required(:guard_log_id).filled(:integer)   # NEW — missing/wrong-type → bad_request (400)
  required(:prompt).filled(:string)
  optional(:history).array(:hash) do
    required(:role).filled(:string)
    required(:content).filled(:string)
  end
  optional(:file_context).filled(:string)    # NEW — optional live-workspace block
end
```

- `guard_log_id` is `required` so a missing/non-integer value fails validation →
  `Failure[:bad_request]` → **400**, exactly as the doc's error table (L245) and body
  table (L85, "Missing → 400") require. The `params` block coerces a JSON string/integer
  to Integer; a non-coercible value fails. The existing `history` 500 KB `rule` is unchanged.

### 2.2 ADD `Repository::PromptLogs.find(id)` (lookup support)

The `update` method already loads a row by primary key via `Database::PromptLogOrm[id]`
([prompt_logs.rb:22](../app/infrastructure/database/repositories/prompt_logs.rb#L22)); add a
read-only sibling:

```ruby
def find(id)
  rebuild_entity(Database::PromptLogOrm[id])   # nil when not found
end
```

Returns an `Entity::PromptLog` (carrying `prompt` + `attack_probability`) or `nil`.

### 2.3 ADD a verdict helper (testable, pure) — D1

A small domain helper that maps a guard row to its derived verdict and answers "may the
tutor proceed?". Keep it pure so it is unit-testable and the §1.1 table lives in one place.

```ruby
# app/domain/values/guard_log_verdict.rb
module Tyla
  module Values
    module GuardLogVerdict
      # Returns :unavailable | :done | :forbidden from a persisted attack_probability.
      def self.from(attack_probability)
        return :unavailable if attack_probability.nil?

        Values::AttackPolicy.allowed?(attack_probability) ? :done : :forbidden
      end
    end
  end
end
```

### 2.4 EDIT `app/application/services/tutor_chat/run_tutor_chat.rb` — the core change (T3, T4, T5)

Remove the `GuardAgent` call and the guard re-run; replace with `guard_log_id` verification.

**Remove:** lines 31-40 (`GuardAgent.new`, `guard.check`, `llm_unavailable` derived from a
live guard result, the inline forbidden branch keyed off `guard_result.allowed?`), and the
guard half of `usage_sum`.

**New flow** after `params = validated.to_h`:

```ruby
guard_log = Repository::PromptLogs.find(params[:guard_log_id])
verdict   = guard_log && guard_log.prompt == params[:prompt] &&
            Values::GuardLogVerdict.from(guard_log.attack_probability)

# guard_log missing, prompt mismatch, or derived verdict :forbidden → refuse, no tutor call
unless verdict == :done || verdict == :unavailable
  log = persist_turn(params, guard_log)          # carry-forward verdict (see below)
  return Success([:forbidden, build_forbidden_response(log.id, params[:project_id])])
end

log = persist_turn(params, guard_log)

assembled = Prompts::BudgetAwarePromptAssembler.call(
  persona:      Infrastructure::Filesystem::TutorPersonaLoader.load(params[:project_id]),
  assignment:   Infrastructure::Filesystem::AssignmentLoader.load(params[:project_id]),
  solution:     Infrastructure::Filesystem::SolutionLoader.load(params[:project_id]),
  student_file: { path:    Infrastructure::Filesystem::StudentFileLoader::FILENAME,
                  content: Infrastructure::Filesystem::StudentFileLoader.load(params[:project_id]) },
  file_context: params[:file_context],            # NEW — nil when absent
  history:      params[:history],
  user_prompt:  params[:prompt],
  endpoint:     endpoint
)
return Failure[:context_overflow, 'prompt exceeds model context window'] if assembled.overflow?

llm_reply       = llm.send_prompt(system_prompt: assembled.system_prompt,
                                  user_message: params[:prompt],
                                  history: assembled.history,
                                  max_tokens: assembled.max_tokens)
prose, actions  = Values::TutorReplyParser.call(llm_reply.content)   # NEW (§2.5)

status   = verdict == :unavailable ? 'unavailable' : 'done'
response = Response::TutorChat.new(
  log_id:  log.id,
  status:  status,
  content: prose,
  actions: actions,                               # [] when none
  usage:   llm_reply.usage                         # TUTOR-ONLY (T5)
)
Success([verdict, response])                        # verdict is :done | :unavailable
```

`build_forbidden_response` drops the `guard_usage` argument and sets `usage: nil`,
`actions: nil` (so the key is **omitted** — never present on `forbidden`, T6/doc L151):

```ruby
def build_forbidden_response(log_id, project_id)
  Response::TutorChat.new(
    log_id:  log_id,
    status:  'forbidden',
    content: Infrastructure::Filesystem::RefusalLoader.load(project_id),
    actions: nil,        # omitted by the representer
    usage:   nil
  )
end
```

`usage_sum` (lines 109-116) is **deleted** — `usage` is now `llm_reply.usage` verbatim.
The `GuardAgent` require/usage and the now-unused `LLM_UNAVAILABLE_EVALUATION` constant go too.

**`persist_turn` — what the tutor-turn row stores.** The doc states `attack_probability` and
`evaluation` are *still persisted* in `prompt_logs` (doc L181-183), but the guard no longer
runs here. So the turn row **carries forward** the referenced guard row's verdict fields:

```ruby
def persist_turn(params, guard_log)
  entity = Entity::PromptLog.new(
    id:                 nil,
    course_id:          params[:course_id],
    project_id:         params[:project_id],
    student_id:         params[:student_id],
    prompt:             params[:prompt],
    attack_probability: guard_log&.attack_probability,   # copied from the guard row
    evaluation:         guard_log&.evaluation,           # (nil when guard_log missing)
    created_at:         nil
  )
  Repository::PromptLogs.create(entity)
end
```

The `Errno::ENOENT` / `Sequel::Error` / `LlmError` rescues stay as-is.

> **Note — verification happens before any LLM cost.** The lookup + prompt-match + verdict
> derivation is a single DB read; on `forbidden` no LLM is called and `usage` is `null`,
> matching doc L204. On `done`/`unavailable` only the **tutor** LLM is called.

### 2.5 ADD `Values::TutorReplyParser` — split prose from `<actions>` (T6, Q-B2)

Pure parser, mirrors the parent plan §3.2 + Q-B2 ("malformed actions JSON → drop actions,
keep prose"):

```ruby
# app/domain/values/tutor_reply_parser.rb
module Tyla
  module Values
    module TutorReplyParser
      BLOCK = /<actions>\s*(.*?)\s*<\/actions>/m

      # Returns [prose, actions]. actions is always an Array ([] when none/malformed).
      def self.call(content)
        m = content.match(BLOCK)
        return [content.strip, []] unless m

        prose   = content.sub(BLOCK, '').strip
        actions = parse(m[1])
        [prose, actions]
      end

      def self.parse(json)
        parsed = JSON.parse(json)
        parsed.is_a?(Array) ? parsed : []
      rescue JSON::ParserError
        []   # malformed → drop actions, keep prose (Q-B2)
      end
      private_class_method :parse
    end
  end
end
```

> **Scope note.** Per Q-B2 the backend parses the block out and passes `actions[]` through;
> deep schema validation of each `TutorAction` (`edit_file` / `execute_script` / `load_file`)
> is the frontend's concern. We keep parsing permissive (array-or-drop) and leave per-action
> validation as a future hardening (Q3).

### 2.6 EDIT the prompt builders — `file_context` injection + actions protocol (T7, T8)

**`tutor_system_prompt.rb`** — add a `live_context:` parameter and an actions-protocol
section. When `live_context` is present, render it under `## Student Workspace (live)`
**instead of** the fixture `## Student Workspace Files` block (Q-B1 suppression):

```ruby
def self.build(policy_text:, solution_text:, context_files:, live_context: nil)
  parts = [policy_text]
  parts << "## Reference Solution\n#{solution_text}" unless blank?(solution_text)

  if !blank?(live_context)
    parts << "## Student Workspace (live)\n#{live_context}"      # NEW — suppresses fixture WIP
  elsif !blank?(context_files)
    file_block = context_files.map { |f| format_file(f) }.join("\n\n")
    parts << "## Student Workspace Files\n#{file_block}"
  end

  parts << ACTIONS_PROTOCOL                                       # NEW — static instructions
  parts.join("\n\n---\n\n")
end
```

`ACTIONS_PROTOCOL` is a constant string that documents the wire format the parser expects —
e.g. "When you have a concrete code suggestion, after your prose emit a single
`<actions>[...]</actions>` block containing a JSON array of `{type, …}` objects
(`edit_file` with search/replace `patches`, `execute_script` with `code`, `load_file` with
`path`). Omit the block when you have no suggestion." (Match the `TutorAction` shape in doc
L162-167.)

**`budget_aware_prompt_assembler.rb`** — accept `file_context:` and budget it as the
droppable workspace block, replacing the fixture student-file slot when present:

- Add `file_context:` to the `call` signature.
- In the droppable phase (currently lines 48-64), **if `file_context` is present**: estimate
  its tokens, include it whole if it fits (else drop whole), and do **not** include the
  fixture `student_file`. **If absent**: keep today's fixture-WIP logic unchanged.
- Pass the surviving block to `TutorSystemPrompt.build` as `live_context:` (when from
  `file_context`) or `context_files:` (fixture path), so exactly one of the two sections
  renders. The doc's "participates in the same newest-first token-budget trim" is satisfied
  by budgeting `file_context` **before** `trim_history` (same slot the fixture WIP occupies
  today), so when it is dropped the freed budget flows to history.

### 2.7 EDIT `app/presentation/representers/tutor_chat_representer.rb` — add `actions` (T6)

```ruby
module Tyla
  module Response
    TutorChat = Data.define(:log_id, :status, :content, :actions, :usage)   # + :actions
  end

  module Representer
    class TutorChat < Roar::Decorator
      include Roar::JSON

      property :log_id
      property :status
      property :content
      property :actions          # NO render_nil → nil is OMITTED, [] renders as []
      property :usage, render_nil: true
    end
  end
end
```

> **Divergence from parent plan §3.2 (intentional, follows the doc).** The parent plan said
> "the representer emits `actions` unconditionally." The **doc is stricter**: `actions` is
> "**Never present on `forbidden`**" (L151) and the `forbidden` example (L195-202) has no
> `actions` key. We honour the doc by leaving `render_nil` off: the service sets
> `actions: nil` on `forbidden` (key omitted) and `actions: []`/`[…]` on `done`/`unavailable`
> (key rendered). Every caller of `Response::TutorChat.new` must now pass `actions:`.

### 2.8 Controller `api.rb` — no change required

The `tutor_chats` block already wraps the DTO with `Representer::TutorChat` and sets 202 only
on `:unavailable` ([api.rb:43-45](../app/application/controllers/api.rb#L43-L45)). The service
still returns `Success([:done|:forbidden|:unavailable, dto])`, so the existing mapping holds.
Refresh the stale block comment (L24-28) to drop "Re-runs the guard server-side" and mention
`guard_log_id` verification + `file_context`.

---

## 3. Specs

| Spec | Action |
|------|--------|
| `spec/application/requests/tutor_chat_spec.rb` | **EDIT** — add: missing `guard_log_id` → invalid; non-integer `guard_log_id` → invalid; valid `file_context` string accepted; `file_context` optional (absent is valid). |
| `spec/application/services/run_tutor_chat_spec.rb` | **REWRITE** the guard-centric cases. The scripted-LLM helper no longer needs a "first call = guard" arm — **only the tutor LLM is called**. New cases: (a) `guard_log_id` → row with `attack_probability 0.1` + matching prompt ⇒ `Success([:done, dto])`, tutor called **once**, `dto.usage == llm_reply.usage` (tutor-only), `dto.actions == []`; (b) row with `attack_probability nil` (fail-open) ⇒ `:unavailable`, 202-kind, tutor called; (c) row `attack_probability 0.95` ⇒ `:forbidden`, **tutor not called**, `dto.usage` nil, `dto.actions` nil; (d) `guard_log_id` not in DB ⇒ `:forbidden`; (e) row exists but **prompt mismatch** ⇒ `:forbidden`; (f) tutor reply containing `<actions>[…]</actions>` ⇒ `dto.content` = prose only, `dto.actions` = parsed array; (g) malformed actions JSON ⇒ `actions == []`, prose kept; (h) missing key → `Failure[:forbidden]`; (i) missing `guard_log_id`/bad body → `Failure[:bad_request]`; (j) tutor timeout/upstream → `Failure[:upstream_timeout|:upstream_error]`. Seed the guard row via the in-memory `RTC_DB[:prompt_logs]` insert before each call. |
| `spec/presentation/representers/tutor_chat_representer_spec.rb` | **EDIT** — `done`/`unavailable` DTO emits `actions` (array); `forbidden` DTO (`actions: nil`) **omits** the key; JSON round-trip includes `actions` on `done`. Update `build_dto` to pass `actions:`. |
| `spec/application/prompts/builders/tutor_system_prompt_spec.rb` | **EDIT** — `live_context` renders `## Student Workspace (live)` and suppresses `## Student Workspace Files`; absent `live_context` keeps fixture-files behaviour; output contains the actions-protocol marker. |
| `spec/application/prompts/builders/budget_aware_prompt_assembler_spec.rb` | **EDIT** — `file_context` present ⇒ live block in system prompt, fixture student file absent; oversized `file_context` ⇒ dropped whole, freed budget flows to history; `file_context` absent ⇒ unchanged. |
| `spec/domain/values/guard_log_verdict_spec.rb` | **CREATE** — `nil → :unavailable`, `< 0.7 → :done`, `>= 0.7 → :forbidden`. |
| `spec/domain/values/tutor_reply_parser_spec.rb` | **CREATE** — prose-only (no block) ⇒ `[]`; well-formed block ⇒ prose stripped + array; malformed JSON ⇒ prose kept + `[]`; non-array JSON ⇒ `[]`. |
| `spec/infrastructure/database/repositories/prompt_logs_spec.rb` | **EDIT** — `find(id)` returns the entity; `find(unknown)` returns `nil`. |

Run focused specs, then the full suite (confirm the runner from the `Rakefile` / CI):

```powershell
bundle exec rake spec
```

---

## 4. Doc

[`doc/api_tutor_chats.md`](../doc/api_tutor_chats.md) is already the target contract. Once the
code lands and specs pass, **edit the Partial TARGET banner (L3-14)**: the three NEW/CHANGED
items are now shipped, so remove the "Until the plan ships…" paragraph (L12-14) and either
drop the banner or downgrade it to a "shipped 2026-06-04" note. No body edits — the Request/
Response/Composed-prompt sections already describe the implemented behaviour.

---

## 5. Order of work

1. `Request::TutorChat` (§2.1) + request spec → run.
2. `Repository::PromptLogs.find` (§2.2) + repo spec → run.
3. `Values::GuardLogVerdict` (§2.3) + `Values::TutorReplyParser` (§2.5) + their specs → run.
4. Prompt builders (§2.6) + builder specs → run.
5. `Representer::TutorChat` actions field (§2.7) + representer spec → run.
6. `RunTutorChat` rewrite (§2.4) + service spec rewrite → run.
7. Controller comment refresh (§2.8) → run full suite.
8. Manual smoke against a local server: `done` (200 + `actions`), `forbidden` (200, no
   `actions`, `usage:null`), `unavailable` (202), missing `guard_log_id` (400),
   prompt-mismatch (200 `forbidden`), `file_context` injection.
9. Update the doc banner (§4).

---

## 6. Acceptance checklist

- [ ] `done` (200): `{log_id, status:"done", content, actions:[…or []], usage:{tutor tokens}}`; tutor LLM called **once**; **no guard LLM call**.
- [ ] `unavailable` (202): same shape, `status:"unavailable"`; reached only when the referenced guard row's `attack_probability` is `nil`.
- [ ] `forbidden` (200): `{log_id, status:"forbidden", content:<refusal>, usage:null}` with **no `actions` key**; reached on missing/`forbidden`/prompt-mismatch `guard_log_id`; tutor LLM **not** called.
- [ ] Missing `guard_log_id` (or non-integer) → **400** `bad_request`.
- [ ] `usage` is tutor-only on success and `null` on `forbidden` (no guard tokens anywhere in this route).
- [ ] `file_context` present ⇒ system prompt has `## Student Workspace (live)` and **no** `## Student Workspace Files`; absent ⇒ fixture WIP injected as before.
- [ ] `<actions>…</actions>` parsed out: `content` is prose only; malformed block ⇒ `actions:[]`, prose preserved.
- [ ] Tutor-turn `prompt_logs` row carries forward `attack_probability` + `evaluation` from the referenced guard row.
- [ ] Doc Partial TARGET banner updated to reflect shipped reality.

---

## 7. Open questions / design decisions

- **D1 (decided) — derive verdict from `attack_probability`, no new column.** See §1.1.
- **Q1 — tutor-turn rows also derive a verdict.** After this change, a tutor-turn row stores
  the *copied* guard verdict (§2.4 `persist_turn`), so a client could pass a prior **tutor**
  `log_id` as `guard_log_id`. This is **not** a bypass: the prompt-match check still binds
  verification to the exact judged prompt, and the copied verdict reflects a real prior guard
  pass for that prompt. If we later want strict source separation, add a `kind`
  (`guard` / `tutor`) column and require `kind = 'guard'` — deferred; the parent plan does not
  require it.
- **Q2 — prompt-match exactness.** We compare `guard_log.prompt == params[:prompt]` byte-for-byte
  (the frontend resends the identical prompt). No normalisation/trim, to keep the security
  binding unambiguous (doc §Security L323-328). Flag if the frontend ever reformats the prompt
  between the two calls.
- **Q3 — per-action schema validation.** The parser is permissive (array-or-drop, Q-B2); it does
  not validate each `TutorAction`'s `type`/fields. Per the doc the frontend executes actions
  behind a human-approval gate and owns validation. Tighten server-side only if a need appears.
- **Q-B3 (confirmed) — guard never sees `file_context`.** Satisfied automatically: the guard now
  runs only in `/guard_checks`, which receives no `file_context`. No server-side guard sees it.
