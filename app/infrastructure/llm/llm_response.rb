# frozen_string_literal: true

module Tyla
  module Infrastructure
    LlmResponse = Data.define(:content, :usage, :tool_calls) do
      def initialize(content:, usage:, tool_calls: [])
        super
      end
    end
  end
end
