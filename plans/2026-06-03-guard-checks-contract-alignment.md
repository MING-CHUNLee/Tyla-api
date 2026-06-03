# Plan — Align `guard_checks` code with `doc/api_guard_checks.md`

> **Date:** 2026-06-03
> **Status:** Ready to implement
> **Scope:** Workstream A of [`2026-06-03-agentic-tutor-backend.md`](./2026-06-03-agentic-tutor-backend.md) — make the live `POST /api/v1/guard_checks` endpoint match the **TARGET CONTRACT** in [`doc/api_guard_checks.md`](../doc/api_guard_checks.md).
> **Out of scope:** Workstream B (`tutor_chats` `file_context` / `actions[]` / `guard_log_id` verification) — tracked separately in the parent plan.

---

## 0. Goal

The doc is a contract-first **target**; the code has not caught up. After this plan,
`guard_checks` returns the unified `status` enum (`done` / `forbidden` / `unavailable`),
maps a missing `X-LLM-Key` to **403** (not 401), emits `usage`, and drops
`allowed` / `attack_probability` / `evaluation` / `warning` from the response body.

---

## 1. Gap analysis (verified against HEAD)

| # | Doc requirement | Current code | File |
|---|-----------------|--------------|------|
| G1 | Response keys = `log_id`, `status`, `refusal`, `usage` only | Emits `log_id`, `allowed`, `attack_probability`, `evaluation`, `refusal?`, `warning?` | [run_guard_check.rb:57-70](../app/application/services/guard/run_guard_check.rb#L57-L70) |
| G2 | `status` ∈ `done`/`forbidden`/`unavailable` | No `status` field; success kinds are `:ok`/`:llm_unavailable` | [run_guard_check.rb:45-50](../app/application/services/guard/run_guard_check.rb#L45-L50) |
| G3 | Missing key → **403** `forbidden` | `Failure[:unauthorized, ...]` → 401 | [run_guard_check.rb:17](../app/application/services/guard/run_guard_check.rb#L17) |
| G4 | `usage` = guard judge tokens on `done`/`forbidden`; `null` on `unavailable` | `usage` never emitted (it lives on `GuardResult#usage` but is dropped) | [run_guard_check.rb:57-70](../app/application/services/guard/run_guard_check.rb#L57-L70) |
| G5 | Body produced via a `Representer` + DTO (uniform shape, like `tutor_chats`) | Returns a raw `Hash` directly from the route | [api.rb:67-69](../app/application/controllers/api.rb#L67-L69) |
| G6 | HTTP 202 only on `unavailable` | Keyed off `:llm_unavailable` (correct logic, wrong symbol name) | [api.rb:68](../app/application/controllers/api.rb#L68) |
| G7 | `refusal` is the blocked-message field, declared on every body (`null` when absent) | `:refusal` only added when blocked; key absent otherwise | [run_guard_check.rb:67](../app/application/services/guard/run_guard_check.rb#L67) |

Already correct (no change): request validation contract
([guard_check.rb](../app/application/requests/guard_check.rb)) matches the doc's body
table; `SERVICE_FAILURE_STATUS` already maps `:bad_request → 400`, `:forbidden → 403`,
`:db_error → :internal_error → 500` ([api.rb:8-18](../app/application/controllers/api.rb#L8-L18));
the judged `prompt` is already persisted to `prompt_logs`
([run_guard_check.rb:33-43](../app/application/services/guard/run_guard_check.rb#L33-L43)) —
satisfies the §3.3 prerequisite for Workstream B.

---

## 2. Changes

This mirrors exactly what Issue-1 did for `tutor_chats`: **DTO + Representer**, kind-symbol
rename, reuse the existing `SERVICE_FAILURE_STATUS` `:forbidden` row.

### 2.1 CREATE `app/presentation/representers/guard_check_representer.rb`

Mirror [tutor_chat_representer.rb](../app/presentation/representers/tutor_chat_representer.rb):

```ruby
# frozen_string_literal: true

require 'roar/decorator'
require 'roar/json'

module Tyla
  module Response
    GuardCheck = Data.define(:log_id, :status, :refusal, :usage)
  end

  module Representer
    class GuardCheck < Roar::Decorator
      include Roar::JSON

      property :log_id
      property :status
      property :refusal, render_nil: true
      property :usage,   render_nil: true
    end
  end
end
```

`refusal` and `usage` are declared unconditionally with `render_nil: true` so every body
shares one key set (`null` when absent) — Issue-1 R6 uniform-shape principle.

### 2.2 EDIT `app/application/services/guard/run_guard_check.rb`

- **G3** — line 17: `Failure[:unauthorized, 'missing X-LLM-Key']` → `Failure[:forbidden, 'missing X-LLM-Key']`.
- **G1/G2/G4/G7** — replace `build_response` with a DTO builder:

```ruby
response = build_response(result: result, log_id: log.id, llm_unavailable: llm_unavailable)
if llm_unavailable
  Success([:unavailable, response])
else
  Success([result.allowed? ? :done : :forbidden, response])
end
```

```ruby
def build_response(result:, log_id:, llm_unavailable:)
  if llm_unavailable
    return Response::GuardCheck.new(log_id: log_id, status: 'unavailable', refusal: nil, usage: nil)
  end

  allowed = result.allowed?
  Response::GuardCheck.new(
    log_id:  log_id,
    status:  allowed ? 'done' : 'forbidden',
    refusal: allowed ? nil : Values::RefusalTemplates.for,
    usage:   result.usage
  )
end
```

Notes:
- `usage` comes from `GuardResult#usage` (already populated by `GuardAgent`, see
  [guard_agent.rb:26,33](../app/application/services/guard/guard_agent.rb#L26)).
- On `unavailable`, `usage` is forced to `nil` per the doc table (§Response L110) even
  though `GuardAgent` may carry a usage object on an unparseable-reply path — the contract
  says `null` when the judge "did not run".
- `attack_probability` / `evaluation` / `warning` are no longer in the response; they remain
  persisted via the `Entity::PromptLog` insert (lines 33-43, unchanged) and queryable through
  `GET /api/v1/prompt_logs`.

### 2.3 EDIT `app/application/controllers/api.rb` — `guard_checks` POST block (lines 53-70)

Swap the success-kind handling to use the representer and the new symbols:

```ruby
kind, dto = outcome.value!
response.status = kind == :unavailable ? 202 : 200
Representer::GuardCheck.new(dto).to_hash
```

The failure branch (lines 56-65) is unchanged — `SERVICE_FAILURE_STATUS.fetch(:forbidden)`
already yields `:forbidden` → 403 via `HttpResponse::HTTP_CODE`. Update the stale block
comment (lines 50-52) to describe the `status` enum instead of "allowed/blocked decision".

Confirm `Representer::GuardCheck` is autoloaded/required the same way `Representer::TutorChat`
is (check the app's require/loader manifest; add a require if representers are loaded explicitly).

### 2.4 Q-A2 — `:unauthorized` cleanup (defer, note only)

After this change, no caller produces `:unauthorized` (both `guard_checks` and `tutor_chats`
now use `:forbidden`). Leave the `SERVICE_FAILURE_STATUS` / `HTTP_CODE` `:unauthorized` rows
in place for now; removal is a separate low-risk follow-up once a grep confirms zero
producers. Out of scope here.

---

## 3. Specs

| Spec | Action |
|------|--------|
| `spec/presentation/representers/guard_check_representer_spec.rb` | **CREATE** — mirror [tutor_chat_representer_spec.rb](../spec/presentation/representers/tutor_chat_representer_spec.rb): assert `done` DTO emits all four keys; `forbidden` DTO has non-null `refusal`; `unavailable` DTO renders `refusal: null` and `usage: null`; JSON round-trip. |
| `spec/application/services/run_guard_check_spec.rb` | **CREATE** (none exists today) — scripted-LLM pattern from [run_tutor_chat_spec.rb](../spec/application/services/run_tutor_chat_spec.rb): allow verdict → `Success([:done, dto])` with `usage` present; block verdict (`attack >= 0.7`) → `[:forbidden, dto]` with `refusal` present; judge-raises → `[:unavailable, dto]` with `usage`/`refusal` nil; missing key → `Failure[:forbidden, ...]`; invalid body → `Failure[:bad_request, ...]`; `Sequel::Error` → `Failure[:db_error, ...]`. |

Run focused, then the full suite:

```powershell
bundle exec rake spec   # or: bundle exec ruby spec/.../run_guard_check_spec.rb
```

(Confirm the exact runner from the repo's `Rakefile` / existing CI invocation before running.)

---

## 4. Doc

[`doc/api_guard_checks.md`](../doc/api_guard_checks.md) is **already** the target contract.
Once the code lands and specs pass, **remove the TARGET banner** (lines 3-10) so the doc
reflects shipped reality. No other doc edits needed.

---

## 5. Order of work

1. CREATE representer (§2.1) + its spec (§3) → run spec.
2. EDIT service (§2.2) + CREATE service spec (§3) → run spec.
3. EDIT controller (§2.3) → run full suite.
4. Manual smoke (optional): `done`, `forbidden`, `unavailable`, missing-key (403),
   missing-field (400) against a local server.
5. Strip the doc's TARGET banner (§4).

## 6. Acceptance checklist

- [ ] `done` (200): body is exactly `{log_id, status:"done", refusal:null, usage:{...}}`.
- [ ] `forbidden` (200): `status:"forbidden"`, `refusal` non-null (from `RefusalTemplates`), `usage` present.
- [ ] `unavailable` (202): `status:"unavailable"`, `refusal:null`, `usage:null`.
- [ ] Missing `X-LLM-Key` → **403** `{status:"forbidden", message:"missing X-LLM-Key"}`.
- [ ] Missing body field → 400 `bad_request` with `errors`.
- [ ] No `allowed` / `attack_probability` / `evaluation` / `warning` keys in any response.
- [ ] `attack_probability` + `evaluation` still written to `prompt_logs`.
- [ ] TARGET banner removed from `doc/api_guard_checks.md`.
