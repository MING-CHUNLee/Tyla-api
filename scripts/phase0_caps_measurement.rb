# frozen_string_literal: true

# Phase 0 measurement harness for Option C history compression.
# Plan: plans/2026-06-15-option-c-backend-owned-history-compression.md  §8.1 / §8.6
#
# Goal: calibrate PROSE_CAP / PATCH_CAP / SCRIPT_CAP / PASTE_CAP and quantify the
# before/after history-token effect (and hence the rolling-summary trigger rate,
# §5.3) using the REAL backend tokenizer (chars/3.5) against the real artifacts
# we actually have on disk.
#
# Run:  ruby scripts/phase0_caps_measurement.rb
#
# This is deliberately a standalone, re-runnable script (no rspec, no app boot):
# §8.6 asks for an *ongoing* "log before/after history token" measurement, so as
# more session-*.json files accumulate this can simply be re-run.

require 'json'
require_relative '../app/domain/values/tokenizer'

T = Tyla::Values::Tokenizer
ROOT = File.expand_path('..', __dir__)

def tok(str) = T.estimate(str.to_s)
def chars(str) = str.to_s.length

def rule(title)
  puts
  puts('=' * 78)
  puts title
  puts('=' * 78)
end

def kv(label, *vals)
  printf("  %-42s %s\n", label, vals.join('   '))
end

# Truncate by characters the way the serializer will (safe-ish; real impl must
# avoid cutting multibyte chars / a ``` fence — §4.2 of the plan). For sizing,
# a plain char slice is faithful enough for the tokenizer (which is char-based).
def truncate(str, cap)
  s = str.to_s
  return s if s.length <= cap

  "#{s[0, cap]}…"
end

# Pull fenced ```...``` blocks out of a markdown/Rmd string — stand-ins for real
# execute_script `code` (SCRIPT_CAP) and student-pasted code (PASTE_CAP).
def fenced_blocks(text)
  blocks = []
  current = nil
  text.to_s.each_line do |line|
    if line.lstrip.start_with?('```')
      if current
        blocks << current
        current = nil
      else
        current = +''
      end
    elsif current
      current << line
    end
  end
  blocks.reject { |b| b.strip.empty? }
end

# Reconstruct a realistic `file_context` payload from a raw file: `### path`
# header + ` N| ` line prefixes (what the frontend ships, and what a naive
# history would copy verbatim into a turn's content).
def to_file_context(path, content)
  header = "### #{path}\n"
  body = content.each_line.each_with_index.map do |line, i|
    format('%4d| %s', i + 1, line)
  end.join
  header + body
end

# ---------------------------------------------------------------------------
# 0. Environment
# ---------------------------------------------------------------------------
rule('0. ENVIRONMENT (real backend constants)')
kv('Tokenizer', "chars / #{Tyla::Values::Tokenizer::CHARS_PER_TOKEN} (ceil)  [heuristic]")
kv('GitHub Models free input cap', '8_000 tokens   <-- binding budget for student demos')
kv('Anthropic direct input cap', '200_000 tokens')
kv('FORMATTING_OVERHEAD', '200 tokens')
kv('ROLE_OVERHEAD (per history msg)', '4 tokens')

# ---------------------------------------------------------------------------
# 1. Corpus inventory — be honest about what real data exists
# ---------------------------------------------------------------------------
rule('1. CORPUS INVENTORY (what we can actually measure)')

session_glob = File.join(ROOT, '..', 'MindyCLI_demo', 'tyla', '.tyla', 'sessions', 'session-*.json')
session_files = Dir.glob(session_glob)
real_turns = []
real_turns_with_actions = 0
real_turns_with_file_context = 0
session_files.each do |f|
  data = JSON.parse(File.read(f))
  Array(data['turns']).each do |t|
    real_turns << t
    real_turns_with_actions += 1 if Array(t['apiLogs']).any? || Array(t['actions']).any?
  end
end

kv('session-*.json files found', session_files.size.to_s)
kv('total real turns', real_turns.size.to_s)
kv('turns with apiLogs/actions', real_turns_with_actions.to_s)
kv('turns with file_context', real_turns_with_file_context.to_s)
puts
puts '  NOTE: the real session corpus carries NO apiLogs / file_context / actions'
puts '  (the on-disk schema is userMessage/assistantMessage/fileChanges/outputs only,'
puts '  all tool signal absent). So action-shaped caps (PATCH/SCRIPT) are calibrated'
puts '  from the assignment FIXTURES (real R code + real patch shapes), and PROSE/PASTE'
puts '  from the one real assistant answer. Statistical calibration is UNDERPOWERED;'
puts '  treat the recommendations as principled defaults to re-confirm once real'
puts '  multi-turn tutor sessions (with apiLogs) are captured.'

# ---------------------------------------------------------------------------
# 2. Base-prompt budget — how much room history actually gets
# ---------------------------------------------------------------------------
rule('2. BASE-PROMPT BUDGET (what is left for history, on the 8K channel)')

persona    = File.read(File.join(ROOT, 'spec/fixtures/assignments/CSDS-HW2/tutors/tutor-guide/TUTOR.md'))
assignment = File.read(File.join(ROOT, 'spec/fixtures/assignments/CSDS-HW2/assignment/HW 02.docx.txt'))
solution   = File.read(File.join(ROOT, 'spec/fixtures/assignments/CSDS-HW2/solutions/Hw2.Rmd'))
student    = File.read(File.join(ROOT, 'spec/fixtures/assignments/CSDS-HW2/student-files/Hw2.Rmd'))

budget = 8_000
user_prompt_tok = tok('In @hw2.R, I want to calculate the quartiles, but the probs I used seem incorrect. Please fix it directly for me.')

base_r1 = tok(persona) + tok(assignment) + user_prompt_tok + 200
base_r2 = base_r1 + tok(solution) # hybrid-lazy round 2 injects solution as mandatory

kv('persona (TUTOR.md)', "#{tok(persona)} tok")
kv('assignment (HW02)', "#{tok(assignment)} tok")
kv('solution (round 2 only)', "#{tok(solution)} tok")
kv('user_prompt (sample)', "#{user_prompt_tok} tok")
kv('base round 1 (no solution)', "#{base_r1} tok", "remaining = #{budget - base_r1} tok")
kv('base round 2 (with solution)', "#{base_r2} tok", "remaining = #{budget - base_r2} tok")

file_context = to_file_context('hw2.R', student)
fc_tok = tok(file_context)
kv('live file_context (hw2.R loaded)', "#{fc_tok} tok  (#{chars(file_context)} chars)")
rem_r1_after_fc = budget - base_r1 - fc_tok
rem_r2_after_fc = budget - base_r2 - fc_tok
kv('-> remaining for HISTORY, round 1', "#{rem_r1_after_fc} tok")
kv('-> remaining for HISTORY, round 2', "#{rem_r2_after_fc} tok  #{rem_r2_after_fc.negative? ? '(file_context alone overflows!)' : ''}")

# ---------------------------------------------------------------------------
# 3. The "before" cost: a turn that copies file_context into history
# ---------------------------------------------------------------------------
rule('3. BEFORE: naive history turn carries the file_context verbatim')
naive_turn_tok = fc_tok + 4 + user_prompt_tok + 4
kv('naive past turn (user+assistant)', "#{naive_turn_tok} tok",
   "= prompt #{user_prompt_tok} + file_context #{fc_tok} + 2x role overhead")
kv('naive turns that fit (round 1)', "#{[rem_r1_after_fc, 0].max / naive_turn_tok} full turns")
puts '  => Even ONE past turn that inlines a 9 KB file ~ blows the entire history budget.'
puts '     This is the bloat Option C removes (§3.1, §5).'

# ---------------------------------------------------------------------------
# 4. Per-cap sensitivity
# ---------------------------------------------------------------------------
rule('4. PER-CAP SENSITIVITY (real samples vs candidate caps)')

# --- PROSE_CAP: the one real assistant answer we have -----------------------
session_one = session_files.map { |f| JSON.parse(File.read(f)) }
                           .flat_map { |d| Array(d['turns']) }
prose_samples = session_one.map { |t| t['assistantMessage'] }.compact.reject(&:empty?)
puts
puts '  PROSE_CAP  (assistant prose; default 600 chars = %d tok)' % tok('x' * 600)
if prose_samples.any?
  prose_samples.each_with_index do |p, i|
    kv("  real assistant msg ##{i + 1}", "#{chars(p)} chars / #{tok(p)} tok")
  end
  [400, 600, 800, 1000].each do |cap|
    truncated = prose_samples.map { |p| truncate(p, cap) }
    saved = prose_samples.sum { |p| tok(p) } - truncated.sum { |p| tok(p) }
    cut = prose_samples.count { |p| chars(p) > cap }
    kv("  cap=#{cap} chars (#{tok('x' * cap)} tok)", "truncates #{cut}/#{prose_samples.size} samples", "saves #{saved} tok total")
  end
else
  puts '  (no prose samples found)'
end

# --- SCRIPT_CAP & PASTE_CAP: real R code blocks from the fixtures -----------
code_blocks = fenced_blocks(student) + fenced_blocks(solution)
code_blocks = code_blocks.reject { |b| b.strip.start_with?('Answer') } # drop prose-in-fence
puts
puts '  SCRIPT_CAP / PASTE_CAP  (real R code blocks from fixtures, n=%d)' % code_blocks.size
if code_blocks.any?
  lens = code_blocks.map { |b| chars(b) }.sort
  kv('  code-block chars (min/med/max)', "#{lens.first} / #{lens[lens.size / 2]} / #{lens.last}")
  kv('  code-block tokens (med/max)', "#{tok('x' * lens[lens.size / 2])} / #{tok('x' * lens.last)} tok")
  [150, 200, 300, 400].each do |cap|
    cut = code_blocks.count { |b| chars(b) > cap }
    kv("  cap=#{cap} chars (#{tok('x' * cap)} tok)", "truncates #{cut}/#{code_blocks.size} blocks")
  end
else
  puts '  (no code blocks found)'
end

# --- PATCH_CAP: the worked-example single-line patch (06-14 §4.5) -----------
patch_search  = 'quartiles_d123 <- quantile(d123, probs = c(0.25, 0.50, 0.75))'
patch_replace = 'quartiles_d123 <- quantile(d123, probs = c(0.25, 0.5, 0.75))'
puts
puts '  PATCH_CAP  (single search/replace string; default 400 chars = %d tok)' % tok('x' * 400)
kv('  worked-example search', "#{chars(patch_search)} chars / #{tok(patch_search)} tok")
kv('  worked-example replace', "#{chars(patch_replace)} chars / #{tok(patch_replace)} tok")
kv('  largest fixture code block', "#{code_blocks.map { |b| chars(b) }.max} chars (worst-case multi-line patch)")

# ---------------------------------------------------------------------------
# 5. AFTER: a compressed turn at recommended caps, and turns-that-fit
# ---------------------------------------------------------------------------
rule('5. AFTER: compressed turn cost + rolling-summary trigger impact')

PROSE = 600
PATCH = 400
placeholder = "\n\n[Previously inspected last turn (contents not included now; " \
              "call load_file to see them again): hw2.R]"

# user entry: prompt (pasted code stripped) + placeholder
compressed_user = user_prompt_tok + tok(placeholder)
# assistant entry: capped prose + one neutral patch line
patch_line = "Suggested editing `hw2.R` (line 8): `#{truncate(patch_search, PATCH)}` -> `#{truncate(patch_replace, PATCH)}`"
prose_sample = prose_samples.first || ''
compressed_assistant = tok(truncate(prose_sample, PROSE)) + tok(patch_line)
compressed_turn = compressed_user + 4 + compressed_assistant + 4

kv('compressed user entry', "#{compressed_user} tok")
kv('compressed assistant entry', "#{compressed_assistant} tok")
kv('compressed past turn (pair)', "#{compressed_turn} tok",
   "vs naive #{naive_turn_tok} tok  (#{(100 * (naive_turn_tok - compressed_turn) / naive_turn_tok.to_f).round}% smaller)")
puts
kv('compressed turns that fit (r1)', "#{[rem_r1_after_fc, 0].max / compressed_turn}", "vs #{[rem_r1_after_fc, 0].max / naive_turn_tok} naive")
kv('compressed turns that fit (r2)', "#{[rem_r2_after_fc, 0].max / compressed_turn}", "vs #{[rem_r2_after_fc, 0].max / naive_turn_tok} naive")
puts
puts '  Rolling-summary triggers when history overflows the remaining budget (§5.3).'
puts '  Fitting N turns instead of 0-1 turns is the trigger-rate reduction Phase 0 set'
puts '  out to quantify: on the 8K channel, compression turns "summary almost always"'
puts '  into "summary only after a long multi-turn session".'

puts
puts 'DONE.'
