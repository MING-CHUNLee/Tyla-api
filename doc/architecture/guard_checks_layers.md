# Architecture — `POST /api/v1/guard_checks`

This document records, layer by layer, how the `guard_checks` endpoint is
served: which file calls which, and on what basis each branch is taken.

- The **sequence diagram** shows the cross-layer call chain between files.
- The **flowchart** shows the decision criteria that determine the outcome.

Source of truth: [`app/application/controllers/api.rb`](../../app/application/controllers/api.rb)
(route block `r.on 'guard_checks'`).

> Note: `Services::RateLimiter` (`app/application/services/guard/rate_limiter.rb`)
> exists but is **not** wired into `RunGuardCheck`, so it is intentionally
> omitted from both diagrams below.

---

## Layers and files

| Layer | File | Role |
|-------|------|------|
| Application / Controllers | `app/application/controllers/api.rb` | Roda route handler; maps service outcome to HTTP |
| Application / Services | `app/application/services/guard/run_guard_check.rb` | Orchestrates the whole guard check |
| Application / Services | `app/application/services/guard/guard_agent.rb` | Runs the LLM judge, parses its verdict |
| Application / Requests | `app/application/requests/guard_check.rb` | dry-validation contract for the request body |
| Application / Prompts | `app/application/prompts/builders/judge_system_prompt.rb` | Builds the judge system prompt from on-disk artefacts |
| Domain / Values | `app/domain/values/guard_result.rb` | Value object holding the judge verdict |
| Domain / Values | `app/domain/policy/attack_policy.rb` | `allowed?` threshold rule (0.7) |
| Domain / Values | `app/domain/values/refusal_templates.rb` | Random refusal message pool |
| Domain / Entities | `app/domain/entities/prompt_log.rb` | Persistable prompt-log entity |
| Infrastructure / LLM | `app/infrastructure/llm/llm_client.rb` | Provider factory (`openai` / `anthropic`) |
| Infrastructure / LLM | `app/infrastructure/llm/openai_client.rb`, `anthropic_client.rb` | Concrete LLM clients |
| Infrastructure / Database | `app/infrastructure/database/repositories/prompt_logs.rb` | Repository for `prompt_logs` |
| Infrastructure / Database | `app/infrastructure/database/orm/prompt_log_orm.rb` | Sequel ORM model |
| Presentation | `app/presentation/responses/result.rb` | Error envelope (`status`, `message`, `errors`) |
| Presentation | `app/presentation/representers/http_response.rb` | Maps `status` symbol to HTTP code + JSON |

---

## Sequence diagram — cross-layer file calls

```mermaid
sequenceDiagram
    autonumber
    actor Client

    box rgb(225,238,255) Application layer
    participant Api as Controller<br/>api.rb
    participant RGC as Services::RunGuardCheck
    participant Req as Request::GuardCheck
    participant GA as Services::GuardAgent
    participant JSP as Prompts::JudgeSystemPrompt
    end

    box rgb(255,243,225) Domain layer
    participant GR as Values::GuardResult
    participant AP as Values::AttackPolicy
    participant RT as Values::RefusalTemplates
    participant Ent as Entity::PromptLog
    end

    box rgb(230,250,232) Infrastructure layer
    participant LC as Infrastructure::LlmClient
    participant LLM as OpenAi / Anthropic Client
    participant Repo as Repository::PromptLogs
    participant ORM as Database::PromptLogOrm
    end

    box rgb(245,233,255) Presentation layer
    participant Result as Response::Result
    participant HttpRep as Representer::HttpResponse
    end

    Client->>Api: POST /api/v1/guard_checks<br/>{course_id, project_id, student_id, prompt}<br/>+ X-LLM-* headers
    Api->>RGC: call(r.params, request.env)

    Note over RGC: (1) Resolve headers:<br/>provider / api_key / model / endpoint
    alt api_key is nil or empty
        RGC-->>Api: Failure[:unauthorized, 'missing X-LLM-Key']
    end

    RGC->>Req: new.call(raw_params)
    Note over Req: dry-validation contract:<br/>course_id / project_id / student_id / prompt<br/>all required, filled(:string)
    Req-->>RGC: validated (success? / errors)
    alt validated.success? == false
        RGC-->>Api: Failure[:bad_request, 'validation failed', errors]
    end

    RGC->>LC: for(provider:, api_key:, model:, endpoint:)
    Note over LC: Branch on provider:<br/>'openai' -> OpenAiClient<br/>'anthropic' -> AnthropicClient<br/>else -> raise UnsupportedProvider
    LC-->>RGC: llm client instance

    RGC->>GA: new(llm_client: llm).check(prompt:, mode: nil)

    GA->>JSP: build
    Note over JSP: Read guard-judge.md +<br/>jailbreak-strategies.md, inject catalog
    JSP-->>GA: system_prompt string

    GA->>LLM: send_prompt(system_prompt:, user_message: prompt)
    alt LLM responds normally
        LLM-->>GA: response.content (JSON)
        Note over GA: JSON.parse -> attack-probability, evaluation
        GA->>GR: new(reason:, probability: {attack:})
    else LLM fails (rescue StandardError)
        Note over GA: fail-open: warn, no probability
        GA->>GR: new(allowed: true,<br/>reason: 'llm-judge unavailable')
    end
    GR-->>RGC: GuardResult

    Note over RGC: llm_unavailable = result.probability.nil?

    RGC->>Ent: new(course_id, project_id, student_id, prompt,<br/>attack_probability, evaluation)
    RGC->>Repo: create(entity)
    Repo->>ORM: create(entity.to_attr_hash)
    ORM-->>Repo: db_resource
    Repo-->>RGC: Entity::PromptLog (with id)

    Note over RGC: build_response -> decide allowed / blocked
    RGC->>GR: allowed?
    GR->>AP: allowed?(attack_probability)
    Note over AP: attack_probability < THRESHOLD (0.7)<br/>-> true allowed / false blocked
    AP-->>GR: true / false
    GR-->>RGC: allowed (boolean)

    alt allowed == false (blocked)
        RGC->>RT: for
        RT-->>RGC: random refusal message
    end
    Note over RGC: llm_unavailable -> payload[:warning]

    alt llm_unavailable == true
        RGC-->>Api: Success([:llm_unavailable, response])
    else
        RGC-->>Api: Success([:ok, response])
    end

    alt outcome.failure?
        Note over Api: SERVICE_FAILURE_STATUS maps<br/>failure tag -> status symbol
        Api->>Result: new(status:, message:, errors:)
        Api->>HttpRep: new(result)
        Note over HttpRep: http_status_code via HTTP_CODE table
        HttpRep-->>Api: http_status_code + to_json
        Api-->>Client: r.halt(status_code, JSON error body)
    else outcome success
        Note over Api: kind == :llm_unavailable ? 202 : 200
        Api-->>Client: HTTP 200 / 202 + payload<br/>{log_id, allowed, attack_probability,<br/>evaluation, refusal?, warning?}
    end
```

---

## Flowchart — decision criteria

```mermaid
flowchart TD
    Start([POST /api/v1/guard_checks]) --> Headers[RunGuardCheck:<br/>resolve provider / api_key / model / endpoint]

    Headers --> KeyCheck{api_key present<br/>and non-empty?}
    KeyCheck -- No --> Fail401[Failure :unauthorized<br/>'missing X-LLM-Key']
    KeyCheck -- Yes --> Validate[Request::GuardCheck.call<br/>dry-validation contract]

    Validate --> ValidCheck{All 4 fields<br/>filled strings?}
    ValidCheck -- No --> Fail400[Failure :bad_request<br/>'validation failed' + errors]
    ValidCheck -- Yes --> Provider{provider value?}

    Provider -- openai --> OpenAi[OpenAiClient]
    Provider -- anthropic --> Anthropic[AnthropicClient]
    Provider -- other --> Raise[raise UnsupportedProvider]

    OpenAi --> Judge[GuardAgent.check:<br/>send judge prompt to LLM]
    Anthropic --> Judge

    Judge --> LlmOk{LLM call<br/>succeeded?}
    LlmOk -- No, StandardError raised --> FailOpen[fail-open GuardResult:<br/>allowed = true, probability = nil]
    LlmOk -- Yes --> Parse[JSON.parse response:<br/>attack-probability, evaluation]
    Parse --> Verdict[GuardResult with<br/>probability = attack_prob]

    FailOpen --> Persist[(Persist Entity::PromptLog<br/>via Repository::PromptLogs)]
    Verdict --> Persist

    Persist --> DbOk{DB write OK?}
    DbOk -- No, Sequel::Error --> Fail500[Failure :db_error<br/>-> internal_error 500]
    DbOk -- Yes --> Unavail{probability<br/>is nil?}

    Unavail -- Yes, LLM unavailable --> Resp202[Response + warning<br/>'guard skipped: llm unavailable']
    Unavail -- No --> Threshold{AttackPolicy.allowed?<br/>attack_probability < 0.7}

    Threshold -- "true (< 0.7)" --> Allowed[allowed = true<br/>no refusal]
    Threshold -- "false (>= 0.7)" --> Blocked[allowed = false<br/>attach RefusalTemplates.for]

    Resp202 --> Out202([HTTP 202 Accepted<br/>allowed = true + warning])
    Allowed --> Out200a([HTTP 200 OK<br/>allowed = true])
    Blocked --> Out200b([HTTP 200 OK<br/>allowed = false + refusal])

    Fail401 --> ErrEnv[Build Response::Result +<br/>Representer::HttpResponse]
    Fail400 --> ErrEnv
    Fail500 --> ErrEnv
    ErrEnv --> OutErr([HTTP 4xx / 5xx<br/>status + message + errors])

    classDef fail fill:#ffe0e0,stroke:#c0392b;
    classDef ok fill:#e0f5e0,stroke:#27ae60;
    classDef warn fill:#fff3d0,stroke:#e0a000;
    class Fail401,Fail400,Fail500,Raise,OutErr fail;
    class Allowed,Out200a,Out200b ok;
    class FailOpen,Resp202,Out202,Blocked warn;
```

---

## Decision criteria reference

| Decision point | Layer / file | Criterion | Outcome |
|---|---|---|---|
| API key check | `RunGuardCheck` | `X-LLM-Key` header (or `OPENAI_API_KEY`) is nil/empty | `Failure[:unauthorized]` -> HTTP 401 |
| Body validation | `Request::GuardCheck` (dry-validation) | All 4 fields required and `filled(:string)` | failure -> `Failure[:bad_request]` -> HTTP 400 |
| Provider routing | `LlmClient.for` | `provider` = `openai` / `anthropic` / other | build client, or `raise UnsupportedProvider` |
| LLM availability | `GuardAgent#check` | `send_prompt` raises `StandardError` | failure -> fail-open (`allowed: true`, `probability: nil`) |
| Attack verdict | `AttackPolicy.allowed?` | `attack_probability < 0.7` (THRESHOLD) | true = allowed / false = blocked |
| Refusal message | `RefusalTemplates.for` | `allowed? == false` | attach random refusal string |
| DB write | `Repository::PromptLogs` | `Sequel::Error` raised | `Failure[:db_error]` -> HTTP 500 |
| HTTP status | Controller `api.rb` | `kind == :llm_unavailable` | 202 (guard skipped) / 200 (normal) |
| Error mapping | `SERVICE_FAILURE_STATUS` + `HTTP_CODE` | failure tag -> status symbol -> HTTP code | 400 / 401 / 500 |

### Key design points

1. **Fail-open** — when the LLM judge is unavailable, `GuardAgent` does not
   block the request; it returns `allowed: true` with a `warning`, and the
   controller responds `202 Accepted`.
2. **`RateLimiter` is not wired in** — `Services::RateLimiter` is implemented
   but never called by `RunGuardCheck`; rate limiting must be invoked
   explicitly in the service if it is to take effect.
