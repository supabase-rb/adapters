# frozen_string_literal: true

require "spec_helper"
require "jwt"
require "json"
require "net/http"
require "openssl"
require "uri"
require "supabase/server/rails"

RSpec.describe "Thread safety (NFR-1)" do
  THREAD_COUNT = 16

  def valid_env(overrides = {})
    Supabase::Server::SupabaseEnv.new(
      url: "https://test.supabase.co",
      publishable_keys: { "default" => "sb_publishable_xyz" },
      secret_keys: { "default" => "sb_secret_xyz" },
      jwks: nil,
      **overrides
    )
  end

  around do |example|
    cleared = {
      "SUPABASE_URL" => nil,
      "SUPABASE_PUBLISHABLE_KEY" => nil,
      "SUPABASE_PUBLISHABLE_KEYS" => nil,
      "SUPABASE_SECRET_KEY" => nil,
      "SUPABASE_SECRET_KEYS" => nil,
      "SUPABASE_JWKS" => nil,
      "SUPABASE_JWKS_URL" => nil
    }
    with_env(cleared) { example.run }
  end

  def run_concurrently(count)
    barrier = Mutex.new
    cv = ConditionVariable.new
    ready = 0
    go = false

    threads = Array.new(count) do |i|
      Thread.new do
        barrier.synchronize do
          ready += 1
          cv.broadcast if ready == count
          cv.wait(barrier) until go
        end
        yield(i)
      end
    end

    barrier.synchronize do
      cv.wait(barrier) until ready == count
      go = true
      cv.broadcast
    end

    threads.map(&:value)
  end

  describe "no mutable class-level state in request path" do
    it "Env, Core, CORS, and Server expose zero instance variables" do
      [Supabase::Server::Env, Supabase::Server::Core, Supabase::Server::CORS, Supabase::Server].each do |mod|
        expect(mod.instance_variables).to(
          be_empty,
          "expected #{mod} to have no module-level instance variables (request-path modules must be stateless), got #{mod.instance_variables.inspect}"
        )
      end
    end

    it "Supabase::Server::JWT only owns the cache mutex + cache hash" do
      expect(Supabase::Server::JWT.instance_variables).to contain_exactly(:@cache_mutex, :@cache)
      expect(Supabase::Server::JWT.instance_variable_get(:@cache_mutex)).to be_a(Mutex)
      expect(Supabase::Server::JWT.instance_variable_get(:@cache)).to be_a(Hash)
    end

    it "Supabase::Server::Logging owns only the logger mutex + logger ref" do
      expect(Supabase::Server::Logging.instance_variables).to contain_exactly(:@mutex, :@logger)
      expect(Supabase::Server::Logging.instance_variable_get(:@mutex)).to be_a(Mutex)
    end
  end

  describe "JWKS cache" do
    before(:context) do
      @rsa_private = OpenSSL::PKey::RSA.generate(2048)
      jwk = ::JWT::JWK.new(@rsa_private.public_key)
      @kid = jwk.kid
      @jwks = { "keys" => [jwk.export] }
    end

    before(:each) { Supabase::Server::JWT._reset_cache! }

    def make_token(sub: "user-123")
      ::JWT.encode(
        { sub: sub, role: "authenticated", exp: Time.now.to_i + 3600 },
        @rsa_private, "RS256", { kid: @kid }
      )
    end

    it "serializes concurrent fetches behind the mutex (single network call)" do
      jwks_url = URI("https://jwks-concurrent.example/jwks.json")
      fetch_count = 0
      fetch_lock = Mutex.new
      jwks_body = JSON.generate(@jwks)

      allow(Net::HTTP).to receive(:get_response).with(jwks_url) do
        fetch_lock.synchronize { fetch_count += 1 }
        # Simulate slow network so threads queue on the mutex.
        sleep 0.05
        response = instance_double(Net::HTTPOK, body: jwks_body)
        allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
        response
      end

      env = valid_env(jwks: jwks_url)
      results = run_concurrently(THREAD_COUNT) do
        Supabase::Server::JWT.verify(make_token, env: env)
      end

      expect(results.map { |r| r[:user_claims].id }).to all(eq("user-123"))
      expect(fetch_count).to eq(1)
    end

    it "isolates cache entries per URL across concurrent threads" do
      url_a = URI("https://jwks-a.example/jwks.json")
      url_b = URI("https://jwks-b.example/jwks.json")

      other_rsa = OpenSSL::PKey::RSA.generate(2048)
      other_jwk = ::JWT::JWK.new(other_rsa.public_key)
      jwks_b = { "keys" => [other_jwk.export] }

      response_a = instance_double(Net::HTTPOK, body: JSON.generate(@jwks))
      response_b = instance_double(Net::HTTPOK, body: JSON.generate(jwks_b))
      allow(response_a).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(response_b).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(Net::HTTP).to receive(:get_response).with(url_a).and_return(response_a)
      allow(Net::HTTP).to receive(:get_response).with(url_b).and_return(response_b)

      token_a = make_token(sub: "user-a")
      token_b = ::JWT.encode(
        { sub: "user-b", exp: Time.now.to_i + 3600 },
        other_rsa, "RS256", { kid: other_jwk.kid }
      )

      results = run_concurrently(THREAD_COUNT) do |i|
        if i.even?
          Supabase::Server::JWT.verify(token_a, env: valid_env(jwks: url_a))
        else
          Supabase::Server::JWT.verify(token_b, env: valid_env(jwks: url_b))
        end
      end

      results.each_with_index do |r, i|
        expected = i.even? ? "user-a" : "user-b"
        expect(r[:user_claims].id).to eq(expected)
      end
    end
  end

  describe "per-request context isolation" do
    before(:context) do
      @rsa_private = OpenSSL::PKey::RSA.generate(2048)
      jwk = ::JWT::JWK.new(@rsa_private.public_key)
      @kid = jwk.kid
      @jwks = { "keys" => [jwk.export] }
    end

    before(:each) { Supabase::Server::JWT._reset_cache! }

    def token_for(sub)
      ::JWT.encode(
        { sub: sub, role: "authenticated", exp: Time.now.to_i + 3600 },
        @rsa_private, "RS256", { kid: @kid }
      )
    end

    it "returns the right user_claims for each concurrent create_context call" do
      env = valid_env(jwks: @jwks)

      results = run_concurrently(THREAD_COUNT) do |i|
        sub = "user-#{i}"
        request = { "Authorization" => "Bearer #{token_for(sub)}" }
        ctx, err = Supabase::Server.create_context(request, auth: :user, env: env)
        [sub, ctx, err]
      end

      results.each do |sub, ctx, err|
        expect(err).to be_nil
        expect(ctx).to be_a(Supabase::Server::SupabaseContext)
        expect(ctx.user_claims.id).to eq(sub)
        expect(ctx.jwt_claims["sub"]).to eq(sub)
      end
    end

    it "Rack middleware stores context per-env (no cross-request bleed)" do
      env_obj = valid_env(jwks: @jwks)

      downstream = lambda do |rack_env|
        ctx = rack_env["supabase.context"]
        [200, { "Content-Type" => "text/plain" }, [ctx.user_claims.id]]
      end

      middleware = Supabase::Server::Rails::Middleware.new(
        downstream, auth: :user, env: env_obj, cors: false
      )

      results = run_concurrently(THREAD_COUNT) do |i|
        sub = "user-#{i}"
        rack_env = { "HTTP_AUTHORIZATION" => "Bearer #{token_for(sub)}", "REQUEST_METHOD" => "GET" }
        status, _headers, body = middleware.call(rack_env)
        [sub, status, body.first, rack_env["supabase.context"]]
      end

      results.each do |sub, status, body_id, stashed_ctx|
        expect(status).to eq(200)
        expect(body_id).to eq(sub)
        expect(stashed_ctx.user_claims.id).to eq(sub)
      end
    end
  end
end
