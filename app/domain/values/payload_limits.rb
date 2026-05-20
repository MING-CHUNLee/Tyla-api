# frozen_string_literal: true

module Tyla
  module Values
    module PayloadLimits
      MAX_CONTEXT_FILES_BYTES = 1_048_576
      MAX_HISTORY_BYTES       = 512_000

      MAX_HISTORY_TURNS = 10
      MAX_FILE_LINES    = 200
    end
  end
end
