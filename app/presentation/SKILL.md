---
name: presentation
description: Presentation layer serializes domain entities to wire formats (JSON, etc.)
---

# Presentation Layer

`app/presentation/` is the seam between the application's domain vocabulary
and whatever shape the outside world expects.

```text
app/presentation/
└── representers/    ← Roar decorators that turn entities into JSON
```

## Responsibilities

- Take a domain `Entity::*` (or response DTO) and produce the JSON / hash
  the route is about to write
- Decide field ordering, naming on the wire, and formatting (e.g.
  `iso8601` for timestamps)

## Non-responsibilities

- **No business logic.** A representer that calls a policy, queries the DB,
  or chooses fields based on a runtime rule is doing service work — the
  service should build the right response DTO first, and presentation
  should serialize what it gets.
- **No domain knowledge.** Representers shape data; they do not interpret
  it.

See [`./representers/SKILL.md`](./representers/SKILL.md) for the representer
conventions and the inline `PromptLog` example.
