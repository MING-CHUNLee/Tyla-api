# Plan — Tutor Orchestration Backend (Tyla API)

> **Date:** 2026-05-20
> **Branch:** `refactor/thin-client` (same branch name as frontend, but on Tyla-api repo)
> **Companion plan:** `MindyCLI_demo/plans/2026-05-20-thin-client-frontend.md`

## Background

Tyla-api today exposes one endpoint, `POST /api/v1/prompt_logs`, used by the
CLI to record guard decisions. The frontend GuardAgent and tutor policies are
about to move server-side. This plan repurposes the existing endpoint into a
full chat orchestrator that:

1. Receives the student's prompt with course/project/student identity.
2. Pass-through reads the student's LLM provider/key from request headers
   (never stored).
3. Runs the GuardAgent (LLM-as-judge) against the jailbreak catalog.
4. (TODO this round, stub for now) Injects the official solution document.
5. Calls the upstream LLM with the composed prompt + history + file context.
6. Persists the log entry server-side.
7. Returns either an `ok` content payload or a `refused` refusal payload.

## Decisions (agreed with user)

| Topic | Decision |
|---|---|
| Endpoint | Reshape `POST /api/v1/prompt_logs` (same path, new contract). Old logging callers will break — only the CLI uses it today. |
| LLM key transport | Headers `X-LLM-Provider`, `X-LLM-Key`. Never logged, never written to DB. |
| Frontend Guard | Removed. Backend is the sole gate. |
| Modes covered | `tutor-socratic`, `tutor-guide` only. Other modes don't hit this endpoint. |
| HW solutions | Stub. Solution-injection step returns empty string this round. |
| Streaming | Non-streaming first pass — return full JSON when LLM completes. |
| Test framework | **minitest** with `Minitest::Spec` DSL. All specs in `spec/`, files end in `_spec.rb`. Run with `bundle exec rake spec`. |
| Guard JSON schema | LLM judge emits `{ "attack-probability": Float, "evaluation": String }`. `benign = 1.0 - attack`. |
| Guard threshold | **Domain-defined:** `AttackPolicy::THRESHOLD = 0.7`. `attack-probability >= 0.7` → blocked, no LLM call. |
| Guard failure mode | Judge LLM unavailable → fail-open (log warning). Judge returns attack >= 0.7 → hard block, no LLM call. |
| Refusal generation | **Templated** — no second LLM call. `RefusalTemplates` value object holds 2–3 sentences per mode (domain layer). |
| Guard prompt input | `JudgeSystemPrompt.build` reads `guard-judge.md` + `jailbreak-strategies.md`; no policy text passed to guard. |
| Layering | Service Objects in `app/application/services/`; prompt builders in `app/application/prompts/builders/`; domain rules/constants in `app/domain/values/`. |
| Prompt source | All prompts stay as MD files. Ruby builders are thin loaders/composers — no duplicated string literals in Ruby. |
| Policy path | `app/application/prompts/tutors/<mode>/TUTOR.md` (files already present, no migration needed). |
| Result monad | All services use `dry-monads` `Success`/`Failure` + ROP per `services/SKILL.md`. |
| Thin controller | Route handler only calls `HandleTutorChat.new.call(parsed, headers)` and pattern-matches the Result. |
| DB write timing | Write `pending` row **before** LLM call; update after. Requires migration: make `allowed` nullable. |
| Mode in DB | **Not stored** — mode is assigned per-class by the teacher, not per-log. |
| Model selection | Determined by the student's LLM key subscription. Backend cannot and does not control it. |
| CORS | `rack-cors` middleware; origin allowlist via `CORS_ALLOW_ORIGIN` env var. |
| X-LLM-Key redaction | Rack middleware scrubs key from error responses + warnings. Tests confirm key never appears in DB, response body, or log output. |
| Rate limiting | Per-`student_id`, max requests per window. **Domain defines the policy** (`RateLimitPolicy`); enforcer lives in application services. |
| Payload size limits | **Domain-defined constants** (`PayloadLimits`). `context.files` total ≤ 1 MB; `history` total ≤ 500 KB. Contract rejects over-limit requests. |
| Token-budget truncation | Before LLM call: keep last `MAX_HISTORY_TURNS = 10` turns; truncate each file at `MAX_FILE_LINES = 200`. Constants in `PayloadLimits`. |
| Mode validation | Contract strict whitelist (`tutor-socratic`, `tutor-guide`). `PolicyLoader` raises on unknown mode — no fallback. |
| Origin check | Rack middleware enforces `Origin` allowlist (same list as CORS). Rejects cross-origin POST from unlisted origins. |
| Idempotency (D1) | Accept optional `X-Request-Id` header; store in `request_id` column with `UNIQUE` index. Duplicate request → return existing row, skip LLM. **Tentative — may slip to follow-up PR.** |
| Structured logging (D2) | One JSON line per request to `$stdout` (no key, no prompt content). Fields: `time`, `request_id`, `student_id`, `course_id`, `mode`, `attack_prob`, `guard_allowed`, `latency_ms`, `input_tokens`, `output_tokens`, `status`. |
| Header access (D3) | `r.headers['X-LLM-Provider']` via `plugin :request_headers` (already mounted). Pin with a route spec so a future plugin removal breaks loudly. |
| Contract type (D4) | `json do` block in `TutorChatRequest` — parses nested JSON cleanly, no string coercion. |
| Naming (D5) | Endpoint path and table remain `prompt_logs` (legacy). Ruby class: `TutorChatRequest` (contract), `TutorChatResponseRepresenter` (Roar). PR description documents the legacy URL name. |
| Roar representer (D6) | `Gemfile` already has `roar`. Use `Roar::JSON` for `TutorChatResponseRepresenter` to shape the response — consistent with existing gem set. |

## Out of scope

- Solution storage / retrieval (separate follow-up).
- Authentication / authorization on the endpoint (student_id is trusted for
  now; deferred until JWT story is settled).
- SSE / streaming response.

---

## New API contract

### Request

```
POST /api/v1/prompt_logs
Host: localhost:9292
Content-Type: application/json
X-LLM-Provider: openai            # required
X-LLM-Key:      sk-...            # required, pass-through, not persisted
Origin:         http://localhost:3000   # must be in allowlist

{
  "course_id":   "CS101",
  "project_id":  "proj-001",
  "student_id":  "student-123",
  "mode":        "tutor-socratic",     # required: tutor-socratic | tutor-guide
  "userPrompt":  "How do I write bubble sort?",
  "history": [                         # optional, total ≤ 500 KB
    { "role": "user",      "content": "..." },
    { "role": "assistant", "content": "..." }
  ],
  "context": {                         # optional, total ≤ 1 MB
    "files": [
      { "path": "hw11.R", "content": "..." }
    ]
  }
}
```

### Response — allowed branch

```json
{
  "status":   "ok",
  "content":  "<LLM reply>",
  "usage":    { "input_tokens": 1234, "output_tokens": 256 },
  "log_id":   42
}
```

### Response — refused branch

```json
{
  "status":  "refused",
  "content": "<templated refusal sentence>",
  "reason":  "<evaluation from guard judge>",
  "probability": { "attack": 0.91, "benign": 0.09 },
  "log_id":  43
}
```

### Errors

| Status | Cause |
|---|---|
| 400 | Origin not in allowlist |
| 422 | Contract validation failed (missing/invalid field, oversized payload) |
| 401 | Missing `X-LLM-Provider` or `X-LLM-Key` header |
| 429 | Rate limit exceeded for this `student_id` |
| 502 | Upstream LLM call failed |
| 504 | Upstream LLM timeout (>30s) |

---

## Code layout (`Tyla-api/app/`)

```
app/
├── application/
│   ├── requests/
│   │   └── tutor_chat_request.rb          ← REPLACE create_prompt_log.rb
│   ├── services/
│   │   ├── handle_tutor_chat.rb           ← thin entry-point for controller
│   │   ├── tutor_orchestrator.rb          ← Guard → solution stub → LLM (dry-monads)
│   │   ├── guard_agent.rb                 ← LLM-as-judge
│   │   ├── policy_loader.rb               ← loads TUTOR.md by mode name (raises on unknown)
│   │   └── rate_limiter.rb                ← per-student in-memory rate check
│   ├── prompts/
│   │   ├── builders/
│   │   │   ├── judge_system_prompt.rb     ← reads guard-judge.md + jailbreak-strategies.md
│   │   │   └── tutor_system_prompt.rb     ← reads TUTOR.md + composes context (with truncation)
│   │   ├── guard-judge.md                 ← EXISTING (unchanged)
│   │   ├── jailbreak-strategies.md        ← EXISTING (unchanged)
│   │   └── tutors/
│   │       ├── tutor-socratic/TUTOR.md    ← EXISTING (unchanged)
│   │       └── tutor-guide/TUTOR.md       ← EXISTING (unchanged)
│   └── routes/
│       └── app_routes.rb                  ← thin controller (pattern-match on Result)
├── domain/
│   └── values/
│       ├── guard_result.rb                ← Struct: allowed, reason, probability
│       ├── attack_policy.rb               ← THRESHOLD = 0.7
│       ├── rate_limit_policy.rb           ← MAX_REQUESTS_PER_MINUTE, WINDOW_SECONDS
│       ├── payload_limits.rb              ← file/history size + truncation constants
│       └── refusal_templates.rb           ← per-mode templated refusal sentences
├── infrastructure/
│   ├── database/orm/prompt_log_orm.rb     ← unchanged
│   ├── middleware/
│   │   └── key_scrubber.rb               ← Rack middleware: redacts X-LLM-Key from errors
│   └── llm/
│       ├── llm_client.rb                  ← provider router
│       ├── openai_client.rb
│       └── anthropic_client.rb
└── presentation/
    └── representers/
        └── tutor_chat_response_representer.rb  ← Roar::JSON representer (shapes the JSON response)
```

---

## Domain values (`app/domain/values/`)

### `attack_policy.rb`

```ruby
module Tyla
  module Values
    module AttackPolicy
      THRESHOLD = 0.7
      # attack-probability >= THRESHOLD: blocked, no LLM call, return templated refusal.
      # attack-probability <  THRESHOLD: allowed, proceed to tutor LLM.
    end
  end
end
```

### `rate_limit_policy.rb`

```ruby
module Tyla
  module Values
    module RateLimitPolicy
      MAX_REQUESTS_PER_MINUTE = 20   # per student_id
      WINDOW_SECONDS          = 60
    end
  end
end
```

### `payload_limits.rb`

```ruby
module Tyla
  module Values
    module PayloadLimits
      # Hard limits — contract rejects requests exceeding these.
      MAX_CONTEXT_FILES_BYTES = 1_048_576   # 1 MB
      MAX_HISTORY_BYTES       = 512_000     # 500 KB

      # Soft truncation — applied inside TutorSystemPrompt before the LLM call.
      MAX_HISTORY_TURNS = 10    # keep last N user+assistant pairs
      MAX_FILE_LINES    = 200   # truncate each file after this many lines
    end
  end
end
```

### `refusal_templates.rb`

No second LLM call. Pick a sentence at random from a single shared pool (mode-agnostic):

```ruby
module Tyla
  module Values
    module RefusalTemplates
      TEMPLATES = [
        "That question isn't something I can help with directly here. " \
          "What aspect of the topic are you trying to understand?",
        "I'm not able to respond to that. " \
          "Try rephrasing as a conceptual question — what's the first idea you'd explore?",
        "Let's redirect. Instead of asking for the answer, what step would you take first to approach this problem?",
      ].freeze

      def self.for(_mode = nil)
        TEMPLATES.sample
      end
    end
  end
end
```

---

## Prompt builders (`app/application/prompts/builders/`)

### `judge_system_prompt.rb`

```ruby
module Tyla
  module Prompts
    module JudgeSystemPrompt
      TEMPLATE_PATH = File.expand_path('../../prompts/guard-judge.md', __dir__)
      CATALOG_PATH  = File.expand_path('../../prompts/jailbreak-strategies.md', __dir__)

      def self.build
        template = File.read(TEMPLATE_PATH)
        catalog  = File.read(CATALOG_PATH)
        template.gsub('{{jailbreakCatalog}}', catalog)
      end
    end
  end
end
```

### `tutor_system_prompt.rb`

Applies truncation constants from `PayloadLimits` before composing the LLM prompt:

```ruby
module Tyla
  module Prompts
    module TutorSystemPrompt
      def self.build(policy_text:, solution_text:, context_files:)
        parts = [policy_text]
        parts << "## Reference Solution\n#{solution_text}" unless solution_text.empty?

        unless context_files.empty?
          file_block = context_files.map { |f| format_file(f) }.join("\n\n")
          parts << "## Student Workspace Files\n#{file_block}"
        end

        parts.join("\n\n---\n\n")
      end

      def self.truncate_history(history)
        # Keep last MAX_HISTORY_TURNS user+assistant pairs.
        max_messages = Values::PayloadLimits::MAX_HISTORY_TURNS * 2
        history.last(max_messages)
      end

      private_class_method def self.format_file(file)
        lines = file[:content].lines
        limit = Values::PayloadLimits::MAX_FILE_LINES
        body  = lines.first(limit).join
        body += "\n# ... (truncated, showing first #{limit} lines)\n" if lines.size > limit
        "### #{file[:path]}\n```\n#{body}\n```"
      end
    end
  end
end
```

---

## Application services (`app/application/services/`)

### `policy_loader.rb`

Raises `ArgumentError` on unknown mode — no silent fallback:

```ruby
module Tyla
  module Services
    class PolicyLoader
      BASE_PATH = File.expand_path('../../prompts/tutors', __dir__)

      def load(mode)
        path = File.join(BASE_PATH, mode, 'TUTOR.md')
        raise ArgumentError, "unknown mode: #{mode}" unless File.exist?(path)

        File.read(path)
      end
    end
  end
end
```

### `guard_agent.rb`

Uses `AttackPolicy::THRESHOLD` (domain constant). Fail-open only for judge
unavailability; detected attacks are always hard-blocked:

```ruby
module Tyla
  module Services
    class GuardAgent
      def initialize(llm_client:)
        @llm = llm_client
      end

      # Returns Values::GuardResult.
      def check(prompt:, mode:)
        response    = @llm.send_prompt(
          system_prompt: Prompts::JudgeSystemPrompt.build,
          user_message:  prompt,
        )
        parsed      = JSON.parse(response.content)
        attack_prob = Float(parsed.fetch('attack-probability'))
        evaluation  = parsed.fetch('evaluation')
        benign_prob = (1.0 - attack_prob).round(4)
        allowed     = attack_prob < Values::AttackPolicy::THRESHOLD

        Values::GuardResult.new(
          allowed:     allowed,
          reason:      evaluation,
          probability: { attack: attack_prob, benign: benign_prob },
        )
      rescue StandardError => e
        # Judge LLM unavailable → fail-open. Log so the incident is visible.
        warn "[GuardAgent] judge unavailable (#{e.class}): #{e.message}"
        Values::GuardResult.new(allowed: true, reason: "llm-judge unavailable: #{e.class}")
      end
    end
  end
end
```

### `tutor_orchestrator.rb`

Refused branch returns a **templated refusal** — no second LLM call:

```ruby
module Tyla
  module Services
    class TutorOrchestrator
      include Dry::Monads[:result]

      def initialize(llm_client:, guard:, policy_loader:)
        @llm    = llm_client
        @guard  = guard
        @policy = policy_loader
      end

      def call(request)
        policy_text  = @policy.load(request.mode)   # raises ArgumentError on bad mode
        guard_result = @guard.check(prompt: request.user_prompt, mode: request.mode)

        if guard_result.allowed?
          composed = Prompts::TutorSystemPrompt.build(
            policy_text:   policy_text,
            solution_text: SolutionLoader.load_stub,   # TODO: real solutions
            context_files: request.context_files,
          )
          truncated_history = Prompts::TutorSystemPrompt.truncate_history(request.history)
          llm_response = @llm.send_prompt(
            system_prompt: composed,
            user_message:  request.user_prompt,
            history:       truncated_history,
          )
          Success(TutorChatResult.ok(content: llm_response.content, usage: llm_response.usage, guard: guard_result))
        else
          Success(TutorChatResult.refused(
            content:     Values::RefusalTemplates.for(request.mode),
            reason:      guard_result.reason,
            probability: guard_result.probability,
          ))
        end
      rescue ArgumentError => e
        Failure[:bad_mode, e.message]
      rescue LlmError::Timeout
        Failure[:upstream_timeout, 'LLM request timed out']
      rescue LlmError::Upstream => e
        Failure[:upstream_error, e.message]
      end
    end
  end
end
```

### `rate_limiter.rb`

Domain policy (`RateLimitPolicy`) is read here; enforcement is in-memory
(thread-safe `Mutex`). Sufficient for single-process Puma V1:

```ruby
module Tyla
  module Services
    class RateLimiter
      include Dry::Monads[:result]

      POLICY = Values::RateLimitPolicy

      def initialize
        @mutex   = Mutex.new
        @buckets = Hash.new { |h, k| h[k] = [] }  # student_id → [timestamps]
      end

      def check!(student_id)
        now = Time.now.to_f
        @mutex.synchronize do
          window_start = now - POLICY::WINDOW_SECONDS
          @buckets[student_id].reject! { |t| t < window_start }
          if @buckets[student_id].size >= POLICY::MAX_REQUESTS_PER_MINUTE
            return Failure[:rate_limited, 'too many requests — please wait a moment']
          end
          @buckets[student_id] << now
        end
        Success(true)
      end
    end
  end
end
```

A single `RateLimiter` instance is shared across requests (class-level or injected via
config initializer). Add to `config/application.rb`:

```ruby
RATE_LIMITER = Services::RateLimiter.new
```

### `handle_tutor_chat.rb`

Writes a `pending` row **before** the LLM call; updates it after.
This ensures every request has a log entry even if the LLM fails:

```ruby
module Tyla
  module Services
    class HandleTutorChat
      include Dry::Monads[:result]
      include Dry::Monads::Do

      def call(request_data, headers)
        provider = headers['X-LLM-Provider'] or return Failure[:unauthorized, 'missing X-LLM-Provider']
        api_key  = headers['X-LLM-Key']      or return Failure[:unauthorized, 'missing X-LLM-Key']

        request = TutorChatRequest.from(request_data)

        # Rate check (domain policy enforced here)
        yield RATE_LIMITER.check!(request.student_id)

        # Write pending row before LLM call
        log = Database::PromptLogOrm.create(
          course_id:  request.course_id,
          project_id: request.project_id,
          student_id: request.student_id,
          prompt:     request.user_prompt,
          allowed:    nil,   # nil = pending (requires nullable column — see Database section)
        )

        llm    = Infrastructure::LlmClient.for(provider: provider, api_key: api_key)
        guard  = GuardAgent.new(llm_client: llm)
        policy = PolicyLoader.new
        orch   = TutorOrchestrator.new(llm_client: llm, guard: guard, policy_loader: policy)

        result = yield orch.call(request)

        log.update(
          attack_prob: result.probability&.fetch(:attack),
          benign_prob: result.probability&.fetch(:benign),
          reason:      result.reason,
          allowed:     result.allowed?,
        )

        Success({ result: result, log_id: log.id })
      rescue Sequel::Error
        Failure[:db_error, 'could not write log entry']
      end
    end
  end
end
```

---

## Infrastructure

### `middleware/key_scrubber.rb`

Rack middleware that redacts `X-LLM-Key` from response bodies and warning strings
before they reach the client or log output:

```ruby
module Tyla
  module Middleware
    class KeyScrubber
      KEY_PATTERN = /(?:X-LLM-Key\s*:\s*|Bearer\s+)(sk-[A-Za-z0-9_\-]+)/i

      def initialize(app)
        @app = app
      end

      def call(env)
        status, headers, body = @app.call(env)
        scrubbed = body.map { |chunk| chunk.gsub(KEY_PATTERN, '[REDACTED]') }
        [status, headers, scrubbed]
      end
    end
  end
end
```

Mount in `config/application.rb`:

```ruby
use Middleware::KeyScrubber
```

### CORS (`rack-cors`)

Add to Gemfile:

```ruby
gem 'rack-cors', '~> 2.0'
```

Configure in `config/application.rb` (before route plugin):

```ruby
require 'rack/cors'

use Rack::Cors do
  allow do
    origins ENV.fetch('CORS_ALLOW_ORIGIN', 'http://localhost:3000').split(',')
    resource '/api/*',
      headers: :any,
      methods: %i[get post options],
      expose:  ['Content-Type']
  end
end
```

Set `CORS_ALLOW_ORIGIN=http://localhost:3000` in `.env` for local development.
For production, set to the deployed frontend URL.

### `llm_client.rb` (provider router)

```ruby
module Tyla
  module Infrastructure
    class LlmClient
      def self.for(provider:, api_key:)
        case provider
        when 'openai'    then OpenAiClient.new(api_key: api_key)
        when 'anthropic' then AnthropicClient.new(api_key: api_key)
        else raise LlmError::UnsupportedProvider, provider
        end
      end
    end
  end
end
```

Concrete clients use `Net::HTTP` with a 30s read timeout.
Both return `LlmResponse.new(content:, usage:)`.
On timeout: raise `LlmError::Timeout`. On non-2xx: raise `LlmError::Upstream`.

---

## Route handler (thin controller)

```ruby
r.on 'prompt_logs' do
  r.post do
    contract = Request::TutorChatRequest.new
    parsed   = contract.call(r.params)
    r.halt(422, { errors: parsed.errors.to_h }.to_json) unless parsed.success?

    outcome = Services::HandleTutorChat.new.call(parsed.to_h, r.headers)

    case outcome
    in Success({ result:, log_id: })
      response.status = 200
      Presentation::TutorChatResponseRepresenter.render(result, log_id: log_id)
    in Failure[:unauthorized, msg]
      r.halt(401, { error: msg }.to_json)
    in Failure[:rate_limited, msg]
      r.halt(429, { error: msg }.to_json)
    in Failure[:bad_mode, msg]
      r.halt(422, { error: msg }.to_json)
    in Failure[:upstream_timeout, msg]
      r.halt(504, { error: msg }.to_json)
    in Failure[:upstream_error, msg]
      r.halt(502, { error: msg }.to_json)
    in Failure[:db_error, msg]
      r.halt(500, { error: 'internal error' }.to_json)
    end
  end

  # GET /api/v1/prompt_logs — unchanged, admin queries
  r.get do
    dataset = Database::PromptLogOrm.order(Sequel.desc(:created_at))
    dataset = dataset.where(student_id: r.params['student_id']) if r.params['student_id']
    dataset = dataset.where(course_id:  r.params['course_id'])  if r.params['course_id']
    dataset = dataset.where(project_id: r.params['project_id']) if r.params['project_id']
    dataset.map { |log| serialize(log) }
  end
end
```

---

## Presentation (`app/presentation/representers/tutor_chat_response_representer.rb`)

Uses `Roar::JSON` (already in Gemfile) to shape the response. The representer decorates
a plain result hash; the route handler calls `render` and writes the JSON directly:

```ruby
require 'roar/json'

module Tyla
  module Presentation
    class TutorChatResponseRepresenter
      include Roar::JSON

      property :status
      property :content
      property :log_id
      property :reason
      property :probability
      property :usage

      # Build a plain struct, extend it with the representer, serialise.
      def self.render(result, log_id:)
        data = OpenStruct.new(
          status:      result.status,
          content:     result.content,
          log_id:      log_id,
          reason:      result.reason,
          probability: result.probability,
          usage:       result.usage,
        )
        data.extend(self)
        data.to_json
      end
    end
  end
end
```

Only fields with non-nil values will be meaningful; the JSON serialiser passes
`nil` properties through — callers should ignore absent keys (ok branch has no
`reason`/`probability`; refused branch has no `usage`).

---

## Structured logging (D2)

One JSON line written to `$stdout` per completed request. Written inside
`HandleTutorChat` after the row update (or on failure). Never contains the
LLM key or raw prompt content:

```ruby
# Inside HandleTutorChat#call, after log.update(...)
structured_log = {
  time:          Time.now.utc.iso8601(3),
  request_id:    request_id,           # from X-Request-Id header, may be nil
  student_id:    request.student_id,
  course_id:     request.course_id,
  mode:          request.mode,
  attack_prob:   result.probability&.fetch(:attack),
  guard_allowed: result.allowed?,
  latency_ms:    latency_ms,           # computed with monotonic clock
  input_tokens:  result.usage&.fetch(:input_tokens),
  output_tokens: result.usage&.fetch(:output_tokens),
  status:        result.status,
}.compact
$stdout.puts structured_log.to_json
```

Key omissions: no `X-LLM-Key`, no `prompt`, no `history`, no `context.files`.

---

## Request contract (`app/application/requests/tutor_chat_request.rb`)

Replaces `create_prompt_log.rb`. Hard payload-size limits enforced here via
domain constants; mode whitelist is a `rule`:

```ruby
module Tyla
  module Request
    class TutorChatRequest < Dry::Validation::Contract
      LIMITS = Values::PayloadLimits

      json do
        required(:course_id).filled(:string)
        required(:project_id).filled(:string)
        required(:student_id).filled(:string)
        required(:mode).filled(:string)
        required(:userPrompt).filled(:string)
        optional(:history).array(:hash) do
          required(:role).filled(:string)
          required(:content).filled(:string)
        end
        optional(:context).hash do
          optional(:files).array(:hash) do
            required(:path).filled(:string)
            required(:content).filled(:string)
          end
        end
      end

      rule(:mode) do
        unless %w[tutor-socratic tutor-guide].include?(value)
          key.failure('must be tutor-socratic or tutor-guide')
        end
      end

      rule(:history) do
        next unless value
        bytes = value.to_json.bytesize
        key.failure("must be ≤ #{LIMITS::MAX_HISTORY_BYTES / 1024} KB") if bytes > LIMITS::MAX_HISTORY_BYTES
      end

      rule(:context) do
        next unless value&.fetch(:files, nil)
        bytes = value[:files].to_json.bytesize
        key.failure("context.files must be ≤ #{LIMITS::MAX_CONTEXT_FILES_BYTES / 1024 / 1024} MB") if bytes > LIMITS::MAX_CONTEXT_FILES_BYTES
      end
    end
  end
end
```

---

## Database

### Migration required (new)

The pending-row strategy requires `allowed` to be **nullable** (nil = pending).
Current schema has `allowed: null: false, default: true` — add a migration:

```ruby
# backend_app/db/migrations/002_allow_nullable_allowed.rb
Sequel.migration do
  up   { alter_table(:prompt_logs) { set_column_allow_null :allowed } }
  down { alter_table(:prompt_logs) { set_column_not_null :allowed, default: true } }
end
```

No other schema changes this PR. `mode`, `assistant_content`, token usage deferred
to follow-up.

---

## Specs (`Tyla-api/spec/`)

```ruby
# Example structure using Minitest::Spec DSL
require 'minitest/autorun'

describe Tyla::Services::GuardAgent do
  it 'allows prompts below threshold' do ...  end
  it 'blocks prompts at or above threshold' do ... end
end
```

| Spec file | What it covers |
|---|---|
| `spec/domain/values/attack_policy_spec.rb` | `THRESHOLD == 0.7`; boundary: `attack < 0.7` allowed, `>= 0.7` blocked. |
| `spec/domain/values/refusal_templates_spec.rb` | `for('tutor-socratic')` returns non-empty string; unknown mode falls back gracefully. |
| `spec/domain/values/payload_limits_spec.rb` | Constants match design (`1_048_576`, `512_000`, `10`, `200`). |
| `spec/application/services/policy_loader_spec.rb` | Loads tutor-socratic and tutor-guide MD; raises `ArgumentError` on unknown mode. |
| `spec/application/services/guard_agent_spec.rb` | (a) Allowed when attack-probability < 0.7; (b) Blocked when ≥ 0.7; (c) `benign = 1.0 - attack`; (d) Fail-open + `warn` when LLM raises; (e) Fail-open when JSON missing keys; (f) `refusal_instruction` not present on `GuardResult` (refusal is in `RefusalTemplates`). |
| `spec/application/services/tutor_orchestrator_spec.rb` | (a) Allowed path calls LLM and returns `Success(TutorChatResult.ok)`; (b) Refused path returns `Success(TutorChatResult.refused)` with templated content — **LLM is NOT called**; (c) History is truncated to `MAX_HISTORY_TURNS * 2` messages; (d) File content is truncated at `MAX_FILE_LINES`; (e) LLM timeout → `Failure[:upstream_timeout]`; (f) LLM error → `Failure[:upstream_error]`; (g) Unknown mode → `Failure[:bad_mode]`. |
| `spec/application/services/rate_limiter_spec.rb` | (a) Allows under limit; (b) Returns `Failure[:rate_limited]` at limit; (c) Window expires and allows again; (d) Thread-safety (concurrent requests don't corrupt counter). |
| `spec/application/services/handle_tutor_chat_spec.rb` | (a) Missing provider header → `Failure[:unauthorized]`; (b) Missing key header → `Failure[:unauthorized]`; (c) Rate limited → `Failure[:rate_limited]`; (d) Pending row written before LLM call; (e) Row updated after LLM success; (f) `X-LLM-Key` never appears in any DB column; (g) Orchestrator `Failure` propagated without DB update. |
| `spec/application/routes/prompt_logs_route_spec.rb` | (a) 422 on missing `mode`/`userPrompt`; (b) 422 on invalid mode value; (c) 422 on oversized `context.files` (> 1 MB); (d) 422 on oversized `history` (> 500 KB); (e) 401 on missing headers; (f) 429 on rate limit; (g) 200 `status:'ok'` happy path; (h) 200 `status:'refused'` when guard blocks; (i) 502/504 on LLM errors; (j) DB row written exactly once per request; (k) `X-LLM-Key` does not appear in response body. |
| `spec/infrastructure/llm/openai_client_spec.rb` | WebMock-stubbed; auth header, body shape, 30s timeout, non-2xx → `LlmError::Upstream`, Net timeout → `LlmError::Timeout`. |
| `spec/infrastructure/middleware/key_scrubber_spec.rb` | (a) `sk-xxx` in response body is replaced with `[REDACTED]`; (b) `X-LLM-Key: sk-xxx` pattern redacted; (c) Clean bodies pass through unchanged. |
| `spec/application/prompts/builders/judge_system_prompt_spec.rb` | `build` replaces `{{jailbreakCatalog}}` with catalog content; result is non-empty. |
| `spec/application/routes/header_access_spec.rb` (D3) | Pins that `r.headers['X-LLM-Provider']` correctly reads the `X-LLM-Provider` HTTP header via `plugin :request_headers`. Fails loudly if the plugin is ever removed. |
| `spec/application/services/handle_tutor_chat_spec.rb` (structured log) | Captures `$stdout` during a request; asserts the emitted JSON line contains `student_id`, `mode`, `guard_allowed`, `status` — and does **not** contain `sk-` or `X-LLM-Key`. |

---

## Migration files & data movement

All prompt MD files are **already present** in this repo — no file copying needed.

| File | Status |
|---|---|
| `app/application/prompts/tutors/tutor-socratic/TUTOR.md` | Already present — no action. |
| `app/application/prompts/tutors/tutor-guide/TUTOR.md` | Already present — no action. |
| `app/application/prompts/guard-judge.md` | Already present — no action. |
| `app/application/prompts/jailbreak-strategies.md` | Already present — no action. |
| `app/application/requests/create_prompt_log.rb` | **Delete** — replaced by `tutor_chat_request.rb`. |
| `backend_app/db/migrations/002_allow_nullable_allowed.rb` | **Create** — makes `allowed` nullable for pending-row pattern. |

Frontend side: `tyla/src/application/services/guard-agent.ts` and related
prompt TS files are deleted in the companion frontend plan.

---

## Gemfile additions

```ruby
gem 'rack-cors', '~> 2.0'
```

`roar` is **already present** in Gemfile — used for `TutorChatResponseRepresenter`.
No other new gems — `Net::HTTP`, `dry-monads`, `dry-operation` already present.

---

## Execution order

1. **Branch:** `git checkout -b refactor/thin-client` on Tyla-api.
2. **Scaffold directories:**
   `app/application/services/`, `app/application/prompts/builders/`,
   `app/domain/values/`, `app/infrastructure/llm/`, `app/infrastructure/middleware/`,
   `spec/` mirrors.
3. **Domain values:** `AttackPolicy`, `RateLimitPolicy`, `PayloadLimits`, `RefusalTemplates`, `GuardResult` + minimal specs.
4. **Prompt builders:** `JudgeSystemPrompt`, `TutorSystemPrompt` (with truncation) + specs.
5. **`LlmClient` + `OpenAiClient`** — WebMock-stubbed spec first (TDD).
6. **`PolicyLoader`** + spec (raises on unknown mode).
7. **`GuardAgent`** + spec — stub LLM, table-driven cases using `AttackPolicy::THRESHOLD`.
8. **`RateLimiter`** + spec (window, limit, thread-safety).
9. **`TutorOrchestrator`** + spec — no second LLM call in refused branch; truncation verified.
10. **`HandleTutorChat`** + spec — pending row → LLM → update; key never in DB.
11. **DB migration 002** (`allowed` nullable). Run `bundle exec rake db:migrate`.
12. **Replace `Request::CreatePromptLog`** with `TutorChatRequest` (size rules from domain constants).
13. **`KeyScrubber` middleware** + spec. Mount in `config/application.rb`.
14. **CORS middleware** — add `rack-cors` to Gemfile, configure in `config/application.rb`.
15. **Reshape route handler** — pattern-match on Result, add 429 branch.
16. **`TutorChatRepresenter`** (`presentation/representers/`).
17. `bundle exec rake spec` — all green.
18. **Smoke test** against the frontend `refactor/thin-client` branch end-to-end before merging either.

---

## Risk & rollback

- **Endpoint contract is breaking.** Only known caller is the frontend, also on `refactor/thin-client`. Merge in lockstep.
- **LLM-as-judge costs one extra LLM call per turn.** Same profile as the old frontend implementation, now server-side.
- **Header-based key exposure.** `KeyScrubber` middleware redacts from response bodies. `error_handler` catches and scrubs before returning to client. Verify no server-side logging captures headers.
- **Guard fail-open.** Accepted for V1. A `warn` log makes the incident visible for debugging. Attack-detected branch is always hard-blocked regardless.
- **Pending-row migration.** Low risk — single-column change, SQLite and PostgreSQL both support it. `allowed: nil` rows are the only new state.
- **Rate limiter is in-memory.** State resets on restart; not shared across Puma workers if using `preload_app`. Acceptable for V1 single-process dev. Replace with Redis-backed counter before production multi-process deploy.
- **Rollback** = revert branch + run `bundle exec rake db:rollback` (migration 002). `prompt_logs` table data is untouched.

---

## Open follow-ups (next PRs, not this one)

1. Solution-injection: storage format, lookup keys, version control.
2. Backend authentication: JWT for student identity.
3. Multi-provider LLM key validation / safe handling docs.
4. Extend `prompt_logs` schema with `assistant_content` + token usage.
5. Replace in-memory `RateLimiter` with Redis-backed store for multi-process Puma.
6. `STRICT_MODE` env var to make guard fail-closed on judge unavailability.
7. Idempotency key (`X-Request-Id`) + DB unique index to prevent duplicate charges on retry.
8. Structured per-request logging (attack-rate, LLM latency, token cost) for research analytics.
