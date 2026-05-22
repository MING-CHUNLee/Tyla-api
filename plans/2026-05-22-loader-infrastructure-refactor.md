# Plan — Move Artefact Loaders to Infrastructure Layer

> **Date:** 2026-05-22
> **Status:** DRAFT
> **Related:** `plans/2026-05-21-tutor-chat-api.md`

## Background

Five loader modules currently live under `app/application/services/tutor_chat/`:

| File | What it does |
|---|---|
| `assignment_loader.rb` | `File.read` on the assignment text fixture |
| `policy_loader.rb` | `File.read` on a mode-keyed `TUTOR.md` prompt file |
| `solution_loader.rb` | `File.read` on the solution text fixture |
| `student_file_loader.rb` | `File.read` on the student WIP fixture |
| `tutor_persona_loader.rb` | `File.read` on the single-persona `TUTOR.md` fixture |

These are pure filesystem I/O adapters with no business logic. Placing them in the
application layer violates the Dependency Rule — application services should depend
on abstractions or infrastructure interfaces, not embed raw `File.read` calls
themselves. The existing infrastructure layer already follows this split:
`infrastructure/database/` and `infrastructure/llm/` own their respective I/O
concerns. Filesystem reads deserve the same treatment.

---

## Goal

Move all five loaders to `app/infrastructure/filesystem/tutor_chat/` and update
callers so that the application layer only depends on constants or injected
objects defined in infrastructure.

---

## Target layout

```
app/
├── application/
│   └── services/
│       └── tutor_chat/
│           └── run_tutor_chat.rb        ← require path changes only
│
└── infrastructure/
    ├── database/
    ├── llm/
    └── filesystem/                      ← NEW top-level namespace
        └── tutor_chat/                  ← NEW
            ├── assignment_loader.rb     ← MOVED
            ├── policy_loader.rb         ← MOVED
            ├── solution_loader.rb       ← MOVED
            ├── student_file_loader.rb   ← MOVED
            └── tutor_persona_loader.rb  ← MOVED
```

---

## Module namespace changes

| Before | After |
|---|---|
| `Tyla::Services::AssignmentLoader` | `Tyla::Infrastructure::Filesystem::AssignmentLoader` |
| `Tyla::Services::PolicyLoader` | `Tyla::Infrastructure::Filesystem::PolicyLoader` |
| `Tyla::Services::SolutionLoader` | `Tyla::Infrastructure::Filesystem::SolutionLoader` |
| `Tyla::Services::StudentFileLoader` | `Tyla::Infrastructure::Filesystem::StudentFileLoader` |
| `Tyla::Services::TutorPersonaLoader` | `Tyla::Infrastructure::Filesystem::TutorPersonaLoader` |

> `PolicyLoader` is a `class` (not a module); keep it as a class. All others are
> `module` with a `.load` singleton method; keep the same interface.

---

## Caller changes

### `run_tutor_chat.rb`

```ruby
# Before
assignment = AssignmentLoader.load(params[:project_id])
solution   = SolutionLoader.load(params[:project_id])
student    = StudentFileLoader.load(params[:project_id])
persona    = TutorPersonaLoader.load(params[:project_id])
# ... and FILENAME reference:
context_files: [{ path: StudentFileLoader::FILENAME, content: student }]

# After
assignment = Infrastructure::Filesystem::AssignmentLoader.load(params[:project_id])
solution   = Infrastructure::Filesystem::SolutionLoader.load(params[:project_id])
student    = Infrastructure::Filesystem::StudentFileLoader.load(params[:project_id])
persona    = Infrastructure::Filesystem::TutorPersonaLoader.load(params[:project_id])
# FILENAME constant stays on the class:
context_files: [{ path: Infrastructure::Filesystem::StudentFileLoader::FILENAME, content: student }]
```

### `handle_tutor_chat.rb` (uses `PolicyLoader`)

```ruby
# Before
policy_loader = Services::PolicyLoader.new

# After
policy_loader = Infrastructure::Filesystem::PolicyLoader.new
```

### `tutor_orchestrator.rb` (uses `SolutionLoader.load_stub`)

This caller was not in the original plan but was found via grep. Line 23 references
`SolutionLoader` without a namespace prefix, resolved within `Tyla::Services`:

```ruby
# Before
solution_text: SolutionLoader.load_stub,

# After
solution_text: Infrastructure::Filesystem::SolutionLoader.load_stub,
```

Locate every call site by running:
```bash
grep -r "PolicyLoader\|AssignmentLoader\|SolutionLoader\|StudentFileLoader\|TutorPersonaLoader" app/ spec/
```

---

## Spec changes

Spec files mirror the source tree. Move or update `describe` targets:

| Before | After |
|---|---|
| `spec/application/services/tutor_chat_loaders_spec.rb` | `spec/infrastructure/filesystem/tutor_chat_loaders_spec.rb` |
| `spec/application/services/policy_loader_spec.rb` | `spec/infrastructure/filesystem/policy_loader_spec.rb` |

`describe` blocks change from `Tyla::Services::*` to
`Tyla::Infrastructure::Filesystem::*`. Test logic is unchanged.

`spec/application/services/tutor_orchestrator_spec.rb` is **not** moved (it
tests an application service), but its `require` paths must be updated:

```ruby
# Before
app/application/services/tutor_chat/solution_loader.rb
app/application/services/tutor_chat/policy_loader.rb

# After
app/infrastructure/filesystem/tutor_chat/solution_loader.rb
app/infrastructure/filesystem/tutor_chat/policy_loader.rb
```

The `let(:policy_loader) { PolicyLoader.new }` inside the spec resolves within
`Tyla::Services`; change it to `Infrastructure::Filesystem::PolicyLoader.new`.

---

## Autoload / require changes

Check `config/application.rb` (or wherever `Zeitwerk` / `require_relative` chains
are configured) to ensure the new path is picked up automatically. Typical pattern:

```ruby
# If using Zeitwerk (inferred from directory structure):
# No change needed — Zeitwerk maps Tyla::Infrastructure::Filesystem::* to
# app/infrastructure/filesystem/*.rb automatically.

# If using explicit requires, add:
require_relative '../infrastructure/filesystem/tutor_chat/assignment_loader'
# ... etc.
```

---

## Implementation steps

1. **Create directory**
   `mkdir -p app/infrastructure/filesystem/tutor_chat`

2. **Move files and rename namespace** (one file at a time):
   - Change `module Tyla / module Services` wrapper to
     `module Tyla / module Infrastructure / module Filesystem`
   - Update `PolicyLoader::BASE_PATH` — the `__dir__` anchor changes after the
     move, so the relative path must be adjusted:
     ```ruby
     # Before (resolved from app/application/services/tutor_chat/)
     BASE_PATH = File.expand_path('../../prompts/tutors', __dir__)
     # After (resolved from app/infrastructure/filesystem/tutor_chat/)
     BASE_PATH = File.expand_path('../../../application/prompts/tutors', __dir__)
     ```
   - All other loader file contents (logic, FIXTURE_PATH, FILENAME) are unchanged
     because the new directory is at the same depth from the project root

3. **Update callers in `app/`**
   - `run_tutor_chat.rb` — four loader calls + `FILENAME` constant
   - Any other service using `PolicyLoader` (grep to confirm)

4. **Delete old files** once callers are updated

5. **Move spec files** to `spec/infrastructure/filesystem/tutor_chat/`
   - Update `describe` targets to new namespace
   - No logic changes

6. **Run tests**
   ```bash
   bundle exec rspec spec/infrastructure/filesystem/
   bundle exec rspec spec/application/services/run_tutor_chat_spec.rb
   bundle exec rspec spec/application/services/handle_tutor_chat_spec.rb
   bundle exec rspec  # full suite
   ```

7. **Confirm no old namespace references remain**
   ```bash
   grep -r "Services::AssignmentLoader\|Services::SolutionLoader\|Services::StudentFileLoader\|Services::TutorPersonaLoader\|Services::PolicyLoader" app/ spec/
   # expect: no output
   ```

---

## What does NOT change

- `FIXTURE_PATH` and `FILENAME` constant values in the four fixture loaders
  (they remain correct because the new path has the same depth from the project
  root as the old one: `app/<3-levels>/tutor_chat/` in both cases)
- `BASE_PATH` **constant name** — but its **value must change** (see step 2)
- The Phase 1 fixture-path approach — this refactor is structural only
- `PolicyLoader`'s `load(mode)` interface
- The Phase 2 TODO (switch from fixture to production data root) — that work
  still happens in the same files, now in the right layer

---

## Risks

| Risk | Mitigation |
|---|---|
| Missed call site updates | Grep for old namespace before closing the PR |
| Autoload not picking up new path | Run full suite; check Zeitwerk's eager-load list |
| `spec/` path mismatch breaking CI | Move spec files in step 5 before running full suite |
| `PolicyLoader::BASE_PATH` wrong after move | Step 2 explicitly adjusts the relative path (see note) |
| `tutor_orchestrator.rb` still references bare `SolutionLoader` | Update in step 3 along with other callers |
| `tutor_orchestrator_spec.rb` require paths left stale | Update both require lines in step 5 |

---

## Out of scope

- Phase 2 loader logic (keying by `course_id`+`project_id`, real filesystem or DB)
- Defining a Ruby interface / abstract class for the loaders (worth considering
  when Phase 2 introduces multiple backends, not now)
- Any changes to prompt builders or the request contract
