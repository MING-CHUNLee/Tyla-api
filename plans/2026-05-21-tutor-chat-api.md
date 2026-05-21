# Plan — Tutor Chat API (POST /api/v1/tutor_chats)

> **Date:** 2026-05-21
> **Status:** DRAFT v2 — design answers received, awaiting confirmation on Q2/Q3 sub-questions
> **Companion:** `doc/api_guard_checks.md` (the first API of this two-step flow)

## Background

The third API in the project (counting `prompt_logs` as the first). Second
stage of the **guard → tutor pipeline**:

```
┌─────────────────────────────────────────────────────────────────┐
│  Step 1: POST /api/v1/guard_checks   (existing)                 │
│    → frontend-facing guard. Returns allowed/blocked.            │
│    → On blocked, frontend stops and shows refusal.              │
├─────────────────────────────────────────────────────────────────┤
│  Step 2: POST /api/v1/tutor_chats    (THIS PLAN)                │
│    → server-side compose & forward to tutor LLM.                │
│    → Internally re-runs guard as defence-in-depth (Q3-C-1).     │
│    → Loads assignment, solution, student file, tutor persona    │
│      from disk based on project_id.                             │
│    → Returns LLM reply or refusal.                              │
└─────────────────────────────────────────────────────────────────┘
```

---

## Design decisions (confirmed with user)

| # | Topic | Decision |
|---|---|---|
| Q1 | Artefact source | **Phase 1:** hardcoded fixture path (`spec/fixtures/assignments/CSDS-HW2/...`). **Future:** filesystem keyed by `course_id`+`project_id` (storage format TBD). |
| Q2 | PDF handling | **Text only** — current `LlmClient` doesn't support PDF upload. `Hw2.pdf` will be pre-extracted offline to `Hw2.txt` and committed alongside the PDF. |
| Q3 | Guard trust boundary | **(C-1) Defence in depth** — re-run guard inside `/tutor_chats` even though frontend already called `/guard_checks`. ⚠ Cost: ~3 LLM calls per turn (2 guard + 1 tutor). **PENDING — please confirm C-1 vs C-2 vs C-3.** |
| Q4 | Endpoint path | `POST /api/v1/tutor_chats` (new, parallel to `/guard_checks`). |
| Q5 | Assignment lookup | `project_id` maps to one assignment folder. For Phase 1: any `project_id` resolves to the CSDS-HW2 fixture. |
| Q6 | Tutor modes | **Single persona** — drop the `mode` field. Server always loads `spec/fixtures/assignments/CSDS-HW2/tutors/tutor-guide/TUTOR.md`. |
| Q7 | Payload limit | Hard cap **2 MB** per request (matches `MAX_CONTEXT_FILES_BYTES` order of magnitude). Re-tune `PayloadLimits`. |

---

## Phase 1: hardcoded fixture paths

All four artefacts are read from disk on the server:

| Role | Server-side path (Phase 1) |
|---|---|
| Assignment | `spec/fixtures/assignments/CSDS-HW2/assignment/HW 02.docx.txt` |
| Solution | `spec/fixtures/assignments/CSDS-HW2/solutions/Hw2.txt` ← **needs to be created from Hw2.pdf** |
| Student WIP | `spec/fixtures/assignments/CSDS-HW2/student-files/Hw2.Rmd` |
| Tutor persona | `spec/fixtures/assignments/CSDS-HW2/tutors/tutor-guide/TUTOR.md` |

> Note: in Phase 1 even the student file is read from fixture. Realistically the
> student's Rmd is dynamic — Phase 2 should accept it in the request body.

### Pre-extraction step (one-time, before this PR can run)

```bash
# Use Ruby + pdf-reader to dump Hw2.pdf → Hw2.txt
# (Or any other PDF→text tool. Commit the .txt next to the .pdf.)
```

`pdf-reader` ([rubygems.org/gems/pdf-reader](https://rubygems.org/gems/pdf-reader))
is the simplest option. Added to `Gemfile` only if we want runtime extraction
(otherwise just used once locally).

---

## Request / response contract

### Request

```http
POST /api/v1/tutor_chats HTTP/1.1
Content-Type:    application/json
X-LLM-Key:       <token>            (required)
X-LLM-Provider:  openai             (optional, default openai)
X-LLM-Model:     gpt-4o             (optional, falls back to LLM_MODEL env)
X-LLM-Endpoint:  https://...        (optional)

{
  "course_id":  "CSDS",
  "project_id": "HW2",
  "student_id": "stu-abc",
  "prompt":     "Why is Freedman-Diaconis least sensitive to outliers?",
  "history": [
    { "role": "user",      "content": "..." },
    { "role": "assistant", "content": "..." }
  ]
}
```

Matches `/guard_checks` body shape (same four fields) + optional `history`.

### Response — allowed (200 OK)

```json
{
  "log_id":  101,
  "allowed": true,
  "content": "<LLM reply text>",
  "usage":   { "input_tokens": 4321, "output_tokens": 512 }
}
```

### Response — blocked by internal guard (200 OK)

```json
{
  "log_id":             102,
  "allowed":            false,
  "attack_probability": 0.91,
  "evaluation":         "Direct answer demand",
  "refusal":            "<templated refusal>"
}
```

### Response — judge LLM unavailable (202 Accepted)

Same fail-open policy as `/guard_checks`. We still call the tutor LLM but
attach a warning.

```json
{
  "log_id":  103,
  "allowed": true,
  "content": "<LLM reply text>",
  "warning": "guard skipped: llm unavailable"
}
```

### Errors

| Status | `status` | Cause |
|---|---|---|
| 400 | `bad_request` | Body validation failed |
| 401 | `unauthorized` | Missing `X-LLM-Key` |
| 404 | `not_found` | `project_id` doesn't map to an assignment folder |
| 413 | `payload_too_large` | Request body > 2 MB |
| 500 | `internal_error` | DB write or local file read failed |
| 502 | `upstream_error` | Tutor LLM call failed |
| 504 | `upstream_timeout` | Tutor LLM call timed out (>30s) |

---

## Composed system prompt structure

Built by `Prompts::TutorSystemPrompt.build`:

```
{TUTOR.md content — persona, role, allowed/forbidden, enforcement}

---

## Assignment
{HW 02.docx.txt content}

---

## Reference Solution
{Hw2.txt content (extracted from Hw2.pdf)}

---

## Student Workspace Files
### Hw2.Rmd
```{markdown}
{Hw2.Rmd content, truncated to MAX_FILE_LINES if needed}
```
```

The student's `prompt` goes in the user-message slot (not system). History
messages follow `chat completions` convention.

---

## Code layout

```
app/
├── application/
│   ├── controllers/
│   │   └── api.rb                                  ← ADD r.on 'tutor_chats' block
│   ├── requests/
│   │   └── tutor_chat.rb                           ← NEW (dry-validation contract)
│   ├── services/
│   │   └── tutor_chat/
│   │       ├── run_tutor_chat.rb                   ← NEW (mirrors RunGuardCheck)
│   │       ├── assignment_loader.rb                ← NEW
│   │       ├── solution_loader.rb                  ← REPLACE stub
│   │       ├── student_file_loader.rb              ← NEW (Phase 1: fixture path)
│   │       ├── tutor_persona_loader.rb             ← NEW (replaces PolicyLoader for this endpoint)
│   │       └── (existing tutor_orchestrator.rb — unused for this endpoint; the
│   │            new RunTutorChat composes guard + loaders + LLM directly)
│   └── prompts/
│       └── builders/
│           └── tutor_system_prompt.rb              ← already exists, may extend
├── domain/values/
│   └── payload_limits.rb                           ← bump caps to 2 MB if needed
└── presentation/representers/
    └── tutor_chat_representer.rb                   ← NEW (or inline JSON)
```

---

## Service sketch — `Services::RunTutorChat`

Mirrors the `RunGuardCheck` pattern (same shape the controller already
handles for `/guard_checks`):

```ruby
module Tyla
  module Services
    class RunTutorChat
      include Dry::Monads[:result]
      include Dry::Monads::Do

      def call(raw_params, headers)
        provider = headers['HTTP_X_LLM_PROVIDER'] || ENV.fetch('LLM_PROVIDER', 'openai')
        api_key  = headers['HTTP_X_LLM_KEY']      || ENV['OPENAI_API_KEY']
        return Failure[:unauthorized, 'missing X-LLM-Key'] if api_key.nil? || api_key.empty?

        model    = headers['HTTP_X_LLM_MODEL']
        endpoint = headers['HTTP_X_LLM_ENDPOINT']

        validated = Request::TutorChat.new.call(raw_params)
        return Failure[:bad_request, 'validation failed', validated.errors.to_h] unless validated.success?
        params = validated.to_h

        # --- Load artefacts (Phase 1: hardcoded fixture path) ---
        assignment = AssignmentLoader.load(params[:project_id])
        solution   = SolutionLoader.load(params[:project_id])
        student    = StudentFileLoader.load(params[:project_id])
        persona    = TutorPersonaLoader.load(params[:project_id])

        llm   = Infrastructure::LlmClient.for(provider: provider, api_key: api_key, model: model, endpoint: endpoint)
        guard = GuardAgent.new(llm_client: llm)

        # --- Defence-in-depth guard (Q3-C-1) ---
        guard_result = guard.check(prompt: params[:prompt], mode: nil)

        log = persist_pending_log(params, guard_result)

        if !guard_result.allowed?
          # Blocked → return refusal, no tutor LLM call
          return Success([:blocked, build_blocked_response(log, guard_result)])
        end

        # --- Compose & call tutor LLM ---
        system_prompt = Prompts::TutorSystemPrompt.build(
          policy_text:   persona,
          solution_text: "## Assignment\n#{assignment}\n\n## Reference Solution\n#{solution}",
          context_files: [{ path: 'Hw2.Rmd', content: student }]
        )
        llm_reply = llm.send_prompt(
          system_prompt: system_prompt,
          user_message:  params[:prompt],
          history:       params[:history] || []
        )

        Success([:ok, build_ok_response(log, llm_reply, guard_result)])

      rescue Infrastructure::LlmError::Timeout
        Failure[:upstream_timeout, 'LLM request timed out']
      rescue Infrastructure::LlmError::Upstream => e
        Failure[:upstream_error, e.message]
      rescue Sequel::Error
        Failure[:db_error, 'could not write log entry']
      rescue Errno::ENOENT => e
        Failure[:not_found, "missing artefact: #{e.message}"]
      end
    end
  end
end
```

---

## Route handler (`app/application/controllers/api.rb`)

Add a new block parallel to `guard_checks`:

```ruby
r.on 'tutor_chats' do
  r.post do
    outcome = Services::RunTutorChat.new.call(r.params, request.env)

    if outcome.failure?
      tag, message, errors = outcome.failure
      result = Response::Result.new(
        status:  SERVICE_FAILURE_STATUS.fetch(tag, :internal_error),
        message: message,
        errors:  errors
      )
      rep = Representer::HttpResponse.new(result)
      r.halt(rep.http_status_code, rep.to_json)
    end

    kind, payload = outcome.value!
    response.status = case kind
                      when :llm_unavailable then 202
                      else 200
                      end
    payload
  end
end
```

Map `not_found` → 404, `upstream_timeout` → 504, `upstream_error` → 502 in
`SERVICE_FAILURE_STATUS` (extend the existing table).

---

## Request contract sketch — `Request::TutorChat`

```ruby
module Tyla
  module Request
    class TutorChat < Dry::Validation::Contract
      params do
        required(:course_id).filled(:string)
        required(:project_id).filled(:string)
        required(:student_id).filled(:string)
        required(:prompt).filled(:string)
        optional(:history).array(:hash) do
          required(:role).filled(:string)
          required(:content).filled(:string)
        end
      end

      rule(:history) do
        next unless value
        bytes = value.to_json.bytesize
        key.failure('history exceeds 500 KB') if bytes > 500_000
      end
    end
  end
end
```

(Total request body is capped by middleware at 2 MB.)

---

## Loader sketches (Phase 1 — hardcoded fixture)

```ruby
module Tyla
  module Services
    FIXTURE_ROOT = File.expand_path('../../../../spec/fixtures/assignments', __dir__)

    module AssignmentLoader
      def self.load(_project_id)
        File.read(File.join(FIXTURE_ROOT, 'CSDS-HW2/assignment/HW 02.docx.txt'))
      end
    end

    module SolutionLoader
      def self.load(_project_id)
        File.read(File.join(FIXTURE_ROOT, 'CSDS-HW2/solutions/Hw2.txt'))
      end
    end

    module StudentFileLoader
      def self.load(_project_id)
        File.read(File.join(FIXTURE_ROOT, 'CSDS-HW2/student-files/Hw2.Rmd'))
      end
    end

    module TutorPersonaLoader
      def self.load(_project_id)
        File.read(File.join(FIXTURE_ROOT, 'CSDS-HW2/tutors/tutor-guide/TUTOR.md'))
      end
    end
  end
end
```

> **Phase 2 refactor (not in this PR):** all four loaders accept real
> `course_id`+`project_id` and read from a production data root (filesystem
> layout `data/courses/<course_id>/projects/<project_id>/...` or a DB table).
> Hardcoded fixture lookup gets replaced with directory-based lookup.

---

## Risks & known difficulties

1. **PDF pre-extraction is a manual setup step.** `Hw2.txt` must be committed
   before the route works. If forgotten, route returns 404 / 500.
2. **3 LLM calls per turn (if Q3-C-1 confirmed).** Verify cost target with the
   user — Q3-C-2 (single API, no separate guard endpoint) halves this.
3. **Loaders use fixture path under `spec/`.** Running with `RACK_ENV=production`
   typically excludes `spec/`. Either move fixtures out of `spec/` or
   document that Phase 1 only runs in dev/test environments.
4. **TUTOR.md fixture has YAML front-matter** (`name:`/`description:`/`approach:`)
   that the LLM may parse as metadata. Decide: keep front-matter, strip it
   before composing, or move it elsewhere.
5. **`Hw2.Rmd` size (~6 KB) is fine** but real student files could grow. The
   2 MB hard cap covers it; `MAX_FILE_LINES = 200` may truncate longer files —
   confirm whether that's the right behaviour for student WIP.
6. **History accumulation.** Six turns of full assignment+solution payload
   per turn doesn't happen — we only send the assignment/solution ONCE in the
   system prompt; history is just past user+assistant chat. Truncation logic
   in `TutorSystemPrompt.truncate_history` already handles this.
7. **No DB schema change needed** — reuse the existing `prompt_logs` table
   (same as `/guard_checks` writes to). Each `/tutor_chats` call creates one
   row; tracing a single student turn means reading two rows (guard_checks
   row + tutor_chats row). Consider whether they should be linked via
   `request_id` later.

---

## Implementation order

1. **Pre-extract `Hw2.pdf` → `Hw2.txt`** and commit it (uses `pdf-reader` locally).
2. **`Request::TutorChat`** contract + spec.
3. **Loaders** (`AssignmentLoader`, `SolutionLoader`, `StudentFileLoader`, `TutorPersonaLoader`) + specs.
4. **`RunTutorChat`** service + spec — internal guard + LLM call.
5. **Route handler** in `api.rb` + extend `SERVICE_FAILURE_STATUS` map.
6. **Documentation** — `doc/api_tutor_chats.md` (mirror the format of `api_guard_checks.md`).
7. **End-to-end test** — stub LLM, call route, assert response shape + DB row.

---

## Out of scope (follow-ups)

1. **Phase 2 loader refactor** — drop fixture path, key by `course_id`+`project_id`,
   decide between filesystem and DB storage.
2. **Student file upload mechanism** — accept `.Rmd` in request body (or via
   separate upload endpoint).
3. **Linking guard_checks + tutor_chats logs** via shared `request_id`.
4. **Streaming response** (SSE).
5. **Multimodal PDF input** if/when LLM provider supports it natively.
6. **Multiple tutor modes** (re-introduce `mode` field if needed).

---

## ⚠ Pending confirmations

- **Q3 sub-question:** confirm C-1 (3 LLM calls — both endpoints run guard)
  vs C-2 (2 LLM calls — `/tutor_chats` is the only entry, `/guard_checks`
  becomes optional UI hint).
- **Q2 sub-question:** confirm pre-extract `Hw2.pdf` → `Hw2.txt` (commit the
  .txt) vs runtime extraction via `pdf-reader` gem.
- **TUTOR.md front-matter:** keep or strip before sending to LLM?
