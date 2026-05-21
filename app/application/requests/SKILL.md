---
name: requests
description: Request contracts validate input AND map external API names onto domain entities
---

# Request Contracts

`app/application/requests/` is the **only** layer that is allowed to know
about external API field names. By the time data leaves this layer, every
field is named in the domain's vocabulary.

Inline example: [`./create_prompt_log.rb`](./create_prompt_log.rb)

## Two responsibilities, owned together

A `Request::*` class has two jobs. They live in one file so the API
boundary stays in one place:

1. **Validate** the raw params hash via `Dry::Validation::Contract`.
2. **Map** the validated hash into a domain `Entity::*` via a class method
   `self.to_entity(validated_hash)`.

```ruby
# Validate
contract = Request::CreatePromptLog.new
result   = contract.call(r.params)
r.halt(422, ...) unless result.success?

# Map — external names die here
entity = Request::CreatePromptLog.to_entity(result.to_h)
saved  = Repository::PromptLogs.create(entity)
```

## Naming rule

External API names (`userPrompt`, `attack-probability`, camelCase /
hyphenated / snake_case mixes, whatever the caller uses) appear **only**
inside this file (and any wire-format key normalisation in the route,
e.g. hyphen → underscore before validation):

- In the `params do ... end` block as required keys
- In the `to_entity` mapping table

After `to_entity` returns, the rest of the codebase only sees domain names
(`prompt`, `attack_probability`, `evaluation`).

## Anti-patterns

- Reading `r.params[:userPrompt]` in a route or service. The route hands
  the validated hash straight to `to_entity`. External names must die
  there.
- Building an `Entity::*` from a request hash in a service. If that
  conversion is needed, add a class method on the request and call it from
  the route.
- Putting business decisions in the contract. Validation answers "did the
  caller send the right shape?" — not "is this attendance late?".
