# frozen_string_literal: true

require "openssl"
require "supabase"

require_relative "env"
require_relative "errors"
require_relative "jwt"

module Supabase
  module Server
    Credentials = Struct.new(:token, :apikey, keyword_init: true)

    AuthResult = Struct.new(
      :auth_mode, :token, :user_claims, :jwt_claims, :key_name,
      keyword_init: true
    )

    UserClaims = Struct.new(
      :id, :role, :email, :app_metadata, :user_metadata,
      keyword_init: true
    )

    module Core
      module_function

      def extract_credentials(headers)
        Credentials.new(
          token: extract_bearer_token(lookup_header(headers, "authorization")),
          apikey: stringify(lookup_header(headers, "apikey"))
        )
      end

      def verify_credentials(credentials, auth: :user, env: nil)
        resolved_env = env.is_a?(SupabaseEnv) ? env : Env.resolve(env || {})

        modes = Array(auth)
        modes = [:user] if modes.empty?

        modes.each do |mode|
          result = try_mode(mode, credentials, resolved_env)
          return result if result
        end

        raise AuthError.invalid_credentials
      end

      def create_context_client(auth: nil, env: nil, supabase_options: nil)
        resolved_env = env.is_a?(SupabaseEnv) ? env : Env.resolve(env || {})
        token, key_name = extract_auth_fields(auth)

        anon_key = resolve_publishable_key(resolved_env.publishable_keys, key_name)

        ::Supabase::Client.new(
          supabase_url: resolved_env.url,
          supabase_key: anon_key,
          options: build_client_options(supabase_options || {}, token)
        )
      end

      def create_admin_client(auth: nil, env: nil, supabase_options: nil)
        resolved_env = env.is_a?(SupabaseEnv) ? env : Env.resolve(env || {})
        _token, key_name = extract_auth_fields(auth)

        secret_key = resolve_secret_key(resolved_env.secret_keys, key_name)

        ::Supabase::Client.new(
          supabase_url: resolved_env.url,
          supabase_key: secret_key,
          options: build_client_options(supabase_options || {}, nil)
        )
      end

      def extract_auth_fields(auth)
        return [nil, nil] if auth.nil?

        if auth.respond_to?(:token) && auth.respond_to?(:key_name)
          return [auth.token, auth.key_name]
        end

        token = auth[:token]
        token = auth["token"] if token.nil?

        key_name =
          if auth.respond_to?(:key?) && auth.key?(:key_name)
            auth[:key_name]
          elsif auth.respond_to?(:key?) && auth.key?("key_name")
            auth["key_name"]
          end

        [token, key_name]
      end

      def resolve_publishable_key(keys, key_name)
        name = key_name || "default"
        anon_key = keys[name]
        anon_key = keys.values.first if anon_key.nil? && key_name.nil?

        if anon_key.nil? || anon_key.to_s.empty?
          raise(
            name == "default" ? EnvError.missing_default_publishable_key : EnvError.missing_publishable_key(name)
          )
        end

        anon_key
      end

      def resolve_secret_key(keys, key_name)
        name = key_name || "default"
        secret_key = keys[name]
        secret_key = keys.values.first if secret_key.nil? && key_name.nil?

        if secret_key.nil? || secret_key.to_s.empty?
          raise(
            name == "default" ? EnvError.missing_default_secret_key : EnvError.missing_secret_key(name)
          )
        end

        secret_key
      end

      def build_client_options(supabase_options, token)
        global = option_value(supabase_options, :global) || {}
        raw_headers = option_value(global, :headers) || {}

        safe_headers = raw_headers.reject do |k, _|
          key = k.to_s.downcase
          key == "authorization" || key == "apikey"
        end
        safe_headers = safe_headers.merge("Authorization" => "Bearer #{token}") if token && !token.to_s.empty?

        auth_opts = option_value(supabase_options, :auth) || {}
        auth_opts = auth_opts.merge(
          persist_session: false,
          auto_refresh_token: false,
          detect_session_in_url: false
        )

        new_global = global.merge(headers: safe_headers)

        supabase_options.merge(global: new_global, auth: auth_opts)
      end

      def option_value(hash, key)
        return nil unless hash.is_a?(Hash)

        hash.key?(key) ? hash[key] : hash[key.to_s]
      end

      def lookup_header(headers, name)
        return nil if headers.nil?

        target = name.downcase

        if headers.respond_to?(:each_pair)
          headers.each_pair do |key, value|
            return value if key.to_s.downcase == target
          end
        elsif headers.respond_to?(:each)
          headers.each do |key, value|
            return value if key.to_s.downcase == target
          end
        end

        nil
      end

      def extract_bearer_token(authorization)
        return nil if authorization.nil?

        str = authorization.to_s
        return nil if str.length < 7
        return nil unless str[0, 6].casecmp("Bearer").zero?
        return nil unless str[6] == " "

        token = str[7..].to_s.strip
        token.empty? ? nil : token
      end

      def stringify(value)
        return nil if value.nil?

        str = value.to_s
        str.empty? ? nil : str
      end

      def parse_auth_mode(mode)
        str = mode.to_s
        colon = str.index(":")
        return [str.to_sym, nil] if colon.nil?

        base = str[0, colon].to_sym
        key_name = str[(colon + 1)..]
        key_name = nil if key_name.nil? || key_name.empty?
        [base, key_name]
      end

      def try_mode(mode, credentials, env)
        base, key_name = parse_auth_mode(mode)

        case base
        when :none
          AuthResult.new(
            auth_mode: :none, token: nil,
            user_claims: nil, jwt_claims: nil, key_name: nil
          )
        when :publishable
          try_apikey_mode(:publishable, env.publishable_keys, credentials.apikey, key_name)
        when :secret
          try_apikey_mode(:secret, env.secret_keys, credentials.apikey, key_name)
        when :user
          try_user_mode(credentials, env)
        end
      end

      def try_apikey_mode(mode_sym, keys, apikey, key_name)
        return nil if apikey.nil? || apikey.to_s.empty?

        if key_name == "*"
          keys.each do |name, value|
            next if value.nil? || value.empty?
            return build_apikey_result(mode_sym, name) if secure_compare(apikey, value)
          end
          return nil
        end

        name = key_name || "default"
        value = keys[name]
        return nil if value.nil? || value.empty?

        return build_apikey_result(mode_sym, name) if secure_compare(apikey, value)

        nil
      end

      def build_apikey_result(mode_sym, name)
        AuthResult.new(
          auth_mode: mode_sym, token: nil,
          user_claims: nil, jwt_claims: nil, key_name: name
        )
      end

      def try_user_mode(credentials, env)
        token = credentials.token
        return nil if token.nil? || token.to_s.empty?
        return nil if token.start_with?("sb_")

        claims = JWT.verify(token, env: env)

        AuthResult.new(
          auth_mode: :user,
          token: token,
          user_claims: claims[:user_claims],
          jwt_claims: claims[:jwt_claims],
          key_name: nil
        )
      end

      def secure_compare(a, b)
        a_str = a.to_s
        b_str = b.to_s
        return false if a_str.bytesize != b_str.bytesize

        OpenSSL.fixed_length_secure_compare(a_str, b_str)
      end
    end
  end
end
