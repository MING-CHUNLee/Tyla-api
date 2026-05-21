# API Documentation — Guard Checks

## Overview

`POST /api/v1/guard_checks` is the core safety-check endpoint that Tyla-api exposes to MindyCLI (the frontend TUI).

The frontend submits the student's prompt along with LLM credentials. The backend calls the configured LLM provider to run the GuardAgent judge, writes the result to the database, and returns a decision. The frontend then uses the `allowed` field to decide whether to forward the prompt to the tutor model.

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
   │  { allowed, attack_probability,  │                               │
   │    evaluation, log_id, ... }     │                               │
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

### Prompt allowed (`200 OK`)

The judge determined `attack_probability < 0.7`. The prompt is safe to forward to the tutor model.

```json
{
  "log_id":             42,
  "allowed":            true,
  "attack_probability": 0.05,
  "evaluation":         "Genuine clarification question about assignment"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `log_id` | integer | Database ID of this guard check record |
| `allowed` | boolean | `true` = safe, frontend may proceed; `false` = blocked, frontend should show refusal |
| `attack_probability` | float | Attack probability score, range `0.0`–`1.0` (threshold = `0.7`) |
| `evaluation` | string | Short evaluation returned by the LLM judge |

---

### Prompt blocked (`200 OK`)

The judge determined `attack_probability >= 0.7`. The backend blocks the prompt and returns a refusal message.

```json
{
  "log_id":             43,
  "allowed":            false,
  "attack_probability": 0.87,
  "evaluation":         "Direct answer demand",
  "refusal":            "That question isn't something I can help with directly here. What aspect of the topic are you trying to understand?"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `refusal` | string | Message the frontend should display to the student. Selected randomly by the backend to prevent students from reverse-engineering the detection rules. |

> **Frontend behaviour:** When `allowed` is `false`, display the `refusal` string to the student and do not forward the prompt to the tutor model.

---

### LLM judge unavailable (`202 Accepted`)

The guard LLM call failed (timeout, invalid credentials, upstream error, etc.). The backend adopts a **fail-open** policy: the prompt is allowed through with a warning attached.

```json
{
  "log_id":             44,
  "allowed":            true,
  "attack_probability": null,
  "evaluation":         "llm-unavailable",
  "warning":            "guard skipped: llm unavailable"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `warning` | string | The frontend may log this for debugging; it should not be shown to the student. |

> **Frontend behaviour:** On HTTP 202, continue the tutor flow normally. Log the `warning` field for observability.

---

### Error responses

All error responses share a common body format:

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
| `401` | `unauthorized` | `X-LLM-Key` header is absent or empty |
| `500` | `internal_error` | Database write failed |

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

#### 401 — Missing API key

```http
HTTP/1.1 401 Unauthorized
Content-Type: application/json

{
  "status":  "unauthorized",
  "message": "missing X-LLM-Key"
}
```

---

## End-to-end flow

### Frontend (MindyCLI) responsibilities

1. Read LLM credentials and endpoint from `.env` (or equivalent config).
2. Assemble the JSON body (`course_id`, `project_id`, `student_id` are maintained by the CLI session).
3. Send `POST /api/v1/guard_checks` with all four LLM headers.
4. Handle the response:
   - `allowed: true` (200) → forward the prompt to the tutor model.
   - `allowed: false` (200) → display the `refusal` field to the student; abort this turn.
   - HTTP 202 + `warning` → continue the tutor flow; optionally log the warning.
   - HTTP 4xx / 5xx → surface an error to the student and suggest retrying.

### Backend (Tyla-api) responsibilities

1. Validate headers and body fields.
2. Resolve LLM credentials in priority order: request header → server environment variable → built-in default.
3. Call the configured LLM endpoint with the judge system prompt.
4. Write `attack_probability` and `evaluation` to the `prompt_logs` table.
5. Apply `AttackPolicy` (threshold = 0.7) to derive `allowed`.
6. When blocking, select a random refusal message from `RefusalTemplates`.

### Header resolution order

| Parameter | Priority 1 (highest) | Priority 2 | Priority 3 (default) |
|-----------|----------------------|------------|----------------------|
| Provider  | `X-LLM-Provider` header | `LLM_PROVIDER` env var | `openai` |
| API key   | `X-LLM-Key` header | `OPENAI_API_KEY` env var | — (returns 401) |
| Model     | `X-LLM-Model` header | `LLM_MODEL` env var | `gpt-4o-mini` |
| Endpoint  | `X-LLM-Endpoint` header | `OPENAI_API_BASE` env var | Provider default |

---

## Security notes

- `X-LLM-Key` is transmitted over HTTPS and is never written to the database.
- The `KeyScrubber` middleware automatically redacts `sk-xxx` patterns from all response bodies and logs, replacing them with `[REDACTED]`.
- Encryption of keys at rest is a future roadmap item.
