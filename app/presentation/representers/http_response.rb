# frozen_string_literal: true

require 'roar/decorator'
require 'roar/json'

module Tyla
  module Representer
    # Wraps a Response::Result for the wire. The route asks for
    # `http_status_code` to set on the rack response, then uses `to_json`
    # (or `to_hash`) for the body.
    #
    #   result = Response::Result.new(status: :not_found, message: 'no log')
    #   rep    = Representer::HttpResponse.new(result)
    #   r.halt(rep.http_status_code, rep.to_json)
    class HttpResponse < Roar::Decorator
      include Roar::JSON

      property :status
      property :message
      property :errors

      HTTP_CODE = {
        ok:               200,
        created:          201,
        accepted:         202,
        no_content:       204,

        bad_request:      400,
        unauthorized:     401,
        forbidden:        403,
        not_found:        404,
        conflict:         409,
        cannot_process:   422,

        internal_error:   500,
        upstream_error:   502,
        upstream_timeout: 504
      }.freeze

      def http_status_code
        HTTP_CODE.fetch(represented.status)
      end
    end
  end
end
