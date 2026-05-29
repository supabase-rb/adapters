# frozen_string_literal: true

require "spec_helper"
require "json"
require "supabase/rails"

RSpec.describe Supabase::Rails::Middleware do
  def valid_env(overrides = {})
    Supabase::Rails::SupabaseEnv.new(
      url: "https://test.supabase.co",
      publishable_keys: { "default" => "sb_publishable_xyz" },
      secret_keys: { "default" => "sb_secret_xyz" },
      jwks: nil,
      **overrides
    )
  end

  def rack_env(overrides = {})
    {
      "REQUEST_METHOD" => "GET",
      "PATH_INFO" => "/",
      "rack.input" => StringIO.new
    }.merge(overrides)
  end

  let(:downstream_response) { [200, { "Content-Type" => "text/plain" }, ["ok"]] }
  let(:app) do
    captured = captured_env
    ->(env) { captured << env; downstream_response }
  end
  let(:captured_env) { [] }

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

  describe "successful auth" do
    it "stashes the SupabaseContext in env['supabase.context'] and calls the app" do
      middleware = described_class.new(app, auth: :none, env: valid_env)

      status, _headers, body = middleware.call(rack_env)

      expect(status).to eq(200)
      expect(body).to eq(["ok"])
      expect(captured_env.length).to eq(1)
      ctx = captured_env.first["supabase.context"]
      expect(ctx).to be_a(Supabase::Rails::SupabaseContext)
      expect(ctx.auth_mode).to eq(:none)
    end

    it "extracts credentials from Rack env (HTTP_AUTHORIZATION / HTTP_APIKEY)" do
      middleware = described_class.new(app, auth: :publishable, env: valid_env)

      status, _h, _b = middleware.call(rack_env("HTTP_APIKEY" => "sb_publishable_xyz"))

      expect(status).to eq(200)
      expect(captured_env.first["supabase.context"].auth_mode).to eq(:publishable)
    end

    it "defaults auth to :user" do
      middleware = described_class.new(app, env: valid_env)

      status, _h, body = middleware.call(rack_env)

      expect(status).to eq(401)
      expect(JSON.parse(body.first)["code"]).to eq(
        Supabase::Rails::AuthError::INVALID_CREDENTIALS
      )
    end
  end

  describe "auth failure" do
    it "returns a JSON 401 with code and message when auth: :user has no token" do
      middleware = described_class.new(app, auth: :user, env: valid_env)

      status, headers, body = middleware.call(rack_env)

      expect(status).to eq(401)
      expect(headers["Content-Type"]).to eq("application/json")
      parsed = JSON.parse(body.first)
      expect(parsed["code"]).to eq(Supabase::Rails::AuthError::INVALID_CREDENTIALS)
      expect(parsed["message"]).to be_a(String)
      expect(parsed["message"]).not_to be_empty
      expect(captured_env).to be_empty
    end

    it "uses the AuthError status (500) for client creation failures" do
      bad_env = Supabase::Rails::SupabaseEnv.new(
        url: "https://test.supabase.co",
        publishable_keys: {},
        secret_keys: {},
        jwks: nil
      )
      middleware = described_class.new(app, auth: :none, env: bad_env)

      status, _h, _b = middleware.call(rack_env)

      expect(status).to eq(500)
      expect(captured_env).to be_empty
    end
  end

  describe "skip pattern" do
    it "skips and calls the app when env['supabase.context'] is already set" do
      pre_set_ctx = Object.new
      middleware = described_class.new(app, auth: :user, env: valid_env)

      env = rack_env("supabase.context" => pre_set_ctx)
      status, _h, _b = middleware.call(env)

      expect(status).to eq(200)
      expect(captured_env.first["supabase.context"]).to equal(pre_set_ctx)
    end
  end

  describe "CORS" do
    it "responds to OPTIONS preflight with 204 and default CORS headers" do
      middleware = described_class.new(app, auth: :user, env: valid_env)

      status, headers, body = middleware.call(rack_env("REQUEST_METHOD" => "OPTIONS"))

      expect(status).to eq(204)
      expect(headers["Access-Control-Allow-Origin"]).to eq("*")
      expect(headers["Access-Control-Allow-Headers"]).to include("authorization")
      expect(headers["Access-Control-Allow-Methods"]).to include("GET")
      expect(body).to eq([])
      expect(captured_env).to be_empty
    end

    it "merges CORS headers into the downstream success response" do
      middleware = described_class.new(app, auth: :none, env: valid_env)

      _status, headers, _body = middleware.call(rack_env)

      expect(headers["Access-Control-Allow-Origin"]).to eq("*")
      expect(headers["Content-Type"]).to eq("text/plain")
    end

    it "merges CORS headers into the error response" do
      middleware = described_class.new(app, auth: :user, env: valid_env)

      _status, headers, _body = middleware.call(rack_env)

      expect(headers["Access-Control-Allow-Origin"]).to eq("*")
      expect(headers["Content-Type"]).to eq("application/json")
    end

    it "applies custom CORS headers when configured" do
      middleware = described_class.new(
        app,
        auth: :none,
        env: valid_env,
        cors: { "Access-Control-Allow-Origin" => "https://example.com" }
      )

      _status, headers, _body = middleware.call(rack_env)

      expect(headers["Access-Control-Allow-Origin"]).to eq("https://example.com")
    end

    it "skips CORS handling entirely when cors: false" do
      middleware = described_class.new(app, auth: :none, env: valid_env, cors: false)

      _status, headers, _body = middleware.call(rack_env)

      expect(headers["Access-Control-Allow-Origin"]).to be_nil
    end

    it "does not respond to OPTIONS specially when cors: false" do
      middleware = described_class.new(app, auth: :none, env: valid_env, cors: false)

      status, _h, body = middleware.call(rack_env("REQUEST_METHOD" => "OPTIONS"))

      expect(status).to eq(200)
      expect(body).to eq(["ok"])
    end

    it "does not mutate the downstream headers hash" do
      original = { "Content-Type" => "text/plain" }
      mutating_app = ->(_env) { [200, original, ["ok"]] }
      middleware = described_class.new(mutating_app, auth: :none, env: valid_env)

      middleware.call(rack_env)

      expect(original).to eq({ "Content-Type" => "text/plain" })
    end
  end

  describe "supabase_options forwarding" do
    it "forwards supabase_options to create_context" do
      middleware = described_class.new(
        app,
        auth: :none,
        env: valid_env,
        supabase_options: { db: { schema: "api" } }
      )

      status, _h, _b = middleware.call(rack_env)

      expect(status).to eq(200)
      expect(captured_env.first["supabase.context"].supabase).to be_a(::Supabase::Client)
    end
  end
end
