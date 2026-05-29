# frozen_string_literal: true

require "spec_helper"

RSpec.describe Supabase::Rails::Core, ".create_admin_client" do
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

  it "returns a Supabase::Client when env is valid" do
    client = described_class.create_admin_client(env: valid_env)

    expect(client).to be_a(::Supabase::Client)
    expect(client.supabase_key).to eq("sb_secret_xyz")
  end

  it "raises EnvError when SUPABASE_URL is missing" do
    expect do
      described_class.create_admin_client(
        env: { secret_key: "sb_secret_xyz" }
      )
    end.to raise_error(Supabase::Rails::EnvError) { |e|
      expect(e.code).to eq(Supabase::Rails::EnvError::MISSING_SUPABASE_URL)
    }
  end

  it "raises MISSING_DEFAULT_SECRET_KEY when secret_keys is empty and no key_name given" do
    expect do
      described_class.create_admin_client(env: valid_env(secret_keys: {}))
    end.to raise_error(Supabase::Rails::EnvError) { |e|
      expect(e.code).to eq(Supabase::Rails::EnvError::MISSING_DEFAULT_SECRET_KEY)
    }
  end

  it "uses the named key when key_name is provided" do
    env = valid_env(
      secret_keys: {
        "default" => "sb_secret_default",
        "web" => "sb_secret_web",
        "mobile" => "sb_secret_mobile"
      }
    )
    client = described_class.create_admin_client(
      auth: { key_name: "web" },
      env: env
    )

    expect(client.supabase_key).to eq("sb_secret_web")
  end

  it "raises MISSING_SECRET_KEY when named key does not exist" do
    expect do
      described_class.create_admin_client(
        auth: { key_name: "nonexistent" },
        env: valid_env
      )
    end.to raise_error(Supabase::Rails::EnvError) { |e|
      expect(e.code).to eq(Supabase::Rails::EnvError::MISSING_SECRET_KEY)
    }
  end

  it "falls back to the default key when key_name is nil" do
    env = valid_env(
      secret_keys: {
        "default" => "sb_secret_default",
        "web" => "sb_secret_web"
      }
    )
    client = described_class.create_admin_client(
      auth: { key_name: nil },
      env: env
    )

    expect(client.supabase_key).to eq("sb_secret_default")
  end

  it "raises MISSING_DEFAULT_SECRET_KEY when no \"default\" exists and key_name is nil" do
    env = valid_env(
      secret_keys: {
        "web" => "sb_secret_web",
        "mobile" => "sb_secret_mobile"
      }
    )

    expect do
      described_class.create_admin_client(
        auth: { key_name: nil },
        env: env
      )
    end.to raise_error(Supabase::Rails::EnvError) { |e|
      expect(e.code).to eq(Supabase::Rails::EnvError::MISSING_DEFAULT_SECRET_KEY)
    }
  end

  it "raises EnvError when key_name is nil and secret_keys is empty" do
    expect do
      described_class.create_admin_client(
        auth: { key_name: nil },
        env: valid_env(secret_keys: {})
      )
    end.to raise_error(Supabase::Rails::EnvError) { |e|
      expect(e.code).to eq(Supabase::Rails::EnvError::MISSING_DEFAULT_SECRET_KEY)
    }
  end

  it "accepts custom supabase_options" do
    client = described_class.create_admin_client(
      env: valid_env,
      supabase_options: { db: { schema: "api" } }
    )

    expect(client).to be_a(::Supabase::Client)
  end

  it "never injects the user token into Authorization, even when auth.token is present" do
    client = described_class.create_admin_client(
      auth: { token: "user-jwt" },
      env: valid_env
    )

    expect(client.headers["Authorization"]).to eq("Bearer sb_secret_xyz")
  end

  it "defaults apikey to the secret key" do
    client = described_class.create_admin_client(env: valid_env)

    expect(client.headers["apikey"]).to eq("sb_secret_xyz")
  end

  it "strips user-supplied Authorization and apikey headers (sanitization)" do
    client = described_class.create_admin_client(
      env: valid_env,
      supabase_options: {
        global: {
          headers: {
            "Authorization" => "Bearer attacker-token",
            "apikey" => "attacker-key",
            "X-Tenant" => "acme"
          }
        }
      }
    )

    expect(client.headers["Authorization"]).to eq("Bearer sb_secret_xyz")
    expect(client.headers["apikey"]).to eq("sb_secret_xyz")
    expect(client.headers["X-Tenant"]).to eq("acme")
  end

  it "force-disables session persistence and auto refresh in client options" do
    client = described_class.create_admin_client(env: valid_env)

    auth_opts = client.options[:auth]
    expect(auth_opts[:persist_session]).to eq(false)
    expect(auth_opts[:auto_refresh_token]).to eq(false)
    expect(auth_opts[:detect_session_in_url]).to eq(false)
  end

  it "accepts an AuthResult struct as auth and ignores its token" do
    auth_result = Supabase::Rails::AuthResult.new(
      auth_mode: :user,
      token: "result-token",
      user_claims: nil,
      jwt_claims: nil,
      key_name: nil
    )
    client = described_class.create_admin_client(auth: auth_result, env: valid_env)

    expect(client.headers["Authorization"]).to eq("Bearer sb_secret_xyz")
  end

  it "accepts an AuthResult struct with a key_name" do
    env = valid_env(
      secret_keys: {
        "default" => "sb_secret_default",
        "web" => "sb_secret_web"
      }
    )
    auth_result = Supabase::Rails::AuthResult.new(
      auth_mode: :secret,
      token: nil,
      user_claims: nil,
      jwt_claims: nil,
      key_name: "web"
    )
    client = described_class.create_admin_client(auth: auth_result, env: env)

    expect(client.supabase_key).to eq("sb_secret_web")
  end

  it "accepts string-keyed auth hashes" do
    env = valid_env(
      secret_keys: {
        "default" => "sb_secret_default",
        "web" => "sb_secret_web"
      }
    )
    client = described_class.create_admin_client(
      auth: { "key_name" => "web" },
      env: env
    )

    expect(client.supabase_key).to eq("sb_secret_web")
  end

  it "resolves env via Env.resolve when env is a hash of overrides" do
    with_env(
      "SUPABASE_URL" => "https://from-env.supabase.co",
      "SUPABASE_SECRET_KEY" => "sb_secret_from_env"
    ) do
      client = described_class.create_admin_client
      expect(client.supabase_url).to eq("https://from-env.supabase.co")
      expect(client.supabase_key).to eq("sb_secret_from_env")
    end
  end

  it "does not mutate the caller's supabase_options hash" do
    user_opts = { global: { headers: { "X-Tenant" => "acme" } } }
    original = Marshal.dump(user_opts)
    described_class.create_admin_client(
      env: valid_env,
      supabase_options: user_opts
    )

    expect(Marshal.dump(user_opts)).to eq(original)
  end
end
