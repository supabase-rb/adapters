# frozen_string_literal: true

module Supabase
  module Rails
    class EnvError < StandardError
      ENV_GENERIC_ERROR = "ENV_ERROR"
      MISSING_SUPABASE_URL = "MISSING_SUPABASE_URL"
      MISSING_PUBLISHABLE_KEY = "MISSING_PUBLISHABLE_KEY"
      MISSING_DEFAULT_PUBLISHABLE_KEY = "MISSING_DEFAULT_PUBLISHABLE_KEY"
      MISSING_SECRET_KEY = "MISSING_SECRET_KEY"
      MISSING_DEFAULT_SECRET_KEY = "MISSING_DEFAULT_SECRET_KEY"

      attr_reader :code, :status

      def initialize(message, code = ENV_GENERIC_ERROR)
        super(message)
        @code = code
        @status = 500
      end

      def self.missing_supabase_url
        new("SUPABASE_URL is required but not set", MISSING_SUPABASE_URL)
      end

      def self.missing_publishable_key(name)
        new(
          %(No "#{name}" publishable key found. Include a "#{name}" entry in SUPABASE_PUBLISHABLE_KEYS.),
          MISSING_PUBLISHABLE_KEY
        )
      end

      def self.missing_default_publishable_key
        new(
          'No default publishable key found. Set SUPABASE_PUBLISHABLE_KEY or include a "default" entry in SUPABASE_PUBLISHABLE_KEYS.',
          MISSING_DEFAULT_PUBLISHABLE_KEY
        )
      end

      def self.missing_secret_key(name)
        new(
          %(No "#{name}" secret key found. Include a "#{name}" entry in SUPABASE_SECRET_KEYS.),
          MISSING_SECRET_KEY
        )
      end

      def self.missing_default_secret_key
        new(
          'No default secret key found. Set SUPABASE_SECRET_KEY or include a "default" entry in SUPABASE_SECRET_KEYS.',
          MISSING_DEFAULT_SECRET_KEY
        )
      end
    end

    class AuthError < StandardError
      AUTH_GENERIC_ERROR = "AUTH_ERROR"
      INVALID_CREDENTIALS = "INVALID_CREDENTIALS"
      CREATE_SUPABASE_CLIENT_ERROR = "CREATE_SUPABASE_CLIENT_ERROR"

      attr_reader :code, :status

      def initialize(message, code = AUTH_GENERIC_ERROR, status = 401)
        super(message)
        @code = code
        @status = status
      end

      def self.invalid_credentials
        new("Invalid credentials", INVALID_CREDENTIALS, 401)
      end

      def self.create_supabase_client_error
        new("Failed to create Supabase client", CREATE_SUPABASE_CLIENT_ERROR, 500)
      end
    end
  end
end
