# frozen_string_literal: true

require "json"
require_relative "../rails"

module Supabase
  module Rails
    module Controller
      def self.included(base)
        base.helper_method(:supabase_context) if base.respond_to?(:helper_method)
        base.rescue_from(AuthError, with: :render_supabase_auth_error) if base.respond_to?(:rescue_from)
      end

      def supabase_context
        request.env[Rails::CONTEXT_KEY]
      end

      def verify_supabase_auth(auth: nil, env: nil, supabase_options: nil)
        if auth.nil? && env.nil? && supabase_options.nil?
          raise AuthError.invalid_credentials if supabase_context.nil?

          return supabase_context
        end

        result = Rails.create_context(
          request,
          auth: auth || :user,
          env: env,
          supabase_options: supabase_options
        )

        raise result.error if result.failure?

        request.env[Rails::CONTEXT_KEY] = result.value
      end

      private

      def render_supabase_auth_error(error)
        render(
          json: { message: error.message, code: error.code },
          status: error.status
        )
      end
    end
  end
end
