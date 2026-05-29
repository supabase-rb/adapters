# frozen_string_literal: true

require "json"
require "jwt"
require "net/http"
require "uri"

require_relative "env"
require_relative "errors"

module Supabase
  module Rails
    module JWT
      ALGORITHMS = %w[RS256 ES256 HS256].freeze
      LEEWAY_SECONDS = 30
      CACHE_TTL_SECONDS = 600
      MISS_COOLDOWN_SECONDS = 30

      @cache_mutex = Mutex.new
      @cache = {}

      class << self
        def verify(token, env:)
          raise AuthError.invalid_credentials if token.nil? || token.to_s.empty?

          jwks_source = env.jwks
          if jwks_source.nil?
            raise AuthError.new(
              "JWKS not configured for user auth mode",
              AuthError::AUTH_GENERIC_ERROR,
              500
            )
          end

          jwks = resolve_jwks(jwks_source)
          payload = decode(token, jwks)

          unless payload.is_a?(Hash) && payload["sub"].is_a?(String)
            raise AuthError.invalid_credentials
          end

          { user_claims: build_user_claims(payload), jwt_claims: payload }
        rescue AuthError
          raise
        rescue StandardError
          raise AuthError.invalid_credentials
        end

        def _reset_cache!
          @cache_mutex.synchronize { @cache.clear }
        end

        private

        def decode(token, jwks)
          payload, _header = ::JWT.decode(
            token, nil, true,
            algorithms: ALGORITHMS,
            jwks: jwks,
            leeway: LEEWAY_SECONDS,
            allow_nil_kid: true
          )
          payload
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

        def resolve_jwks(source)
          return source if source.is_a?(Hash)

          if source.is_a?(URI::HTTPS)
            return fetch_with_cache(source)
          end

          if source.is_a?(URI::HTTP) && Env.loopback_host?(source.host)
            return fetch_with_cache(source)
          end

          raise AuthError.invalid_credentials
        end

        def fetch_with_cache(url)
          url_str = url.to_s

          @cache_mutex.synchronize do
            entry = @cache[url_str]
            now = current_time
            return entry[:value] if entry && entry[:value] && !ttl_expired?(entry[:fetched_at], now)
            if entry && entry[:last_miss_at] && !cooldown_expired?(entry[:last_miss_at], now)
              raise AuthError.invalid_credentials
            end

            begin
              fetched = fetch_remote(url)
              @cache[url_str] = { value: fetched, fetched_at: current_time }
              fetched
            rescue StandardError => e
              slot = (@cache[url_str] ||= {})
              slot[:last_miss_at] = current_time
              raise e
            end
          end
        end

        def fetch_remote(url)
          response = Net::HTTP.get_response(url)
          raise AuthError.invalid_credentials unless response.is_a?(Net::HTTPSuccess)

          parsed = JSON.parse(response.body)
          raise AuthError.invalid_credentials unless parsed.is_a?(Hash) && parsed["keys"].is_a?(Array)

          parsed
        end

        def ttl_expired?(fetched_at, now)
          (now - fetched_at) >= CACHE_TTL_SECONDS
        end

        def cooldown_expired?(last_miss_at, now)
          (now - last_miss_at) >= MISS_COOLDOWN_SECONDS
        end

        def current_time
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end
    end
  end
end
