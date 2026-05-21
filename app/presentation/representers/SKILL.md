---
name: representers
description: Roar::Decorator representers that turn domain entities into JSON
---

# Representers

Each representer is a `Roar::Decorator` that turns a single entity (or
response DTO) into JSON / hash output for the API.

Inline example: [`./prompt_log_representer.rb`](./prompt_log_representer.rb)

## Conventions

- Class name mirrors the entity: `Entity::PromptLog` →
  `Representer::PromptLog`
- Module path `Tyla::Representer::*`
- Inherit `Roar::Decorator`, `include Roar::JSON`
- One `property :field_name` per output field, in the order the API
  contract documents
- Use a `getter:` lambda only for **formatting** (e.g. `created_at` →
  `iso8601`). Not for computing values; not for conditional inclusion

## Usage from a route

```ruby
Representer::PromptLog.new(entity).to_hash   # for the halt/JSON response body
Representer::PromptLog.new(entity).to_json   # if you need the string
```

For collections, map representers — do not write a single wrapping
representer:

```ruby
entities.map { |e| Representer::PromptLog.new(e).to_hash }
```

## Anti-patterns

- A representer that does `entity.attendances.where(...)` — that is a
  query. Belongs in a repository, called by a service that builds a
  response DTO; the representer then serializes the DTO.
- A representer that conditionally hides a field based on the current
  user. That is application-policy work. The service should produce a
  different response DTO for that case, and the route should pick the
  matching representer.
- Feeding a representer from an `OpenStruct` — typos silently become `nil`
  on the wire. Use a `Data.define` response DTO or a real entity.
