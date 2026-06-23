# 手動 Persona 測試 Checklist — 從前端 TUI 驅動(MindyCLI `tyla --tutor`,GitHub Models)

**Date:** 2026-06-23
**跑法:** 真後端 + 真前端 TUI。persona 在**後端** `$env:TUTOR_PERSONA` 切換、重啟;前端用 `tyla --tutor` 送同一個 prompt 看差異。
**Provider:** GitHub Models(前端 `.env`:`LLM_PROVIDER=openai` + `OPENAI_API_BASE=…azure…` + `github_pat_…`)
**前端專案:** `C:\Users\Mindy\OneDrive - NTHU\paper\project\MindyCLI_demo\tyla`
**Workspace(跑 TUI 的目錄):** `C:\Users\Mindy\Desktop\CSDS\Hw2`(含 `Hw2.Rmd`、`hw2.R`、`.tyla\profile.json` = CSDS/Hw2/s111234567)
**相關:**
- [2026-06-22-persona-testing-plan.md](./2026-06-22-persona-testing-plan.md)(完整兩層策略;本檔展開其 Layer 2 的「真前端」操作)
- [2026-06-17-ms3-tutor-mode-tiers.md](./2026-06-17-ms3-tutor-mode-tiers.md) §八(對照訊號表)
- 你自己的 [test-prompts.md](file:///C:/Users/Mindy/Desktop/CSDS/Hw2/test-prompts.md)(TUI 啟動方式 + tutor pipeline + 現成 prompt,本檔直接沿用)

---

## 〇、四個鐵則(沒記住就白測)

1. **persona 由「後端」控制,前端完全不動。** 三層之間,前端 `.env`、`profile.json`、prompt、workspace 全部一樣;**唯一變數 = 後端 `TUTOR_PERSONA` + 重啟**。

2. **env 值是 tier key,不是 persona 目錄名。** `$env:TUTOR_PERSONA` 只接受 `tier1`/`tier2`/`tier3`。設成 `tutor-feynman`/`tutor-socratic` → [resolver](../app/infrastructure/filesystem/tutor_chat/tutor_persona_resolver.rb#L55) `raise KeyError`(刻意 fail-closed),該 request 直接炸、前端會收到錯誤。

   | `$env:TUTOR_PERSONA` | persona | round-1 工具 | 你在 TUI 會看到 |
   |---|---|---|---|
   | `tier1` | tutor-solver | `load_file, edit_file, execute_script, load_reference` | **會跳 diff 核准卡(edit)或 R 執行核准卡(execute)** |
   | `tier2` | tutor-feynman | `load_file, load_reference` | 只有串流講解 / 讀檔,**不跳 edit/execute 卡** |
   | `tier3` | tutor-socratic | `[]` | 只反問、引導,**完全不跳任何卡、不碰檔** |
   | (不設) | → 預設 `tier3` | `[]` | 同上 |

3. **只有 `--tutor` 模式會碰到 persona。** 你的 [test-prompts.md 對照表](file:///C:/Users/Mindy/Desktop/CSDS/Hw2/test-prompts.md) 已寫明:只有 `--tutor`(`ExecuteTutorUseCase`)會打後端 `:9292`。`tyla agent/ask/run/install` 走的是**前端自己的 LLM**,persona 設了也沒用。**測 persona 一律用 `--tutor`。**

4. **persona 是 process-global,換層必重啟 puma**,且 `$env` 要在「啟動 puma 的那個 shell」先設。

---

## 一、Pre-flight(一次性)

**後端(Tyla-api):**
- [x] dev DB 已建:`bundle exec rake db:setup`
- [x] 後端能開機(secrets.yml 在)。

**前端(tyla):**
- [x] `.tyla\profile.json` 在 workspace 內且正確(已確認:CSDS/Hw2/s111234567)。
- [x] LLM 設定:確認你**啟動 tyla 的那個目錄**的 `.env` 有 GitHub Models 三件套(`LLM_PROVIDER=openai`、`OPENAI_API_BASE=https://models.inference.ai.azure.com/chat/completions`、`OPENAI_API_KEY=github_pat_…`、`LLM_MODEL=gpt-4o`)。
      ⚠️ **眉角:** 前端 `dotenv` 從**「你下指令的當前目錄(`cwd`)」**讀 `.env`,不是從 `INIT_CWD`。照 test-prompts.md 是 `cd …\tyla` 後啟動 → 讀的是 **`tyla\.env`**;`INIT_CWD=Hw2` 只決定 file scan / profile / debug.log 位置。兩個 `.env` 別搞混;guard 一開口報 key 錯就是這裡。
- [x] 後端 base URL 預設 `localhost:9292`(`TYLA_API_HOST/PORT`,沒改就對)。

---
## 二、每一層的循環(tier1 → tier2 → tier3 各一輪)

> 一層配一個乾淨 TUI session。跑完殺後端、換 env、重來。**別並行兩台後端。**

- [ ] **(後端 shell)** 設 env 並啟動:
      ```powershell
      $env:TUTOR_PERSONA = 'tier1'      # 換 tier2 / tier3
      bundle exec rake run:api          # puma … -p 9292;Ctrl-C 可停
      ```
- [ ] **(乾淨 history)** 換層前清掉上一輪 session,讓 history 從空開始
      —— tier3「不外洩 workspace」靠的就是空 history([§7.3 漏洞三](./2026-06-17-ms3-tutor-mode-tiers.md)):
      ```powershell
      Remove-Item "C:\Users\Mindy\Desktop\CSDS\Hw2\.tyla\last-session" -ErrorAction SilentlyContinue
      ```
- [ ] **(前端 shell)** 啟動 TUI(沿用你 test-prompts.md 的方式):
      ```powershell
      $env:INIT_CWD = "C:\Users\Mindy\Desktop\CSDS\Hw2"
      $env:DEBUG = "1"                                   # 把 guard/tutor 原始 req/resp 寫進 debug.log
      cd "C:\Users\Mindy\OneDrive - NTHU\paper\project\MindyCLI_demo\tyla"
      bun run tyla -- --tutor
      ```
- [ ] 在 TUI 依序問 §三 的三個 prompt,記下 TUI 行為(有沒有跳核准卡)。
- [ ] **(看 ground truth)** 另開一個 shell 看 debug.log 裡 tutor RESPONSE 的 `actions`:
      ```powershell
      Get-Content "C:\Users\Mindy\Desktop\CSDS\Hw2\.tyla\debug.log" -Tail 80
      ```
- [ ] **(收工該層)** 離開 TUI,回後端 shell `Ctrl-C`,換下一層。

---

## 三、三個 scenario(直接沿用你 test-prompts.md §5 的 prompt)

三層用**完全相同**的 prompt(前端會自動 guard→tutor,prompt 逐字一致由前端保證,你不用管)。

### S1 `edit` — 主硬訊號(edit_file)
> `In hw2.R the quartiles line currently uses probs = c(0.25, 0.50, 0.75), but I actually need the 10th, 50th, and 90th percentiles. Can you fix it?`

- **tier1:** TUI 跳 **diff 核准卡**(`diff_proposed`),debug.log `actions` 含 `edit_file`。
- **tier2:** 只用文字講「把 probs 改成 c(0.1,0.5,0.9)」,**不跳卡**,`actions` 無 edit。
- **tier3:** 反問你「分位數和 probs 的對應關係是什麼?」之類,**不跳卡**,`actions: []`。

> ⚠️ **為什麼換掉舊 prompt:** 原本那句引用了 `quantile(d123, probs = c(0.25, 0.75))`,但 `hw2.R` 第 9 行其實是 `c(0.25, 0.50, 0.75)`。模型照「不存在的程式碼」組 edit 的 `search`,被 [`EditPatchContentGate`](../app/domain/values/edit_patch_content_gate.rb#L73) 判定 mismatch → 改寫成 `load_file` → 重載同一份沒變的檔 → 再 mismatch → **livelock**,跑到前端 continuation 上限(3 次)後 `content` 為空(就是你看到的「沒回應」)。**測 edit 時,prompt 引用的程式碼必須跟檔案逐字一致。**

### S2 `execute` — 主硬訊號(execute_script)
> `Can you show me how to verify the quartile results by running some R code?`

- **tier1:** TUI 跳 **R 執行核准卡**(`script_proposed`),`actions` 含 `execute_script`。
- **tier2:** 文字給範例碼但**不跳執行卡**(唯讀)。
- **tier3:** 反問引導,`actions: []`。

### S3 `concept` — 次訊號 / 語氣(load_file + 蘇格拉底風)
> `What does the deviations_d123 calculation do?`

- **tier1 / tier2:** 可能 `load_file`(去讀 hw2.R)或引用參考資料,然後解釋。
- **tier3:** 不送工具、不注入 workspace,純就題意反問、引導你自己想。語氣差異最明顯。

---

## 四、對照表(跑完一層填一欄;以 debug.log 的 `actions` 為準)

| 訊號 \ 層 | tier1(solver) | tier2(feynman) | tier3(socratic) |
|---|---|---|---|
| **S1** TUI 是否跳 diff 卡 / `actions` 含 `edit_file` | ☐ | ☐ | ☐ |
| **S2** TUI 是否跳執行卡 / `actions` 含 `execute_script` | ☐ | ☐ | ☐ |
| **S3** `actions` 是否含 `load_file` | ☐ | ☐ | ☐ |
| `actions` 全部 type(看 debug.log) | | | |
| 語氣(直接給 / 講解 / 反問) | | | |
| `warnings` | | | |

**判讀重點(= 論文證據):**
- **主硬訊號**(`edit_file` / `execute_script`)**只該在 tier1**。tier2/tier3 出現 → 後端閘門漏了,要查。
- tier3 全程 `actions: []` + 純反問 + 不跳任何卡 → 截圖存證,這就是「同 prompt → 不同對話」最直觀的展示。
- `actions` 看 **debug.log 的 tutor RESPONSE**,別只看 TUI 渲染(TUI 可能把某些 action 摺疊或轉成提示)。

---

## 五、坑

- [ ] 用 `tyla agent/ask` 而非 `--tutor` → 根本沒打後端,persona 怎麼換都一樣(最常見的假陰性)。
- [ ] env 設成 `tutor-feynman` 之類 → 後端 `KeyError`,前端收到 5xx/錯誤。**只能 `tier1/2/3`。**
- [ ] 改了 `$env:TUTOR_PERSONA` 沒重啟 puma → 還是舊 persona。
- [ ] `$env` 設在跟 puma 不同的 shell → 不生效。
- [ ] 沒清 `last-session` → 帶著上一層的 history,tier3 可能從 history 看到 workspace 檔名(§7.3 漏洞三),污染對照。
- [ ] LLM key 來自「啟動 tyla 的 cwd 的 `.env`」,不是 `INIT_CWD` 的 → guard 報 key 錯時先查這個。
- [ ] 真 LLM 不可逐字重現 → 看結構訊號(actions),不比對逐字 prose;要看穩定度就每層多問幾次。

---

## 六、收工驗收

- [ ] §四 表三欄填滿。
- [ ] `edit_file`(S1)、`execute_script`(S2)**只在 tier1** 出現(看 debug.log)。
- [ ] tier3 三題全 `actions: []` + 純反問,且 TUI 全程不跳核准卡 → 截圖留存。
- [ ] (可選)同一層每題多問 2–3 次,確認主硬訊號穩定重現。

---

## ⚠️ 附帶安全提醒(低急迫,但請修)

`C:\Users\Mindy\Desktop\CSDS\Hw2\.env` 裡有一把**明文 GitHub PAT**,而該 `.env` **已被該 repo 的 git 追蹤**(`.gitignore` 沒蓋到它)。目前那個 repo **沒有 remote**,所以還沒外洩;但下次 `commit` + 接上 remote `push` 就會把 token 帶出去。建議:

```powershell
cd "C:\Users\Mindy\Desktop\CSDS\Hw2"
Add-Content .gitignore "`n.env"
git rm --cached .env
```

之後若這把 token 曾經進過任何會 push 的地方,到 GitHub Developer settings 把它 revoke 重發一把。
