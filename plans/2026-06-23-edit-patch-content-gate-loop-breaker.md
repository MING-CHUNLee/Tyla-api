# EditPatchContentGate loop-breaker — 把「prompt 對不上檔」降級成正常回覆,而不是空字串

**Date:** 2026-06-23
**Type:** 後端行為變更(domain gate)+ 測試。**無 schema 變更、無 DB、無前端必改。**
**起因:** 手動 persona 測試時,tier1 對 `hw2.R` 下 edit,TUI 收到「空回應」+ `edit_file_redirected` warning。
**相關:**
- [2026-06-23-manual-persona-testing-checklist.md](./2026-06-23-manual-persona-testing-checklist.md) §三 S1 的 ⚠️ note(現象與觸發條件)
- [2026-06-13 §4.4 / §8-6] EditPatchContentGate 原始設計(stale-snapshot self-heal)
- 受影響碼:[edit_patch_content_gate.rb](../app/domain/values/edit_patch_content_gate.rb)、[run_tutor_chat.rb](../app/application/services/tutor_chat/run_tutor_chat.rb#L383)(`apply_gates`)、[redundant_load_gate.rb](../app/domain/values/redundant_load_gate.rb)(header 註解需更新)

---

## 一、根因(一句話)

[`EditPatchContentGate`](../app/domain/values/edit_patch_content_gate.rb#L52) **只會對「已載入」的檔觸發**(`file = line_map[path]`,沒 header 就 `nil` 直接放行)。當 patch 的 `search` 對不上快照時,它把 edit **改寫成 `load_file` 同一支檔** → 前端重載**同一份沒變的檔** → 模型再吐同樣對不上的 edit → 再 mismatch → **livelock**,跑到前端 continuation 上限(3 次)後 `content` 為空。

關鍵觀察:**這個 gate 觸發的每一次 reload,都是 reload「模型剛剛才看過的同一份內容」。** 模型會 mismatch,只可能是因為它的 `search` 不是來自 live 快照(幻覺、引用 chat 貼的碼、start_line 抓錯)。這三種情況下,reload 同一份檔**永遠**不會改變結果 → 必然 loop。

> 真正「快照過期(學生 out-of-band 改檔)」而 reload 有用的情況極罕見,且當下模型多半是照**舊快照**組 `search`(於是 match、不觸發 gate)。換言之 gate 的 self-heal 分支實務上幾乎只服務 livelock,沒服務到它設計時想救的 case。

旁證:後端其實已有 `FALLBACK_PROSE` 防空轉(Decision E,[run_tutor_chat.rb:419](../app/application/services/tutor_chat/run_tutor_chat.rb#L419)),但它要求 `actions.empty?` 才會補話。gate 改寫出的 `load_file` 讓**每一輪 actions 都非空**,所以 fallback 永遠不觸發 → 才會空到底。

---

## 二、設計決定

### 改法(採用):mismatch → **drop**,不再 reload

把 `EditPatchContentGate` 在「已載入檔 + 內容對不上」時的行為,從「改寫成 `load_file`」改成「**直接丟掉那筆 edit**」。連帶效果:

- 該 edit 是唯一 action → `actions == []` → 既有 `FALLBACK_PROSE` 接手 → 學生拿到一句正常的話(或模型自己的 prose),**不再空字串**。
- 同一 reply 還有其他合法 action → 它們照常通過(drop 是 per-action 的)。
- 仍保留早期警示價值:後端**永遠不會把一筆它已知對不上快照的 patch 送到前端**(避免 silent misapply)。

### warning:沿用 `edit_file_redirected`(零 plumbing,採用)

第二個回傳值仍是同一顆 boolean,只是語意從「redirected to load」變成「因內容不符而改動了 edit 集合」。它照舊 OR 進 [`apply_gates`](../app/application/services/tutor_chat/run_tutor_chat.rb#L390) 的 `c_redirect` → `edit_file_redirected`。**回傳 arity 完全不變**,`extract_reply` / `ok_outcome` / `warnings_for` 一行都不用動。前端已會處理 `edit_file_redirected`,語意上「你的 edit 沒套用,我換方式處理」對 redirect / drop 兩種都成立。

> **替代(不採用,但記錄):** 另開新 token `edit_content_mismatch`,語意更精準。代價:`EditPatchContentGate.call` 多回一值 → `apply_gates`(3→4 回傳)→ `extract_reply`(4→5)→ `ok_outcome` 解構 → `warnings_for` 多一個 kwarg,且前端要新認一個 token。為了 demo 穩定度,不值得這層 churn。若日後前端要把「redirect」和「drop」分開顯示,再走這條。

### 被否決的方案:有狀態的「只 redirect 一次」

理論上最忠於原設計:第一次 mismatch 仍 redirect(救罕見的 stale case),第二次才 drop。但 gate 是**跨輪無狀態的純函式**,要判斷「第幾次」得從 history/session_turns 拉訊號或讓前端回傳 marker —— 超出「改一支 gate」的範圍,且前端 continuation 是否把上一輪 `load_file` 寫進 history 是前端相依的。**罕見 self-heal 的兜底本來就由前端自己的 patch 驗證負責**(gate header 自己寫了「the frontend's validation (plan §5) remains the authoritative guard」),所以無狀態 drop 是安全且足夠的。

---

## 三、程式改動

### 3.1 `app/domain/values/edit_patch_content_gate.rb`

**`gate_action`** — mismatch 分支改成丟掉,不再產 `load_file`:

```ruby
# 之前
def self.gate_action(action, line_map, emitted)
  return [[action], false] unless action_type(action) == EDIT_FILE
  path    = FileContextHeader.normalize(path_of(action))
  file    = line_map[path]
  patches = patches_of(action)
  return [[action], false] if file.nil? || !patches.is_a?(Array) || patches.empty?
  return [[action], false] unless content_mismatch?(patches, file)
  load = emitted.add?(path) ? [load_file_for(action, path_of(action))] : []
  [load, true]
end

# 之後
def self.gate_action(action, line_map)
  return [[action], false] unless action_type(action) == EDIT_FILE
  path    = FileContextHeader.normalize(path_of(action))
  file    = line_map[path]
  patches = patches_of(action)
  return [[action], false] if file.nil? || !patches.is_a?(Array) || patches.empty?
  return [[action], false] unless content_mismatch?(patches, file)
  # 已載入檔卻對不上 → reload 同一份必然徒勞(livelock 源頭)。直接丟掉這筆 edit:
  # 若它是唯一 action,RunTutorChat 的 FALLBACK_PROSE 會補上一句正常回覆,不再空字串。
  [[], true]
end
```

**`apply`** — `emitted` Set 不再需要(不再產 `load_file`,無跨筆去重問題):

```ruby
def self.apply(actions, line_map)
  changed = false
  gated = actions.flat_map do |action|
    keep, hit = gate_action(action, line_map)
    changed ||= hit
    keep
  end
  [gated, changed]
end
```

**刪除死碼:** `load_file_for`(L121–128)整支移除;`require 'set'` / `Set` 若僅此處用到也一併確認。`LOAD_FILE` 常數若無其他引用可留可刪(留著無害)。

**更新檔頭註解**(L5–23):把「redirect to load_file so the model gets fresh, re-numbered content」改寫為「drop the mismatching edit; an already-loaded file cannot be self-healed by reloading the same snapshot, so re-issuing load_file would livelock. Dropping degrades the turn to prose (FALLBACK_PROSE) instead.」並保留 sparse-snapshot 那段(行為不變)。

> **語意提醒:** `content_mismatch?` 只要**任一** patch 對不上就回 true → 整筆 edit 被丟。沿用既有語意,不改。

### 3.2 `app/domain/values/redundant_load_gate.rb`(只改註解)

檔頭「Ordering in apply_gates」那段(L18–24)的理由失效了:content gate 不再產 reload,RedundantLoadGate 跑在它前面已不是為了「保住 content gate 的 reload」。**順序維持不變**(無功能理由要動),但把註解更新為:content gate 現在 drop 而非 reload,故此 ordering 不再有 self-healing 依賴;保留順序純為穩定。

### 3.3 `app/application/services/tutor_chat/run_tutor_chat.rb`(只改註解)

[`extract_reply` 上方註解 §3](../app/application/services/tutor_chat/run_tutor_chat.rb#L355-L359)說「the path/content gates rewrite stale edits to load_file」——把 content gate 那半句更新為「the content gate now **drops** a mismatching edit for an already-loaded file (reloading the same snapshot would livelock); its flag still drives `edit_file_redirected`」。`apply_gates` 本體不動。

---

## 四、測試

### 4.1 `spec/domain/values/edit_patch_content_gate_spec.rb`(翻轉 3 個、新增 2 個)

**翻轉**(原本斷言 redirect-to-load_file,改成斷言 drop):

| 行 | 原 | 改後斷言 |
|---|---|---|
| L54 `redirects to load_file when content mismatches` | result == `[load_file]` | **`drops the edit when content mismatches`**:result == `[]`,flag == `true` |
| L93 `handles symbol-keyed … mirrors key style in the redirect` | symbol-keyed → `[load_file sym]` | **symbol-keyed mismatch 也 drop**:result == `[]`,flag == `true`(key-style mirroring 不再適用) |
| L101 `deduplicates load_file redirects …` | 兩筆同 path → 1 個 load_file | **`drops every mismatching edit for the same path`**:result == `[]`,flag == `true`(dedup 已 moot) |

**保留不動**(這些本來就斷言 `false` + 原 actions 通過,行為不變):inert(nil/empty/no-header)、非 edit 放行、path 不在 context、content match、sparse match、incomplete-snapshot pass-through、CRLF match、無 start_line pass-through、CRLF header。

**新增 2 個**(證明 drop 是 per-action、不會誤殺):
```ruby
it 'keeps a matching edit_file while dropping a sibling mismatching one (same path)' do
  good = edit_action(start_line: 1, search: 'x <- 1', replace: 'x <- 99')   # match
  bad  = edit_action(start_line: 2, search: 'WRONG',  replace: 'y <- 99')   # mismatch
  result, changed = Tyla::Values::EditPatchContentGate.call(actions: [good, bad], file_context: ctx)
  _(result).must_equal [good]
  _(changed).must_equal true
end

it 'leaves non-edit actions intact while dropping a mismatching edit' do
  load = { 'type' => 'load_file', 'path' => 'hw3.R' }
  bad  = edit_action(start_line: 1, search: 'WRONG', replace: 'x <- 99')
  result, changed = Tyla::Values::EditPatchContentGate.call(actions: [load, bad], file_context: ctx)
  _(result).must_equal [load]
  _(changed).must_equal true
end
```

### 4.2 `spec/application/services/run_tutor_chat_spec.rb`

**改寫 L785 cross-gate 測試**(現premise「content gate reload 要 survive load gate」整個失效):
```ruby
it 'cross-gate: a stale already-loaded edit is dropped (not reloaded) and degrades to prose' do
  id      = seed_guard(attack_probability: 0.1)
  request = request_for(id, file_context: "## File Contents\n### hw2.R\n  1| x <- 1")
  stale   = [{ 'start_line' => 1, 'search' => 'WRONG CONTENT', 'replace' => 'x <- 99' }]
  client  = tool_calls_llm(content: 'Fixing.',
                           tool_calls: [{ 'type' => 'edit_file', 'path' => 'hw2.R', 'patches' => stale }])
  outcome = call_with(request: request, llm_client: client)

  _, dto = outcome.value!
  _(dto.actions).must_equal []                       # dropped, 不再產 load_file
  _(dto.content).must_equal 'Fixing.'                # 模型有 prose → 保留,不套 FALLBACK
  _(dto.warnings).must_include 'edit_file_redirected'
  _(dto.warnings).wont_include 'redundant_load_dropped'
end
```

**新增**(直接針對使用者那顆 bug 的回歸:tool-only、無 prose → 不再空字串):
```ruby
it 'tool-only reply whose only edit mismatches → FALLBACK_PROSE, never empty content' do
  id      = seed_guard(attack_probability: 0.1)
  request = request_for(id, file_context: "## File Contents\n### hw2.R\n  1| x <- 1")
  stale   = [{ 'start_line' => 1, 'search' => 'WRONG CONTENT', 'replace' => 'x <- 99' }]
  client  = tool_calls_llm(content: '',              # tool-only,無 prose(就是 TUI 看到的空回應源頭)
                           tool_calls: [{ 'type' => 'edit_file', 'path' => 'hw2.R', 'patches' => stale }])
  _, dto = call_with(request: request, llm_client: client).value!

  _(dto.actions).must_equal []
  _(dto.content).wont_be_empty                       # ← 修好的核心斷言
  _(dto.content).must_include "couldn't act on that automatically"  # FALLBACK_PROSE
  _(dto.warnings).must_include 'edit_file_redirected'
end
```

> 其餘 L680–703 的 WorkspaceEditGate 測試**不受影響**(那是 path-not-loaded 的合法 redirect,行為不變)。

---

## 五、驗證

```powershell
# 單元
bundle exec ruby -Ispec spec/domain/values/edit_patch_content_gate_spec.rb
# 整合(gate 鏈 + fallback)
bundle exec ruby -Ispec spec/application/services/run_tutor_chat_spec.rb
# 全套回歸
bundle exec rake test   # 或現用的 spec runner
```
- [ ] 上面三個都綠。
- [ ] RuboCop:`bundle exec rubocop app/domain/values/edit_patch_content_gate.rb`
      ⚠️ 此機 `rubocop -a` 會把 CRLF 改壞([memory: rubocop-windows-crlf]),自動修完要把行尾 re-normalize 回 LF。

**手動 smoke(可選,接 checklist):** 故意用一個「引用檔裡沒有的程式碼」的 prompt 對 tier1 下 edit → TUI 應該收到一句正常解釋(或 fallback)+ `edit_file_redirected` warning,**且只跑一輪、不再空轉到底**。改用 checklist 修正後的 S1(引用真實內容)→ 正常跳 diff 卡。

---

## 六、風險 / 範圍外

- **失去罕見 self-heal**(學生 out-of-band 改檔、又把新碼貼進 chat)。可接受:前端 patch 驗證是 authoritative guard;且當前這條路徑實務上幾乎只在製造 livelock。
- **`edit_file_redirected` 語意擴張**:現在同時涵蓋「WorkspaceEditGate 真的 redirect 成 load」與「content gate 因不符而 drop」。對前端是 soft 訊號,兩者都成立。若未來要分流 → 走 §二 的新-token 替代方案(範圍外)。
- **前端無須改**:未知/沿用的 warning 都能 graceful degrade;continuation 行為因 actions 變空而自然停。**不在本 plan 動前端。**
- **不動** WorkspaceEditGate / RedundantLoadGate 的行為,只動後者一段註解。

## 七、Rollback

純 domain 改動,單檔可逆:把 `gate_action` 的 mismatch 分支與 `apply`/`load_file_for` 還原、spec 改回即可。無資料/schema 足跡。
