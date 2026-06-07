# Service Objects

> Part of the Application Layer — see `../SKILL.md` for full context.
> Source: SOA Week 11 — "Application Layer" (Service Oriented Architecture)

**Definition:** A Service Object is a design pattern wherein an object
encapsulates operations that **span across layers, components, or modules**.

**Use Service Objects when:**
- The action interacts with external/internal **infrastructure** (API, DB, filesystem)
- The action reaches across **multiple domain models**
- The logic is too complex or stateful for a controller

This project's convention: every service is a class under
`Tyla::Services::` with a `#call` method that returns a `Dry::Monads`
`Result` (`Success(...)` or `Failure[:tag, message]`). Controllers
unwrap the Result and translate it to HTTP — they do not branch on
service internals.

---

## Transaction Script Pattern

Controllers are **transaction scripts** — a procedural design pattern:

```
inputs → [step → step → step] → output
               ↓ (any failure)
             error
```

- A **set of actions must succeed or fail together**
- **Inputs** require validation before any step runs
- Each **step**: success → go to next; failure → end with error
- **Output** only if *everything* succeeds
- **Error** reported immediately when anything fails

**Problem with transaction scripts in controllers:**
- Controller must know the entire workflow
- Controller must error-check at every step
- Controller must know the correct error message per step
- Results in deeply nested if/else or begin/rescue chains

**Solution:** Extract steps into a Service Object using Result monads.

---

## Single-Step Service Object

Some transactions entail only one activity (one DB call, one API call,
one file write).

```ruby
# app/application/services/list_projects.rb
module Tyla
  module Services
    class ListProjects
      include Dry::Monads[:result]

      def call(project_list)
        Success(Repository::Projects.find_all(project_list))
      rescue Sequel::Error
        Failure[:db_error, 'could not access database']
      end
    end
  end
end
```

Controller calls it and unwraps:

```ruby
outcome = Services::ListProjects.new.call(session_watching)
if outcome.failure?
  tag, message = outcome.failure
  # render error using SERVICE_FAILURE_STATUS table in the controller
end
projects = outcome.value!
```

---

## Multi-Step Service Object

When a service has many sequential steps, naive if/else chaining is
unreadable:

```ruby
# BAD — deeply nested, separates result from its error
first = step_one(input)
if first.success?
  second = step_two(first.value!)
  if second.success?
    third = step_three(second.value!)
    if third.success?
      ...
    else
      return Failure(third.failure)
    end
  else
    return Failure(second.failure)
  end
else
  return Failure(first.failure)
end
```

Problems:
- Method becomes too long
- Code nests deeply
- The variable `first` is referenced top and bottom (hard to read)

---

## Railway Oriented Programming (ROP) with `Dry::Monads::Do`

ROP solves chaining by **binding monadic steps**:

- **Success?** → unwrap the value and pass it to the next step
- **Failure?** → short-circuit immediately, skip all remaining steps

Two tracks like a railway — success track and failure track:

```
  ●─── step1 ───── step2 ───── step3 ───→ Value
       │           │           │
       ↓           ↓           ↓
  Error track (any failure exits here)  → Error
```

In this project we use `Dry::Monads::Do` (the `yield` notation) — it is
the successor to the now-deprecated `dry-transaction` gem, and it
flattens the chain so each step reads like a normal assignment while
still short-circuiting on `Failure`:

```ruby
# GOOD — flat chain, each step returns Result
module Tyla
  module Services
    class ListPromptLogs
      include Dry::Monads[:result]
      include Dry::Monads::Do

      REQUIRED_FILTERS = %w[student_id course_id project_id].freeze

      def call(params)
        filters  = yield validate_filters(params)
        entities = yield fetch_logs(filters)
        Success(entities)
      end

      private

      def validate_filters(params)
        missing = REQUIRED_FILTERS.reject do |key|
          value = params[key]
          value.is_a?(String) && !value.strip.empty?
        end
        return Success(REQUIRED_FILTERS.each_with_object({}) { |k, h| h[k.to_sym] = params[k] }) if missing.empty?

        Failure[:bad_request, "missing required query parameters: #{missing.join(', ')}"]
      end

      def fetch_logs(filters)
        Success(Repository::PromptLogs.find_all(filters))
      rescue Sequel::Error
        Failure[:db_error, 'could not load prompt logs']
      end
    end
  end
end
```

**Rules for each step:**
1. Each step is a **private method** taking the previous step's success value
2. Each step must return a **Result** (`Success(...)` or `Failure[:tag, message]`)
3. On failure, the chain short-circuits — remaining steps are skipped
4. Failures carry a **tag symbol** (`:bad_request`, `:db_error`, `:unauthorized`, ...)
   so the controller can map them to HTTP without parsing message strings

### Tag → HTTP mapping lives in the controller

Services do not know about HTTP. The controller owns one place where
failure tags become `Response::Result` statuses
(see `SERVICE_FAILURE_STATUS` in `app/application/controllers/api.rb`).

---

## Services in This Project

```
services/
├── list_prompt_logs.rb         ← Lists prompt logs scoped to (student_id, course_id, project_id)
├── guard/
│   ├── guard_agent.rb          ← Wraps an LLM call that classifies a prompt Ｓas attack vs. benign
│   └── run_guard_check.rb      ← Endpoint service for POST /api/v1/guard_checks
└── tutor_chat/
    └── run_tutor_chat.rb       ← Endpoint service for POST /api/v1/tutor_chats
```

Canonical examples to read first:
- [`list_prompt_logs.rb`](./list_prompt_logs.rb) — minimal two-step service: validate, then DB call
- [`tutor_chat/run_tutor_chat.rb`](./tutor_chat/run_tutor_chat.rb) — multi-step orchestration:
  re-runs the guard server-side, composes the tutor prompt from on-disk artefacts, and forwards
  to the tutor LLM with tagged failures (`:upstream_timeout`, `:upstream_error`, …)

Services can be **directly integration-tested** independent of
controllers — they are plain classes with a `call` method that take
typed inputs and return Results. See
`spec/application/services/*_spec.rb` for the testing pattern (in-memory
Sequel DB + service called directly).
