---
name: infrastructure-database
description: How orm/ and repositories/ split responsibility in app/infrastructure/database/
---

# Infrastructure / Database

Two sublayers, two jobs:

```text
app/infrastructure/database/
├── orm/            ← thin Sequel models, no business logic
└── repositories/   ← maps ORM rows ↔ domain entities, owns DB queries
```

## Responsibilities

| Layer | Knows about | Returns | Allowed to contain |
|---|---|---|---|
| `orm/`          | Sequel + schema | ORM model instances | `Sequel::Model(:table)`, plugins, associations |
| `repositories/` | ORM + domain entities | Domain entities | Query construction, entity (re)building |

## Dependency direction

```
repositories/  →  orm/
```

- `repositories/` requires / uses `orm/` classes.
- `orm/` must NOT import `repositories/`, services, controllers, or anything
  upstream.
- Callers (services, controllers, application orchestration) talk to
  `repositories/`. They must not reference `Database::*Orm` directly.

## Why split

The ORM model knows the database. The Repository knows the domain. If
callers were allowed to touch the ORM directly, the schema would leak into
services and controllers, and swapping persistence would touch every caller.

See sublayer details in:

- [`./orm/SKILL.md`](./orm/SKILL.md)
- [`./repositories/SKILL.md`](./repositories/SKILL.md)
