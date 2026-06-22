# API Documentation — Tutor Chats

> **✅ Shipped 2026-06-04 (Workstream B).** This doc now describes live behaviour. The
> three changes planned in
> [`plans/2026-06-03-agentic-tutor-backend.md`](../plans/2026-06-03-agentic-tutor-backend.md)
> (and detailed in
> [`plans/2026-06-04-tutor-chats-contract-alignment.md`](../plans/2026-06-04-tutor-chats-contract-alignment.md))
> are implemented and are still annotated **NEW** / **CHANGED** below for historical context:
> 1. `file_context` request field (NEW);
> 2. `actions[]` response field (NEW);
> 3. **the internal guard LLM is removed** — this route no longer re-runs the guard.
>    Instead it requires a `guard_log_id` from a prior `/guard_checks` pass and verifies
>    it against the DB (no LLM call); `usage` is now **tutor-only** (CHANGED).

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
| `file_context` | string | Optional | **NEW (Workstream B); CONTRACT NARROWED (2026-06-12).** The line-numbered **contents of files the frontend has ALREADY loaded** (e.g. `@`-mentioned, or fetched in response to a `load_file` action) — *not* a project overview (that is now `workspace_overview`). Injected verbatim under `## Student Workspace (live)`. **Line-number convention:** every line of a text file carries a `N| ` prefix with its real file line number (e.g. `  3| quantile(d123)`); PDF excerpts carry no prefixes. **Header convention (now load-bearing — §gate):** each loaded file MUST begin with a `### <relative path>` header line, the path spelled exactly as `workspace_overview` lists it; the backend parses these headers to decide which paths are editable. The backend appends a `## Workspace Line Numbers` guide and the `edit_file` tool schema instructs the LLM to read the prefix into `patches[].start_line` (a required 1-based integer) and put **plain code with no prefix** in `search` / `replace` (CHANGED 2026-06-13). See [Composed system prompt](#composed-system-prompt). |
| `workspace_overview` | string | Optional | **NEW (2026-06-12).** The frontend's workspace **file listing / scan summary** — names only, **no contents, no line numbers**. Injected under `## Student Workspace (overview)`, followed by a `## Loading Workspace Files` guide telling the tutor these files exist but must be `load_file`d before reading/editing (and never to invent `N| ` prefixes). Coexists with `file_context`: the overview lists every workspace file, `file_context` carries the loaded subset. **This field also arms the server-side `edit_file` gate** (see [Workspace edit gate](#workspace-edit-gate)); an older CLI that omits it keeps the pre-2026-06-12 behaviour unchanged. |

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
  "workspace_overview": "## Project Context\nScanned: ...\nR scripts (.R): hw2.R, util.R\n...",
  "file_context": "## File Contents\n### hw2.R\n  1| rdata <- read.csv(\"d.csv\")\n  2| hist(rdata)\n..."
}
```

> **`workspace_overview` vs `file_context` (2026-06-12).** Send the project scan / file
> listing in `workspace_overview`; send `file_context` **only** when you have actually
> loaded line-numbered file contents (an `@`-mention, or in response to a `load_file`
> action). Each loaded file in `file_context` MUST start with a `### <relative path>`
> header — the backend's [edit gate](#workspace-edit-gate) reads those headers. Do **not**
> concatenate the overview into `file_context`; that overloads one field and reintroduces
> the fabricated-line-number bug this split fixes.

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
      "patches": [ { "start_line": 42, "search": "mean(x)", "replace": "mean(x, na.rm=TRUE)" } ] }
  ],
  "usage":   { "input_tokens": 4321, "output_tokens": 512 }
}
```

`usage` is **tutor-LLM tokens only** (CHANGED — Workstream B). The guard's tokens are
billed by `/guard_checks`; this route no longer calls the guard.

> **CHANGED (2026-06-12, hybrid lazy solution).** `usage` is now the **sum over all
> tutor LLM calls made this turn**. Normally that is one call; when the tutor consults
> the reference solution (see [Hybrid lazy solution loading](#hybrid-lazy-solution-loading))
> the backend makes a second call and `usage` is the Σ of both rounds'
> `input_tokens` / `output_tokens`.

| Field | Type | Description |
|-------|------|-------------|
| `log_id` | integer | Database ID of this turn's `prompt_logs` row |
| `status` | string | One of `"done"`, `"forbidden"`, `"unavailable"` |
| `content` | string | The tutor LLM's reply (or Socratic refusal text on `forbidden`) |
| `actions` | array | **NEW (Workstream B).** Structured suggestions for the TUI to execute behind a human-approval gate. `[]` or omitted when the tutor has no concrete suggestion. **Never present on `forbidden`.** See [Actions](#actions). |
| `usage` | object \| null | **Tutor-LLM tokens only** (CHANGED). **Σ over all tutor calls this turn** (1 normally, 2 when the reference solution was consulted — CHANGED 2026-06-12). `null` on `forbidden` (no tutor call). Always present on 2xx responses. |
| `warnings` | string[] | **NEW (2026-06-11, §2.7).** Backend trim/redirect notices; **omitted entirely when empty** (older clients unaffected). Values: `"file_context_dropped"` — the live `file_context` did not fit the remaining input budget and was dropped whole (the tutor did not see the student's loaded files this turn); `"history_truncated"` — one or more oldest history turns were dropped by the newest-first trim; `"reference_loaded"` (**NEW 2026-06-12**) — the tutor consulted the instructor's reference solution server-side this turn (informational; the solution content itself is never returned); `"workspace_overview_dropped"` (**NEW 2026-06-12**) — the `workspace_overview` listing did not fit the input budget and was dropped whole; `"edit_file_redirected"` (**NEW 2026-06-12**) — the tutor asked to `edit_file` a path it had not loaded, so the backend rewrote that action to a `load_file` (see [Workspace edit gate](#workspace-edit-gate)); render it so the extra round-trip is explained, not silent; `"redundant_load_dropped"` (**NEW 2026-06-13**) — the tutor asked to `load_file` a path that is **already** loaded in `file_context` (or duplicated it within one reply), so the backend dropped that action (see [Redundant load gate](#redundant-load-gate)); when this is set and `actions` is now empty, read it as "the backend broke a load loop", not an error; `"session_limit_reached"` (**NEW 2026-06-16**) — this turn's assembled input has closed on the LLM channel's per-request input cap (≥ 90 %, measured against the tutor call's real `usage.input_tokens`). The turn still succeeded, but the conversation has effectively outgrown the window; render it as a prompt to the student to **wrap up and start a new conversation** rather than letting further turns silently drop older history (`history_truncated`) or hard-fail with `413`; `"provider_rate_limited"` (**NEW 2026-06-18, route C**) — the provider's pass-through rate-limit headers show the account/key's rate window (per-minute / per-day) closing on its quota; the turn still succeeded, but the key is about to be throttled. **Orthogonal to `session_limit_reached`, and its remedy is the OPPOSITE** — "wait / back off", *not* "start a new conversation" (a new conversation reuses the same key against the same quota); render it on a distinct path with distinct copy (see [Which limit](#which-limit-scope--dimension)). The CLI surfaces these as status warnings. |

---

### Actions

**NEW (Workstream B).** When the tutor has a concrete code suggestion, it appends a
structured `actions[]` array. Each action is a tool the **frontend** executes — the
backend never touches the student's filesystem.

```
TutorAction =
  | { "type": "edit_file";      "path": string; "patches": [ { "start_line": integer, "search": string, "replace": string } ] }
  | { "type": "execute_script"; "code": string }
  | { "type": "load_file";      "path": string }
```

Rules:

- **`edit_file` uses search-replace patches, never full file content.** The LLM key's
  4000-token output ceiling cannot carry whole files; patches keep each suggestion small.
- **`edit_file` patches anchor by line number, validate by content (CHANGED 2026-06-13,
  [`plans/2026-06-13-edit-file-line-anchor.md`](../plans/2026-06-13-edit-file-line-anchor.md)).**
  Each patch is `{ "start_line": integer, "search": string, "replace": string }`:
  - `start_line` is the **1-based** file line number of the first line of `search` (line 1 =
    the file's first line), read from the `N| ` prefix the backend shows in
    `## Student Workspace (live)`. It is a **required** schema field — the model can no longer
    omit the location the way it routinely dropped the old in-`search` prefix.
  - `search` / `replace` are **plain code with NO `N| ` prefix** — the file on disk has no such
    prefix, so plain content matches directly. (The backend defensively strips any `N| ` prefix
    the model still pastes in, so actions on the wire always carry plain content.)
  - The frontend applies a patch by reading lines `start_line … start_line + (search line count)
    − 1` from the live file, comparing them to `search` (line-endings normalized first — files are
    CRLF), and replacing only on an exact content match; a mismatch is rejected, not silently
    applied. Line number locates, content guards. `search` should still be unique enough to be
    unambiguous as a fallback when `start_line` is absent (XML fallback only).
- **`edit_file` requires a loaded file.** A file is editable only once its line-numbered
  contents are in `file_context` (under `## Student Workspace (live)`). If the tutor emits
  `edit_file` for a path that is only listed in `workspace_overview` (or not shown at all),
  the backend rewrites that action to `load_file` for the same path — see
  [Workspace edit gate](#workspace-edit-gate).
- **`execute_script` is read-only on the frontend** — the TUI runs it through the
  read-only `r_exec` guard (no file writes / package installs). Changing files goes
  through `edit_file` (which gets a diff preview), not `execute_script`.
- **Never emit `actions` when `status` is `"forbidden"`** (or on any error).
- **`load_reference` never appears in `actions`** (2026-06-12). It is a server-side
  tool: the backend consumes it inside the turn (see
  [Hybrid lazy solution loading](#hybrid-lazy-solution-loading)) and defensively
  filters it from the terminal `actions` array. Clients never need to handle it.
- The frontend renders `content`, then surfaces each action as a proposal the student
  must approve. For `edit_file`: diff → preview → approval → write.

`attack_probability` and `evaluation` are still persisted in `prompt_logs`
and are available via `GET /api/v1/prompt_logs`; they are no longer emitted
in this response.

---

## Workspace edit gate

**NEW (2026-06-12,
[`plans/2026-06-12-workspace-context-contract-split.md`](../plans/2026-06-12-workspace-context-contract-split.md) §2.2).**
The tutor may only edit a file whose line-numbered contents it can actually see. The
`## Loading Workspace Files` guide and the tightened tool descriptions steer the model, but
they are soft constraints — some models invent a `N| ` prefix when the student pastes code
into the chat. So the backend also enforces the rule structurally, on the same shared path
where `load_reference` is defensively filtered (covering both the native `tool_calls` and
the XML-fallback parse branches):

- **Loaded-paths set.** Each loaded file in `file_context` begins with a `### <relative path>`
  header; the backend extracts the editable-path set with a line-anchored match on those
  headers. **This makes the header part of the wire format, not cosmetics** — a loaded file
  sent without its header is treated as not loaded.
- **Gate.** For every `edit_file` whose (normalized) `path` is **not** in the loaded set, the
  backend drops the patch payload and rewrites the action to `{ "type": "load_file", "path":
  <same path> }`, deduplicated (one `load_file` per missing path; no duplicate when the reply
  already contains a `load_file` for it). `warnings` gains `"edit_file_redirected"`.
  `edit_file`s whose path **is** loaded pass through untouched; other action types are never
  touched.
- **Self-healing.** A redirected `load_file` resolves like a model-initiated one: the CLI
  reads the file, `N| `-prefixes it, re-sends it in `file_context` next turn — where the edit
  is now legal. Worst case the fabricated edit costs one extra round-trip instead of a silent
  no-op.
- **Activation / backward compatibility.** The gate runs **only when the request carries
  `workspace_overview`** (the new-contract marker). An old CLI that sends the combined blob in
  `file_context` with no overview never trips it, so v1 `@`-mention edits are byte-identical
  to the pre-2026-06-12 behaviour. See [Migration order](#migration-order).

---

## Redundant load gate

**NEW (2026-06-13,
[`plans/2026-06-13-load-file-loop.md`](../plans/2026-06-13-load-file-loop.md) §3).** `load_file`
is **idempotent**: once a file's line-numbered contents are in `file_context`, a further
`load_file` for it can never be productive. Without a structural stop, a model that re-requests
an already-loaded file drives an infinite loop — the CLI faithfully re-reads and re-sends, the
model re-requests again. So the backend drops these on the same shared action path as the other
gates (covering both `tool_calls` and XML-fallback parses):

- **Already-loaded.** For every `load_file` whose (normalized) `path` is already present in
  `file_context` — detected by the same line-anchored `### <relative path>` header match the
  [Workspace edit gate](#workspace-edit-gate) uses — the backend **drops** the action and sets
  `warnings += "redundant_load_dropped"`.
- **Intra-reply duplicates.** Two `load_file`s for the same path in one reply collapse to one
  (also flagged). Other action types are never touched.
- **Ordering.** This gate runs **before** the workspace-edit and content gates. The content gate
  legitimately rewrites a stale `edit_file` (already-loaded path, but `search` no longer matches
  the snapshot) into a `load_file` for that same already-loaded path; that reload is a deliberate
  self-heal and must survive. Running the redundant-load gate first drops only the model's own
  redundant loads, then lets the edit gates emit needed reloads.
- **Activation.** Inert unless `file_context` is non-empty **and** carries at least one `###`
  header (same trigger as the content gate; **not** bound to `workspace_overview`). Dropping a
  load for an already-loaded path is correct under both the old combined-blob and new
  two-channel contracts, so there is no backward-compatibility risk.
- **Termination caveat.** If `file_context` is budget-trimmed so a loaded file's `### header`
  is cut, the gate can no longer see it as loaded and the loop returns; the frontend's
  `load_file` round cap is the backstop there. See
  [`plans/2026-06-13-load-file-loop.md`](../plans/2026-06-13-load-file-loop.md) §6 D4.
- **Never a blank turn.** When the gate (or any gate) clears every action and the model gave no
  prose, the backend injects a short fallback message, so a `done` turn is never `content`-empty
  with `actions: []` (plan §2 decision E).

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
| `429` | `rate_limited` | **NEW (2026-06-18, route C).** The tutor LLM provider returned `429` — the account's rate-limit window is exhausted. `errors.retry_after` (and, when present, the `Retry-After` response header) carries the suggested back-off in seconds; `errors.limit_scope` is always `"provider_account"`; `errors.limit_dimension` is best-effort `"requests"` / `"tokens"` / `"unknown"` (see [Which limit](#which-limit-scope--dimension)). **Distinct from `502 upstream_error`** — this is a back-off signal, not a hard failure: wait and retry, do not hammer-retry (that hits the limit faster). |
| `500` | `internal_error` | Database write failed |
| `502` | `upstream_error` | The tutor LLM call returned a non-2xx **other than 429** |
| `504` | `upstream_timeout` | The tutor LLM call timed out (>30 s) |

> **Why `403` and not `401`?** The presence of an `X-LLM-Key` header is a
> client-side authorization concern (the user must supply their own key),
> not a server-issued credential check. `403 Forbidden` is the correct
> mapping: the request is well-formed and the server understood it, but the
> client did not supply the credential the operation requires.

### Provider rate-limited — `status: "rate_limited"` (`429 Too Many Requests`)

**NEW (2026-06-18, route C).** The tutor LLM provider returned `429`: the API key's
rate-limit window (per-minute / per-day request or token quota) is exhausted. The turn
could not complete, so this is a failure response — but a **recoverable** one, semantically
the opposite of a `502`. Back off and retry; do **not** treat it as a hard error or retry
immediately (an immediate retry just hits the limit again, faster).

```json
{
  "status":  "rate_limited",
  "message": "LLM provider rate limited",
  "errors": {
    "retry_after":     "30",
    "limit_scope":     "provider_account",
    "limit_dimension": "requests"
  }
}
```

| `errors` field | Type | Meaning |
|---|---|---|
| `retry_after` | string \| null | Suggested back-off in seconds, taken from the provider's `Retry-After`. **Also echoed as the `Retry-After` response header** when present, so a client can back off without parsing the body; the body field is the fallback. `null` when the provider sent no `Retry-After`. |
| `limit_scope` | string | Always `"provider_account"` for a 429 — it is an account/key-level rate window, **never** conversation-level (see [Which limit](#which-limit-scope--dimension)). |
| `limit_dimension` | string | Best-effort `"requests"` / `"tokens"` / `"unknown"`, inferred from the provider's `*remaining*` headers. `"unknown"` when the provider sent only `Retry-After` (no remaining axis to read). |

> **Deployment note (2026-06-18).** Each student supplies their own key, so a 429 is *that
> student's* quota — the message can be direct ("your key is rate-limited, wait ~N s"),
> no "maybe someone else exhausted it" hedge needed.

---

## Which limit (scope / dimension)

**NEW (2026-06-18, route C §3.1).** Three different "limits" can be in play, and they are
**not** interchangeable. The response keeps them on **separate signals** so the frontend
never gives the wrong remedy:

| Limit (`limit_scope`) | Signal | Surfaced as | What it means | Remedy |
|---|---|---|---|---|
| `per_request` | `session_limit_reached` | `warnings[]` (turn still `done`) | *This single turn's* assembled input has closed on the model's per-request context window | **Start a fresh conversation** — a new conversation empties the history, freeing the window |
| `provider_account` | `provider_rate_limited` (soft) / `rate_limited` (hard 429) | `warnings[]` (soft) / `429` body `errors` (hard) | *Your key's* rate window (per-minute / per-day requests or tokens) is near / past its quota | **Wait / back off** — a fresh conversation does **not** help; it reuses the same key against the same quota |
| `conversation` | — (**never emitted**) | — | A running per-conversation token tally | n/a — the backend does **not** track this and the provider does not report it; route B was deliberately not built |

> **⚠️ The two active signals demand OPPOSITE actions.** `session_limit_reached` says "start
> a new conversation"; `provider_rate_limited` / `429` says "wait — a new conversation makes
> it *worse*". They can fire on the same turn. **Never merge them into one "you hit a limit,
> start over" message** — that gives `rate_limited` exactly the wrong advice. Render them on
> distinct paths with distinct copy. See [§6 of the route-C plan](../plans/2026-06-18-provider-rate-limit-passthrough.md).

> The backend **never** labels a route-C signal `conversation`-level. A 429 / `provider_rate_limited`
> is an account rate window that resets on its own period; it is **not** "this conversation got
> too long" (that is `session_limit_reached`, a different scope). The `limit_dimension`
> sub-label (`requests` / `tokens` / `unknown`) lets the frontend sharpen 429 copy
> ("your per-minute **request** quota is spent" vs "your **token** quota is spent"); fall back
> to generic wording on `unknown`.

---

## Hybrid lazy solution loading

**NEW (2026-06-12,
[`plans/2026-06-11-hybrid-lazy-solution-implementation.md`](../plans/2026-06-11-hybrid-lazy-solution-implementation.md)).**
The reference solution is no longer sent to the tutor LLM on every call. Each turn is a
bounded two-round mini-loop, invisible to the client:

1. **Round 1** — system prompt carries persona + assignment + a course-materials
   *manifest* (the solution's existence, not its content) and offers a server-side
   `load_reference` tool.
2. If the model calls `load_reference`, the backend **re-assembles** the prompt with the
   solution injected, removes the tool from the tool list (structural termination — a
   third round is impossible), and calls the LLM once more. **Round 2's reply is the
   terminal reply**; round 1's prose is discarded.

Client-visible effects, all backward-compatible:

- `usage` = Σ of both rounds when the loop ran (see above);
- `warnings` gains `"reference_loaded"` on loop turns;
- `actions` never contains `load_reference`;
- the solution content itself never appears in any response field;
- worst-case latency doubles on loop turns (2 × the 30 s upstream timeout).

State does **not** persist across turns: a follow-up question re-triggers the loop if the
model needs the solution again (Phase 1 decision — accepted, measured via the
`reference_loaded` rate).

---

## Composed system prompt

The server reads four artefacts on every allowed call and concatenates them
in this order via `Prompts::TutorSystemPrompt.build`:

```
{TUTOR.md — persona, role, allowed/forbidden, enforcement}

---

## Assignment
{HW 02.docx.txt content}

---

## Available Course Materials
{manifest: advertises `reference_solution` via `load_reference` (round 1);
switches to an "included below" notice once loaded (round 2)}

---

## Reference Solution            ← round 2 only (hybrid lazy)
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

> **NEW (2026-06-12) — two workspace channels.** `workspace_overview` renders as its own
> `## Student Workspace (overview)` section (followed by a `## Loading Workspace Files`
> guide and **no** `## Workspace Line Numbers` guide — the overview has no numbered lines).
> It **coexists** with `## Student Workspace (live)`: overview = the full file listing,
> `file_context` = the loaded subset. The fixture `## Student Workspace Files` block is now
> a Phase-1 fallback rendered **only when the request carries neither field**. Budgeting:
> `workspace_overview` is the cheapest droppable and is budgeted **first** (before
> `file_context`, before history); dropping it sets the `workspace_overview_dropped`
> warning and frees its budget to the slots below.

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

## Migration order

**NEW (2026-06-12).** The `workspace_overview` split is rolled out **backend-first**:

1. **Backend (this repo) — shipped.** Backward compatible: a CLI that still sends the
   combined project-summary-plus-contents blob in `file_context` (no `workspace_overview`)
   behaves exactly as before. The `edit_file` gate is **inert** without `workspace_overview`,
   so v1 `@`-mention edits are unchanged.
2. **Frontend (MindyCLI) — pending.** The CLI then splits what it sends: the project scan
   summary moves to `workspace_overview`; `file_context` carries **only** loaded,
   line-numbered file contents, each prefixed with its `### <relative path>` header (the
   path spelled exactly as the overview lists it — the gate matches on it). The CLI keeps
   resolving `load_file` actions by reading the file, prefixing line numbers, and re-sending
   in `file_context` next turn, and renders the `edit_file_redirected` warning. Two hygiene
   measures pair with the [Redundant load gate](#redundant-load-gate) (plan 2026-06-13 §5):
   (a) **dedupe** `file_context` so each loaded path appears once — including `@`-mention
   paths in the dedup set — and (b) cap the `load_file` resolve loop at a fixed number of
   rounds (the structural backstop when a budget-trimmed `### header` slips past the backend
   gate), surfacing `redundant_load_dropped` to converge early.

Do **not** ship the CLI first: a backend that predates `workspace_overview` would let
`dry-validation` strip the unknown field, losing the file listing entirely.

---

## Security notes

- `X-LLM-Key` is forwarded to the LLM provider over HTTPS and is never
  written to the database.
- `KeyScrubber` middleware redacts `sk-xxx` patterns from response bodies
  and logs.
- **Tutor-only LLM calls here (CHANGED — Workstream B; 2026-06-12).** This route calls
  only the **tutor** LLM — once normally, twice when the hybrid lazy mini-loop consults
  the reference solution. The guard runs once, in the `/guard_checks` pre-call. Each
  route bills its own calls — no double-counting; this route's `usage` is the Σ of its
  own 1–2 tutor calls.
- **The solution stays server-side (2026-06-12).** `load_reference` and the
  course-materials manifest exist only in the LLM API payload (tool list / system
  prompt), never in the HTTP response: the tool is filtered from `actions`, and the
  solution text is injected only into the round-2 system prompt. The only client-visible
  trace is the content-free `"reference_loaded"` warning.
- **Rate-limit headers are generic pass-through (2026-06-18, route C).** The backend keeps
  every response header whose name contains `ratelimit` (plus `Retry-After`) and surfaces them
  as the `rate_limited` / `provider_rate_limited` signals — it does **not** hard-code any one
  provider's field schema (OpenAI, Anthropic, and GitHub Models all name them differently). The
  `X-LLM-Key` request header is never written to any log, including the optional wire-level
  debug log.
- **Trust without a second guard call.** The `guard_log_id` verification (log exists,
  status ∈ {`done`, `unavailable`}, stored prompt matches) is a DB read that preserves the
  skip/fabricate-resistant trust boundary the old internal guard provided, at no token
  cost. **For this to be sound, `/guard_checks` must persist the judged `prompt`** with the
  log so this route can confirm the same prompt is being tutored. See
  [`plans/2026-06-03-agentic-tutor-backend.md`](../plans/2026-06-03-agentic-tutor-backend.md) §4.
