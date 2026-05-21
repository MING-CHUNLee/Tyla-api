# API Documentation — Tutor Chats

## Overview

`POST /api/v1/tutor_chats` is the second leg of the guard → tutor pipeline.
Where `/guard_checks` runs the safety judge for the frontend, `/tutor_chats`
composes the full tutor prompt from on-disk assignment artefacts and forwards
it to the tutor LLM.

The endpoint re-runs the guard server-side (defence in depth) even when
`/guard_checks` has already passed. This keeps the trust boundary at the
server so a client that skips or fabricates a `/guard_checks` call still
cannot bypass safety.

```
MindyCLI                          Tyla-api                        LLM Provider
   │                                  │                               │
   │  POST /api/v1/tutor_chats        │                               │
   │  X-LLM-Key: <token>              │                               │
   │  { prompt, course_id, ... }      │                               │
   │ ────────────────────────────────>│                               │
   │                                  │  chat/completions (judge)     │
   │                                  │ ─────────────────────────────>│
   │                                  │  { attack-probability, eval } │
   │                                  │ <─────────────────────────────│
   │                                  │  INSERT prompt_logs           │
   │                                  │                               │
   │                                  │  Load assignment/solution/    │
   │                                  │  student/persona from disk    │
   │                                  │                               │
   │                                  │  chat/completions (tutor)     │
   │                                  │ ─────────────────────────────>│
   │                                  │  { reply, usage }             │
   │                                  │ <─────────────────────────────│
   │  { allowed, content, usage,      │                               │
   │    log_id }                      │                               │
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
| `prompt` | string | Required | The student's message |
| `history` | array | Optional | Prior chat turns, in order. Each entry is `{ "role": "user" \| "assistant", "content": "..." }`. Capped at 500 KB; older turns beyond `MAX_HISTORY_TURNS` are truncated server-side. |

### Example Request

```http
POST /api/v1/tutor_chats HTTP/1.1
Host: localhost:9292
Content-Type: application/json
X-LLM-Key: sk-xxxxxxxxxxxx

{
  "course_id":  "CSDS",
  "project_id": "HW2",
  "student_id": "stu-abc",
  "prompt":     "Why is the Freedman-Diaconis rule least sensitive to outliers?",
  "history": [
    { "role": "user",      "content": "What are Sturges, Scott, and FD?" },
    { "role": "assistant", "content": "Hint 1: ..." }
  ]
}
```

---

## Response

### Tutor reply (`200 OK`)

The guard allowed the prompt and the tutor LLM returned a reply.

```json
{
  "log_id":  101,
  "allowed": true,
  "content": "Step 1: ...\nHint 1: ...",
  "usage":   { "input_tokens": 4321, "output_tokens": 512 }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `log_id` | integer | Database ID of this turn's `prompt_logs` row |
| `allowed` | boolean | Always `true` on this branch |
| `content` | string | The tutor LLM's reply |
| `usage` | object | Token counts from the tutor LLM (`input_tokens`, `output_tokens`) |

---

### Prompt blocked (`200 OK`)

The internal guard determined `attack_probability >= 0.7`. The tutor LLM is
**not** called; the backend returns a refusal.

```json
{
  "log_id":             102,
  "allowed":            false,
  "attack_probability": 0.91,
  "evaluation":         "Direct answer demand",
  "refusal":            "Let's redirect. Instead of asking for the answer, what step would you take first to approach this problem?"
}
```

> **Frontend behaviour:** When `allowed` is `false`, display the `refusal`
> string to the student. Don't retry the same prompt against `/tutor_chats`.

---

### Guard unavailable (`202 Accepted`)

Same fail-open policy as `/guard_checks`. If the guard call fails (timeout,
malformed JSON, etc.) the tutor LLM is still called, and the response carries
a `warning` field.

```json
{
  "log_id":  103,
  "allowed": true,
  "content": "<tutor reply>",
  "usage":   { "input_tokens": 4100, "output_tokens": 480 },
  "warning": "guard skipped: llm unavailable"
}
```

---

### Error responses

All error responses share the common envelope used by the rest of the API:

```json
{ "status": "...", "message": "...", "errors": { ... } }
```

| HTTP Status | `status` value | Trigger condition |
|-------------|----------------|-------------------|
| `400` | `bad_request` | Body field validation failed (missing field, wrong type, history > 500 KB) |
| `401` | `unauthorized` | `X-LLM-Key` header is absent or empty |
| `404` | `not_found` | An assignment artefact file is missing on disk |
| `500` | `internal_error` | Database write failed |
| `502` | `upstream_error` | The tutor LLM call returned a non-2xx |
| `504` | `upstream_timeout` | The tutor LLM call timed out (>30 s) |

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
{student's WIP, truncated at MAX_FILE_LINES if long}
```
```

The student's `prompt` is placed in the user-message slot. `history` entries
sit between the system prompt and the new user message.

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
- The route makes **two LLM calls per turn** (guard + tutor). Budget
  accordingly when sizing rate limits or cost alarms.
