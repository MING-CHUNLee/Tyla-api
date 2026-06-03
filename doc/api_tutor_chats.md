# API Documentation — Tutor Chats

> **⚠️ Partial TARGET (as of 2026-06-03).** The `status` enum is **live** (shipped by
> Issue-1). Three **planned** changes from
> [`plans/2026-06-03-agentic-tutor-backend.md`](../plans/2026-06-03-agentic-tutor-backend.md)
> (Workstream B) are marked **NEW** / **CHANGED** where they appear:
> 1. `file_context` request field (NEW);
> 2. `actions[]` response field (NEW);
> 3. **the internal guard LLM is removed** — this route no longer re-runs the guard.
>    Instead it requires a `guard_log_id` from a prior `/guard_checks` pass and verifies
>    it against the DB (no LLM call); `usage` becomes **tutor-only** (CHANGED).
>
> Until the plan ships, the request has no `file_context` / `guard_log_id`, the route
> still re-runs the guard, and responses carry no `actions[]`.

## Overview

`POST /api/v1/tutor_chats` is the second leg of the guard → tutor pipeline.
Where `/guard_checks` runs the safety judge for the frontend, `/tutor_chats`
composes the full tutor prompt from on-disk assignment artefacts and forwards
it to the tutor LLM.

**Trust boundary (CHANGED — Workstream B).** This route no longer re-runs the guard
LLM. Instead it requires a `guard_log_id` — the `log_id` returned by a prior
`/guard_checks` call — and verifies against the DB that the log exists, its status was
`done` or `unavailable` (not `forbidden`), and its stored prompt matches this request's
`prompt`. The check is a single DB read (no second LLM call), so a client that skips or
fabricates `/guard_checks`, or reuses a guard pass for a different prompt, still cannot
bypass safety — and the guard's tokens are billed once, by `/guard_checks`.

```
MindyCLI                          Tyla-api                        LLM Provider
   │                                  │                               │
   │  POST /api/v1/tutor_chats        │                               │
   │  X-LLM-Key: <token>              │                               │
   │  { prompt, guard_log_id, ... }   │                               │
   │ ────────────────────────────────>│                               │
   │                                  │  verify guard_log_id          │
   │                                  │ ──────────> DB (no LLM)        │
   │                                  │  status in {done,unavailable} │
   │                                  │  & stored prompt matches?     │
   │                                  │                               │
   │                                  │  Load assignment/solution/    │
   │                                  │  persona from disk            │
   │                                  │  + inject file_context        │
   │                                  │                               │
   │                                  │  chat/completions (tutor)     │
   │                                  │ ─────────────────────────────>│
   │                                  │  { reply, usage }             │
   │                                  │ <─────────────────────────────│
   │  { log_id, status, content,      │                               │
   │    actions, usage }              │                               │
   │ <────────────────────────────────│                               │
```

---

## Endpoint

```
POST /api/v1/tutor_chats
```

---

## Request

### Headers

| Header | Required | Description |
|--------|----------|-------------|
| `Content-Type` | Required | Must be `application/json` |
| `X-LLM-Key` | Required | API key for the LLM provider. Used for both the guard call and the tutor call. Never stored in the database. |
| `X-LLM-Provider` | Optional | LLM provider name. Defaults to `openai`. Supported values: `openai`, `anthropic`. |
| `X-LLM-Model` | Optional | Model identifier. Falls back to `LLM_MODEL` env var, then `gpt-4o-mini`. |
| `X-LLM-Endpoint` | Optional | Override the LLM API base URL. Falls back to `OPENAI_API_BASE`, then the provider default. |

### Body (JSON)

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `course_id` | string | Required | Course identifier, e.g. `"CSDS"` |
| `project_id` | string | Required | Project identifier, e.g. `"HW2"`. Phase 1: any value resolves to the bundled `CSDS-HW2` fixture. |
| `student_id` | string | Required | Student identifier |
| `guard_log_id` | integer | Required **(NEW, Workstream B)** | The `log_id` returned by the `/guard_checks` pre-call **for this same `prompt`**. The backend verifies it (exists, status ∈ {`done`, `unavailable`}, stored prompt matches) before calling the tutor. Missing → `400`; invalid / `forbidden` / prompt-mismatch → `status: "forbidden"`. |
| `prompt` | string | Required | The student's message |
| `history` | array | Optional | Prior chat turns, in order. Each entry is `{ "role": "user" \| "assistant", "content": "..." }`. Capped at 500 KB at the transport layer. The backend then runs a token-budget trim (newest-first) so the assembled prompt fits the LLM channel's input window; oldest turns are silently dropped if needed. |
| `file_context` | string | Optional | **NEW (Workstream B).** Pre-assembled, token-budgeted plain-text block of the student's workspace, built by the frontend (the backend cannot reach the student's local filesystem). Injected verbatim into the system prompt under `## Student Workspace (live)`. See [Composed system prompt](#composed-system-prompt). |

### Example Request

```http
POST /api/v1/tutor_chats HTTP/1.1
Host: localhost:9292
Content-Type: application/json
X-LLM-Key: sk-xxxxxxxxxxxx

{
  "course_id":    "CSDS",
  "project_id":   "HW2",
  "student_id":   "stu-abc",
  "guard_log_id": 42,
  "prompt":       "Why is the Freedman-Diaconis rule least sensitive to outliers?",
  "history": [
    { "role": "user",      "content": "What are Sturges, Scott, and FD?" },
    { "role": "assistant", "content": "Hint 1: ..." }
  ],
  "file_context": "## Project Context\nWorking dir: ...\n## File Contents\n### Hw2.Rmd\n..."
}
```

---

## Response

All success responses share the same key set: `log_id`, `status`, `content`,
`usage`. The HTTP status code and the body's `status` field are two
independent layers — clients should key off `status` for branching.

| `status` value | HTTP | Meaning |
|---|---|---|
| `done` | 200 | `guard_log_id` valid (guard status `done`); tutor LLM replied |
| `forbidden` | 200 | `guard_log_id` missing / invalid / `forbidden`, or prompt mismatch; tutor LLM not called |
| `unavailable` | 202 | `guard_log_id` valid but its guard was fail-open (status `unavailable`); tutor LLM replied |

### Tutor reply — `status: "done"` (`200 OK`)

The guard allowed the prompt and the tutor LLM returned a reply.

```json
{
  "log_id":  101,
  "status":  "done",
  "content": "Step 1: ...\nHint 1: ...",
  "actions": [
    { "type": "edit_file", "path": "hw11.R",
      "patches": [ { "search": "mean(x)", "replace": "mean(x, na.rm=TRUE)" } ] }
  ],
  "usage":   { "input_tokens": 4321, "output_tokens": 512 }
}
```

`usage` is **tutor-LLM tokens only** (CHANGED — Workstream B). The guard's tokens are
billed by `/guard_checks`; this route no longer calls the guard.

| Field | Type | Description |
|-------|------|-------------|
| `log_id` | integer | Database ID of this turn's `prompt_logs` row |
| `status` | string | One of `"done"`, `"forbidden"`, `"unavailable"` |
| `content` | string | The tutor LLM's reply (or Socratic refusal text on `forbidden`) |
| `actions` | array | **NEW (Workstream B).** Structured suggestions for the TUI to execute behind a human-approval gate. `[]` or omitted when the tutor has no concrete suggestion. **Never present on `forbidden`.** See [Actions](#actions). |
| `usage` | object \| null | **Tutor-LLM tokens only** (CHANGED). `null` on `forbidden` (no tutor call). Always present on 2xx responses. |

---

### Actions

**NEW (Workstream B).** When the tutor has a concrete code suggestion, it appends a
structured `actions[]` array. Each action is a tool the **frontend** executes — the
backend never touches the student's filesystem.

```
TutorAction =
  | { "type": "edit_file";      "path": string; "patches": [ { "search": string, "replace": string } ] }
  | { "type": "execute_script"; "code": string }
  | { "type": "load_file";      "path": string }
```

Rules:

- **`edit_file` uses search-replace patches, never full file content.** The LLM key's
  4000-token output ceiling cannot carry whole files; patches keep each suggestion small.
  `search` strings must be unique enough in the file to be unambiguous.
- **`execute_script` is read-only on the frontend** — the TUI runs it through the
  read-only `r_exec` guard (no file writes / package installs). Changing files goes
  through `edit_file` (which gets a diff preview), not `execute_script`.
- **Never emit `actions` when `status` is `"forbidden"`** (or on any error).
- The frontend renders `content`, then surfaces each action as a proposal the student
  must approve. For `edit_file`: diff → preview → approval → write.

`attack_probability` and `evaluation` are still persisted in `prompt_logs`
and are available via `GET /api/v1/prompt_logs`; they are no longer emitted
in this response.

---

### Prompt blocked — `status: "forbidden"` (`200 OK`)

The `guard_log_id` failed verification — it does not exist, its guard verdict was
`forbidden`, or its stored prompt does not match this request's `prompt` (e.g. a client
tried to reuse a benign guard pass for a different message). The tutor LLM is **not**
called; the backend returns a Socratic redirect sourced from the tutor's `TUTOR.md`
(`## Refusal Message` section).

```json
{
  "log_id":  102,
  "status":  "forbidden",
  "content": "Let's work through this together. What aspect of the problem would you like to explore first?",
  "usage":   null
}
```

`usage` is `null` — no LLM is called on this path (the guard already ran in
`/guard_checks`; this route only did a DB lookup).

> **Frontend behaviour:** When `status` is `"forbidden"`, display `content`
> to the student. Don't retry the same prompt against `/tutor_chats`. In the normal flow
> the frontend only reaches `/tutor_chats` after a `done` / `unavailable` guard, so this
> branch primarily guards against clients that skip or tamper with the pre-call.

---

### Guard was fail-open — `status: "unavailable"` (`202 Accepted`)

The supplied `guard_log_id` is valid but its guard verdict was `unavailable` — i.e. the
`/guard_checks` judge had failed and fell open. The tutor LLM is still called; this route
propagates the upstream fail-open signal so the frontend knows the prompt was **not**
actually judged. The HTTP `202` plus `status: "unavailable"` carry the signal.

```json
{
  "log_id":  103,
  "status":  "unavailable",
  "content": "<tutor reply>",
  "actions": [],
  "usage":   { "input_tokens": 4100, "output_tokens": 480 }
}
```

`usage` is tutor-LLM tokens only (this route never calls the guard).

---

### Error responses

All error responses share the common envelope used by the rest of the API:

```json
{ "status": "...", "message": "...", "errors": { ... } }
```

| HTTP Status | `status` value | Trigger condition |
|-------------|----------------|-------------------|
| `400` | `bad_request` | Body field validation failed (missing field incl. `guard_log_id`, wrong type, history > 500 KB) |
| `403` | `forbidden` | `X-LLM-Key` header is absent or empty |
| `404` | `not_found` | An assignment artefact file is missing on disk |
| `500` | `internal_error` | Database write failed |
| `502` | `upstream_error` | The tutor LLM call returned a non-2xx |
| `504` | `upstream_timeout` | The tutor LLM call timed out (>30 s) |

> **Why `403` and not `401`?** The presence of an `X-LLM-Key` header is a
> client-side authorization concern (the user must supply their own key),
> not a server-issued credential check. `403 Forbidden` is the correct
> mapping: the request is well-formed and the server understood it, but the
> client did not supply the credential the operation requires.

---

## Composed system prompt

The server reads four artefacts on every allowed call and concatenates them
in this order via `Prompts::TutorSystemPrompt.build`:

```
{TUTOR.md — persona, role, allowed/forbidden, enforcement}

---

## Reference Solution
## Assignment
{HW 02.docx.txt content}

## Reference Solution
{Hw2.Rmd reference-solution content}

---

## Student Workspace Files
### Hw2.Rmd
```
{student's WIP — included in full when it fits the remaining
token budget, dropped entirely when it does not}
```
```

The student's `prompt` is placed in the user-message slot. `history` entries
sit between the system prompt and the new user message.

> **NEW (Workstream B) — `file_context` injection.** When the request carries
> `file_context`, the backend appends it as a `## Student Workspace (live)` section and
> **suppresses the fixture `## Student Workspace Files` section** (Q-B1 resolved): the
> frontend's live files are the source of truth, so the fixture WIP is dropped to avoid
> sending the same file twice (and to avoid showing the LLM a stale copy). When
> `file_context` is absent, the fixture WIP is injected as before. The live section
> participates in the same newest-first token-budget trim.

### Phase 1 artefact paths

| Role | Path |
|------|------|
| Assignment | `spec/fixtures/assignments/CSDS-HW2/assignment/HW 02.docx.txt` |
| Reference solution | `spec/fixtures/assignments/CSDS-HW2/solutions/Hw2.Rmd` |
| Student WIP | `spec/fixtures/assignments/CSDS-HW2/student-files/Hw2.Rmd` |
| Tutor persona | `spec/fixtures/assignments/CSDS-HW2/tutors/tutor-guide/TUTOR.md` |

> Phase 1 reads even the "student WIP" from a fixture; `project_id` is
> currently ignored by the loaders. Phase 2 will key by `course_id`+`project_id`
> and accept the student file in the request body.

---

## Security notes

- `X-LLM-Key` is forwarded to the LLM provider over HTTPS and is never
  written to the database.
- `KeyScrubber` middleware redacts `sk-xxx` patterns from response bodies
  and logs.
- **One LLM call per turn here (CHANGED — Workstream B).** This route calls only the
  **tutor** LLM; the guard runs once, in the `/guard_checks` pre-call. Per turn the system
  makes two LLM calls total (guard pre-call + tutor here), but each route bills its own —
  no double-counting.
- **Trust without a second guard call.** The `guard_log_id` verification (log exists,
  status ∈ {`done`, `unavailable`}, stored prompt matches) is a DB read that preserves the
  skip/fabricate-resistant trust boundary the old internal guard provided, at no token
  cost. **For this to be sound, `/guard_checks` must persist the judged `prompt`** with the
  log so this route can confirm the same prompt is being tutored. See
  [`plans/2026-06-03-agentic-tutor-backend.md`](../plans/2026-06-03-agentic-tutor-backend.md) §4.
