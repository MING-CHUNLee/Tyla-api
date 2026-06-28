# frozen_string_literal: true

require_relative '../../spec_helper'

describe Tyla::Values::HistoryTurnSerializer do
  HTS = Tyla::Values::HistoryTurnSerializer

  def base_turn(overrides = {})
    {
      'prompt'          => 'Please help me with this code',
      'prose'           => 'Sure, here is what I suggest.',
      'context_headers' => '',
      'actions'         => []
    }.merge(overrides)
  end

  def edit_action(path: 'hw2.R', start_line: 5, search: 'q <- 1', replace: 'q <- 2')
    { 'type' => 'edit_file', 'path' => path,
      'patches' => [{ 'start_line' => start_line, 'search' => search, 'replace' => replace }] }
  end

  def load_action(path: 'data.R')
    { 'type' => 'load_file', 'path' => path }
  end

  # S1 — complete turn produces a user+assistant pair with all expected content
  it 'S1: full turn returns [user, assistant] with prose and rendered actions' do
    turn = base_turn('actions' => [edit_action, load_action])
    result = HTS.call(turn)

    _(result.size).must_equal 2
    _(result[0][:role]).must_equal 'user'
    _(result[1][:role]).must_equal 'assistant'
    _(result[0][:content]).must_include 'Please help me'
    _(result[1][:content]).must_include 'Sure, here is what I suggest.'
    _(result[1][:content]).must_include 'Suggested editing'
    _(result[1][:content]).must_include 'hw2.R'
    _(result[1][:content]).must_include 'Requested the contents of'
    _(result[1][:content]).must_include 'data.R'
  end

  # S2 — seen_paths placeholder uses correct wording: conditional load_file (not unconditional)
  it 'S2: ### a.R in context_headers → placeholder with conditional "call load_file only if not in live section"' do
    turn = base_turn('context_headers' => "### a.R\n")
    result = HTS.call(turn)
    user = result[0][:content]

    _(user).must_include 'Previously inspected'
    _(user).must_include 'call load_file'
    _(user).must_include 'a.R'
    _(user).must_include 'Student Workspace (live)'   # conditional reference to live section
    _(user).wont_include 'Loaded'
    _(user).wont_include 'shown'
  end

  # S3 — CRLF headers-only: path extracted without trailing \r
  it 'S3: CRLF context_headers → seen_paths contains path with no trailing \\r' do
    turn = base_turn('context_headers' => "### a.R\r\n")
    result = HTS.call(turn)
    user = result[0][:content]

    _(user).must_include 'a.R'
    _(user).wont_include "a.R\r"
  end

  # S4 — caps truncation
  describe 'S4: caps' do
    it 'truncates prose over PROSE_CAP=600 chars' do
      long_prose = 'word ' * 150  # 750 chars
      turn = base_turn('prose' => long_prose, 'actions' => [])
      content = HTS.call(turn)[1][:content]

      _(content.length).must_be :<=, HTS::PROSE_CAP + 10  # +10 for the ellipsis char
      _(content).must_include '…'
    end

    it 'truncates patch search/replace each over PATCH_CAP=400 chars' do
      long_val = 'a' * 500
      turn = base_turn('prose' => '', 'actions' => [edit_action(search: long_val, replace: long_val)])
      content = HTS.call(turn)[1][:content]

      _(content).must_include '…'
    end

    it 'small single-line patch (~44 chars) is preserved fully' do
      small = 'q <- quantile(data, probs = c(0.25, 0.75))'
      turn = base_turn('prose' => '', 'actions' => [edit_action(search: small, replace: 'x')])
      content = HTS.call(turn)[1][:content]

      _(content).must_include small
      _(content).wont_include '…'
    end

    it 'truncates execute_script code over SCRIPT_CAP=200 chars' do
      long_code = "plot(x)\n" * 30  # > 200 chars
      turn = base_turn('prose' => '',
                       'actions' => [{ 'type' => 'execute_script', 'code' => long_code }])
      content = HTS.call(turn)[1][:content]

      _(content).must_include 'Suggested a demo script'
      _(content).must_include '…'
    end

    it 'strips fenced code block over PASTE_CAP=200 chars in prompt, preserves prose' do
      fence = "```r\n#{"x <- 1\n" * 40}```"
      turn = base_turn('prompt' => "please fix:\n#{fence}")
      user_content = HTS.call(turn)[0][:content]

      _(user_content).must_include 'please fix:'
      _(user_content).must_include 'pasted code omitted'
    end

    it 'keeps fenced code block under PASTE_CAP=200 chars intact' do
      fence = "```r\nx <- 1\n```"  # well under 200
      turn = base_turn('prompt' => "look:\n#{fence}")
      user_content = HTS.call(turn)[0][:content]

      _(user_content).must_include fence
      _(user_content).wont_include 'pasted code omitted'
    end
  end

  # S5 — edit_file neutral wording ("Suggested editing", not Applied/Changed)
  it 'S5: edit_file renders neutral "Suggested editing `path` (line N):"' do
    turn = base_turn('actions' => [edit_action(path: 'hw2.R', start_line: 5)])
    content = HTS.call(turn)[1][:content]

    _(content).must_include 'Suggested editing `hw2.R` (line 5):'
    _(content).wont_include 'Applied'
    _(content).wont_include 'Changed'
  end

  # S5b — multi-line patch uses -/+ diff format
  it 'S5b: multi-line patch renders as -/+ diff' do
    turn = base_turn('prose' => '',
                     'actions' => [edit_action(search: "a <- 1\nb <- 2", replace: "a <- 10\nb <- 20")])
    content = HTS.call(turn)[1][:content]

    _(content).must_include '- a <- 1'
    _(content).must_include '+ a <- 10'
  end

  # S6 — degenerate turn: no prose, no renderable actions → contract safety fallback
  it 'S6: empty prose and no actions → assistant content is "(No actionable reply.)"' do
    turn = base_turn('prose' => '', 'actions' => [])
    _(HTS.call(turn)[1][:content]).must_equal '(No actionable reply.)'
  end

  it 'S6b: unknown action type → still falls back to "(No actionable reply.)" when prose absent' do
    turn = base_turn('prose' => '',
                     'actions' => [{ 'type' => 'unknown_future_action', 'data' => 'x' }])
    _(HTS.call(turn)[1][:content]).must_equal '(No actionable reply.)'
  end

  # S7 — blank/nil prompt → skip entire turn (pair-or-skip invariant)
  it 'S7: blank prompt → returns [] (pair-or-skip)' do
    _(HTS.call(base_turn('prompt' => '   '))).must_equal []
  end

  it 'S7b: missing prompt key → returns []' do
    turn = { 'prose' => 'something', 'context_headers' => '', 'actions' => [] }
    _(HTS.call(turn)).must_equal []
  end

  # S8 — string-keyed and symbol-keyed turns produce identical results
  it 'S8: symbol-keyed turn produces same output as string-keyed turn' do
    str_turn = {
      'prompt'          => 'hello',
      'prose'           => 'hi there',
      'context_headers' => "### x.R\n",
      'actions'         => [{ 'type' => 'load_file', 'path' => 'x.R' }]
    }
    sym_turn = {
      prompt:          'hello',
      prose:           'hi there',
      context_headers: "### x.R\n",
      actions:         [{ type: 'load_file', path: 'x.R' }]
    }

    str_result = HTS.call(str_turn)
    sym_result = HTS.call(sym_turn)

    _(str_result[0][:content]).must_equal sym_result[0][:content]
    _(str_result[1][:content]).must_equal sym_result[1][:content]
  end

  it 'S8b: symbol-keyed edit_file patches work correctly' do
    sym_turn = {
      prompt:          'fix it',
      prose:           'Done.',
      context_headers: '',
      actions:         [{ type: 'edit_file', path: 'f.R',
                          patches: [{ start_line: 3, search: 'old', replace: 'new' }] }]
    }
    content = HTS.call(sym_turn)[1][:content]

    _(content).must_include 'Suggested editing `f.R` (line 3):'
    _(content).must_include '"old"'
    _(content).must_include '"new"'
  end
end
