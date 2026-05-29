# frozen_string_literal: true

require "json"
require "jwt"
require "net/http"
require "openssl"
require "uri"

require_relative "env"
require_relative "errors"

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

        if env.jwks.nil?
          raise AuthError.new(
            "JWKS not configured for user auth mode",
            AuthError::AUTH_GENERIC_ERROR,
            500
          )
        end

        jwt_claims = verify_jwt(token, env.jwks)
        raise AuthError.invalid_credentials unless jwt_claims.is_a?(Hash) && jwt_claims["sub"].is_a?(String)

        AuthResult.new(
          auth_mode: :user,
          token: token,
          user_claims: build_user_claims(jwt_claims),
          jwt_claims: jwt_claims,
          key_name: nil
        )
      rescue AuthError
        raise
      rescue StandardError
        raise AuthError.invalid_credentials
      end

      def verify_jwt(token, jwks_source)
        jwks_data = jwks_url?(jwks_source) ? fetch_jwks(jwks_source) : jwks_source

        payload, _header = JWT.decode(
          token, nil, true,
          algorithms: %w[RS256 ES256 HS256],
          jwks: jwks_data,
          allow_nil_kid: true
        )
        payload
      end

      def jwks_url?(jwks)
        jwks.is_a?(URI::HTTP) || jwks.is_a?(URI::HTTPS)
      end

      def fetch_jwks(url)
        response = Net::HTTP.get_response(url)
        raise AuthError.invalid_credentials unless response.is_a?(Net::HTTPSuccess)

        parsed = JSON.parse(response.body)
        return parsed if parsed.is_a?(Hash) && parsed["keys"].is_a?(Array)

        raise AuthError.invalid_credentials
      end

      def build_user_claims(jwt_claims)
        UserClaims.new(
          id: jwt_claims["sub"],
          role: jwt_claims["role"],
          email: jwt_claims["email"],
          app_metadata: jwt_claims["app_metadata"],
          user_metadata: jwt_claims["user_metadata"]
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
