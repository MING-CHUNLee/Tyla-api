---
name: orm
description: Thin Sequel::Model wrappers — no business logic, no domain knowledge
---

# ORM Models

`orm/` holds the thinnest possible `Sequel::Model` subclasses. They exist to
configure table mapping and Sequel plugins — nothing more.

## Rules

- Class name suffix `*Orm`, module path `Tyla::Database::*Orm`
- One file per table
- Allowed contents: `Sequel::Model(:table_name)`, `plugin :timestamps`,
  associations (`one_to_many`, etc.), and the validations Sequel itself needs
  to enforce DB invariants
- **No business logic.** No domain predicates (`allowed?`, `expired?`), no
  formatters, no derived columns. Anything that is not "this is the DB
  shape" belongs in an entity, a value object, or a service
- Callers outside `app/infrastructure/database/` must not reference these
  classes directly — they go through a repository

If you find yourself wanting to add a method here, ask: does this belong on
the domain entity, the repository, or the service?
