---
name: domain-entities
description: When to use Dry::Struct DTO entities vs. plain Ruby class entities in domain/entities/
---

# Domain Entities

Entities live in `app/domain/entities/` and represent things the domain
recognizes by identity. This project uses two implementation styles depending
on whether the entity carries behavior.

## Two flavors

### Dry::Struct DTO entity — for pure data carriers

Use `Dry::Struct` when the entity is a passive container that:

- Comes from / goes to external boundaries (DB row, HTTP request, JSON)
- Has no domain methods beyond simple accessors
- Is mostly serialized, mapped, or persisted as-is

Inline example: [`./prompt_log.rb`](./prompt_log.rb)

Required shape:

- Module path `Tyla::Entity::*`
- Strict types via `Dry.Types()`. Only use `.optional` for fields the schema
  or workflow legitimately allows to be nil — e.g. `id` before persistence,
  pending-row columns that get back-filled later
- `to_attr_hash` method returning `to_hash.except(:id, :created_at)` so a
  repository can pass it straight into the ORM without re-mapping

### Plain Ruby class entity — for behavioral entities

Use a plain Ruby class when the entity:

- Takes collaborators in the constructor and computes derived data
- Has memoized methods, queries, or domain rules
- Is the place where business logic naturally lives

See [`../SKILL.md`](../SKILL.md) (section "Entity & Value Object
Implementation") for the canonical `AttendanceReport` example.

## Decision heuristic

| Question | Answer | Choice |
|---|---|---|
| Does it have methods beyond getters? | No | Dry::Struct DTO |
| Does it compute or memoize derived values? | Yes | Plain Ruby class |
| Does it cross a boundary as data (DB / API) with no behavior? | Yes | Dry::Struct DTO |

## Anti-pattern (do not do this)

`Dry::Struct` + external `.build` factory that *computes* values and stuffs
them into a passive struct. That separates computation from the object that
should own it.

The `Dry::Struct` form here is reserved for **pure DTOs** with no computation
— the values come straight from the boundary (DB row, validated request),
nothing is calculated in flight.
