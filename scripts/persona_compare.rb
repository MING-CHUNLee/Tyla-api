# frozen_string_literal: true

# Layer 2 — in-process persona comparison harness (MS3 §八, testing plan §三/§四).
# Plan: plans/2026-06-22-persona-testing-plan.md  §3.1 Option A / §4
#       plans/2026-06-17-ms3-tutor-mode-tiers.md   §八 (signal table)
#
# Goal: replay ONE fixed student request against all three tiers in a SINGLE
# process and dump MS3 §八's comparison table — the "different TUTOR.md → different
# conversation" evidence. Because the persona key is the process-global env seam
# (`TUTOR_PERSONA`, §7.5), and it is re-read on every RunTutorChat#call, Option A
# can switch tiers between iterations WITHOUT restarting anything (the env seam is
# set fresh each loop; no server, no DB migration).
#
# This needs a REAL provider key — it makes real tutor LLM calls (one per tier,
# plus a possible round-2 per tier when the model loads the reference). The guard
# leg is bypassed in-process by seeding a passing guard_log row directly (testing
# plan §四: "繞過 guard 的真 LLM 呼叫"), so no guard tokens are spent.
#
# Run (PowerShell) — OpenAI:
#   $env:X_LLM_KEY = '<real key>'; $env:X_LLM_PROVIDER = 'openai'
#   $env:PERSONA_COMPARE_RUNS = '5'                                 # sample each tier 5×
#   bundle exec ruby scripts/persona_compare.rb
#
# GitHub Models (OpenAI-compatible) — provider stays 'openai', ONLY the endpoint
# changes. A github_* PAT is rejected by api.openai.com; it authenticates against
# GitHub's endpoint alone (see doc/api_guard_checks.md). There is NO 'github'
# provider — LlmClient.for only knows openai/anthropic:
#   $env:X_LLM_ENDPOINT = 'https://models.inference.ai.azure.com/chat/completions'
#
# Scenarios (see built_in_scenarios below): no single prompt can elicit every
# signal, so the harness runs SEVERAL fixed turns and reports a table per scenario.
#   $env:PERSONA_COMPARE_SCENARIO = 'all'   # load | edit | demo | all (default all)
# PERSONA_COMPARE_PROMPT still overrides with one ad-hoc no-file_context scenario.
#
# Optional env: X_LLM_MODEL, X_LLM_ENDPOINT, PERSONA_COMPARE_SCENARIO,
#               PERSONA_COMPARE_PROMPT, PERSONA_COMPARE_RUNS (default 1 — set ≥5 for
#               §六 stability + D6/幻覺 rates).
#
# Output: one markdown table PER scenario on stdout + a single JSON dump (every
# sample's full prose preserved) under tmp/persona_compare-<timestamp>.json. Real
# LLMs are NOT reproducible verbatim, so each table reports per-tier RATES of the
# STRUCTURAL signals (edit/execute hits = 主硬訊號, load_file hits = D6, cites-line#
# hits = tier3 prose 幻覺頻率); prose is stored for human inspection only (§五).

require 'json'
require 'sequel'
require 'dry/monads'

ROOT = File.expand_path('..', __dir__)
ENV['RACK_ENV'] ||= 'development' # not 'test' — we want a real run, not stubs

# ── App code (mirrors run_tutor_chat_spec's require set) ────────────────────────
%w[
  app/domain/**/*.rb
  app/infrastructure/llm/**/*.rb
  app/infrastructure/middleware/**/*.rb
  app/application/prompts/**/*.rb
].each { |pattern| Dir.glob(File.join(ROOT, pattern)).each { |f| require f } }

# ── In-memory DB (guard log seam only; no real DB touched) ──────────────────────
# The table must exist BEFORE the ORM subclass loads (Sequel::Model reads schema
# at subclass time), exactly as run_tutor_chat_spec sets it up.
DB = Sequel.sqlite
DB.create_table(:prompt_logs) do
  primary_key :id
  String   :course_id,  null: false
  String   :project_id, null: false
  String   :student_id, null: false
  Text     :prompt,     null: false
  Float    :attack_probability
  Text     :evaluation
  DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
end
Sequel::Model.db = DB

%w[
  app/infrastructure/database/orm/prompt_log_orm.rb
  app/infrastructure/database/repositories/prompt_logs.rb
  app/application/requests/tutor_chat.rb
  app/infrastructure/filesystem/tutor_chat/assignment_loader.rb
  app/infrastructure/filesystem/tutor_chat/solution_loader.rb
  app/infrastructure/filesystem/tutor_chat/student_file_loader.rb
  app/infrastructure/filesystem/tutor_chat/tutor_persona_resolver.rb
  app/presentation/representers/tutor_chat_representer.rb
  app/application/services/tutor_chat/run_tutor_chat.rb
].each { |f| require File.join(ROOT, f) }

Tyla::Database::PromptLogOrm.dataset = DB[:prompt_logs]

# ── Fixed fixtures (MS3 §八 / testing plan §3.2) ───────────────────────────────
# Each tier is replayed against an identical fixed turn. The workspace overview
# always names the REAL fixture student file (Hw2.Rmd) so a `load_file` targets
# something that exists — the old constant pointed at a non-existent analysis.R,
# and the old prompt referenced a summarize() that is in no fixture, which is part
# of why the first real run produced no actions. Whether the file's CONTENTS are
# pre-loaded into file_context is the seam each scenario varies (it turns one
# signal on and another off — see built_in_scenarios). Clean first turn (empty
# history) also sidesteps the §7.3 history-channel leak.
WORKSPACE_OVERVIEW = "R Markdown (.Rmd): #{Tyla::Infrastructure::Filesystem::StudentFileLoader::FILENAME}"
TIERS = %w[tier1 tier2 tier3].freeze

# §六 acceptance wants the MAIN hard signal (edit/execute only in tier1) to be
# "多次重跑下穩定重現", and D6 / tier3 prose hallucination are explicit *rates*
# (§3.3, §五: 只量測幻覺頻率). So each tier is sampled RUNS times and the table
# reports per-tier rates, not a single draw. RUNS=1 reproduces the old behaviour.
RUNS = Integer(ENV.fetch('PERSONA_COMPARE_RUNS', '1'))

def headers_from_env
  key = ENV['X_LLM_KEY'] || ENV['OPENAI_API_KEY'] || ENV['LLM_API_KEY']
  abort 'Set X_LLM_KEY (or OPENAI_API_KEY) to a real provider key before running.' if key.nil? || key.empty?

  h = { 'HTTP_X_LLM_KEY' => key }
  h['HTTP_X_LLM_PROVIDER'] = ENV['X_LLM_PROVIDER'] if ENV['X_LLM_PROVIDER']
  h['HTTP_X_LLM_MODEL']    = ENV['X_LLM_MODEL']    if ENV['X_LLM_MODEL']
  h['HTTP_X_LLM_ENDPOINT'] = ENV['X_LLM_ENDPOINT'] if ENV['X_LLM_ENDPOINT']
  h
end

# Seed a passing guard row (low attack prob, prompt verbatim) and return its id.
# derive_verdict requires guard_log.prompt == this request's prompt (§3.0).
def seed_guard(prompt)
  DB[:prompt_logs].insert(
    course_id: 'CSDS', project_id: 'HW2', student_id: 'persona-compare',
    prompt: prompt, attack_probability: 0.0, evaluation: 'ok'
  )
end

def action_types(actions)
  Array(actions).map { |a| a['type'] || a[:type] }
end

# Soft prose signal (testing plan §3.3): does the reply cite a concrete line number?
# tier3 "should not" — but this is prompt-only (no structural backing, §7.3 漏洞二),
# so it is recorded, never asserted.
def cites_lineno?(text)
  !(text.to_s =~ /line\s+\d+|第?\s*\d+\s*行|行\s*\d+/i).nil?
end

def run_tier(key, service, request, headers)
  ENV['TUTOR_PERSONA'] = key
  # tools_sent is deterministic from the resolved profile — the same array the
  # service hands the transport — so read it directly rather than wire-tapping.
  tools_sent = Tyla::Infrastructure::Filesystem::TutorPersonaResolver.call(key).profile.tool_names
  outcome    = service.call(request, headers)

  if outcome.success?
    kind, dto = outcome.value!
    {
      tier:                key,
      status:              kind.to_s,
      tools_sent:          tools_sent,
      action_types:        action_types(dto.actions),
      has_edit_or_execute: action_types(dto.actions).any? { |t| %w[edit_file execute_script].include?(t) },
      has_load_file:       action_types(dto.actions).include?('load_file'),
      cites_lineno:        cites_lineno?(dto.content),
      warnings:            Array(dto.warnings),
      content:             dto.content.to_s
    }
  else
    tag, msg, = outcome.failure
    { tier: key, status: "FAILURE:#{tag}", error: msg, tools_sent: tools_sent }
  end
end

# Collapse N per-tier samples into the rates §三/§六 actually grade. tools_sent is
# deterministic (profile-derived, identical every run), so the first sample speaks
# for all; the behavioural columns become hit/N rates.
def aggregate(samples)
  ok = samples.select { |s| s[:status] && !s[:status].start_with?('FAILURE') }
  n  = samples.size
  {
    runs:                n,
    ok_runs:            ok.size,
    statuses:            samples.map { |s| s[:status] }.tally,
    tools_sent:          samples.first[:tools_sent],
    edit_or_execute_hits: ok.count { |s| s[:has_edit_or_execute] },   # 主硬訊號:只該 tier1>0
    load_file_hits:       ok.count { |s| s[:has_load_file] },         # D6:tier2 想看碼必先叫
    cites_lineno_hits:    ok.count { |s| s[:cites_lineno] },          # tier3 prose 幻覺(soft)
    action_types_union:   ok.flat_map { |s| Array(s[:action_types]) }.tally,
    warnings_union:       ok.flat_map { |s| Array(s[:warnings]) }.tally
  }
end

def rate(hits, total) = total.zero? ? '—' : "#{hits}/#{total}"

def fmt_tally(tally) = tally.empty? ? '—' : tally.map { |k, v| "#{k}×#{v}" }.join(', ')

def fmt_list(arr) = arr.empty? ? '—' : arr.join(', ')

def print_table(scenario, aggs)
  rows = {
    'runs (ok/total)'        => ->(a) { rate(a[:ok_runs], a[:runs]) },
    'tools_sent'             => ->(a) { fmt_list(Array(a[:tools_sent])) },
    'edit/execute hits (主硬)' => ->(a) { rate(a[:edit_or_execute_hits], a[:ok_runs]) },
    'load_file hits (次/D6)'  => ->(a) { rate(a[:load_file_hits], a[:ok_runs]) },
    'cites line# hits (soft)' => ->(a) { rate(a[:cites_lineno_hits], a[:ok_runs]) },
    'action_types (union)'   => ->(a) { fmt_tally(a[:action_types_union]) },
    'warnings (union)'       => ->(a) { fmt_tally(a[:warnings_union]) },
    'statuses'               => ->(a) { fmt_tally(a[:statuses]) }
  }
  puts
  puts "| #{scenario[:name]} · #{scenario[:signal]} (rate = hits / ok-runs, RUNS=#{RUNS}) | #{TIERS.join(' | ')} |"
  puts "|---|#{TIERS.map { '---' }.join('|')}|"
  rows.each do |label, cell|
    cells = TIERS.map { |t| cell.call(aggs.fetch(t)) }
    puts "| #{label} | #{cells.join(' | ')} |"
  end
  puts
  puts '主硬訊號(edit/execute 只該在 tier1)應跨重跑穩定(理想 tier1=ok/ok、tier2=tier3=0);'
  puts 'load_file 押在 D6(tier2 命中率即 D6 量測值)、cites line# 為 tier3 prose 幻覺頻率(soft 輔證)。'
end

# ── Scenarios ───────────────────────────────────────────────────────────────────
# No single prompt isolates every signal — a WITHHELD file forces load_file but
# starves edit_file of anything to patch; a PRE-LOADED file enables edit_file but
# removes the reason to load. So three fixed turns, each tuned to one signal:
#
#   load — Hw2.Rmd in workspace_overview ONLY (no file_context). load_file is the
#          structural tier1/2-vs-tier3 signal and the D6 measurement (§9 D6):
#          tier1/tier2 must load to see code, tier3 holds no such tool.
#   edit — the SAME file PRE-LOADED into file_context (line-numbered) + a concrete
#          edit instruction. Now tier1 has code to patch → edit_file is the 主硬
#          signal; tier2 (read-only) and tier3 (no tools) structurally cannot. The
#          patch runs the WorkspaceEdit/EditPatchContent gates, so a malformed
#          patch surfaces as `edit_file_redirected` in warnings, not a silent miss.
#   demo — "show me a runnable example" + no file_context → execute_script (demo
#          code present in no file). That is the one 主硬 tool NO gate touches, so
#          it is the cleanest UNgated tier1-only signal — a second, independent
#          elicitation of the 主硬 contrast alongside edit.
#
# Each scenario carries a `signal:` blurb that is printed and dumped, so the table
# and JSON are self-documenting for the writeup (§五).

# Render `### <path>` + "N| " line-numbered contents EXACTLY as the gates parse
# them (FileContextHeader::HEADER + EditPatchContentGate::PREFIX), so a well-formed
# edit_file patch validates against this snapshot instead of being redirected.
def numbered_file_context(path, content)
  body = content.to_s.lines.each_with_index.map { |line, i| "#{i + 1}| #{line.chomp}" }.join("\n")
  "### #{path}\n#{body}\n"
end

def student_file_context
  numbered_file_context(
    Tyla::Infrastructure::Filesystem::StudentFileLoader::FILENAME,
    Tyla::Infrastructure::Filesystem::StudentFileLoader.load('HW2')
  )
end

def built_in_scenarios
  [
    { name: 'load',
      signal: 'D6 load_file rate',
      prompt: 'My Freedman–Diaconis bin width (h_fd) in the Question 3 histogram part looks ' \
              'wrong — can you take a look at my code?',
      file_context: nil },
    { name: 'edit',
      signal: '主硬 edit_file (gated)',
      prompt: 'Please add a short comment line directly above the Freedman–Diaconis line ' \
              '(h_fd <- ...) in my Question 3(b) chunk explaining what the rule does, and apply ' \
              'the edit to my file.',
      file_context: :student_file },
    { name: 'demo',
      signal: '主硬 execute_script (ungated)',
      prompt: 'Can you show me a short, runnable R snippet that computes the Freedman–Diaconis ' \
              'bin width for a numeric vector x, so I can sanity-check my own?',
      file_context: nil }
  ]
end

def resolve_file_context(value)
  value == :student_file ? student_file_context : value
end

# Selection precedence: PERSONA_COMPARE_PROMPT (legacy escape hatch) → a single
# ad-hoc no-file_context scenario; else PERSONA_COMPARE_SCENARIO names one built-in,
# or 'all' (default) runs every built-in in order.
def selected_scenarios
  if (custom = ENV['PERSONA_COMPARE_PROMPT'])
    return [{ name: 'custom', signal: 'ad-hoc PERSONA_COMPARE_PROMPT', prompt: custom, file_context: nil }]
  end

  want = ENV.fetch('PERSONA_COMPARE_SCENARIO', 'all')
  return built_in_scenarios if want == 'all'

  found = built_in_scenarios.find { |s| s[:name] == want }
  if found.nil?
    abort "Unknown PERSONA_COMPARE_SCENARIO=#{want.inspect}; choose: " \
          "#{built_in_scenarios.map { |s| s[:name] }.join(', ')}, all"
  end
  [found]
end

# ── Run ────────────────────────────────────────────────────────────────────────
# Replay one scenario across all tiers and print its table. Each scenario seeds its
# OWN guard row keyed to its prompt — derive_verdict requires guard_log.prompt ==
# the request prompt (§3.0), so one shared row would refuse every other scenario.
def run_scenario(scenario, service, headers)
  guard_log_id = seed_guard(scenario[:prompt])
  file_context = resolve_file_context(scenario[:file_context])
  base_request = {
    course_id: 'CSDS', project_id: 'HW2', student_id: 'persona-compare',
    guard_log_id: guard_log_id, prompt: scenario[:prompt], workspace_overview: WORKSPACE_OVERVIEW
  }
  base_request[:file_context] = file_context if file_context

  puts
  puts "═══ scenario: #{scenario[:name]} — #{scenario[:signal]}"
  puts "prompt:        #{scenario[:prompt]}"
  puts "file_context:  #{file_context ? "#{Tyla::Infrastructure::Filesystem::StudentFileLoader::FILENAME} (pre-loaded, line-numbered)" : 'none (withheld)'}"

  samples = {}
  aggs    = {}
  TIERS.each do |key|
    samples[key] = Array.new(RUNS) do |i|
      warn "→ [#{scenario[:name]}] #{key} run #{i + 1}/#{RUNS}…"
      run_tier(key, service, base_request.dup, headers)
    end
    aggs[key] = aggregate(samples[key])
  end
  print_table(scenario, aggs)

  { signal: scenario[:signal], prompt: scenario[:prompt], workspace_overview: WORKSPACE_OVERVIEW,
    file_context_loaded: !file_context.nil?, aggregates: aggs, samples: samples }
end

def run!
  headers   = headers_from_env
  service   = Tyla::Services::RunTutorChat.new
  scenarios = selected_scenarios

  puts "provider:           #{headers['HTTP_X_LLM_PROVIDER'] || 'openai (default)'}"
  puts "runs per tier:      #{RUNS}"
  puts "scenarios:          #{scenarios.map { |s| s[:name] }.join(', ')}"

  results = scenarios.each_with_object({}) do |scenario, acc|
    acc[scenario[:name]] = run_scenario(scenario, service, headers)
  end

  # JSON evidence dump (every sample's full prose preserved for human inspection).
  Dir.mkdir(File.join(ROOT, 'tmp')) unless Dir.exist?(File.join(ROOT, 'tmp'))
  stamp = Time.now.strftime('%Y%m%d-%H%M%S')
  out   = File.join(ROOT, 'tmp', "persona_compare-#{stamp}.json")
  File.write(out, JSON.pretty_generate(runs: RUNS, scenarios: results))
  puts
  puts "JSON dump → #{out}"
end

# Guard the run so the harness can be `require`d (bootstrap only) for a stubbed
# smoke test without firing real LLM calls.
run! if $PROGRAM_NAME == __FILE__
