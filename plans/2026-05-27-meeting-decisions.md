# Meeting Notes & Plan — 2026-05-27

> **Date:** 2026-05-27
> **Status:** CONFIRMED decisions from professor meeting
> **Builds on:** `2026-05-21-tutor-chat-api.md`
> **Last audited:** 2026-05-28 — Issues 1 & 2 are shipped to `main`;
> Issue 3 has design questions still open (see end of file).

---

## Summary

Following last week's system refactoring (loader migration to infrastructure layer),
three new topics were resolved in this meeting:

1. **Issue 1 — API response standardization** for `POST /api/v1/tutor_chats` — ✅ shipped
2. **Issue 2 — Backend ownership** of LLM input token trimming — ✅ shipped (via `BudgetAwarePromptAssembler`)
3. **Issue 3 — TUI visibility** of per-request token usage — ⏳ in design; backend contract ready, TUI work pending; see corrections section below

---

## Issue 1 — API Response Standardization

### Decision

Replace the `allowed: true/false` boolean with a unified `status` string field.
All successful outcomes (including blocked/unavailable) return **200 OK** or **202 Accepted**,
so the client cannot detect anything abnormal from the HTTP status code alone.

### Two-layer design (important)

There are **two independent concerns** that both use the word "status":

| Layer | Purpose | Vocabulary | Where it lives |
|---|---|---|---|
| **HTTP status code** | Transport-layer signal to the HTTP client | `200`, `202`, `400`, `403`, `404`, `500`, `502`, `504` | Set by route handler; see error table below |
| **Internal `status` (body field)** | Application-level classification of *what happened* — used for collecting and classifying student prompts in our pipeline | `done` / `forbidden` / `unavailable` / `error` | Inside the success-response JSON body |

These are **deliberately decoupled**. The HTTP status code tells the client
"the request was processed normally" (200/202), while the body's `status`
field tells our internal pipeline (and the TUI) *which branch* of the
tutor/guard flow produced the reply. A `forbidden` body with HTTP 200 is
correct: the request itself was valid, but the guard blocked the prompt.

### Internal status enum (success-body field)

| Value | Meaning | HTTP code |
|---|---|---|
| `done` | Tutor LLM replied successfully | 200 |
| `forbidden` | Internal guard blocked the prompt (attack_probability >= 0.7); tutor LLM was NOT called | 200 |
| `unavailable` | Guard LLM was unreachable; tutor LLM was called anyway (fail-open) | 202 |
| `error` | Unrecoverable backend error (DB write fail, missing artefact, upstream LLM down, etc.) | 4xx/5xx — see error table |

### Response shapes (revised from 2026-05-21 plan)

**Tutor reply — 200 OK**
```json
{
  "log_id":  101,
  "status":  "done",
  "content": "Step 1: ...\nHint 1: ...",
  "usage":   { "input_tokens": 4321, "output_tokens": 512 }
}
```

**Prompt blocked — 200 OK**

Guard determined `attack_probability >= 0.7`. Tutor LLM is NOT called.
Backend returns a Socratic redirect — the client sees a normal reply.

```json
{
  "log_id":  102,
  "status":  "forbidden",
  "content": "Let's redirect. Instead of asking for the answer, what step would you take first to approach this problem?"
}
```

> `usage` is omitted because no tutor LLM was called. `content` is a
> server-side templated refusal — not an LLM output.

**Guard unavailable — 202 Accepted**

Guard LLM was unreachable; we proceed fail-open and still call the tutor LLM.
The 202 status signals to the client that the response is valid but the guard
check was skipped.

```json
{
  "log_id":  103,
  "status":  "unavailable",
  "content": "<tutor reply>",
  "usage":   { "input_tokens": 4100, "output_tokens": 480 }
}
```

### HTTP error status codes (revised)

These responses use the **existing `Response::Result` envelope** (see
[http_response.rb:18](../app/presentation/representers/http_response.rb#L18))
— NOT the success-body `status` enum above. They are a different layer.

| HTTP | Reason phrase | Cause |
|---|---|---|
| 400 | `Bad Request` | Body validation failed |
| **403** | `Forbidden` | Missing or invalid `X-LLM-Key` (**was 401, now 403**) |
| 404 | `Not Found` | `project_id` doesn't map to an assignment folder |
| 413 | `Payload Too Large` | Request body > 2 MB |
| 500 | `Internal Server Error` | DB write or local file read failed |
| 502 | `Bad Gateway` | Tutor LLM call failed |
| 504 | `Gateway Timeout` | Tutor LLM call timed out (> 30 s) |

> **Key change:** `401 Unauthorized` → `403 Forbidden`.
> Rationale: the endpoint does not use session-based authentication;
> missing `X-LLM-Key` is a permission failure, not an identity challenge.
> Returning 401 would prompt clients to re-authenticate, which is misleading.
>
> **Naming note:** "Forbidden" appears in both layers (HTTP 403 *and* the
> internal `status: "forbidden"` body field). This is intentional — the
> professor wants this terminology preserved. Clients distinguish the two
> by the layer they're reading: HTTP status line vs. body field.

### TODO (Issue 1)

- [ ] **Create** `Representer::TutorChatRepresenter` (does not exist yet — the
      response is currently built inline by `build_blocked_response` /
      `build_ok_response` in [run_tutor_chat.rb:88-107](../app/application/services/tutor_chat/run_tutor_chat.rb#L88-L107)).
      Remove `allowed`, add `status`.
- [ ] Map missing-key failure to `:forbidden` (HTTP 403) instead of `:unauthorized` (401).
      Touches both [run_tutor_chat.rb:21](../app/application/services/tutor_chat/run_tutor_chat.rb#L21)
      (return tag) and the `SERVICE_FAILURE_STATUS` table in
      [api.rb:8-16](../app/application/controllers/api.rb#L8-L16) (add `:forbidden` mapping).
- [ ] Decide `forbidden` content source: keep `Values::RefusalTemplates.for`
      (currently used at [run_tutor_chat.rb:94](../app/application/services/tutor_chat/run_tutor_chat.rb#L94))
      or replace with the Socratic-redirect text in the new spec.
- [ ] Update `doc/api_tutor_chats.md` with new response shapes.
- [ ] **Interim risk:** `/guard_checks` still returns `allowed: bool`
      (see [run_guard_check.rb:57-70](../app/application/services/guard/run_guard_check.rb#L57-L70)).
      TUI will see two inconsistent shapes until next meeting decides whether to align.

---

## Issue 2 — Backend Owns LLM Input Token Trimming

### Decision

The frontend must NOT perform any token counting, trimming, or history
truncation. All token budget management is the backend's responsibility.

### Policy threshold (centralized in domain layer)

```
File: app/domain/policy/attack_policy.rb:5-11
Threshold: attack_probability >= 0.7
```

This constant must NOT be duplicated in the application or infrastructure layers.
**Verified:** grep across `app/` confirms only one occurrence — already centralized.

### Context assembly order (strict priority)

When composing the LLM prompt, load and include content in the following order,
dropping lower-priority items first if the token budget is exhausted:

```
1. Tutor persona         (TUTOR.md)            — always included, highest priority
2. Assignment text       (HW 02.docx.txt)      — always included
3. Reference solution    (Hw2.txt)             — always included
4. Student WIP file      (Hw2.Rmd)             — drop if budget is tight
5. Conversation history  (from request body)   — dynamic: include as many recent
                                                  turns as the remaining token
                                                  budget allows, newest-first
```

> History is filled **last** and trimmed dynamically.
> The backend calculates remaining budget after loading items 1–4,
> then walks history from the most recent turn backwards,
> stopping when no more turns fit.

### Frontend contract

- Frontend sends the **full** history it has — no client-side trimming.
- Backend silently trims; the client does not know how much history was used.
- Frontend must NOT count tokens or enforce any context window logic itself.

### Current gap (what does NOT exist yet)

The existing trimmer in
[tutor_system_prompt.rb:18-23](../app/application/prompts/builders/tutor_system_prompt.rb#L18-L23)
uses a fixed `MAX_HISTORY_TURNS = 10` cutoff — **not** a token budget.
Similarly, [tutor_system_prompt.rb:25-33](../app/application/prompts/builders/tutor_system_prompt.rb#L25-L33)
truncates student files at `MAX_FILE_LINES = 200` per file, with no
awareness of the overall prompt size. Both behaviors need to be replaced
with a budget-aware algorithm.

### Sub-plan required

This is **new functionality**, not a tweak. It deserves its own design doc
(suggested filename: `2026-05-28-token-budget-algorithm.md`) covering:

1. **Tokenizer choice** — character-count heuristic (~4 chars/token, simple
   but imprecise for CJK text) vs. integrating `tiktoken` (more accurate,
   but adds a native dependency). This decision **blocks** implementation.
2. **Budget source** — per-model context window (e.g. 128 K for gpt-4o)
   minus an output-token reservation. Where do we store the per-model
   budget table?
3. **Algorithm** — measure items 1–4 first, then fill history newest-first
   with the remainder; drop student file (item 4) if 1–3 already exceed
   the budget; surface an `error` status if even 1–3 won't fit.
4. **Telemetry** — should the response report how much history was trimmed?
   (Probably no, per Issue 1 "client cannot detect anomalies".)

### TODO (Issue 2)

- [ ] Write `2026-05-28-token-budget-algorithm.md` sub-plan and resolve the
      tokenizer-choice blocker
- [ ] Implement `Domain::TokenBudget` value object (per-model context window
      minus output reservation)
- [ ] Replace `MAX_HISTORY_TURNS` cutoff with budget-aware history trimmer
      (newest-first); extract to `Prompts::HistoryTrimmer`
- [ ] Replace per-file `MAX_FILE_LINES = 200` cap with budget-aware
      student-file dropping (drop the whole file if remaining budget < its size)
- [ ] Add specs: (a) history longer than budget is trimmed newest-first,
      (b) student file is dropped when persona+assignment+solution already
      consume the budget

---

## Issue 3 — TUI Quota Visibility (per-request usage reporting)

### Repo ownership

- **`Tyla-api` (this repo)** — only owns the response contract (the `usage`
  field shape). Contract work for the `done` / `forbidden` / `unavailable`
  cases is **already shipped** as part of Issue 1; the remaining backend
  work depends on the open questions below (guard-token accounting,
  DB logging).
- **`MindyCLI_demo/tyla` (sibling repo)** — owns the actual TUI display
  work (gateway validation, event-mapper forwarding, StatusBar rendering).
  This is where the bulk of Issue 3 lives.

### Context

Students are expected to supply their own GitHub Copilot Pro API key
(obtained via the GitHub Student Developer Pack). GitHub imposes the
following limits on that plan:

- Requests per minute
- Requests per day
- Tokens per request
- Concurrent requests

### Decision

**We do NOT track or display remaining quota.**

Rationale: students may use the same key outside our system (other tools,
personal projects). We cannot know their true remaining quota.

**We DO report per-request usage** so the student knows what this interaction
cost them. This is already present in the `usage` field of the `done` and
`unavailable` responses (see Issue 1 above).

### What the TUI should display

Update the StatusBar with per-turn token usage from the latest response.
No per-message line in the chat stream; no cumulative counter; no
quota-remaining calculation. Format (English, last turn only):

```
── model · context · turn 7 · 4321 in / 512 out ──
```

The `4321 in / 512 out` figure is the **sum of guard + tutor** tokens for
that turn (see Q1 below). On a `forbidden` reply, the figure reflects the
guard call only (tutor was never invoked).

### Important corrections (current vs. plan, 2026-05-28 audit)

1. **The contract for `forbidden` is changing.** Earlier wording said
   `forbidden` omits `usage`; the current code returns `usage: null` (key
   present, value null — see
   [tutor_chat_representer.rb:18](../app/presentation/representers/tutor_chat_representer.rb#L18)
   and [tutor_chat_representer_spec.rb:29–38](../spec/presentation/representers/tutor_chat_representer_spec.rb#L29-L38)).
   With Q1 resolved (sum guard + tutor), the new contract is: **every 2xx
   response carries `usage` with the combined guard+tutor token counts**
   for that turn. `forbidden` now reports the guard call's tokens (no
   longer null). Only `error` (non-2xx) responses lack the field.

2. **Guard tokens are currently dropped silently.** `GuardAgent.check`
   returns a `GuardResult` carrying only `probability` and `reason`
   ([guard_result.rb](../app/domain/values/guard_result.rb)). To honour
   Q1 the value object and the agent need a `usage` field; `RunTutorChat`
   then sums it with `llm_reply.usage` before populating the DTO.

3. **No DB record of token usage** — and per Q2, that stays so.
   Token counts are request-scoped only.

4. **No runtime validation on the TUI side.** The gateway
   (`MindyCLI_demo/tyla/src/infrastructure/api/tutor/tutor-chat-gateway.ts`,
   lines 93–96) does `data.usage?.input_tokens ?? 0` with no integer / range
   check. A bug or hostile backend could surface `NaN`, negative, or
   absurdly large numbers in the UI. Trivial to fix; flagging for the
   security audit.

### TODO (Issue 3)

**Backend (`Tyla-api`) — implement guard-token aggregation (Q1):**

- [x] Confirm `usage` is included in both `done` and `unavailable` response shapes (verified, see Issue 1)
- [ ] Extend `LlmResponse` parsing so guard calls also capture usage (currently `GuardAgent` discards it)
- [ ] Add `usage` field to `Domain::Values::GuardResult` (nullable — `nil` when guard was unreachable)
- [ ] In `RunTutorChat`: sum `guard_result.usage` and `llm_reply.usage` (handling each side being nil) before building `Response::TutorChat`; on the `forbidden` branch pass through the guard-only sum instead of `nil`
- [ ] Update `doc/api_tutor_chats.md`: replace the "`forbidden` returns `usage: null`" example with the new combined-usage shape; document that `usage` reflects guard+tutor sum
- [ ] Specs: `RunTutorChat` returns combined usage on `done`; returns guard-only usage on `forbidden`; returns tutor-only usage on `unavailable` (guard usage unknown)
- [ ] Representer spec: `usage` is no longer null on the `forbidden` DTO; drop the `render_nil` test case for `forbidden` and add a positive case

**TUI (`MindyCLI_demo/tyla`) — StatusBar wiring (Q3, Q4, Q5):**

- [ ] `tutor-chat-gateway.ts`: drop the special-case that omits `usage` on `forbidden` (now always present on 2xx); add runtime validation — input/output counts must be non-negative integers under a sane upper bound (e.g. 10⁶); on invalid, display `—`
- [ ] `agent-service.ts`: forward `usage.inputTokens` / `usage.outputTokens` through the `turn_saved` event payload (currently dropped at the mapper boundary)
- [ ] `shared/view-models/index.ts`: add `lastInputTokens?: number` / `lastOutputTokens?: number` to `StatusBarVM`; add `'tokens'` to `StatusBarItemKey`; *(Q5)* remove `'cost'` from the default `StatusBarDisplayConfig` items
- [ ] `event-mapper.ts`: populate the new VM fields from `turn_saved`; do NOT emit a per-message chat-stream line
- [ ] `StatusBar.tsx`: add a `tokens` renderer rendering `{lastInputTokens} in / {lastOutputTokens} out`; render `—` when either field is undefined or failed validation
- [ ] `App.tsx`: update `DEFAULT_STATUS_CONFIG` items list — replace `'cost'` with `'tokens'`
- [ ] *(optional, Q5 tentative)* `agent-service.ts`: stop maintaining `session.totalCostUSD` if no consumer remains (keep the field if other code paths still read it)
- [ ] Specs: gateway validation rejects null/negative/non-integer; event-mapper surfaces tokens on every 2xx turn; StatusBar renders `—` when fields are missing

---

## Cross-cutting changes required

> **Status as of 2026-05-28 audit.** Issues 1 and 2 are already shipped to
> `main`; the table below records the final outcome (some items diverged
> from the original sketch — notably no standalone `history_trimmer.rb`).

| File | Change | Status | Commit |
|---|---|---|---|
| `app/presentation/representers/tutor_chat_representer.rb` | Extract from inline `build_*_response`; emit `status` field; render `usage` with `render_nil: true` | ✅ DONE | `c748d98`, `cf5698f` |
| `app/application/services/tutor_chat/run_tutor_chat.rb` | Change `:unauthorized` → `:forbidden`; replace inline builders with DTO | ✅ DONE | `1e580c7`, `cf5698f` |
| `app/application/controllers/api.rb` | Add `:forbidden` to `SERVICE_FAILURE_STATUS` table | ✅ DONE | `1e580c7` |
| `app/application/prompts/builders/tutor_system_prompt.rb` | Removed — superseded by `BudgetAwarePromptAssembler` | ✅ DONE (replaced) | `b23148f` |
| `app/application/prompts/builders/budget_aware_prompt_assembler.rb` | **NEW** — unified persona+assignment+solution+student+history assembler with budget enforcement (replaces the planned `history_trimmer.rb` split) | ✅ DONE | `b23148f` |
| `app/domain/values/token_budget.rb` | Per-model context window value object | ✅ DONE | `b23148f` |
| `app/domain/values/tokenizer.rb` | Char-count tokenizer (per sub-plan) | ✅ DONE | `b23148f` |
| `doc/api_tutor_chats.md` | Update response contract docs | ✅ DONE | `90359fc` |
| `doc/api_tutor_chats.md` | Issue-3 rewrite: document combined guard+tutor `usage` on every 2xx, including `forbidden` | ⏳ TODO | — |
| `app/domain/values/guard_result.rb` | Add `usage` field (nullable) carrying guard-call token counts | ⏳ TODO (Q1) | — |
| `app/application/services/guard/guard_agent.rb` | Capture and return `LlmResponse#usage` on the guard call (currently dropped) | ⏳ TODO (Q1) | — |
| `app/application/services/tutor_chat/run_tutor_chat.rb` | Sum guard + tutor usage; pass through on all 2xx branches including `forbidden` | ⏳ TODO (Q1) | — |
| `spec/presentation/representers/tutor_chat_representer_spec.rb` | Update `forbidden` case — `usage` is no longer null | ⏳ TODO (Q1) | — |

> `app/domain/policy/attack_policy.rb` is **not** in this list — verified
> already centralized, no change needed.

---

## Implementation order

Original plan was Issue 1 → 3 → 2. As of 2026-05-28, **Issues 1 and 2 are
already merged** and the previously-blocking design questions (Q1–Q5) are
resolved. Recommended order for Issue 3 work:

1. **Backend — guard-token aggregation (Q1).** This changes the API
   contract (`forbidden` will start returning a non-null `usage`), so it
   has to land before the TUI ships against the new shape.
   - `GuardResult` gets `usage` field
   - `GuardAgent` captures `LlmResponse#usage`
   - `RunTutorChat` sums guard + tutor
   - Specs + representer specs updated
2. **Backend — doc rewrite.** Update `doc/api_tutor_chats.md` once the new
   contract is in.
3. **TUI — gateway hardening.** Drop the `forbidden`-special-case and add
   runtime validation against the new always-present `usage` shape.
4. **TUI — StatusBar wiring.** Forward usage through `agent-service.ts` →
   `event-mapper.ts` → `StatusBarVM` → `StatusBar.tsx`; remove `cost` from
   default items (Q5).
5. **TUI — specs.** Validation, mapper, renderer.

> **Coordination risk:** between step 1 and step 3, the TUI in production
> may temporarily see a non-null `usage` on `forbidden` while still ignoring
> it. That's harmless (just an unused field). The reverse ordering would
> not be — TUI hardening before contract change would assume a `null` that
> the backend stopped sending.

---

## Resolved decisions (2026-05-28)

Q1–Q5 from the previous draft were resolved by the project owner.
Q6–Q7 remain open and carry to the next meeting.

### Q1 — Guard-stage tokens: **summed into a single `usage`**

**Decision:** option (A) — guard + tutor tokens are summed by the backend
and returned as a single `usage` object. No split, no extra fields for
the student.

**Implications:**
- `GuardAgent.check` / `GuardResult` must surface the guard call's token
  usage (currently dropped — `guard_result.probability` and `.reason` only).
- `RunTutorChat` adds `guard_usage + tutor_usage` before building the DTO.
- **`forbidden` response no longer returns `usage: null`** — it returns
  `usage: { input_tokens: G_in, output_tokens: G_out }` reflecting the
  guard call. Only `error` (non-200) responses lack `usage`.
- `unavailable` (guard failed) → guard usage is unknown; report tutor only.
- The doc text saying "`forbidden` returns `usage: null`" must be removed
  (this overrides the earlier wording fix; now `usage` is always present
  on a 2xx response).

### Q2 — DB token logging: **no**

**Decision:** do NOT add `input_tokens` / `output_tokens` to `prompt_logs`.
Token usage stays request-scoped only; no historical record on the server.

### Q3 — UI placement: **StatusBar only**

**Decision:** display per-turn tokens in the StatusBar (last turn only,
no per-message line in the chat stream).

### Q4 — Display language: **English**

**Decision:** keep the existing English UI vocabulary. No i18n layer
needed for this scope.

### Q5 — Cumulative USD cost display: **remove** *(tentative)*

**Decision:** remove `totalCostUSD` from the default StatusBar items.
In backend-gateway mode the cost estimate is unreliable (we don't know
the per-token rate the student's key incurs).

> Marked tentative — original answer had a question mark. Re-confirm if
> this is mistaken before TUI work begins.

---

## Open questions (carry to next meeting)

1. **`/guard_checks` alignment** *(carry-over)* — does that endpoint also
   need to move from `allowed: bool` to a `status` string? Or keep it
   separate since it's a different client interaction? (Interim: TUI sees
   two shapes.)
2. **`forbidden` content source** *(carry-over)* — is the Socratic redirect
   message hardcoded (current: `Infrastructure::Filesystem::RefusalLoader`,
   reads `## Refusal Message` section of `TUTOR.md`), templated per
   assignment, or generated by a small LLM call?
