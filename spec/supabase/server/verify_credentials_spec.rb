# frozen_string_literal: true

require "spec_helper"
require "jwt"
require "openssl"

RSpec.describe Supabase::Server::Core, ".verify_credentials" do
  Credentials = Supabase::Server::Credentials unless defined?(Credentials)

  def default_env(overrides = {})
    {
      url: "https://test.supabase.co",
      publishable_keys: { "default" => "sb_publishable_xyz" },
      secret_keys: { "default" => "sb_secret_xyz" },
      jwks: nil
    }.merge(overrides)
  end

  describe "none mode" do
    it "succeeds with no credentials and key_name is nil" do
      creds = Credentials.new(token: nil, apikey: nil)
      result = described_class.verify_credentials(creds, auth: :none, env: default_env)
      expect(result.auth_mode).to eq(:none)
      expect(result.key_name).to be_nil
      expect(result.token).to be_nil
      expect(result.user_claims).to be_nil
      expect(result.jwt_claims).to be_nil
    end

    it "accepts string mode 'none'" do
      creds = Credentials.new(token: nil, apikey: nil)
      result = described_class.verify_credentials(creds, auth: "none", env: default_env)
      expect(result.auth_mode).to eq(:none)
    end
  end

  describe "publishable mode" do
    it "succeeds with valid publishable key and returns default key_name" do
      creds = Credentials.new(token: nil, apikey: "sb_publishable_xyz")
      result = described_class.verify_credentials(creds, auth: :publishable, env: default_env)
      expect(result.auth_mode).to eq(:publishable)
      expect(result.key_name).to eq("default")
    end

    it "raises InvalidCredentials with invalid key" do
      creds = Credentials.new(token: nil, apikey: "wrong_key")
      expect {
        described_class.verify_credentials(creds, auth: :publishable, env: default_env)
      }.to raise_error(Supabase::Server::AuthError) do |err|
        expect(err.code).to eq(Supabase::Server::AuthError::INVALID_CREDENTIALS)
      end
    end

    it "only matches default key when bare publishable is used" do
      env = default_env(publishable_keys: {
        "default" => "sb_publishable_default",
        "web" => "sb_publishable_web"
      })
      creds = Credentials.new(token: nil, apikey: "sb_publishable_web")
      expect {
        described_class.verify_credentials(creds, auth: :publishable, env: env)
      }.to raise_error(Supabase::Server::AuthError)
    end

    it "matches named key with colon syntax and returns key_name" do
      env = default_env(publishable_keys: {
        "web" => "sb_publishable_web",
        "mobile" => "sb_publishable_mobile"
      })
      creds = Credentials.new(token: nil, apikey: "sb_publishable_web")
      result = described_class.verify_credentials(creds, auth: "publishable:web", env: env)
      expect(result.key_name).to eq("web")
    end

    it "rejects wrong named key" do
      env = default_env(publishable_keys: {
        "web" => "sb_publishable_web",
        "mobile" => "sb_publishable_mobile"
      })
      creds = Credentials.new(token: nil, apikey: "sb_publishable_mobile")
      expect {
        described_class.verify_credentials(creds, auth: "publishable:web", env: env)
      }.to raise_error(Supabase::Server::AuthError)
    end

    it "rejects wrong key type (publishable key against secret mode)" do
      env = default_env(publishable_keys: {
        "web" => "sb_publishable_web"
      }, secret_keys: { "web" => "sb_secret_web" })
      creds = Credentials.new(token: nil, apikey: "sb_publishable_web")
      expect {
        described_class.verify_credentials(creds, auth: "secret:web", env: env)
      }.to raise_error(Supabase::Server::AuthError)
    end

    it "matches any key with wildcard syntax" do
      env = default_env(publishable_keys: {
        "web" => "sb_publishable_web",
        "mobile" => "sb_publishable_mobile"
      })
      creds = Credentials.new(token: nil, apikey: "sb_publishable_mobile")
      result = described_class.verify_credentials(creds, auth: "publishable:*", env: env)
      expect(result.auth_mode).to eq(:publishable)
      expect(result.key_name).to eq("mobile")
    end

    it "wildcard returns correct key_name for non-first key" do
      env = default_env(publishable_keys: {
        "default" => "sb_publishable_default",
        "web" => "sb_publishable_web",
        "mobile" => "sb_publishable_mobile"
      })
      creds = Credentials.new(token: nil, apikey: "sb_publishable_mobile")
      result = described_class.verify_credentials(creds, auth: "publishable:*", env: env)
      expect(result.key_name).to eq("mobile")
    end
  end

  describe "secret mode" do
    it "succeeds with valid secret key and returns default key_name" do
      creds = Credentials.new(token: nil, apikey: "sb_secret_xyz")
      result = described_class.verify_credentials(creds, auth: :secret, env: default_env)
      expect(result.auth_mode).to eq(:secret)
      expect(result.key_name).to eq("default")
    end

    it "raises with invalid secret key" do
      creds = Credentials.new(token: nil, apikey: "wrong_secret")
      expect {
        described_class.verify_credentials(creds, auth: :secret, env: default_env)
      }.to raise_error(Supabase::Server::AuthError)
    end

    it "only matches default key when bare secret is used" do
      env = default_env(secret_keys: {
        "default" => "sb_secret_default",
        "web" => "sb_secret_web"
      })
      creds = Credentials.new(token: nil, apikey: "sb_secret_web")
      expect {
        described_class.verify_credentials(creds, auth: :secret, env: env)
      }.to raise_error(Supabase::Server::AuthError)
    end

    it "matches secret wildcard and returns key_name" do
      env = default_env(secret_keys: {
        "default" => "sb_secret_default",
        "mobile" => "sb_secret_mobile"
      })
      creds = Credentials.new(token: nil, apikey: "sb_secret_mobile")
      result = described_class.verify_credentials(creds, auth: "secret:*", env: env)
      expect(result.key_name).to eq("mobile")
    end
  end

  describe "user mode (inline JWKS)" do
    before(:context) do
      @rsa_private = OpenSSL::PKey::RSA.generate(2048)
      jwk = JWT::JWK.new(@rsa_private.public_key)
      @kid = jwk.kid
      @jwks = { "keys" => [jwk.export] }
      @valid_token = JWT.encode(
        {
          sub: "user-123",
          role: "authenticated",
          email: "test@example.com",
          app_metadata: { "provider" => "email" },
          user_metadata: { "preferred_name" => "tester" },
          iat: Time.now.to_i,
          exp: Time.now.to_i + 3600
        },
        @rsa_private,
        "RS256",
        { kid: @kid }
      )
    end

    it "succeeds with valid JWT and returns user_claims" do
      creds = Credentials.new(token: @valid_token, apikey: nil)
      result = described_class.verify_credentials(creds, auth: :user, env: default_env(jwks: @jwks))
      expect(result.auth_mode).to eq(:user)
      expect(result.key_name).to be_nil
      expect(result.token).to eq(@valid_token)
      expect(result.user_claims.id).to eq("user-123")
      expect(result.user_claims.email).to eq("test@example.com")
      expect(result.user_claims.role).to eq("authenticated")
      expect(result.user_claims.app_metadata).to eq("provider" => "email")
      expect(result.user_claims.user_metadata).to eq("preferred_name" => "tester")
      expect(result.jwt_claims["sub"]).to eq("user-123")
    end

    it "raises with invalid JWT" do
      creds = Credentials.new(token: "invalid.jwt.token", apikey: nil)
      expect {
        described_class.verify_credentials(creds, auth: :user, env: default_env(jwks: @jwks))
      }.to raise_error(Supabase::Server::AuthError) do |err|
        expect(err.code).to eq(Supabase::Server::AuthError::INVALID_CREDENTIALS)
      end
    end

    it "raises with no token" do
      creds = Credentials.new(token: nil, apikey: nil)
      expect {
        described_class.verify_credentials(creds, auth: :user, env: default_env(jwks: @jwks))
      }.to raise_error(Supabase::Server::AuthError) do |err|
        expect(err.code).to eq(Supabase::Server::AuthError::INVALID_CREDENTIALS)
      end
    end

    it "raises with expired JWT" do
      expired_token = JWT.encode(
        { sub: "user-123", iat: Time.now.to_i - 7200, exp: Time.now.to_i - 3600 },
        @rsa_private,
        "RS256",
        { kid: @kid }
      )
      creds = Credentials.new(token: expired_token, apikey: nil)
      expect {
        described_class.verify_credentials(creds, auth: :user, env: default_env(jwks: @jwks))
      }.to raise_error(Supabase::Server::AuthError)
    end

    it "raises AuthError with status 500 when JWKS is not configured" do
      creds = Credentials.new(token: @valid_token, apikey: nil)
      expect {
        described_class.verify_credentials(creds, auth: :user, env: default_env(jwks: nil))
      }.to raise_error(Supabase::Server::AuthError) do |err|
        expect(err.status).to eq(500)
      end
    end

    it "rejects JWT with missing sub claim" do
      no_sub_token = JWT.encode(
        { role: "authenticated", exp: Time.now.to_i + 3600 },
        @rsa_private,
        "RS256",
        { kid: @kid }
      )
      creds = Credentials.new(token: no_sub_token, apikey: nil)
      expect {
        described_class.verify_credentials(creds, auth: :user, env: default_env(jwks: @jwks))
      }.to raise_error(Supabase::Server::AuthError)
    end
  end

  describe "parse_auth_mode edge cases" do
    it "treats trailing colon as bare mode (default key)" do
      creds = Credentials.new(token: nil, apikey: "sb_publishable_xyz")
      result = described_class.verify_credentials(creds, auth: "publishable:", env: default_env)
      expect(result.auth_mode).to eq(:publishable)
      expect(result.key_name).to eq("default")
    end

    it "treats multiple colons as part of key name" do
      env = default_env(publishable_keys: { "key:extra" => "sb_publishable_colon" })
      creds = Credentials.new(token: nil, apikey: "sb_publishable_colon")
      result = described_class.verify_credentials(creds, auth: "publishable:key:extra", env: env)
      expect(result.auth_mode).to eq(:publishable)
      expect(result.key_name).to eq("key:extra")
    end

    it "fails wildcard with empty key object" do
      env = default_env(publishable_keys: {})
      creds = Credentials.new(token: nil, apikey: "sb_publishable_xyz")
      expect {
        described_class.verify_credentials(creds, auth: "publishable:*", env: env)
      }.to raise_error(Supabase::Server::AuthError)
    end
  end

  describe "array auth (first match wins)" do
    it "matches second mode when first fails and returns its key_name" do
      creds = Credentials.new(token: nil, apikey: "sb_publishable_xyz")
      result = described_class.verify_credentials(creds, auth: [:secret, :publishable], env: default_env)
      expect(result.auth_mode).to eq(:publishable)
      expect(result.key_name).to eq("default")
    end

    it "matches first mode when it succeeds" do
      creds = Credentials.new(token: nil, apikey: nil)
      result = described_class.verify_credentials(creds, auth: [:none, :publishable], env: default_env)
      expect(result.auth_mode).to eq(:none)
    end
  end

  describe "invalid credential rejection (no silent fallthrough)" do
    before(:context) do
      rsa = OpenSSL::PKey::RSA.generate(2048)
      jwk = JWT::JWK.new(rsa.public_key)
      @jwks2 = { "keys" => [jwk.export] }
      @rsa2 = rsa
      @kid2 = jwk.kid
    end

    it "rejects invalid JWT instead of falling through to none mode" do
      creds = Credentials.new(token: "garbage.jwt.token", apikey: nil)
      expect {
        described_class.verify_credentials(creds, auth: [:user, :none], env: default_env(jwks: @jwks2))
      }.to raise_error(Supabase::Server::AuthError) do |err|
        expect(err.code).to eq(Supabase::Server::AuthError::INVALID_CREDENTIALS)
      end
    end

    it "rejects expired JWT instead of falling through to none mode" do
      expired_token = JWT.encode(
        { sub: "user-123", iat: Time.now.to_i - 7200, exp: Time.now.to_i - 3600 },
        @rsa2, "RS256", { kid: @kid2 }
      )
      creds = Credentials.new(token: expired_token, apikey: nil)
      expect {
        described_class.verify_credentials(creds, auth: [:user, :none], env: default_env(jwks: @jwks2))
      }.to raise_error(Supabase::Server::AuthError)
    end

    it "falls through to none when no token is present" do
      creds = Credentials.new(token: nil, apikey: nil)
      result = described_class.verify_credentials(creds, auth: [:user, :none], env: default_env(jwks: @jwks2))
      expect(result.auth_mode).to eq(:none)
    end

    it "rejects invalid JWT even when publishable mode follows" do
      creds = Credentials.new(token: "garbage.jwt.token", apikey: "sb_publishable_xyz")
      expect {
        described_class.verify_credentials(creds, auth: [:user, :publishable], env: default_env(jwks: @jwks2))
      }.to raise_error(Supabase::Server::AuthError)
    end

    it "rejects invalid JWT instead of falling through to secret mode" do
      creds = Credentials.new(token: "garbage.jwt.token", apikey: "sb_secret_xyz")
      expect {
        described_class.verify_credentials(creds, auth: [:user, :secret], env: default_env(jwks: @jwks2))
      }.to raise_error(Supabase::Server::AuthError)
    end

    it "falls through to secret when Authorization carries an sb_ secret" do
      creds = Credentials.new(token: "sb_secret_xyz", apikey: "sb_secret_xyz")
      result = described_class.verify_credentials(creds, auth: [:user, :secret], env: default_env(jwks: @jwks2))
      expect(result.auth_mode).to eq(:secret)
      expect(result.key_name).to eq("default")
    end

    it "falls through to publishable when Authorization carries an sb_ publishable key" do
      creds = Credentials.new(token: "sb_publishable_xyz", apikey: "sb_publishable_xyz")
      result = described_class.verify_credentials(creds, auth: [:user, :publishable], env: default_env(jwks: @jwks2))
      expect(result.auth_mode).to eq(:publishable)
      expect(result.key_name).to eq("default")
    end
  end

  describe "defaults" do
    it "defaults to :user when auth is not provided" do
      creds = Credentials.new(token: nil, apikey: nil)
      expect {
        described_class.verify_credentials(creds, env: default_env)
      }.to raise_error(Supabase::Server::AuthError) do |err|
        expect(err.code).to eq(Supabase::Server::AuthError::INVALID_CREDENTIALS)
      end
    end
  end

  describe "constant-time comparison" do
    it "uses OpenSSL.fixed_length_secure_compare for apikey match" do
      expect(OpenSSL).to receive(:fixed_length_secure_compare).at_least(:once).and_call_original
      creds = Credentials.new(token: nil, apikey: "sb_publishable_xyz")
      described_class.verify_credentials(creds, auth: :publishable, env: default_env)
    end

    it "returns false (no match) when key lengths differ instead of raising" do
      env = default_env(publishable_keys: { "default" => "sb_publishable_xyz" })
      creds = Credentials.new(token: nil, apikey: "short")
      expect {
        described_class.verify_credentials(creds, auth: :publishable, env: env)
      }.to raise_error(Supabase::Server::AuthError)
    end
  end
end
