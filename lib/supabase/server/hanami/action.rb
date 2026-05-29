# frozen_string_literal: true

require "json"
require_relative "../../server"

module Supabase
  module Server
    module Hanami
      module Action
        CONTEXT_KEY = "supabase.context"

        def self.included(base)
          base.before(:_capture_supabase_request) if base.respond_to?(:before)
          if base.respond_to?(:handle_exception)
            base.handle_exception(AuthError => :_render_supabase_auth_error)
          end
        end

        def supabase_context
          return nil unless @_supabase_request

          @_supabase_request.env[CONTEXT_KEY]
        end

        def verify_supabase_auth(auth: nil, env: nil, supabase_options: nil)
          if auth.nil? && env.nil? && supabase_options.nil?
            raise AuthError.invalid_credentials if supabase_context.nil?

            return supabase_context
          end

          result = Server.create_context(
            RackRequest.new(@_supabase_request.env),
            auth: auth || :user,
            env: env,
            supabase_options: supabase_options
          )

          raise result.error if result.failure?

          @_supabase_request.env[CONTEXT_KEY] = result.value
        end

        private

        def _capture_supabase_request(request, _response)
          @_supabase_request = request
        end

        def _render_supabase_auth_error(_request, response, error)
          response.status = error.status
          response.headers["Content-Type"] = "application/json"
          response.body = JSON.generate(message: error.message, code: error.code)
        end

        RackRequest = Struct.new(:env)
        private_constant :RackRequest
      end
    end
  end
end
