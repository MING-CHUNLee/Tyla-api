# TODO — `tutor-feynman` 落地剩餘工作(§6.1 改名 blast radius)

**Date:** 2026-06-17
**狀態:** 待辦(草稿 TUTOR.md 已建,改名/接線尚未做)
**相關:**
- [2026-06-17-ms3-tutor-mode-tiers.md](./2026-06-17-ms3-tutor-mode-tiers.md) §6.1
- 已建立:[app/application/prompts/tutors/tutor-feynman/TUTOR.md](../app/application/prompts/tutors/tutor-feynman/TUTOR.md)(純 Feynman 重寫版,**草稿庫副本**)

---

## 背景

Tutor 2 的 persona 文字已重寫為純 Feynman 並落地到**草稿庫** `tutors/tutor-feynman/TUTOR.md`。
但 persona loader 目前真正讀的是 **fixture** 路徑,且舊的 `tutor-guide/` 仍在、hardcoded 路徑仍指向舊名。
以下三件事尚未做,做完才算 §6.1 完整落地。

---

## To Do

- [ ] **1. 建立實際被載入的 fixture 副本**
  - 把 `tutor-feynman/TUTOR.md` 內容複製到 `spec/fixtures/assignments/CSDS-HW2/tutors/tutor-feynman/TUTOR.md`
  - 這是 loader 真正讀取的位置(草稿庫那份不會被載入)
  - frontmatter `name:` 用 `tutor-feynman`

- [ ] **2. 刪除舊的 `tutor-guide/`(兩份)**
  - `app/application/prompts/tutors/tutor-guide/TUTOR.md`(草稿庫)
  - `spec/fixtures/assignments/CSDS-HW2/tutors/tutor-guide/TUTOR.md`(fixture)
  - 先確認上面第 1 點的 fixture 已就位再刪,避免 loader 找不到檔

- [ ] **3. 更新 hardcoded 路徑與相依字串**
  - hardcoded 路徑 ×3:
    - [tutor_persona_loader.rb:8](../app/infrastructure/filesystem/tutor_chat/tutor_persona_loader.rb#L8)
    - [refusal_loader.rb:11](../app/infrastructure/filesystem/tutor_chat/refusal_loader.rb#L11)
    - [scripts/phase0_caps_measurement.rb:124](../scripts/phase0_caps_measurement.rb#L124)
  - spec ×3:
    - [tutor_chat_loaders_spec.rb:33](../spec/...)(描述字串)
    - `guard_agent_spec.rb:53`(mode 字串純裝飾)
    - `refusal_templates_spec.rb:17`(mode 字串純裝飾)
  - API 文件:[doc/api_tutor_chats.md:457](../doc/api_tutor_chats.md#L457)
  - 歷史 plans(多份 2026-05):**不動**(歷史記錄)

---

## 注意

- §6.1 前提:`tutor-guide` **不是** load-bearing 的 mode key(`RefusalTemplates.for` 忽略 mode 參數,request contract 無 `mode` 欄位),所以這是**檔案移動 + 少數 hardcoded 路徑**,沒有邏輯白名單要動。
- MS3 persona 選擇機制(PersonaProfile,§7.1)落地後,`tutor_persona_loader.rb` / `refusal_loader.rb` 的 hardcoded 路徑會被 PersonaProfile 取代——屆時第 3 點的前兩處可一併收斂。
- 做完這三件事後,記得跑一次相關 spec 確認 loader 仍能載入。
