# API Documentation — Guard Checks

## Overview

`POST /api/v1/guard_checks` is the core safety-check endpoint that Tyla-api exposes to MindyCLI (the frontend TUI).

The frontend submits the student's prompt along with LLM credentials. The backend calls the configured LLM provider to run the GuardAgent judge, writes the result to the database, and returns a decision. The frontend then uses the `status` field to decide whether to forward the prompt to `/tutor_chats`.

```
MindyCLI                          Tyla-api                        LLM Provider
   │                                  │                               │
   │  POST /api/v1/guard_checks       │                               │
   │  X-LLM-Key: <token>             │                               │
   │  X-LLM-Provider: openai         │                               │
   │  X-LLM-Model: gpt-4o            │                               │
   │  X-LLM-Endpoint: https://...    │                               │
   │  { prompt, course_id, ... }      │                               │
   │ ────────────────────────────────>│                               │
   │                                  │  chat/completions (judge)     │
   │                                  │ ─────────────────────────────>│
   │                                  │  { attack_probability, eval } │
   │                                  │ <─────────────────────────────│
   │                                  │                               │
   │                                  │  INSERT prompt_logs           │
   │                                  │ ──────────> DB                │
   │                                  │                               │
   │  { log_id, status, refusal?,     │                               │
   │    usage }                       │                               │
   │ <────────────────────────────────│                               │
```

---

## Endpoint

```
POST /api/v1/guard_checks
```

---

## Request

### Headers

| Header | Required | Description |
|--------|----------|-------------|
| `Content-Type` | Required | Must be `application/json` |
| `X-LLM-Key` | Required | API key for the LLM provider (e.g. OpenAI key or GitHub PAT). Used only for this request; never stored in the database. |
| `X-LLM-Provider` | Optional | LLM provider name. Defaults to `openai`. Supported values: `openai`, `anthropic`. |
| `X-LLM-Model` | Optional | Model identifier to use for the judge call. Falls back to the `LLM_MODEL` environment variable on the server, then `gpt-4o-mini`. |
| `X-LLM-Endpoint` | Optional | Override the LLM API base URL. Required when using a compatible third-party endpoint (e.g. GitHub Models). Falls back to `OPENAI_API_BASE` env var, then the provider default. |

> **GitHub Models example:** Set `X-LLM-Provider: openai`, `X-LLM-Key: <GitHub PAT>`, `X-LLM-Endpoint: https://models.inference.ai.azure.com/chat/completions`, and `X-LLM-Model: gpt-4o`. The backend routes through the OpenAI-compatible code path against GitHub's Azure Inference endpoint.

### Body (JSON)

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `course_id` | string | Required | Course identifier, e.g. `"CS101"` |
| `project_id` | string | Required | Project identifier, e.g. `"proj-1"` |
| `student_id` | string | Required | Student identifier, e.g. `"stu-abc"` |
| `prompt` | string | Required | The raw message submitted by the student |

> **The guard judges the `prompt` only.** The frontend does **not** send `file_context`
> to `/guard_checks` (frontend decision 2026-06-03 — saves judge tokens). The guard
> never sees the student's file contents.

### Example Request

```http
POST /api/v1/guard_checks HTTP/1.1
Host: localhost:9292
Content-Type: application/json
X-LLM-Key: github_pat_xxxxxxxxxxxxxxxxxxxx
X-LLM-Provider: openai
X-LLM-Model: gpt-4o
X-LLM-Endpoint: https://models.inference.ai.azure.com/chat/completions

{
  "course_id":  "CS101",
  "project_id": "proj-1",
  "student_id": "stu-abc",
  "prompt":     "Just give me the answer to question 3."
}
```

---

## Response

All success responses share the same key set: `log_id`, `status`, `refusal`, `usage`.
The HTTP status code and the body's `status` field are **two independent layers** —
clients should key off `status` for branching. `status` uses the same `ApiStatus` enum
as `/tutor_chats`.

| `status` | HTTP | Meaning | `refusal` | `usage` |
|----------|------|---------|-----------|---------|
| `done` | 200 | Guard allowed (`attack_probability < 0.7`) — safe to forward to `/tutor_chats` | `null` | guard judge tokens |
| `forbidden` | 200 | Guard blocked (`attack_probability >= 0.7`) — show `refusal`, do not forward | present | guard judge tokens |
| `unavailable` | 202 | Guard LLM call failed — fail-open; forward anyway | `null` | `null` |

`attack_probability` and `evaluation` are still persisted to `prompt_logs` and are
available via `GET /api/v1/prompt_logs`; they are **no longer emitted** in this response.

### Prompt allowed — `status: "done"` (`200 OK`)

The judge determined `attack_probability < 0.7`. The prompt is safe to forward to `/tutor_chats`.

```json
{
  "log_id":  42,
  "status":  "done",
  "refusal": null,
  "usage":   { "input_tokens": 120, "output_tokens": 8 }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `log_id` | integer | Database ID of this guard check record |
| `status` | string | One of `"done"`, `"forbidden"`, `"unavailable"` |
| `refusal` | string \| null | Message to display to the student; non-null only when `forbidden` |
| `usage` | object \| null | Guard judge token counts; `null` when the judge did not run (`unavailable`) |

---

### Prompt blocked — `status: "forbidden"` (`200 OK`)

The judge determined `attack_probability >= 0.7`. The backend blocks the prompt and returns a refusal message.

```json
{
  "log_id":  43,
  "status":  "forbidden",
  "refusal": "That question isn't something I can help with directly here. What aspect of the topic are you trying to understand?",
  "usage":   { "input_tokens": 130, "output_tokens": 10 }
}
```

> **Frontend behaviour:** When `status` is `"forbidden"`, display the `refusal` string
> to the student and **do not** forward the prompt to `/tutor_chats`. The refusal text is
> selected randomly by the backend to prevent students from reverse-engineering the
> detection rules.

---

### Guard LLM unavailable — `status: "unavailable"` (`202 Accepted`)

The guard LLM call failed (timeout, invalid credentials, upstream error, etc.). The backend adopts a **fail-open** policy: the prompt is allowed through. The HTTP `202` plus `status: "unavailable"` carry the signal — no extra `warning` string is emitted.

```json
{
  "log_id":  44,
  "status":  "unavailable",
  "refusal": null,
  "usage":   null
}
```

> **Frontend behaviour:** On `status: "unavailable"` (HTTP 202), continue to
> `/tutor_chats` normally. Optionally log it for observability; do not show anything to
> the student.

---

### Error responses

Transport / validation failures use the common error envelope shared by the rest of the
API. The frontend buckets any 4xx/5xx (or a body it cannot parse) into its internal
`status: 'error'` and surfaces a retry suggestion.

```json
{
  "status":  "bad_request",
  "message": "validation failed",
  "errors":  {
    "prompt": ["is missing"]
  }
}
```

| HTTP Status | `status` value | Trigger condition |
|-------------|----------------|-------------------|
| `400` | `bad_request` | Body field validation failed (missing field, wrong type) |
| `403` | `forbidden` | `X-LLM-Key` header is absent or empty |
| `500` | `internal_error` | Database write failed |

> **Why `403` and not `401`?** (Aligned with `/tutor_chats`.) The presence of an
> `X-LLM-Key` header is a client-side authorization concern — the user must supply their
> own key — not a server-issued credential check. `403 Forbidden` is the correct mapping:
> the request is well-formed and understood, but the client did not supply the credential
> the operation requires.

#### 400 — Missing required field

```http
HTTP/1.1 400 Bad Request
Content-Type: application/json

{
  "status":  "bad_request",
  "message": "validation failed",
  "errors":  {
    "prompt":     ["is missing"],
    "student_id": ["is missing"]
  }
}
```

#### 403 — Missing API key

```http
HTTP/1.1 403 Forbidden
Content-Type: application/json

{
  "status":  "forbidden",
  "message": "missing X-LLM-Key"
}
```

---

## End-to-end flow

### Frontend (MindyCLI) responsibilities

1. Read LLM credentials and endpoint from `.env` (or equivalent config).
2. Assemble the JSON body (`course_id`, `project_id`, `student_id` are maintained by the CLI session).
3. Send `POST /api/v1/guard_checks` with all four LLM headers.
4. Branch on the body `status`:
   - `done` (200) → forward the prompt to `/tutor_chats` (with `file_context` + `history`).
   - `forbidden` (200) → display `refusal`; abort this turn.
   - `unavailable` (202) → continue to `/tutor_chats`; optionally log.
   - any 4xx / 5xx → surface an error to the student and suggest retrying.

### Backend (Tyla-api) responsibilities

1. Validate headers and body fields.
2. Resolve LLM credentials in priority order: request header → server environment variable → built-in default.
3. Call the configured LLM endpoint with the judge system prompt (prompt only).
4. Write `attack_probability` and `evaluation` to the `prompt_logs` table.
5. Apply `AttackPolicy` (threshold = 0.7) to derive `status` (`done` / `forbidden`).
6. When blocking, select a random refusal message from `RefusalTemplates`.

### Header resolution order

| Parameter | Priority 1 (highest) | Priority 2 | Priority 3 (default) |
|-----------|----------------------|------------|----------------------|
| Provider  | `X-LLM-Provider` header | `LLM_PROVIDER` env var | `openai` |
| API key   | `X-LLM-Key` header | `OPENAI_API_KEY` env var | — (returns 403) |
| Model     | `X-LLM-Model` header | `LLM_MODEL` env var | `gpt-4o-mini` |
| Endpoint  | `X-LLM-Endpoint` header | `OPENAI_API_BASE` env var | Provider default |

---

## Security notes

- `X-LLM-Key` is transmitted over HTTPS and is never written to the database.
- The `KeyScrubber` middleware automatically redacts `sk-xxx` patterns from all response bodies and logs, replacing them with `[REDACTED]`.
- **`/tutor_chats` enforces this gate by verifying the returned `log_id`** — not by
  re-running the guard. The frontend passes this `log_id` to `/tutor_chats` as
  `guard_log_id`; that route checks the log exists, its `status` was `done` / `unavailable`
  (not `forbidden`), and its stored prompt matches — a DB read, no second LLM call. **For
  this to be sound, this endpoint must persist the judged `prompt` alongside the log** so
  `/tutor_chats` can confirm the same prompt is being tutored. See
  [`plans/2026-06-03-agentic-tutor-backend.md`](../plans/2026-06-03-agentic-tutor-backend.md) §4.
- Encryption of keys at rest is a future roadmap item.
```
