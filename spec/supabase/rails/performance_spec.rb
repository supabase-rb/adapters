# frozen_string_literal: true

require "spec_helper"
require "jwt"
require "json"
require "net/http"
require "openssl"
require "uri"

# Performance budget from PRD § 6 NFR-2:
#   - Hot-path (JWKS cached, JWT valid): < 2 ms verification overhead.
#   - Cold-path (first request, JWKS fetch needed): < 50 ms overhead vs. a raw Supabase call.
#
# The targets are stated for a "2024-vintage laptop." `PERF_SAFETY_MULTIPLIER`
# (default 5) widens the assertion to absorb CI/older-hardware variance without
# letting the spec become a no-op. Override via env when running on the
# spec-target hardware (`PERF_SAFETY_MULTIPLIER=1`).
RSpec.describe "Performance budget (NFR-2)" do
  HOT_PATH_BUDGET_MS = 2.0
  COLD_PATH_OVERHEAD_BUDGET_MS = 50.0
  SAFETY_MULTIPLIER = Float(ENV.fetch("PERF_SAFETY_MULTIPLIER", 5))
  ITERATIONS = 200
  WARMUP = 20

  def measure_ms
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000.0
  end

  def median(samples)
    sorted = samples.sort
    n = sorted.length
    n.odd? ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
  end

  def valid_env(jwks)
    Supabase::Rails::SupabaseEnv.new(
      url: "https://test.supabase.co",
      publishable_keys: { "default" => "sb_publishable_xyz" },
      secret_keys: { "default" => "sb_secret_xyz" },
      jwks: jwks
    )
  end

  before(:context) do
    @rsa = OpenSSL::PKey::RSA.generate(2048)
    jwk = ::JWT::JWK.new(@rsa.public_key)
    @kid = jwk.kid
    @jwks = { "keys" => [jwk.export] }
    @token = ::JWT.encode(
      { sub: "user-perf", role: "authenticated", exp: Time.now.to_i + 3600 },
      @rsa, "RS256", { kid: @kid }
    )
  end

  describe "hot-path JWT verification" do
    it "verifies a token against an in-memory JWKS in under the budget (median)" do
      env = valid_env(@jwks)

      WARMUP.times { Supabase::Rails::JWT.verify(@token, env: env) }

      samples = Array.new(ITERATIONS) do
        measure_ms { Supabase::Rails::JWT.verify(@token, env: env) }
      end

      med = median(samples)
      budget = HOT_PATH_BUDGET_MS * SAFETY_MULTIPLIER

      expect(med).to be < budget,
                     "hot-path verify median was #{med.round(3)}ms; " \
                     "budget #{HOT_PATH_BUDGET_MS}ms × safety #{SAFETY_MULTIPLIER} = #{budget}ms"
    end

    it "verifies repeatedly against a cached remote JWKS in under the budget (median)" do
      jwks_url = URI("https://jwks-hot.example/jwks.json")
      jwks_body = JSON.generate(@jwks)
      response = instance_double(Net::HTTPOK, body: jwks_body)
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(Net::HTTP).to receive(:get_response).with(jwks_url).and_return(response)

      Supabase::Rails::JWT._reset_cache!
      env = valid_env(jwks_url)

      # Prime the cache + warm up.
      (WARMUP + 1).times { Supabase::Rails::JWT.verify(@token, env: env) }

      samples = Array.new(ITERATIONS) do
        measure_ms { Supabase::Rails::JWT.verify(@token, env: env) }
      end

      med = median(samples)
      budget = HOT_PATH_BUDGET_MS * SAFETY_MULTIPLIER

      expect(med).to be < budget,
                     "hot-path verify (remote JWKS, cached) median was #{med.round(3)}ms; " \
                     "budget #{HOT_PATH_BUDGET_MS}ms × safety #{SAFETY_MULTIPLIER} = #{budget}ms"

      # Sanity: cache was actually hot — exactly one fetch happened.
      expect(Net::HTTP).to have_received(:get_response).with(jwks_url).once
    end
  end

  describe "cold-path create_context overhead" do
    it "stays within the budget compared to a raw Supabase::Client.new (median)" do
      jwks_url = URI("https://jwks-cold.example/jwks.json")
      jwks_body = JSON.generate(@jwks)

      # The PRD's budget assumes a real network fetch (~tens of ms). We stub
      # Net::HTTP so the measurement isolates the library's own overhead, which
      # is what the budget targets in the cold-path-minus-network sense.
      allow(Net::HTTP).to receive(:get_response).with(jwks_url) do
        response = instance_double(Net::HTTPOK, body: jwks_body)
        allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
        response
      end

      env = valid_env(jwks_url)
      request = { "Authorization" => "Bearer #{@token}" }

      WARMUP.times do
        ::Supabase::Client.new(supabase_url: env.url, supabase_key: "sb_publishable_xyz")
      end
      baseline_samples = Array.new(ITERATIONS) do
        measure_ms do
          ::Supabase::Client.new(supabase_url: env.url, supabase_key: "sb_publishable_xyz")
        end
      end

      WARMUP.times do
        Supabase::Rails::JWT._reset_cache!
        Supabase::Rails.create_context(request, auth: :user, env: env)
      end
      cold_samples = Array.new(ITERATIONS) do
        Supabase::Rails::JWT._reset_cache!
        measure_ms { Supabase::Rails.create_context(request, auth: :user, env: env) }
      end

      baseline_med = median(baseline_samples)
      cold_med = median(cold_samples)
      overhead = cold_med - baseline_med
      budget = COLD_PATH_OVERHEAD_BUDGET_MS * SAFETY_MULTIPLIER

      expect(overhead).to be < budget,
                          "cold-path overhead was #{overhead.round(3)}ms " \
                          "(create_context #{cold_med.round(3)}ms vs raw client #{baseline_med.round(3)}ms); " \
                          "budget #{COLD_PATH_OVERHEAD_BUDGET_MS}ms × safety #{SAFETY_MULTIPLIER} = #{budget}ms"
    end
  end
end
