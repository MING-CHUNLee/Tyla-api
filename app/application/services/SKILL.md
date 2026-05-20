# Service Objects

> Part of the Application Layer — see `../SKILL.md` for full context.
> Source: SOA Week 11 — "Application Layer" (Service Oriented Architecture)

**Definition:** A Service Object is a design pattern wherein an object
encapsulates operations that **span across layers, components, or modules**.

**Use Service Objects when:**
- The action interacts with external/internal **infrastructure** (API, DB, filesystem)
- The action reaches across **multiple domain models**
- The logic is too complex or stateful for a controller

---

## Transaction Script Pattern

Controller routes are **transaction scripts** — a procedural design pattern:

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
- Results in deeply nested if/else or try/catch chains

**Solution:** Extract steps into a Service Object using Result Monads.

---

## Single-Step Service Object

Some transactions entail only one activity (one DB call, one API call, one file write).

```typescript
// services/list-projects.ts
class ListProjectsService {
  async call(projectList: string[]): Promise<Result<Project[], string>> {
    try {
      const projects = await Repository.findAll(projectList)
      return Success(projects)
    } catch (error) {
      return Failure('Could not access database')
    }
  }
}
```

Controller calls it and unwraps:

```typescript
const result = await new ListProjectsService().call(session.watching)
if (result.isFailure()) {
  return renderError(result.error)
}
const projects = result.value
```

---

## Multi-Step Service Object

When a service has many sequential steps, naive if/else chaining is unreadable:

```typescript
// BAD — deeply nested, separates result from its error
const first = await stepOne(input)
if (first.success) {
  const second = await stepTwo(first.value)
  if (second.success) {
    const third = await stepThird(second.value)
    if (third.success) { ... }
    else return Failure(third.error)
  } else return Failure(second.error)
} else return Failure(first.error)
```

Problems:
- Method becomes too long
- Code nests deeply
- `first` variable appears at top and bottom (hard to read)

---

## Railway Oriented Programming (ROP)

ROP solves chaining by **binding monadic steps**:

- **Success?** → send the Success value to the next step
- **Failure?** → short-circuit immediately, skip all remaining steps

Two tracks like a railway — success track and failure track:

```
  ●─── step1 ───── step2 ───── step3 ───→ Value
       │           │           │
       ↓           ↓           ↓
  Error track (any failure exits here)  → Error
```

```typescript
// GOOD — flat chain, each step returns Result
class AddProjectService {
  async call(input: RequestInput): Promise<Result<Project, string>> {
    return pipe(
      input,
      (i) => this.parseUrl(i),
      (r) => r.isSuccess() ? this.findProject(r.value) : r,
      (r) => r.isSuccess() ? this.storeProject(r.value) : r,
    )
  }

  private parseUrl(input: RequestInput): Result<ParsedUrl, string> {
    const match = input.remoteUrl.match(/github\.com\/(.+?)\/(.+)$/)
    if (!match) return Failure(`Invalid GitHub URL: ${input.remoteUrl}`)
    return Success({ ownerName: match[1], projectName: match[2] })
  }

  private async findProject(parsed: ParsedUrl): Promise<Result<ProjectData, string>> {
    try {
      const local = await Repository.findByFullName(parsed.ownerName, parsed.projectName)
      if (local) return Success({ localProject: local })
      const remote = await GithubGateway.fetch(parsed.ownerName, parsed.projectName)
      return Success({ remoteProject: remote })
    } catch {
      return Failure('Could not find that project')
    }
  }

  private async storeProject(data: ProjectData): Promise<Result<Project, string>> {
    try {
      if (data.remoteProject) {
        const saved = await Repository.create(data.remoteProject)
        return Success(saved)
      }
      return Success(data.localProject!)
    } catch {
      return Failure('Having trouble accessing the database')
    }
  }
}
```

**Rules for each step:**
1. Each step is a **method** taking the previous step's success value
2. Each step must return a **Result** (`Success(...)` or `Failure(...)`)
3. On failure, the chain short-circuits — remaining steps are skipped

---

## Services in This Project

```
services/
├── code-confirmer.ts       ← Confirms code changes with user before applying
├── context-builder.ts      ← Builds context for LLM from conversation + files
├── diff-engine.ts          ← Computes diffs between file versions
├── edit-staging-service.ts ← Stages file edits before committing
├── evaluator.ts            ← Evaluates LLM output quality
├── file-read-service.ts    ← Reads files with error handling
├── history-summarizer.ts   ← Summarizes conversation history
├── intent-router.ts        ← Routes intent to correct use-case
├── knowledge-base.ts       ← Manages knowledge entries
├── mode-manager.ts         ← Manages CLI operating modes
├── r-environment-service.ts← R environment setup and validation
└── slash-command-router.ts ← Routes slash commands to handlers
```

Services can be **directly integration-tested** independent of controllers —
they are plain classes with a `call` method that take typed inputs and return Results.
