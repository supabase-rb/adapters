# frozen_string_literal: true

require "json"
require_relative "../../server"

module Supabase
  module Server
    module Rails
      class Middleware
        def initialize(app, auth: :user, env: nil, supabase_options: nil, cors: nil)
          @app = app
          @auth = auth
          @env_overrides = env
          @supabase_options = supabase_options
          @cors = cors
        end

        def call(env)
          if cors_enabled? && env["REQUEST_METHOD"] == "OPTIONS"
            return [204, CORS.add_headers({}, @cors), []]
          end

          return @app.call(env) if env[Server::CONTEXT_KEY]

          result = Server.create_context(
            RackRequest.new(env),
            auth: @auth,
            env: @env_overrides,
            supabase_options: @supabase_options
          )

          return error_response(result.error) if result.failure?

          env[Server::CONTEXT_KEY] = result.value
          status, headers, body = @app.call(env)
          headers = CORS.add_headers(headers, @cors) if cors_enabled?
          [status, headers, body]
        end

        private

        def cors_enabled?
          @cors != false
        end

        def error_response(error)
          body = JSON.generate(message: error.message, code: error.code)
          headers = { "Content-Type" => "application/json" }
          headers = CORS.add_headers(headers, @cors) if cors_enabled?
          [error.status, headers, [body]]
        end

        RackRequest = Struct.new(:env)
        private_constant :RackRequest
      end
    end
  end
end
