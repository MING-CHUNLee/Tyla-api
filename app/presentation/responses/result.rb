# frozen_string_literal: true

module Tyla
  module Response
    SUCCESS = Set.new(
      %i[ok created accepted no_content]
    ).freeze

    FAILURE = Set.new(
      %i[bad_request unauthorized forbidden not_found conflict
         payload_too_large cannot_process too_many_requests
         internal_error upstream_error upstream_timeout]
    ).freeze

    CODES = SUCCESS | FAILURE

    # Generic envelope for any operation result. `status` is a symbol drawn
    # from CODES; Representer::HttpResponse maps it to the wire-level HTTP
    # code. `errors` is an optional structured payload — used by 422 to
    # surface dry-validation's per-key error hash.
    Result = Struct.new(:status, :message, :errors) do
      def initialize(status:, message: nil, errors: nil)
        raise(ArgumentError, 'Invalid status') unless CODES.include?(status)

        super(status, message, errors)
      end
    end
  end
end
