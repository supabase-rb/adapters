# frozen_string_literal: true

require "spec_helper"

RSpec.describe Supabase::Rails, ".create_context" do
  def valid_env(overrides = {})
    Supabase::Rails::SupabaseEnv.new(
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

  describe "successful auth" do
    it "returns a Result with the SupabaseContext for auth: :none" do
      result = described_class.create_context({}, auth: :none, env: valid_env)

      expect(result).to be_success
      expect(result).not_to be_failure
      expect(result.error).to be_nil
      expect(result.value).to be_a(Supabase::Rails::SupabaseContext)
      expect(result.value.supabase).to be_a(::Supabase::Client)
      expect(result.value.supabase_admin).to be_a(::Supabase::Client)
      expect(result.value.auth_mode).to eq(:none)
      expect(result.value.auth_key_name).to be_nil
    end

    it "returns user_claims and jwt_claims as nil for non-user auth" do
      result = described_class.create_context({}, auth: :none, env: valid_env)

      expect(result.value.user_claims).to be_nil
      expect(result.value.jwt_claims).to be_nil
    end

    it "accepts publishable key auth" do
      result = described_class.create_context(
        { "apikey" => "sb_publishable_xyz" },
        auth: :publishable,
        env: valid_env
      )

      expect(result).to be_success
      expect(result.value.auth_mode).to eq(:publishable)
      expect(result.value.auth_key_name).to eq("default")
      expect(result.value.supabase).to be_a(::Supabase::Client)
      expect(result.value.supabase_admin).to be_a(::Supabase::Client)
    end

    it "accepts publishable named key auth" do
      result = described_class.create_context(
        { "apikey" => "sb_publishable_web" },
        auth: "publishable:web",
        env: valid_env(
          publishable_keys: { "web" => "sb_publishable_web" }
        )
      )

      expect(result).to be_success
      expect(result.value.auth_mode).to eq(:publishable)
      expect(result.value.auth_key_name).to eq("web")
      expect(result.value.supabase.supabase_key).to eq("sb_publishable_web")
    end

    it "accepts secret key auth" do
      result = described_class.create_context(
        { "apikey" => "sb_secret_xyz" },
        auth: :secret,
        env: valid_env
      )

      expect(result).to be_success
      expect(result.value.auth_mode).to eq(:secret)
      expect(result.value.auth_key_name).to eq("default")
    end

    it "accepts secret named key auth and uses the named secret for the admin client" do
      result = described_class.create_context(
        { "apikey" => "sb_secret_web" },
        auth: "secret:web",
        env: valid_env(
          secret_keys: { "web" => "sb_secret_web" }
        )
      )

      expect(result).to be_success
      expect(result.value.auth_mode).to eq(:secret)
      expect(result.value.auth_key_name).to eq("web")
      expect(result.value.supabase_admin.supabase_key).to eq("sb_secret_web")
    end

    it "passes supabase_options through to clients" do
      result = described_class.create_context(
        {},
        auth: :none,
        env: valid_env,
        supabase_options: { db: { schema: "api" } }
      )

      expect(result).to be_success
      expect(result.value.supabase).to be_a(::Supabase::Client)
      expect(result.value.supabase_admin).to be_a(::Supabase::Client)
    end
  end

  describe "failing auth" do
    it "returns a failure Result when auth: :user has no token" do
      result = described_class.create_context({}, auth: :user, env: valid_env)

      expect(result).to be_failure
      expect(result).not_to be_success
      expect(result.value).to be_nil
      expect(result.error).to be_a(Supabase::Rails::AuthError)
      expect(result.error.status).to eq(401)
      expect(result.error.code).to eq(Supabase::Rails::AuthError::INVALID_CREDENTIALS)
    end

    it "defaults to auth: :user when no auth option is provided" do
      result = described_class.create_context({}, env: valid_env)

      expect(result).to be_failure
      expect(result.error.status).to eq(401)
    end

    it "rejects an invalid secret key" do
      result = described_class.create_context(
        { "apikey" => "wrong_key" },
        auth: :secret,
        env: valid_env
      )

      expect(result).to be_failure
      expect(result.error).to be_a(Supabase::Rails::AuthError)
    end
  end

  describe "client creation failures" do
    it "wraps EnvError as AuthError with status 500" do
      result = described_class.create_context(
        {},
        auth: :none,
        env: Supabase::Rails::SupabaseEnv.new(
          url: "https://test.supabase.co",
          publishable_keys: {},
          secret_keys: {},
          jwks: nil
        )
      )

      expect(result).to be_failure
      expect(result.error).to be_a(Supabase::Rails::AuthError)
      expect(result.error.status).to eq(500)
      expect(result.error.code).to eq(
        Supabase::Rails::EnvError::MISSING_DEFAULT_PUBLISHABLE_KEY
      ).or eq(Supabase::Rails::EnvError::MISSING_DEFAULT_SECRET_KEY)
    end
  end

  describe "Result object" do
    let(:result) do
      described_class.create_context({}, auth: :none, env: valid_env)
    end

    it "exposes value and nil error on success" do
      expect(result).to be_success
      expect(result.value).to be_a(Supabase::Rails::SupabaseContext)
      expect(result.error).to be_nil
    end

    it "exposes error and nil value on failure" do
      failed = described_class.create_context({}, auth: :user, env: valid_env)

      expect(failed).to be_failure
      expect(failed.value).to be_nil
      expect(failed.error).to be_a(Supabase::Rails::AuthError)
    end

    it "does not support implicit array destructuring" do
      # Result is not a tuple — callers must use .value / .error explicitly.
      expect(result).not_to respond_to(:to_a)
      expect(result).not_to respond_to(:to_ary)
    end
  end

  describe "request shape" do
    let(:headers_request_class) { Struct.new(:headers) }
    let(:env_request_class) { Struct.new(:env) }

    it "accepts a request object responding to #headers" do
      request = headers_request_class.new({ "apikey" => "sb_publishable_xyz" })

      result = described_class.create_context(request, auth: :publishable, env: valid_env)

      expect(result).to be_success
      expect(result.value.auth_mode).to eq(:publishable)
    end

    it "accepts a Rack-style request object responding to #env" do
      request = env_request_class.new({ "HTTP_APIKEY" => "sb_publishable_xyz" })

      result = described_class.create_context(request, auth: :publishable, env: valid_env)

      expect(result).to be_success
      expect(result.value.auth_mode).to eq(:publishable)
    end

    it "extracts Authorization from a Rack-style request" do
      request = env_request_class.new({ "HTTP_AUTHORIZATION" => "Bearer sb_publishable_xyz" })

      result = described_class.create_context(request, auth: :user, env: valid_env)

      # `sb_*` tokens skip user-mode by design — falls through to invalid_credentials
      expect(result).to be_failure
    end
  end

  describe "client wiring" do
    it "uses the default publishable key for the context client in :secret mode" do
      result = described_class.create_context(
        { "apikey" => "sb_secret_xyz" },
        auth: :secret,
        env: valid_env
      )

      expect(result.value.supabase.supabase_key).to eq("sb_publishable_xyz")
      expect(result.value.supabase_admin.supabase_key).to eq("sb_secret_xyz")
    end

    it "uses the named publishable key for the context client in :publishable mode" do
      env = valid_env(
        publishable_keys: {
          "default" => "sb_publishable_default",
          "web" => "sb_publishable_web"
        }
      )
      result = described_class.create_context(
        { "apikey" => "sb_publishable_web" },
        auth: "publishable:web",
        env: env
      )

      expect(result.value.supabase.supabase_key).to eq("sb_publishable_web")
      expect(result.value.supabase_admin.supabase_key).to eq("sb_secret_xyz")
    end
  end
end
