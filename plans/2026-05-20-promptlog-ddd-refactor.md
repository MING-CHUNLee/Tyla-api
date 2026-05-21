# PromptLog Refactor — Adopt DDD Layering (Entity / Repository / Request)

> Goal: 把 `api.rb` 內直接呼叫 `Database::PromptLogOrm.create(...)` 的程式碼，
> 重構成 Controller → Request → Entity → Repository → ORM 的分層架構。
> 同時將 PromptLog 作為「inline 範例」放進 repo，後續寫 SKILL.md 直接引用。

---

## 決策紀錄

| 議題 | 決定 | 備註 |
|------|------|------|
| Entity 風格 | **Dry::Struct** | PromptLog 是純 DTO，無領域行為。`app/domain/SKILL.md` 既有的 "Plain Ruby class" 規範保留給有行為的 entity（未來在 SKILL.md 中區分兩種用法） |
| Request → Entity 對應 | `Request::CreatePromptLog.to_entity(validated_hash)` | 把外部 API 命名（`userPrompt`、`probability[:attack]`）映射到 domain 命名 |
| `serialize(log)` helper | **抽出** controller，改用 Roar Representer | controller 不該負責 JSON 序列化；`Gemfile` 已有 `roar`，既有 todo plan 3-4 也走這方向 |
| `Values::GuardResult` | 不動 | 與本次 refactor 無關，留待後續 |
| Autoload | 不需改設定 | `require_app.rb` 已用 `**/*.rb` glob，新檔案會自動載入 |

---

## STEP 1 — Domain Entity

1-1. 新增資料夾 `app/domain/entities/`

1-2. 新建 `app/domain/entities/prompt_log.rb`
- module 路徑：`Tyla::Entity::PromptLog`
- 繼承 `Dry::Struct`，`include Dry.Types`
- attributes：
  - `id` → `Integer.optional`
  - `course_id`, `project_id`, `student_id`, `prompt` → `Strict::String`
  - `attack_prob`, `benign_prob` → `Strict::Float`
  - `reason` → `String.optional`
  - `allowed` → `Strict::Bool`
  - `created_at` → `Time.optional`
- method `to_attr_hash`：`to_hash.except(:id, :created_at)`（給 Repository 寫 DB 用）

1-3. 新建 `spec/domain/entities/prompt_log_spec.rb`
- 驗 attribute 缺漏會 raise `Dry::Struct::Error`
- 驗 `to_attr_hash` 不含 `:id`、`:created_at`
- 驗 `attack_prob` 傳字串 → raise（Strict::Float）

---

## STEP 2 — Repository

2-1. 新增資料夾 `app/infrastructure/database/repositories/`

2-2. 新建 `app/infrastructure/database/repositories/prompt_logs.rb`
- module 路徑：`Tyla::Repository::PromptLogs`
- class methods：
  - `create(entity)` → 呼叫 `Database::PromptLogOrm.create(entity.to_attr_hash)`，回傳 `rebuild_entity(db_resource)`
  - `find_all(filters = {})` → 接 `:student_id` / `:course_id` / `:project_id`，依序 `where`；以 `created_at DESC` 排序；map 成 entity 陣列
  - `rebuild_entity(db_resource)` → 防 nil；逐欄位 `Entity::PromptLog.new(...)`

2-3. 新建 `spec/infrastructure/database/repositories/prompt_logs_spec.rb`
- 驗 `create(entity)` 寫入 DB 並回傳含 `id`、`created_at` 的 entity
- 驗 `find_all(student_id: 's1')` 只回該學生資料
- 驗 `find_all` 多個 filter 同時生效
- 驗 `rebuild_entity(nil)` 回 nil

---

## STEP 3 — Request: 加 `to_entity`

3-1. 改 `app/application/requests/create_prompt_log.rb`
- 在 class 內加 class method `self.to_entity(validated_hash)`
- mapping 表（外部 API → domain）：

| 外部 API key | Entity attribute |
|---|---|
| `:course_id` | `course_id` |
| `:project_id` | `project_id` |
| `:student_id` | `student_id` |
| `:userPrompt` | `prompt` |
| `:probability[:attack]` | `attack_prob` |
| `:probability[:benign]` | `benign_prob` |
| `:reason` | `reason` |
| `:allowed`（fetch default true）| `allowed` |
| `nil` | `id`、`created_at` |

3-2. 新建 `spec/application/requests/create_prompt_log_spec.rb`（如果不存在）
- 驗 `to_entity` 把 `userPrompt` 對應到 `prompt`
- 驗 `to_entity` 把 `probability[:attack]` 對應到 `attack_prob`
- 驗 缺 `allowed` 時 default 為 `true`

---

## STEP 4 — Presentation Representer

4-1. 新增資料夾 `app/presentation/representers/`

4-2. 新建 `app/presentation/representers/prompt_log_representer.rb`
- module 路徑：`Tyla::Representer::PromptLog`
- 使用 `Roar::Decorator` + `Roar::JSON`
- 暴露欄位（順序與目前 `serialize` 相同）：
  `id, course_id, project_id, student_id, prompt, attack_prob, benign_prob, reason, allowed, created_at`
- 不在 representer 內做計算 / 業務邏輯，只純粹序列化

4-3. 新建 `spec/presentation/representers/prompt_log_representer_spec.rb`
- 給一個 `Entity::PromptLog`，驗 `.to_json` / `.to_hash` 欄位齊全且型別正確
- 驗 `created_at` 序列化為 ISO8601 字串（如果 Roar 預設不轉，要在 representer 內處理）

---

## STEP 5 — Slim Controller

5-1. 改 `app/application/controllers/api.rb`

POST：
```
contract validate → r.halt 422 if !success?
entity = Request::CreatePromptLog.to_entity(result.to_h)
saved  = Repository::PromptLogs.create(entity)
response.status = 201
Representer::PromptLog.new(saved).to_hash
```

GET：
```
entities = Repository::PromptLogs.find_all(
  student_id: r.params['student_id'],
  course_id:  r.params['course_id'],
  project_id: r.params['project_id']
)
entities.map { |entity| Representer::PromptLog.new(entity).to_hash }
```

5-2. **刪除** controller 內的 private `serialize(log)` method（搬到 representer 後 controller 不再需要它）

5-3. 確認 controller 內已**不再出現** `Database::PromptLogOrm`、`userPrompt`、`probability[:attack]` 等字串

---

## STEP 6 — 驗證

6-1. `bundle exec rake spec` → 全綠

6-2. 手動 smoke test（pry console 或 curl）：
- POST `/api/v1/prompt_logs` 帶完整 CLI guard-log shape → 回 201 + serialized entity
- GET `/api/v1/prompt_logs?student_id=X` → 回 entity list

6-3. `bundle exec rake style`（若有 RuboCop）→ 無新 offense

---

## STEP 7 — Inline SKILL.md（refactor 完才寫）

> 等 STEP 1–6 完成、且我們對成品滿意後再開始。
> 目的：把這次 refactor 的成品變成「**架構內嵌的活範例**」，未來不論是 Claude 還是新人都能就近讀到規範。

7-1. 新建 `app/domain/entities/SKILL.md`
- 引用：[`./prompt_log.rb`](./prompt_log.rb) 作為 DTO entity 範例
- 內容：
  - 何時用 `Dry::Struct`（無行為的 DTO entity，例：來自外部 request / API）
  - 何時改用 Plain Ruby class（有 memoize 計算、需要行為的 entity，見 `../SKILL.md`）
  - 必備：`to_attr_hash`、`id` 為 `Integer.optional`
  - module 路徑：`Tyla::Entity::*`

7-2. 新建 `app/infrastructure/database/SKILL.md`
- Infrastructure DB 子層總覽：`orm/`（薄）、`repositories/`（厚）的職責
- 依賴方向：`repositories/` → `orm/`，禁止反向

7-3. 新建 `app/infrastructure/database/repositories/SKILL.md`
- 引用：[`./prompt_logs.rb`](./prompt_logs.rb) 作為範例
- 必備介面：`create(entity)` / `find_*` / `rebuild_entity(db_resource)`
- 規範：
  - 只接受 / 回傳 Entity，不對外暴露 ORM 物件
  - `rebuild_entity` 必須防 nil
  - 不放業務邏輯（那是 service 的事）

7-4. 新建 `app/infrastructure/database/orm/SKILL.md`（短篇）
- ORM 只是 Sequel::Model，禁止加 business logic
- 命名 `*Orm`，module 路徑 `Tyla::Database::*Orm`

7-5. 新建 `app/application/requests/SKILL.md`
- Request Contract 同時負責 validate **和** `to_entity` mapping
- 引用 `./create_prompt_log.rb` 作為範例
- 重點：外部 API 命名只准出現在這層，不准漏到 service / controller

7-6. 新建 `app/presentation/SKILL.md` + `app/presentation/representers/SKILL.md`
- Presentation 層職責：把 domain entity 序列化成對外格式（JSON 等）
- Representer 用 `Roar::Decorator` + `Roar::JSON`
- 引用：[`./prompt_log_representer.rb`](./prompt_log_representer.rb) 作為範例
- 禁止：在 representer 內做業務邏輯 / 計算 / 查 DB

7-7. 更新 `app/domain/SKILL.md`
- 在 "Entity & Value Object Implementation" 區塊新增子節：
  - "DTO entities use `Dry::Struct`" — 例：`PromptLog`
  - "Behavioral entities use Plain Ruby class" — 例：`AttendanceReport`
- 把現有的 anti-pattern 警告（"Dry::Struct + .build factory"）改成更精確的形式：是反對「passive struct + 外部 factory 算欄位」這個 anti-pattern，**不是**禁止 Dry::Struct 本身做純 DTO

---

## 完成條件 (Definition of Done)

- [ ] `api.rb` 不再直接 `require` 或呼叫 `Database::PromptLogOrm`
- [ ] `api.rb` 不再含 private `serialize` helper
- [ ] 外部 API 命名（`userPrompt`、`probability`）只出現在 `requests/create_prompt_log.rb` 一處
- [ ] `bundle exec rake spec` 全綠
- [ ] PromptLog 的 Entity / Repository / Request#to_entity / Representer 四個檔案各自有 spec
- [ ] STEP 7 六份新 SKILL.md + 一份更新（共七份文件）就位
- [ ] 在 [app/application/SKILL.md](../app/application/SKILL.md) 的 "Layered Architecture" 區塊
      補上 `domain/entities/`、`infrastructure/database/{orm,repositories}/`、
      `application/requests/`、`presentation/representers/` 指向各自的 SKILL.md
