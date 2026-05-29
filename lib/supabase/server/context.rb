# frozen_string_literal: true

require_relative "core"
require_relative "env"
require_relative "errors"
require_relative "logging"

module Supabase
  module Server
    SupabaseContext = Struct.new(
      :supabase, :supabase_admin,
      :user_claims, :jwt_claims,
      :auth_mode, :auth_key_name,
      keyword_init: true
    )

    class Result
      attr_reader :value, :error

      def initialize(value:, error:)
        @value = value
        @error = error
      end

      def success?
        @error.nil?
      end

      def failure?
        !success?
      end

      def to_a
        [@value, @error]
      end

      def to_ary
        to_a
      end

      def self.success(value)
        new(value: value, error: nil)
      end

      def self.failure(error)
        new(value: nil, error: error)
      end
    end

    def self.create_context(request, auth: :user, env: nil, supabase_options: nil)
      headers = extract_headers(request)
      credentials = Core.extract_credentials(headers)

      auth_result =
        begin
          Core.verify_credentials(credentials, auth: auth, env: env)
        rescue AuthError => e
          Logging.log(:warn, "[#{e.code}] #{e.message}")
          return Result.failure(e)
        end

      build_context_result(auth_result, env: env, supabase_options: supabase_options)
    end

    def self.build_context_result(auth_result, env:, supabase_options:)
      publishable_key_name = auth_result.auth_mode == :publishable ? auth_result.key_name : nil
      supabase = Core.create_context_client(
        auth: { token: auth_result.token, key_name: publishable_key_name },
        env: env,
        supabase_options: supabase_options
      )

      admin_key_name = auth_result.auth_mode == :secret ? auth_result.key_name : nil
      supabase_admin = Core.create_admin_client(
        auth: { key_name: admin_key_name },
        env: env,
        supabase_options: supabase_options
      )

      Result.success(
        SupabaseContext.new(
          supabase: supabase,
          supabase_admin: supabase_admin,
          user_claims: auth_result.user_claims,
          jwt_claims: auth_result.jwt_claims,
          auth_mode: auth_result.auth_mode,
          auth_key_name: auth_result.key_name
        )
      )
    rescue EnvError => e
      wrapped = AuthError.new(e.message, e.code, 500)
      Logging.log(:error, "[#{wrapped.code}] #{wrapped.message}")
      Result.failure(wrapped)
    rescue StandardError
      wrapped = AuthError.create_supabase_client_error
      Logging.log(:error, "[#{wrapped.code}] #{wrapped.message}")
      Result.failure(wrapped)
    end

    def self.extract_headers(request)
      return {} if request.nil?
      return request if request.is_a?(Hash)

      if request.respond_to?(:headers)
        headers = request.headers
        return {
          "Authorization" => header_value(headers, "Authorization"),
          "apikey" => header_value(headers, "apikey")
        }
      end

      if request.respond_to?(:env)
        env = request.env
        return {
          "Authorization" => env["HTTP_AUTHORIZATION"],
          "apikey" => env["HTTP_APIKEY"]
        }
      end

      request
    end

    def self.header_value(headers, name)
      return nil if headers.nil?
      return headers[name] if headers.respond_to?(:[])

      nil
    end

    class << self
      private :build_context_result, :extract_headers, :header_value
    end
  end
end
