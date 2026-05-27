# Plan — Issue 1: API Response Standardization (`POST /api/v1/tutor_chats`)

> **Date:** 2026-05-27
> **Status:** DRAFT v3 — **all six decisions resolved**, ready to execute
> **Parent decision:** [`2026-05-27-meeting-decisions.md`](./2026-05-27-meeting-decisions.md) §Issue 1
> **Scope:** Only `/api/v1/tutor_chats`. `/guard_checks` is **out of scope** (tracked as an open question in the parent doc).

---

## 0. Resolved decisions (from 2026-05-27 user review of DRAFT v1)

| # | Decision |
|---|---|
| **R1** | Drop `attack_probability` / `evaluation` from the **response** body, but **keep persisting them in `prompt_logs`**. The DB write at `RunTutorChat#persist_log` ([run_tutor_chat.rb:74-86](../app/application/services/tutor_chat/run_tutor_chat.rb#L74-L86)) is unchanged; only the response builder stops emitting them. |
| **R2** | Drop the `warning: 'guard skipped: llm unavailable'` string from the `unavailable` response. HTTP 202 + `status: "unavailable"` already carry the signal. |
| **R3** | Do **not** clean up `HandleTutorChat` / `TutorOrchestrator` in this PR. Instead, add a follow-up TODO (§10 below) describing what that code is and why we may want to retire it. |
| **R4** | `forbidden` content comes from a new `## Refusal Message` section appended to `TUTOR.md`, loaded by a new `Infrastructure::Filesystem::RefusalLoader`. Source-of-truth lives with the tutor. **Done in this PR** (not phased). |
| **R5** | New class is named `Representer::TutorChat` (matches repo convention; not `TutorChatRepresenter`). |
| **R6** | When the tutor LLM was not called (forbidden branch), emit **`"usage": null`** so every success-body shares the same key set. The representer always emits `usage`; the value is `null` for forbidden. (User asked for *uniform* response shape — clarification: the LLM truly was not called on the forbidden branch, so there is no real token count; `null` is the honest representation, not omission.) |

---

## 1. Goal

Replace the `allowed: bool` field on the `POST /api/v1/tutor_chats` success
response with a unified `status` string (`done` / `forbidden` / `unavailable`),
and change the missing-`X-LLM-Key` failure from HTTP **401** to HTTP **403**.

The HTTP status code and the body `status` field are **two independent layers** —
this plan preserves that separation exactly as the meeting note describes.

---

## 2. Verified state of the code today

Before writing any code, the assumptions in the meeting note were checked
against the current tree (commit `b4139e9`). All references are still accurate
unless flagged below.

| Meeting-note claim | Verified? | Notes |
|---|---|---|
| `RunTutorChat` builds the response inline via `build_blocked_response` / `build_ok_response` at [run_tutor_chat.rb:88-107](../app/application/services/tutor_chat/run_tutor_chat.rb#L88-L107) | ✓ matches | `build_ok_response` adds `warning:` when guard is unavailable, `build_blocked_response` returns `refusal:` + `attack_probability` + `evaluation` |
| Missing `X-LLM-Key` returns `Failure[:unauthorized, …]` at [run_tutor_chat.rb:21](../app/application/services/tutor_chat/run_tutor_chat.rb#L21) | ✓ matches | Same pattern is **also** in [run_guard_check.rb:17](../app/application/services/guard/run_guard_check.rb#L17) and the legacy [handle_tutor_chat.rb:22-23](../app/application/services/tutor_chat/handle_tutor_chat.rb#L22-L23) — left untouched by this plan |
| `SERVICE_FAILURE_STATUS` lives at [api.rb:8-16](../app/application/controllers/api.rb#L8-L16) and has no `:forbidden` row | ✓ matches | `:forbidden` already exists downstream — [`Response::CODES`](../app/presentation/responses/result.rb#L9-L12) accepts it and [`HttpResponse::HTTP_CODE`](../app/presentation/representers/http_response.rb#L30) maps it to 403. No new wiring needed beyond the table row. |
| `Representer::TutorChatRepresenter` does not exist | ✓ matches | [`app/presentation/representers/`](../app/presentation/representers/) contains only `http_response.rb` and `prompt_log_representer.rb` |
| `Values::RefusalTemplates.for` is used for the blocked branch at [run_tutor_chat.rb:94](../app/application/services/tutor_chat/run_tutor_chat.rb#L94) | ✓ matches | `RefusalTemplates::TEMPLATES[2]` is *literally* the Socratic redirect sentence used in the meeting-note example — see [refusal_templates.rb:11](../app/domain/values/refusal_templates.rb#L11). Keeping `RefusalTemplates.for` therefore satisfies the spec already, with the side-effect that two of the three templates are *not* Socratic redirects. |
| Route maps `:llm_unavailable` → 202, else 200 at [api.rb:42](../app/application/controllers/api.rb#L42) | ✓ matches | This is the only place the HTTP status code is set on the success path |

**Two extra findings the meeting note does not mention** — flagged so we can
decide whether to absorb them into this PR or defer:

1. **Roda's `:json` plugin** is enabled in [application.rb:14](../config/application.rb#L14),
   so returning a Hash from `r.post` auto-serializes to JSON. We can keep
   returning a Hash from the route (no `.to_json` call needed) even after
   introducing a representer — call `.to_hash` on the representer.
2. **`Services::TutorChatResult`** already exists at
   [tutor_chat_result.rb](../app/application/services/tutor_chat/tutor_chat_result.rb)
   with a `status` attribute (`'ok' | 'refused'`), but it is only used by the
   *legacy* `TutorOrchestrator` / `HandleTutorChat` pair, which is **not wired
   into any route**. The live endpoint uses `RunTutorChat` and builds plain
   hashes. We do **not** repurpose this class — its vocabulary (`ok` / `refused`)
   conflicts with the new one (`done` / `forbidden` / `unavailable`) and
   touching it widens the blast radius. See §7 Risk R3.

---

## 3. Target wire contract

Restated from the meeting note in one place for easy diffing against code.

### 3.1 Success body (HTTP 200 / 202)

| Field | Type | Present when | Source |
|---|---|---|---|
| `log_id` | int | always | `prompt_logs.id` from `persist_log` |
| `status` | enum string | always | One of `"done"`, `"forbidden"`, `"unavailable"` |
| `content` | string | always | Tutor LLM reply (done / unavailable) **or** Socratic redirect template (forbidden) |
| `usage` | object | `done`, `unavailable` only | `llm_reply.usage` — **omitted** (key not present) when forbidden |

HTTP status code:

| `status` | HTTP |
|---|---|
| `done` | 200 |
| `forbidden` | 200 |
| `unavailable` | 202 |

### 3.2 Error body (HTTP 4xx / 5xx) — unchanged envelope, one mapping change

Uses the existing `Response::Result` → `Representer::HttpResponse` pipeline.
**Only change** is remapping the missing-key path from 401 to 403.

| Failure tag (service) | `SERVICE_FAILURE_STATUS` → | HTTP |
|---|---|---|
| `:bad_request` | `:bad_request` | 400 |
| `:forbidden` ← *new* (was `:unauthorized`) | `:forbidden` ← *new row* | **403** |
| `:not_found` | `:not_found` | 404 |
| `:upstream_error` | `:upstream_error` | 502 |
| `:upstream_timeout` | `:upstream_timeout` | 504 |
| `:db_error` | `:internal_error` | 500 |

The pre-existing `unauthorized: :unauthorized` row in `SERVICE_FAILURE_STATUS`
stays — it is still used by `/guard_checks`, which is out of scope.

---

## 4. File-by-file change list

### 4.1 `app/presentation/representers/tutor_chat_representer.rb` — **CREATE**

Following the conventions in [presentation/representers/SKILL.md](../app/presentation/representers/SKILL.md):
class name mirrors the DTO, one `property` per documented field, no
conditional-on-user logic.

The DTO is intentionally a tiny `Data.define` (placed in the same file for
locality — `prompt_log_representer.rb` does not need a sibling DTO because
`Entity::PromptLog` already exists; here there is no entity). The `usage`
property is declared **unconditionally** (R6) so every success response —
including `forbidden` — emits the same key set; the value on the forbidden
branch is `null`.

```ruby
# frozen_string_literal: true

require 'roar/decorator'
require 'roar/json'

module Tyla
  module Response
    TutorChat = Data.define(:log_id, :status, :content, :usage)
  end

  module Representer
    class TutorChat < Roar::Decorator
      include Roar::JSON

      property :log_id
      property :status
      property :content
      property :usage   # R6: always emitted; value is null on forbidden
    end
  end
end
```

> **R5 confirmed.** Class is `Representer::TutorChat`, matching the
> `Representer::PromptLog` convention already in the repo.
>
> **R6 confirmed.** The `usage` property is declared *unconditionally* — no
> `if:` predicate — so it always appears in the JSON body. For the forbidden
> branch the value is the Ruby `nil`, which Roar serializes as JSON `null`.
> Every success response therefore has the same key set
> (`log_id`, `status`, `content`, `usage`).

### 4.2 `app/application/services/tutor_chat/run_tutor_chat.rb` — **EDIT**

Three changes, all localized:

| Line(s) today | Change | After |
|---|---|---|
| `21` `Failure[:unauthorized, …]` | rename failure tag (R5 confirmed) | `Failure[:forbidden, 'missing X-LLM-Key']` |
| `40` `Success([:blocked, build_blocked_response(...)])` | rename kind for symmetry with body `status` | `Success([:forbidden, build_forbidden_response(log.id)])` |
| `61` `Success([llm_unavailable ? :llm_unavailable : :ok, response])` | rename kinds for symmetry | `Success([llm_unavailable ? :unavailable : :done, response])` |
| `88-107` inline `build_*_response` | replace with DTO-returning helpers | see below |

The two private builders become:

```ruby
def build_forbidden_response(log_id, project_id)
  Response::TutorChat.new(
    log_id:  log_id,
    status:  'forbidden',
    content: Infrastructure::Filesystem::RefusalLoader.load(project_id),  # R4
    usage:   nil                                                          # R6: serialized as null
  )
end

def build_ok_response(log_id, llm_reply, llm_unavailable:)
  Response::TutorChat.new(
    log_id:  log_id,
    status:  llm_unavailable ? 'unavailable' : 'done',  # R2: no more :warning
    content: llm_reply.content,
    usage:   llm_reply.usage
  )
end
```

The blocked branch at line 40 changes to pass `params[:project_id]`:

```ruby
if !llm_unavailable && !guard_result.allowed?
  return Success([:forbidden, build_forbidden_response(log.id, params[:project_id])])
end
```

The route wraps the DTO with `Representer::TutorChat` and calls `.to_hash` —
see §4.3. The service no longer returns plain hashes.

> **R1 / R2 confirmation in code.** `attack_probability`, `evaluation`, and
> `warning` are removed from the response. The `persist_log` helper at
> [run_tutor_chat.rb:74-86](../app/application/services/tutor_chat/run_tutor_chat.rb#L74-L86)
> is **untouched** — `attack_probability` and `evaluation` continue to be
> written to `prompt_logs` and remain queryable via `GET /api/v1/prompt_logs`.

### 4.3 `app/application/controllers/api.rb` — **EDIT**

Two changes:

| Line(s) | Change |
|---|---|
| `8-16` `SERVICE_FAILURE_STATUS` | add `forbidden: :forbidden,` row |
| `27-44` `tutor_chats` POST block | update `kind` symbols + wrap DTO with representer |

After:

```ruby
SERVICE_FAILURE_STATUS = {
  bad_request:      :bad_request,
  unauthorized:     :unauthorized,   # still used by /guard_checks
  forbidden:        :forbidden,      # new — used by /tutor_chats
  not_found:        :not_found,
  cannot_process:   :cannot_process,
  upstream_error:   :upstream_error,
  upstream_timeout: :upstream_timeout,
  db_error:         :internal_error
}.freeze

# inside r.on 'tutor_chats' do … r.post do
kind, dto = outcome.value!
response.status = (kind == :unavailable ? 202 : 200)
Representer::TutorChat.new(dto).to_hash
```

`r.halt` and the `Response::Result` envelope on the failure path are
unchanged. Because `Response::Result` already accepts `:forbidden`
(see [result.rb:10](../app/presentation/responses/result.rb#L10)) and
`HttpResponse::HTTP_CODE` already maps it to 403
(see [http_response.rb:30](../app/presentation/representers/http_response.rb#L30)),
the new row is the only wire-up needed.

### 4.4 `doc/api_tutor_chats.md` — **EDIT**

Rewrite the **Response** section (lines 96-152) and the **Error responses**
table (lines 156-171):

- Replace each `allowed: …` body example with `status: "done"/"forbidden"/"unavailable"`.
- In the blocked example, rename the `refusal` field to `content`, drop the
  `attack_probability` and `evaluation` fields, and remove the
  "When `allowed` is `false`, display the `refusal` string…" hint
  (clients now key off `status` instead).
- In the unavailable example, drop the `warning` field (the 202 status code +
  `status: "unavailable"` carry the same signal without the extra string).
- In the error table, change the `401 / unauthorized` row to
  `403 / forbidden` with the rationale paragraph from the meeting note.
- Update the ASCII sequence diagram at lines 35-36 from `{ allowed, content, … }`
  to `{ status, content, … }`.

The "Composed system prompt" section (lines 175-216) is untouched.

### 4.5 Test suite

**Update — [spec/application/services/run_tutor_chat_spec.rb](../spec/application/services/run_tutor_chat_spec.rb)**

The current spec asserts on the inline hash. After the change the service
returns a `Response::TutorChat` DTO, not a Hash, so the assertions must
move from `payload[:allowed]` → `dto.status`.

| Existing assertion | Change to |
|---|---|
| `outcome.failure.first.must_equal :unauthorized` (line 107) | `:forbidden` |
| `kind.must_equal :ok` (line 125) | `:done` |
| `payload[:allowed].must_equal true` (line 125-126) | `dto.status.must_equal 'done'` |
| `payload[:usage][:input_tokens].must_equal 10` (line 127) | `dto.usage[:input_tokens].must_equal 10` |
| `kind.must_equal :blocked` (line 145) | `:forbidden` |
| `payload[:allowed].must_equal false`, `payload[:refusal]…` (lines 146-149) | `dto.status.must_equal 'forbidden'`; `dto.content.must_include "Let's redirect"` (loaded from TUTOR.md fixture); `dto.usage.must_be_nil` |
| `kind.must_equal :llm_unavailable` (line 158) | `:unavailable` |
| `payload[:warning]…` (line 161) | **delete** — `warning` field is gone; `:unavailable` kind + 202 carry the same signal |

**Create — `spec/presentation/representers/tutor_chat_representer_spec.rb`**

Mirror the structure of [`prompt_log_representer_spec.rb`](../spec/presentation/representers/prompt_log_representer_spec.rb).
Cover:

- All four fields present on a `done` DTO → emitted as `log_id`, `status`, `content`, `usage`
- A `forbidden` DTO with `usage: nil` → JSON contains `"usage": null` (key present, value null — R6)
- `to_json` round-trip preserves the same field set
- `status` accepts each of `'done' | 'forbidden' | 'unavailable'`

> No new spec is needed for `api.rb`; the route-level behavior (status code
> selection, representer wiring) is covered by the service spec via the
> kind-symbol assertions, plus the representer spec for shape.

### 4.6 R4 — `forbidden` content lives in TUTOR.md

The decision: the refusal text is **per-tutor**, sourced from the same
`TUTOR.md` that already defines the persona. We append a new
`## Refusal Message` section to the fixture and add a small loader that
extracts just that section.

#### 4.6.1 Edit `spec/fixtures/assignments/CSDS-HW2/tutors/tutor-guide/TUTOR.md`

Append the new section at the end of the file (after the existing
`## Enforcement` block):

```markdown
## Refusal Message
Let's redirect. Instead of asking for the answer, what step would you take first to approach this problem?
```

> **Side-effect note.** `TutorPersonaLoader.load` returns the **whole**
> file contents, which means the tutor LLM's system prompt will now also
> include the `## Refusal Message` section. This is acceptable — it just
> shows the tutor LLM the kind of redirect language used elsewhere — and
> keeps the loader logic dead simple. If we later decide the tutor LLM
> should not see this section, we can have `TutorPersonaLoader` strip it
> before returning. Not done in this PR.

#### 4.6.2 Create `app/infrastructure/filesystem/tutor_chat/refusal_loader.rb`

Parallel structure to
[`TutorPersonaLoader`](../app/infrastructure/filesystem/tutor_chat/tutor_persona_loader.rb)
— same fixture path, same `_project_id` parameter (ignored in Phase 1, kept
in the signature so the future `project_id`-keyed migration is a
search-and-replace).

```ruby
# frozen_string_literal: true

module Tyla
  module Infrastructure
    module Filesystem
      # Reads the "## Refusal Message" section out of the tutor's TUTOR.md.
      # Shares the source file with TutorPersonaLoader on purpose: per-tutor
      # refusal text lives next to per-tutor persona text, in one file.
      module RefusalLoader
        FIXTURE_PATH = File.expand_path(
          '../../../../spec/fixtures/assignments/CSDS-HW2/tutors/tutor-guide/TUTOR.md',
          __dir__
        )

        HEADING = '## Refusal Message'

        def self.load(_project_id)
          content = File.read(FIXTURE_PATH)
          match   = content.match(/^#{Regexp.escape(HEADING)}\s*\n(.*?)(?=^##\s|\z)/m)
          raise Errno::ENOENT, "no '#{HEADING}' section in #{FIXTURE_PATH}" if match.nil?

          match[1].strip
        end
      end
    end
  end
end
```

The regex captures everything after the `## Refusal Message` heading until
the next `## ` heading (or end of file), then `.strip`s whitespace. It
raises `Errno::ENOENT` if the section is missing, which `RunTutorChat`
already maps to `Failure[:not_found, …]` at
[run_tutor_chat.rb:66-67](../app/application/services/tutor_chat/run_tutor_chat.rb#L66-L67)
— so a missing section becomes a 404, which is the right wire behaviour for
"can't find an artefact".

#### 4.6.3 Update `spec/infrastructure/filesystem/tutor_chat/tutor_chat_loaders_spec.rb`

Add `require 'app/infrastructure/filesystem/tutor_chat/refusal_loader.rb'` to
the `require` list, and add two new `it` blocks:

- `RefusalLoader.load('HW2')` returns a non-empty string containing the
  Socratic redirect (`"Let's redirect"`)
- `RefusalLoader.load('anything')` works (ignores project_id in Phase 1)

#### 4.6.4 Retire `Values::RefusalTemplates.for` for `/tutor_chats` only

`RefusalTemplates.for` (random sample of 3 strings) is **still used** by
`/guard_checks` at [run_guard_check.rb:67](../app/application/services/guard/run_guard_check.rb#L67).
Leave it alone — `/guard_checks` is out of scope. Only `RunTutorChat`
switches to `RefusalLoader`. No deletion needed.

---

## 5. Implementation order (single PR, no flag)

Single PR. Steps below are ordered so the suite stays green at each step
(except the §5 step 4-5 pair, which must land together because the symbol
rename in `RunTutorChat` and the table change in `api.rb` are
inter-dependent).

1. **Edit** `spec/fixtures/assignments/CSDS-HW2/tutors/tutor-guide/TUTOR.md` — append `## Refusal Message` section (§4.6.1).
2. **Create** `app/infrastructure/filesystem/tutor_chat/refusal_loader.rb` (§4.6.2).
3. **Update** `spec/infrastructure/filesystem/tutor_chat/tutor_chat_loaders_spec.rb` — add `RefusalLoader` coverage (§4.6.3).
4. **Create** `app/presentation/representers/tutor_chat_representer.rb` (DTO + representer, §4.1).
5. **Create** `spec/presentation/representers/tutor_chat_representer_spec.rb` (§4.5).
6. **Edit** `app/application/services/tutor_chat/run_tutor_chat.rb` — switch to DTO, rename failure tag + success kinds, drop the old fields, wire `RefusalLoader` (§4.2). *Suite will momentarily fail until step 7.*
7. **Edit** `app/application/controllers/api.rb` — add `:forbidden` row, swap kind symbols, wrap DTO with representer (§4.3). *Suite back to green.*
8. **Update** `spec/application/services/run_tutor_chat_spec.rb` per §4.5.
9. **Update** `doc/api_tutor_chats.md` per §4.4.
10. Run full suite: `bundle exec rake spec` (or whichever Rakefile target maps to minitest).

Steps 6 + 7 should be committed together. The other steps can be separate
commits.

---

## 6. Out of scope (explicitly)

- `POST /api/v1/guard_checks` — still emits `allowed: bool`, still maps
  missing key to 401. Tracked as an open question on the parent doc; aligning
  it is a separate decision because it has its own client (the TUI calls it
  *before* `/tutor_chats`).
- `Services::HandleTutorChat` and `Services::TutorOrchestrator` — legacy path
  not reachable from any route. No reason to touch them in this PR; if we
  decide to retire them later, that is a separate refactor.
- Issue 2 (token-budget trimming) and Issue 3 (TUI usage display) — covered
  by the parent doc.
- `prompt_logs` table schema — unchanged. `attack_probability` and
  `evaluation` continue to be persisted; we only stop emitting them in the
  `/tutor_chats` blocked response.

---

## 7. Remaining decisions

**All six are resolved (R1-R6) — see §0.** No outstanding decisions block
implementation. Reverse-out risks worth flagging for your final read:

| Area | Risk | Mitigation |
|---|---|---|
| TUI compatibility | TUI is currently coded against `allowed: bool` + `refusal:` / `warning:`. After this PR, it must read `status` and `content` instead. | Issue 3 (TUI usage display) is sequenced *after* this PR per the parent doc's implementation order — TUI work will pick up the new contract |
| TUTOR.md side-effect | Adding `## Refusal Message` puts the refusal text inside the tutor's system prompt. | Acceptable — see §4.6.1 note. If undesirable later, strip in `TutorPersonaLoader` |
| `/guard_checks` divergence | Still returns `allowed: bool` after this PR | Documented in §6 and parent-doc open questions; next meeting decides |

---

## 8. Compatibility evaluation — is this plan executable today?

| Question | Answer |
|---|---|
| Are all referenced files / line ranges still accurate against `HEAD`? | Yes (verified at commit `b4139e9` on 2026-05-27) |
| Does any required infrastructure (`Response::CODES`, `HTTP_CODE`, Roar, `:json` plugin) already exist? | Yes — `:forbidden` is already a known status; only the `SERVICE_FAILURE_STATUS` row is missing |
| Does the change require a DB migration? | No — `prompt_logs` schema is untouched |
| Does the change require a new gem? | No — Roar / dry-monads / Roda are all in use |
| Does any other endpoint break as a side effect? | No — `SERVICE_FAILURE_STATUS` change is additive; `/guard_checks` keeps using `:unauthorized` |
| Are the existing test fixtures and `Infrastructure::LlmResponse` shape sufficient? | Yes — `usage` is already a Hash; no new mocks needed |
| Does the documented frontend behaviour (TUI) need to change to consume the new shape? | **Yes** — but that is Issue 3's TODO, intentionally sequenced after this one |

**Conclusion:** This plan is **fully decided and executable**. The
implementation surface is:

- **2 new files** — `tutor_chat_representer.rb`, `refusal_loader.rb`
- **3 edited files** — `run_tutor_chat.rb`, `api.rb`, `tutors/tutor-guide/TUTOR.md` (fixture)
- **1 new spec** — `tutor_chat_representer_spec.rb`
- **2 updated specs** — `run_tutor_chat_spec.rb`, `tutor_chat_loaders_spec.rb`
- **1 doc update** — `doc/api_tutor_chats.md`

All changes are reversible (no migrations, no new deps, additive to
`SERVICE_FAILURE_STATUS`). Ready to start when you give the go.

---

## 9. Suggested commit titles (for reference)

1. `feat(api): add Response::TutorChat DTO and representer`
2. `refactor(tutor_chat): build response via DTO; rename kinds to done/forbidden/unavailable`
3. `feat(api): map missing X-LLM-Key to 403 Forbidden on /tutor_chats`
4. `test(tutor_chat): assert new status enum + 403 mapping`
5. `docs(api): rewrite /tutor_chats response contract`

---

## 10. Appendix — what `HandleTutorChat` / `TutorOrchestrator` are (R3)

You asked what this code is. Short answer: an **earlier-generation,
parallel implementation of the same endpoint** that was never wired into a
route after the recent refactor. It lives at:

- [`app/application/services/tutor_chat/handle_tutor_chat.rb`](../app/application/services/tutor_chat/handle_tutor_chat.rb)
- [`app/application/services/tutor_chat/tutor_orchestrator.rb`](../app/application/services/tutor_chat/tutor_orchestrator.rb)
- [`app/application/services/tutor_chat/tutor_chat_input.rb`](../app/application/services/tutor_chat/tutor_chat_input.rb)
- [`app/application/services/tutor_chat/tutor_chat_result.rb`](../app/application/services/tutor_chat/tutor_chat_result.rb)
- specs: `spec/application/services/handle_tutor_chat_spec.rb`, `tutor_orchestrator_spec.rb`

### How it differs from the live `RunTutorChat`

| Aspect | `HandleTutorChat` + `TutorOrchestrator` (legacy) | `RunTutorChat` (live) |
|---|---|---|
| Wired into a route? | ❌ No — grep `app/application/controllers/` shows no caller | ✅ Yes — [api.rb:28](../app/application/controllers/api.rb#L28) |
| Mode handling | Multi-mode via `PolicyLoader` | Single tutor persona via `TutorPersonaLoader` |
| Rate limiting | Embeds `RateLimiter` per student | None |
| Response shape | Custom `TutorChatResult` value object (`'ok' / 'refused'`) | Plain Hash (`allowed: bool`) — soon → DTO + representer |
| Structured logging | Emits per-call JSON line to `$stdout` | None |
| DB write | Two-step: insert empty row, then `Repository.update` | One-step: insert with guard result already in place |

### Why it still compiles

Both classes are referenced by their own specs, so the test suite covers
them — but the `Roda` route in `app/application/controllers/api.rb` does not
reach them. They are effectively **dead code from the perspective of HTTP
traffic**.

### Recommendation (for a separate PR — not this one)

Two reasonable paths:

1. **Delete and reclaim the surface area.** Remove the four files above and
   their specs. Risk: low — no caller. Benefit: removes ~250 lines of
   parallel-implementation confusion, kills the diverging `'ok' / 'refused'`
   status vocabulary so only the new `done / forbidden / unavailable`
   remains.
2. **Promote.** If `HandleTutorChat`'s extras (rate limiting, structured
   logging) are actually wanted, port them into `RunTutorChat` and *then*
   delete the legacy pair. This is a bigger PR.

I recommend path (1) once `RunTutorChat` is the only `/tutor_chats`
implementation in use, but defer either decision to a follow-up so this PR
stays focused on the wire contract.

**Suggested follow-up plan file:** `plans/2026-05-2X-retire-legacy-tutor-orchestration.md`
(date to fill in when scheduled). Acceptance criteria: full suite green
after deleting the four files + two specs; no production route or service
references `HandleTutorChat`, `TutorOrchestrator`, `TutorChatInput`, or
`TutorChatResult`.
