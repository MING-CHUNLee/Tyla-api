# Meeting Notes & Plan — 2026-05-27

> **Date:** 2026-05-27
> **Status:** CONFIRMED decisions from professor meeting
> **Builds on:** `2026-05-21-tutor-chat-api.md`

---

## Summary

Following last week's system refactoring (loader migration to infrastructure layer),
three new topics were resolved in this meeting:

1. API response standardization for `POST /api/v1/tutor_chats`
2. Backend ownership of LLM input token trimming
3. TUI visibility of per-request token usage

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

After each tutor reply, show the per-request token usage from the response:

```
Tokens used this turn: 4321 input / 512 output
```

No cumulative counter. No quota-remaining calculation.

### TODO (Issue 3)

- [ ] Confirm `usage` is included in both `done` and `unavailable` response shapes ✓ (see Issue 1)
- [ ] TUI (client) reads `usage.input_tokens` and `usage.output_tokens` and
      displays them after each reply
- [ ] `forbidden` and `error` responses omit `usage` — TUI must handle the
      missing field gracefully (no crash, no display)

---

## Cross-cutting changes required

| File | Change | Status |
|---|---|---|
| `app/presentation/representers/tutor_chat_representer.rb` | **CREATE** — extract from inline `build_*_response`; emit `status` field | new |
| `app/application/services/tutor_chat/run_tutor_chat.rb` | Change `:unauthorized` → `:forbidden`; drop inline response builders | edit |
| `app/application/controllers/api.rb` | Add `:forbidden` to `SERVICE_FAILURE_STATUS` table | edit |
| `app/application/prompts/builders/tutor_system_prompt.rb` | Replace fixed-cutoff trimming with budget-aware logic | edit (depends on sub-plan) |
| `app/domain/values/token_budget.rb` | **CREATE** — per-model context window value object | new |
| `app/application/prompts/history_trimmer.rb` | **CREATE** — newest-first budget-aware history filter | new |
| `doc/api_tutor_chats.md` | Update response contract docs | edit |

> `app/domain/policy/attack_policy.rb` is **not** in this list — verified
> already centralized, no change needed.

---

## Implementation order

Ship in this order to minimize cross-PR coupling:

1. **Issue 1 (API response shape)** — small, self-contained, unblocks the TUI.
2. **Issue 3 (TUI usage display)** — pure client work, depends only on Issue 1.
3. **Issue 2 (token-budget trimming)** — largest scope; gated on the
   tokenizer-choice sub-plan. Do this last so the API contract is stable
   before the trimmer changes the prompt assembly.

---

## Open questions (carry to next meeting)

1. **`/guard_checks` alignment** — does that endpoint also need to move from
   `allowed: bool` to a `status` string? Or keep it separate since it's a
   different client interaction? (Interim: TUI sees two shapes.)
2. **Tokenizer choice** — moved to the Issue 2 sub-plan; this is now a
   **blocker** for Issue 2, not just an open question.
3. **`forbidden` content source** — is the Socratic redirect message hardcoded
   (current: `Values::RefusalTemplates.for`), templated per assignment, or
   generated by a small LLM call?
