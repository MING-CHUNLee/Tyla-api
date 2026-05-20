# frozen_string_literal: true

module Tyla
  module Infrastructure
    module LlmError
      class Base < StandardError; end
      class Timeout < Base; end
      class Upstream < Base; end
      class UnsupportedProvider < Base; end
    end
  end
end
