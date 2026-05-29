# frozen_string_literal: true

module Supabase
  module Server
    module CORS
      SUPABASE_HEADERS = %w[
        authorization
        x-client-info
        apikey
        content-type
        x-retry-count
      ].join(", ").freeze

      SUPABASE_METHODS = %w[
        GET
        POST
        PUT
        PATCH
        DELETE
        OPTIONS
      ].join(", ").freeze

      DEFAULT_HEADERS = {
        "Access-Control-Allow-Origin" => "*",
        "Access-Control-Allow-Headers" => SUPABASE_HEADERS,
        "Access-Control-Allow-Methods" => SUPABASE_METHODS
      }.freeze

      class << self
        def build_headers(config = nil)
          return {} if config == false
          return config if config.is_a?(Hash)

          DEFAULT_HEADERS
        end

        def add_headers(headers, config = nil)
          return headers if config == false

          cors = build_headers(config)
          merged = headers.dup
          cors.each { |key, value| merged[key] = value }
          merged
        end
      end
    end
  end
end
