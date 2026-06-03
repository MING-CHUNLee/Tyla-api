# Plan — Agentic Tutor (backend): guard_checks status alignment + tutor_chats file_context & actions

> **Date:** 2026-06-03
> **Status:** Design — mirrors the frontend plan; ready to spec implementation
> **Frontend counterpart:** `MindyCLI_demo/plans/2026-06-03-agentic-tutor-react-pipeline.md`
> **Closes open question from:** [`2026-05-27-issue-1-api-response-standardization.md`](./2026-05-27-issue-1-api-response-standardization.md) §6 (guard_checks status alignment was deliberately deferred)

---

## 0. Why this plan

The frontend is moving the tutor from a read-only chatbot to an **agentic tutor**:
guard runs as an explicit pre-call, the student's `file_context` is sent up, and the
tutor reply now carries structured `actions[]` (edit_file / execute_script / load_file)
that the TUI executes behind a human-approval gate.

Two backend workstreams fall out of that. They are independent and can ship separately:

| WS | Endpoint | Change | Nature |
|----|----------|--------|--------|
| **A** | `POST /api/v1/guard_checks` | `allowed: bool` → unified `status` enum; `401` → `403`; emit `usage` | Contract standardization — the deferred Issue-1 §6 follow-up |
| **B** | `POST /api/v1/tutor_chats` | accept `file_context` (request); emit `actions[]` (response) | New feature |

Workstream A is the backend counterpart of the frontend plan's §3.1; Workstream B is
the counterpart of §3.2 + §3.3.

---

## 1. Verified backend state today

| Claim | State | Source |
|-------|-------|--------|
| `tutor_chats` already uses `status` enum (`done` / `forbidden` / `unavailable`) | ✅ Done | [api_tutor_chats.md](../doc/api_tutor_chats.md) L100-104; shipped by Issue-1 |
| `tutor_chats` re-runs guard server-side (defence in depth) | ✅ Done | [api_tutor_chats.md](../doc/api_tutor_chats.md) L10-13 |
| `tutor_chats` maps missing `X-LLM-Key` to **403** | ✅ Done | Issue-1 plan §3.2 |
| `tutor_chats` request has **no** `file_context` field | ❌ Missing | [api_tutor_chats.md](../doc/api_tutor_chats.md) L64-70 |
| `tutor_chats` response has **no** `actions[]` field | ❌ Missing | [api_tutor_chats.md](../doc/api_tutor_chats.md) L110-117 |
| `guard_checks` still emits `allowed: bool` + `attack_probability` + `evaluation` | ⚠️ Not aligned | [api_guard_checks.md](../doc/api_guard_checks.md) L92-99 |
| `guard_checks` maps missing key to **401** | ⚠️ Not aligned | [api_guard_checks.md](../doc/api_guard_checks.md) L190-200 |

**Implication:** Workstream A is a small, well-understood change — it applies the exact
pattern Issue-1 already ran on `tutor_chats` (DTO + `Representer`, kind-symbol rename,
`SERVICE_FAILURE_STATUS` row) to `guard_checks`. Workstream B is genuinely new — and it
also **removes** the "re-runs guard server-side" behaviour noted above, replacing it with
a `guard_log_id` DB check (§3.3).

---

## 2. Workstream A — `guard_checks` status alignment

### 2.1 Target wire contract

Unified enum shared with `tutor_chats`:

```ruby
ApiStatus = done | forbidden | error | unavailable
```

**Success body (all HTTP 200 except unavailable):**

```jsonc
{
  "log_id":  42,
  "status":  "done",                                       // see table
  "refusal": "...",                                        // only on forbidden
  "usage":   { "input_tokens": 120, "output_tokens": 8 }   // guard judge tokens
}
```

| `status` | HTTP | Meaning | `refusal` | `usage` |
|----------|------|---------|-----------|---------|
| `done` | 200 | guard allowed (`attack_probability < 0.7`) | — | guard tokens |
| `forbidden` | 200 | guard blocked (`>= 0.7`) | present | guard tokens |
| `unavailable` | 202 | guard LLM failed — fail-open | — | `null` |
| `error` | (4xx/5xx) | request/judge error | — | — |

Notes:
- The frontend keys off `status` only; it reads `refusal` when `status == "forbidden"`.
- `attack_probability` / `evaluation` are **dropped from the response** but **still
  persisted** to `prompt_logs` (same R1 decision as Issue-1) and queryable via
  `GET /api/v1/prompt_logs`.
- Missing `X-LLM-Key` → **403** (was 401), matching the `tutor_chats` decision and
  Issue-1's rationale ("client-side authorization concern, not a server-issued
  credential check").

### 2.2 Implementation sketch (mirror Issue-1)

Apply the same shape Issue-1 used for `tutor_chats`:

1. **CREATE** `app/presentation/representers/guard_check_representer.rb` — a
   `Response::GuardCheck = Data.define(:log_id, :status, :refusal, :usage)` DTO + a
   `Representer::GuardCheck < Roar::Decorator`. `refusal` and `usage` declared
   unconditionally so every body shares one key set (`null` when absent), matching
   Issue-1 R6.
2. **EDIT** `app/application/services/guard/run_guard_check.rb` — replace the inline
   `allowed: bool` hash with the DTO; rename success kinds to `:done` / `:forbidden` /
   `:unavailable`; rename the missing-key failure tag `:unauthorized` → `:forbidden`
   (verify against L17, the line Issue-1 flagged).
3. **EDIT** `app/application/controllers/api.rb` — the `guard_checks` POST block: swap
   kind symbols, set HTTP 202 only on `:unavailable`, wrap the DTO with the representer.
   `SERVICE_FAILURE_STATUS` already has the `:forbidden → :forbidden (403)` row from
   Issue-1 — reuse it (no new row needed).
4. **EDIT** `doc/api_guard_checks.md` — rewrite Request/Response per §2.1 (see §5).
5. **UPDATE** specs — `run_guard_check_spec.rb` assertions move from `allowed` →
   `status`; add `guard_check_representer_spec.rb` mirroring `tutor_chat_representer_spec.rb`.

> The `:unauthorized` row in `SERVICE_FAILURE_STATUS` was kept by Issue-1 *"still used
> by /guard_checks"*. After this workstream, `guard_checks` switches to `:forbidden`
> too — re-check whether any other caller still needs `:unauthorized` before removing it.

---

## 3. Workstream B — `tutor_chats` file_context + actions

### 3.1 Request: accept `file_context`

```jsonc
{
  "course_id":    "CSDS",
  "project_id":   "HW2",
  "student_id":   "stu-abc",
  "guard_log_id": 42,                                              // ← NEW, required (see §3.3)
  "prompt":       "...",
  "history":      [ ... ],
  "file_context": "## Project Context ...\n## File Contents ..."   // ← NEW, optional
}
```

`file_context` is a **pre-assembled, token-budgeted plain-text block** built by the
frontend (it cannot reach the student's local filesystem). The backend injects it
verbatim into the composed system prompt.

**System-prompt injection point.** The current composer
(`Prompts::TutorSystemPrompt.build`, [api_tutor_chats.md](../doc/api_tutor_chats.md)
L201-226) already concatenates assignment / solution / student-WIP artefacts. Append
`file_context` as an additional `## Student Workspace (live)` section **after** the
on-disk artefacts, so the live frontend context supplements — not replaces — the
fixture artefacts. It participates in the existing newest-first token-budget trim.

> **Phase 1 vs Phase 2 interaction (Q-B1 resolved).** Today the backend reads the student
> WIP from a fixture and ignores `project_id`. `file_context` is the bridge to "real"
> student files before the `project_id`-keyed loader migration lands. **When `file_context`
> is present, suppress the fixture `## Student Workspace Files` section** — the frontend's
> live files are the source of truth, so the fixture WIP is dropped to avoid sending the
> same file twice (and to avoid showing the LLM a stale copy). When `file_context` is
> absent, inject the fixture WIP as before.

### 3.2 Response: emit `actions[]`

```jsonc
{
  "log_id":  101,
  "status":  "done",
  "content": "Step 1: ...\nHint 1: ...",
  "actions": [
    { "type": "edit_file", "path": "hw11.R",
      "patches": [ { "search": "mean(x)", "replace": "mean(x, na.rm=TRUE)" } ] }
  ],
  "usage": { "input_tokens": 4321, "output_tokens": 512 }
}
```

```
TutorAction =
  | { type: "edit_file";      path: string; patches: [{ search, replace }] }
  | { type: "execute_script"; code: string }          // frontend runs read-only r_exec
  | { type: "load_file";      path: string }
```

Backend responsibilities:
- Append the actions protocol to the tutor system prompt (the LLM emits an
  `<actions>[...]</actions>` JSON block after its prose). Parse it out of the LLM
  reply; `content` = prose with the block stripped; `actions` = parsed array.
- **`edit_file` uses search-replace patches, never full file content** — the LLM key's
  4000-token output ceiling can't carry whole files. (Matches the frontend plan and
  `MindyCLI_demo/plans/2026-06-02-tutor-actions-implementation.md`.)
- **Never emit `actions` when `status` is `forbidden` / `error`.**
- `actions` is **optional** — omit (or `[]`) when the tutor has no concrete suggestion.

Implementation: extend `Response::TutorChat` DTO with an `actions` property
(default `[]`); add a parser in the tutor-reply path that splits prose from the
`<actions>` block. The representer emits `actions` unconditionally (same R6 uniform-shape
principle).

### 3.3 Guard verification — replaces the internal guard (Q-A1 resolved)

**Decision:** `tutor_chats` **drops its internal guard LLM call entirely.** The guard runs
exactly once per turn, in the `/guard_checks` pre-call. To preserve the trust boundary —
the student is the adversary here, so a client must not be able to skip `/guard_checks`
and call `tutor_chats` directly — `tutor_chats` instead **requires a `guard_log_id`** and
verifies it against the DB:

1. The request carries `guard_log_id` (the `log_id` from the `/guard_checks` response).
2. The backend looks up that `prompt_logs` row and checks **all three**:
   - the row exists;
   - its guard status is `done` **or** `unavailable` (not `forbidden`);
   - its **stored `prompt` matches** this request's `prompt`.
3. Pass → call the tutor LLM. Fail → `status: "forbidden"`, no tutor call.

This is a single DB read — **no second LLM call** — so guard tokens are billed once (by
`/guard_checks`) and `tutor_chats.usage` is **tutor-only**.

**Status mapping (mirrors the guard log's verdict):**

| guard_log verdict | tutor_chats outcome | status | HTTP | usage |
|-------------------|---------------------|--------|------|-------|
| `done` + prompt matches | tutor replies | `done` | 200 | tutor only |
| `unavailable` + prompt matches | tutor replies (propagate fail-open) | `unavailable` | 202 | tutor only |
| missing / `forbidden` / prompt mismatch | refuse, no tutor call | `forbidden` | 200 | `null` |

**Prerequisite (lands with Workstream A):** `/guard_checks` must **persist the judged
`prompt`** with the log so step 2's prompt-match check is possible. (`prompt_logs` already
stores the prompt today — confirm the column is populated and queryable by `log_id`.)

**Why match the prompt, not just the log?** Otherwise a client could call `/guard_checks`
with a benign prompt, get a `done` `log_id`, then reuse it on `tutor_chats` with a
malicious prompt. Binding verification to the exact judged prompt closes that hole.

---

## 4. Per-turn cost & usage (RESOLVED — was: double-guard subtlety)

With the guard removed from `tutor_chats` (§3.3), a turn makes **two LLM calls total**,
one per route, with **no redundancy**:

```
frontend → POST guard_checks   → guard LLM       (usage = guard tokens)
frontend → POST tutor_chats    → tutor LLM only  (usage = tutor tokens; DB verify, no guard LLM)
```

The frontend sums `guard_checks.usage + tutor_chats.usage` for the token bar; because the
two are disjoint, there is **no double-counting**.

> This supersedes the earlier options table. The rejected alternative — keep the internal
> guard but report tutor-only usage (`B-keep-internal`) — was dropped in favour of removing
> the redundant guard call outright, since the `guard_log_id` DB check gives the same
> skip/fabricate-resistant trust boundary without a second judge call.

---

## 5. Doc edits

**Decision (2026-06-03): contract-first.** The docs were updated **ahead** of
implementation, each carrying a clear **TARGET** banner marking what is not yet built, so
frontend and backend code against one agreed contract. (This departs from Issue-1's
ship-doc-with-code convention — chosen deliberately for this cross-repo change.)

### 5.1 `doc/api_guard_checks.md` (Workstream A) — ✅ done (contract-first)
- Replace `allowed: bool` body with `status` enum; add the §2.1 status table.
- Rename the blocked field to `refusal` (frontend reads it); drop `attack_probability` /
  `evaluation` from the response (note they're still in `prompt_logs`).
- Add `usage` to the body.
- Change the `401 / unauthorized` row to `403 / forbidden` with Issue-1's rationale.
- Update the ASCII sequence diagram from `{ allowed, ... }` to `{ status, ... }`.
- Note that `/tutor_chats` enforces the gate by **verifying the returned `log_id`** (not by
  re-running the guard) and that the judged `prompt` must be persisted (§3.3 prerequisite).

### 5.2 `doc/api_tutor_chats.md` (Workstream B) — ✅ done (contract-first)
- Add `guard_log_id` to the request body + example; document the §3.3 verification and the
  **removal of the internal guard** (banner + Overview + sequence diagram).
- Add `file_context` to the request body table + example (§3.1).
- Add `actions[]` to every `done` response example + a field table; state the
  `edit_file` = search-replace-patch rule and the "no actions on forbidden/error" rule.
- Document the `## Student Workspace (live)` injection point + fixture-WIP suppression (Q-B1).
- `usage` description → "tutor only; guard billed via /guard_checks"; `forbidden` usage → `null`.

### 5.3 `MindyCLI_demo/docs/api.md` — ✅ rewritten (2026-06-03)
Was the **legacy** `/resolve` + `/edit` Gemini pipeline (port 9090) and did **not** describe
`guard_checks` / `tutor_chats`. Per user decision it was **fully rewritten** to the current
agentic architecture (guard pre-call → tutor → actions → approval), as a frontend
integration reference that links to these backend docs for canonical field specs.

---

## 6. Files to change (backend)

| File | WS | Change |
|------|----|--------|
| `app/presentation/representers/guard_check_representer.rb` | A | CREATE — DTO + representer |
| `app/application/services/guard/run_guard_check.rb` | A | EDIT — DTO, kind rename, 401→403; ensure the judged `prompt` is persisted to `prompt_logs` for `tutor_chats` §3.3 verification |
| `app/application/controllers/api.rb` | A+B | EDIT — guard_checks kinds/status; tutor_chats actions wiring |
| `doc/api_guard_checks.md` | A | EDIT — §5.1 |
| `app/presentation/representers/tutor_chat_representer.rb` | B | EDIT — add `actions` property |
| `app/application/services/tutor_chat/run_tutor_chat.rb` | B | EDIT — **remove internal guard LLM call**; accept `guard_log_id` + verify against DB (§3.3); accept `file_context` (suppress fixture WIP when present); parse `<actions>`, build actions[]; `usage` → tutor-only |
| `Prompts::TutorSystemPrompt` (composer) | B | EDIT — inject file_context + actions protocol |
| `doc/api_tutor_chats.md` | B | EDIT — §5.2 |
| specs (guard_check, tutor_chat, representers) | A+B | UPDATE/CREATE |

> Paths for `run_guard_check.rb`, `api.rb`, `run_tutor_chat.rb`, the representers and the
> prompt composer are taken from the Issue-1 plan's verified references; re-verify line
> numbers against `HEAD` before editing.

---

## 7. Open questions

- ✅ **Q-A1 RESOLVED — remove the internal guard, verify `guard_log_id`.** `tutor_chats`
  drops its guard LLM and DB-verifies the `guard_log_id` (exists, status ∈ {`done`,
  `unavailable`}, prompt matches); `usage` becomes tutor-only; no double-count. See §3.3 / §4.
- **Q-A2:** after `guard_checks` switches to `:forbidden`, is `:unauthorized` still used
  by any caller? If not, remove the `SERVICE_FAILURE_STATUS` row in a follow-up.
- ✅ **Q-B1 RESOLVED — suppress fixture WIP when `file_context` present.** Live frontend
  files are the source of truth; drop the fixture `## Student Workspace Files` section to
  avoid duplicate/stale copies. See §3.1.
- ✅ **Q-B2 RESOLVED — actions contract.** Shared schema = the `TutorAction` JSON shape
  (§3.2). Backend↔LLM delimiter is `<actions>...</actions>`; the backend parses it out;
  **malformed actions JSON → drop actions, keep prose.** The frontend only ever receives
  clean `actions[]`.
- **Q-B3 (guard sees file_context?):** frontend decided guard does **not** see
  file_context (prompt only). Since the guard now runs **only** in `/guard_checks` (which
  receives no `file_context`), this is automatically satisfied — no server-side guard sees
  file_context. Kept here as a confirmation item.

---

## 8. Relationship to existing backend plans

- **Closes** [2026-05-27-issue-1-api-response-standardization.md](./2026-05-27-issue-1-api-response-standardization.md)
  §6 open question (guard_checks status alignment) → Workstream A.
- **Touches the same usage accounting** discussed in
  [2026-05-28-issue-3-guard-token-aggregation.md](./2026-05-28-issue-3-guard-token-aggregation.md)
  — §4 here is the cross-endpoint consequence once guard is a separate billable call.
- **Extends** [2026-05-21-tutor-chat-api.md](./2026-05-21-tutor-chat-api.md) with the
  file_context input and actions output.
```
