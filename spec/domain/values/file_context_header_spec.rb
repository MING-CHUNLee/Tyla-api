# frozen_string_literal: true

require_relative '../../spec_helper'

describe Tyla::Values::FileContextHeader do
  FCH = Tyla::Values::FileContextHeader

  # F1 — basic match
  it 'F1: matches a plain ### header and returns the path' do
    m = FCH::HEADER.match('### hw2.R')
    _(m[1]).must_equal 'hw2.R'
  end

  # F2 — leading tab and surrounding whitespace in path
  it 'F2: strips surrounding whitespace from path with tab separator' do
    result = FCH.paths("###\t  sub/x.R  \n")
    _(result).must_equal Set['sub/x.R']
  end

  # F3 — two hashes must not match
  it 'F3: rejects ## (section label)' do
    _(FCH.paths("## File Contents\n")).must_equal Set[]
  end

  # F4 — four hashes must not match
  it 'F4: rejects #### (h4 heading)' do
    _(FCH.paths("#### x\n")).must_equal Set[]
  end

  # F5 — indented or inline ### must not match (^ anchor)
  it 'F5a: rejects indented ### (not at line start)' do
    _(FCH.paths("  ### x\n")).must_equal Set[]
  end

  it 'F5b: rejects ### inside a numbered line body' do
    _(FCH.paths(" 1| ### x\n")).must_equal Set[]
  end

  # F6 — LF parity
  it 'F6: LF line ending — path extracted, body line ignored' do
    result = FCH.paths("### a.R\n1| x\n")
    _(result).must_equal Set['a.R']
  end

  # F7 — CRLF parity (key regression guard)
  it 'F7: CRLF line ending — path extracted WITHOUT trailing \r' do
    result = FCH.paths("### a.R\r\n1| x\r\n")
    _(result).must_equal Set['a.R']
    _(result.first).wont_include "\r"
  end

  # F8 — multiple headers → union
  it 'F8: collects multiple ### headers into a Set' do
    result = FCH.paths("### a.R\n### b/c.R\n")
    _(result).must_equal Set['a.R', 'b/c.R']
  end

  # F9 — normalize edge cases
  it 'F9: normalize strips CR, converts backslash, removes leading ./' do
    _(FCH.normalize("./a\\b.R\r")).must_equal 'a/b.R'
    _(FCH.normalize('  x  ')).must_equal 'x'
  end

  # F10 — producer ↔ consumer round-trip
  it 'F10: .line output is readable by .paths (round-trip)' do
    header_line = FCH.line('a/b.R') + "\n"
    _(FCH.paths(header_line)).must_include 'a/b.R'
  end
end
