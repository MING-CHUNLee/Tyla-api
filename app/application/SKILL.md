# Application Layer

> Source: SOA Week 11 — "Application Layer" (Service Oriented Architecture)

The Application Layer sits between the Presentation Layer and the Domain Model.
Its responsibility is to **orchestrate the response to requests** — receive input,
delegate work to Service Objects, and return the result to Presentation.

## Three Components

| Component | Role | One Reason to Change |
|---|---|---|
| **Controller** | Thin orchestrator: receives input, calls Form/Request Objects and Services, returns output | Change in HTTP route / CLI command signature |
| **Form Objects / Request Objects** | Validate and parse raw inputs before any processing | Change in input validation rules |
| **Service Objects** | Execute the actual work — multi-step transaction scripts that interact with infrastructure and domain models. **Contains application-level business logic.** | Change in processing workflow |

> **Controllers orchestrate; Service Objects do the work.**
> Domain Model objects make *domain decisions*. Service Objects coordinate
> *how* those decisions are executed — calling infrastructure, chaining steps,
> propagating errors across multiple domain models.

---

## Layered Architecture (this project)

```
app/
├── presentation/                ← Serialize domain to wire formats (see ../presentation/SKILL.md)
│   └── representers/            ← Roar JSON decorators (see ../presentation/representers/SKILL.md)
├── application/                 ← YOU ARE HERE: orchestrate requests
│   ├── controllers/             ← Thin entry points per CLI / HTTP route
│   ├── requests/                ← Validate input + map external API → entity (see ./requests/SKILL.md)
│   ├── services/                ← Business logic steps (see ./services/SKILL.md)
│   ├── prompts/                 ← LLM prompt builders
├── domain/                      ← Decision-making objects
│   └── entities/                ← Behavioral + DTO entities (see ../domain/SKILL.md, ../domain/entities/SKILL.md)
└── infrastructure/              ← CRUD for outside resources
    └── database/                ← ORM + Repository split (see ../infrastructure/database/SKILL.md)
        ├── orm/                 ← Thin Sequel models (see ../infrastructure/database/orm/SKILL.md)
        └── repositories/        ← ORM ↔ entity mapping (see ../infrastructure/database/repositories/SKILL.md)
```

**Key invariants:**
- Domain Model does not change when other layers change.
- Application Layer depends *downward* on Domain and Infrastructure; never leaks logic upward.
- Controllers have only one reason to change: the CLI command/route signature.

---

## The Problem: Fat Controllers

A fat controller does everything in one place:
1. Parse and validate inputs
2. Call infrastructure directly
3. Call domain model
4. Error-check at every step
5. Format and return output

**Violates Single Responsibility Principle:** one reason to change means one job.
A fat controller changes when input structure, validation rules, infrastructure,
domain logic, *or* output format changes — too many reasons.

---

## Fix 1: Form / Request Objects (Input Validation)

A dedicated class that encapsulates all input validation for one command/request.

```typescript
// Validate before any processing begins
const validated = RequestObject.parse(rawInput)
if (!validated.success) {
  return Failure(validated.error)
}
```

**Why:** Validation code is too detailed for a controller. Extracting it gives
validation its own single reason to change (input contract), independent of
processing steps.

---

## Fix 2: Result Monad (Explicit Error Propagation)

A data structure wrapping an outcome into exactly one of two types:

```
         call service
            /      \
         left       right
       Failure     Success
   (error message) (usable value)
```

- **Success(value)** — wraps the usable result
- **Failure(error)** — wraps the error message

Makes every error path explicit. No hidden control flow. Each step either
succeeds (pass value to next) or fails (short-circuit with error).

---

## Thin Controllers (The Result)

After Form Objects and Service Objects, controllers become thin:

```typescript
// controllers/ask.ts
async function askController(rawInput: unknown) {
  const request = RequestObject.parse(rawInput)       // validate
  const result  = await AskService.call(request)      // delegate

  if (result.isFailure()) {
    return renderError(result.error)                  // handle failure
  }
  return renderSuccess(result.value)                  // format output
}
```

**One reason to change:** the CLI command's input/output signature.
Changes in validation → RequestObject. Changes in logic → Service.

---

## Service Objects

For full Service Object details including multi-step transactions,
Railway Oriented Programming, and error chaining:

> Read **`./services/SKILL.md`**
