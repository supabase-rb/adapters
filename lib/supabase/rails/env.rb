# frozen_string_literal: true

require "json"
require "uri"

require_relative "errors"

module Supabase
  module Rails
    SupabaseEnv = Data.define(:url, :publishable_keys, :secret_keys, :jwks)

    module Env
      module_function

      def resolve(overrides = {})
        overrides = symbolize_overrides(overrides)

        url = overrides.fetch(:url) { ENV["SUPABASE_URL"] }
        raise EnvError.missing_supabase_url if url.nil? || url.to_s.empty?

        SupabaseEnv.new(
          url: url,
          publishable_keys: overrides[:publishable_keys] || resolve_keys("SUPABASE_PUBLISHABLE_KEY", "SUPABASE_PUBLISHABLE_KEYS"),
          secret_keys: overrides[:secret_keys] || resolve_keys("SUPABASE_SECRET_KEY", "SUPABASE_SECRET_KEYS"),
          jwks: overrides.key?(:jwks) ? overrides[:jwks] : resolve_jwks
        )
      end

      def symbolize_overrides(overrides)
        return {} if overrides.nil?
        overrides.each_with_object({}) { |(k, v), h| h[k.to_sym] = v }
      end

      def resolve_keys(singular_var, plural_var)
        plural = ENV[plural_var]
        return parse_keys(plural) if plural && !plural.empty?

        singular = ENV[singular_var]
        return { "default" => singular } if singular && !singular.empty?

        {}
      end

      def parse_keys(raw)
        return {} if raw.nil? || raw.empty?

        parsed = JSON.parse(raw)
        return {} unless parsed.is_a?(Hash)

        parsed
      rescue JSON::ParserError
        {}
      end

      def resolve_jwks
        raw_jwks = ENV["SUPABASE_JWKS"]
        return parse_jwks(raw_jwks) if raw_jwks && !raw_jwks.strip.empty?

        raw_jwks_url = ENV["SUPABASE_JWKS_URL"]
        return parse_jwks_url(raw_jwks_url) if raw_jwks_url && !raw_jwks_url.strip.empty?

        nil
      end

      def parse_jwks(raw)
        return nil if raw.nil? || raw.empty?

        parsed = JSON.parse(raw)
        return { "keys" => parsed } if parsed.is_a?(Array)
        return parsed if parsed.is_a?(Hash) && parsed["keys"].is_a?(Array)

        nil
      rescue JSON::ParserError
        nil
      end

      def parse_jwks_url(raw)
        return nil if raw.nil?

        trimmed = raw.strip
        return nil if trimmed.empty?

        uri = URI.parse(trimmed)
        return nil if uri.host.nil? || uri.host.empty?

        return uri if uri.scheme == "https"
        return uri if uri.scheme == "http" && loopback_host?(uri.host)

        nil
      rescue URI::InvalidURIError
        nil
      end

      def loopback_host?(hostname)
        return false if hostname.nil?
        return true if hostname == "localhost"
        return true if hostname.end_with?(".localhost")
        return true if hostname == "[::1]" || hostname == "::1"
        return true if /\A127\.\d{1,3}\.\d{1,3}\.\d{1,3}\z/.match?(hostname)

        false
      end
    end
  end
end
