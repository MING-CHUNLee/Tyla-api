---
name: repositories
description: Repository pattern for translating between ORM rows and domain entities
---

# Repositories

Repositories sit between domain entities and the ORM. They are the **only**
place in the application where `Database::*Orm` may be referenced outside
of `app/infrastructure/database/orm/`.

Inline example: [`./prompt_logs.rb`](./prompt_logs.rb)

## Registry: `Repository::For`

[`./for.rb`](./for.rb) is the single entry point for looking up a repository
from an entity. Every new repository **must** be registered there:

1. Add a `require_relative '<new_repo>'` line at the top of `for.rb`.
2. Add an `Entity::<Name> => <Repos>` row to the `ENTITY_REPOSITORY` map.

Callers then resolve a repository in one of two ways:

```ruby
Repository::For.klass(Entity::PromptLog)     # => Repository::PromptLogs
Repository::For.entity(prompt_log_instance)  # => Repository::PromptLogs
```

This keeps services and request objects free of `require_relative` chains
into the repositories directory — they ask `For` and get back the right
class. If `For.klass` returns nil for an entity, the entity is not
persistable; do not add ad-hoc fallbacks at the call site, register it
properly instead.

## Required interface

A repository for `Entity::Foo` should expose, at minimum:

| Method | Input | Output | Purpose |
|---|---|---|---|
| `create(entity)`               | `Entity::Foo` | persisted `Entity::Foo` (with `id`, `created_at`) | insert |
| `find_*` (e.g. `find_all`)     | filter args | `Entity::Foo` or `Array<Entity::Foo>` | query |
| `rebuild_entity(db_resource)`  | ORM row or nil | `Entity::Foo` or nil | shared funnel used by all the above |

Additional methods are added as workflows demand — for example
`Repository::PromptLogs.update(id, attrs)` exists for partial updates by id.
New methods must still take / return entities (or primitives like `id`),
never raw ORM rows.

## Rules

1. **Only accept and return entities** (or nil). Never expose `Sequel::Model`
   instances outward. `rebuild_entity` is the single funnel that enforces
   this.
2. **`rebuild_entity` must defend against nil.** Callers rely on it returning
   nil cleanly so `Repository.update(missing_id, ...)` and similar dead-end
   lookups do not raise.
3. **No business logic.** A repository decides *how* to talk to the DB; it
   does not decide *what* the application should do with the result. That is
   service territory.
4. Module path `Tyla::Repository::*`, class methods (`class << self`) —
   repositories are stateless.

## Anti-patterns

- Returning a `Sequel::Model` to a service so the service can call `.update`
  on it. Add a repository method (`Repository::PromptLogs.update(id, attrs)`)
  instead.
- `if user.allowed?` style decisions inside the repository. Move that to the
  service or a policy.
- A repository that knows about HTTP, JSON, or request shapes. Repositories
  speak domain vocabulary, not API vocabulary — the request layer already
  translated that.
