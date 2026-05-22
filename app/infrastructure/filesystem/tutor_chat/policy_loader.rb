# frozen_string_literal: true

module Tyla
  module Infrastructure
    module Filesystem
      class PolicyLoader
        BASE_PATH = File.expand_path('../../../application/prompts/tutors', __dir__)

        def load(mode)
          path = File.join(BASE_PATH, mode, 'TUTOR.md')
          raise ArgumentError, "unknown mode: #{mode}" unless File.exist?(path)

          File.read(path)
        end
      end
    end
  end
end
