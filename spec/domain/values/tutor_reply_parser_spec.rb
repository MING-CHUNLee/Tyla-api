# frozen_string_literal: true

require_relative '../../spec_helper'

describe Tyla::Values::TutorReplyParser do
  describe '.call' do
    it 'returns prose and an empty array when there is no actions block' do
      prose, actions = Tyla::Values::TutorReplyParser.call('Just some advice.')
      _(prose).must_equal 'Just some advice.'
      _(actions).must_equal []
    end

    it 'strips a well-formed actions block and parses the array' do
      reply = <<~REPLY
        Here is a hint.
        <actions>[{"type":"load_file","path":"hw11.R"}]</actions>
      REPLY
      prose, actions = Tyla::Values::TutorReplyParser.call(reply)
      _(prose).must_equal 'Here is a hint.'
      _(actions).must_equal [{ 'type' => 'load_file', 'path' => 'hw11.R' }]
    end

    it 'drops malformed JSON but keeps the prose' do
      reply = "Prose stays.\n<actions>[not valid json}</actions>"
      prose, actions = Tyla::Values::TutorReplyParser.call(reply)
      _(prose).must_equal 'Prose stays.'
      _(actions).must_equal []
    end

    it 'drops a non-array JSON payload (keeps prose, actions empty)' do
      reply = "Prose.\n<actions>{\"type\":\"edit_file\"}</actions>"
      prose, actions = Tyla::Values::TutorReplyParser.call(reply)
      _(prose).must_equal 'Prose.'
      _(actions).must_equal []
    end
  end
end
