# frozen_string_literal: true

require "spec_helper"
require "jwt"
require "openssl"
require "uri"
require "net/http"

RSpec.describe Supabase::Rails::JWT, ".verify" do
  SupabaseEnv = Supabase::Rails::SupabaseEnv unless defined?(SupabaseEnv)

  def env_with(jwks)
    SupabaseEnv.new(
      url: "https://test.supabase.co",
      publishable_keys: { "default" => "sb_publishable_xyz" },
      secret_keys: { "default" => "sb_secret_xyz" },
      jwks: jwks
    )
  end

  before(:context) do
    @rsa_private = OpenSSL::PKey::RSA.generate(2048)
    jwk = ::JWT::JWK.new(@rsa_private.public_key)
    @kid = jwk.kid
    @jwks = { "keys" => [jwk.export] }
  end

  def make_token(payload_overrides = {}, signing_key: @rsa_private, kid: @kid)
    payload = {
      sub: "user-123",
      role: "authenticated",
      email: "test@example.com",
      app_metadata: { "provider" => "email" },
      user_metadata: { "preferred_name" => "tester" },
      iat: Time.now.to_i,
      exp: Time.now.to_i + 3600
    }.merge(payload_overrides)
    ::JWT.encode(payload, signing_key, "RS256", { kid: kid })
  end

  before(:each) { described_class._reset_cache! }

  describe "inline JWKS" do
    it "returns user_claims and jwt_claims for a valid token" do
      token = make_token
      result = described_class.verify(token, env: env_with(@jwks))

      expect(result[:jwt_claims]["sub"]).to eq("user-123")
      expect(result[:user_claims].id).to eq("user-123")
      expect(result[:user_claims].role).to eq("authenticated")
      expect(result[:user_claims].email).to eq("test@example.com")
      expect(result[:user_claims].app_metadata).to eq("provider" => "email")
      expect(result[:user_claims].user_metadata).to eq("preferred_name" => "tester")
    end

    it "raises invalid credentials for a malformed token" do
      expect {
        described_class.verify("not.a.real.jwt", env: env_with(@jwks))
      }.to raise_error(Supabase::Rails::AuthError) do |err|
        expect(err.code).to eq(Supabase::Rails::AuthError::INVALID_CREDENTIALS)
        expect(err.status).to eq(401)
      end
    end

    it "raises invalid credentials for an expired token" do
      expired = ::JWT.encode(
        { sub: "user-123", iat: Time.now.to_i - 7200, exp: Time.now.to_i - 3600 },
        @rsa_private, "RS256", { kid: @kid }
      )
      expect {
        described_class.verify(expired, env: env_with(@jwks))
      }.to raise_error(Supabase::Rails::AuthError)
    end

    it "raises invalid credentials when sub is missing" do
      no_sub = ::JWT.encode(
        { role: "authenticated", exp: Time.now.to_i + 3600 },
        @rsa_private, "RS256", { kid: @kid }
      )
      expect {
        described_class.verify(no_sub, env: env_with(@jwks))
      }.to raise_error(Supabase::Rails::AuthError)
    end

    it "raises invalid credentials when token was signed by a different key" do
      other_rsa = OpenSSL::PKey::RSA.generate(2048)
      foreign = ::JWT.encode(
        { sub: "user-x", exp: Time.now.to_i + 3600 },
        other_rsa, "RS256", { kid: @kid }
      )
      expect {
        described_class.verify(foreign, env: env_with(@jwks))
      }.to raise_error(Supabase::Rails::AuthError)
    end

    it "applies 30s leeway when validating exp" do
      slightly_expired = ::JWT.encode(
        { sub: "user-123", iat: Time.now.to_i - 60, exp: Time.now.to_i - 10 },
        @rsa_private, "RS256", { kid: @kid }
      )
      result = described_class.verify(slightly_expired, env: env_with(@jwks))
      expect(result[:user_claims].id).to eq("user-123")
    end

    it "raises invalid credentials for nil token" do
      expect {
        described_class.verify(nil, env: env_with(@jwks))
      }.to raise_error(Supabase::Rails::AuthError) do |err|
        expect(err.code).to eq(Supabase::Rails::AuthError::INVALID_CREDENTIALS)
      end
    end

    it "raises invalid credentials for empty token" do
      expect {
        described_class.verify("", env: env_with(@jwks))
      }.to raise_error(Supabase::Rails::AuthError)
    end
  end

  describe "missing JWKS" do
    it "raises AuthError with status 500 when env.jwks is nil" do
      token = make_token
      expect {
        described_class.verify(token, env: env_with(nil))
      }.to raise_error(Supabase::Rails::AuthError) do |err|
        expect(err.status).to eq(500)
      end
    end
  end

  describe "remote JWKS" do
    before(:each) do
      @jwks_url = URI("https://jwks-test.example/jwks.json")
      @ok_response = instance_double(Net::HTTPOK, body: JSON.generate(@jwks), is_a?: false)
      allow(@ok_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
    end

    it "fetches keys from the URL and verifies a valid JWT" do
      allow(Net::HTTP).to receive(:get_response).with(@jwks_url).and_return(@ok_response)

      token = make_token
      result = described_class.verify(token, env: env_with(@jwks_url))

      expect(result[:user_claims].id).to eq("user-123")
      expect(Net::HTTP).to have_received(:get_response).once
    end

    it "reuses cached JWKS for repeat calls within TTL" do
      allow(Net::HTTP).to receive(:get_response).with(@jwks_url).and_return(@ok_response)

      token = make_token
      described_class.verify(token, env: env_with(@jwks_url))
      described_class.verify(token, env: env_with(@jwks_url))
      described_class.verify(token, env: env_with(@jwks_url))

      expect(Net::HTTP).to have_received(:get_response).once
    end

    it "refetches per distinct URL" do
      other_url = URI("https://jwks-other.example/jwks.json")
      other_rsa = OpenSSL::PKey::RSA.generate(2048)
      other_jwk = ::JWT::JWK.new(other_rsa.public_key)
      other_jwks = { "keys" => [other_jwk.export] }
      other_response = instance_double(Net::HTTPOK, body: JSON.generate(other_jwks))
      allow(other_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)

      allow(Net::HTTP).to receive(:get_response).with(@jwks_url).and_return(@ok_response)
      allow(Net::HTTP).to receive(:get_response).with(other_url).and_return(other_response)

      token_a = make_token
      token_b = ::JWT.encode(
        { sub: "user-b", exp: Time.now.to_i + 3600 },
        other_rsa, "RS256", { kid: other_jwk.kid }
      )

      a = described_class.verify(token_a, env: env_with(@jwks_url))
      b = described_class.verify(token_b, env: env_with(other_url))

      expect(a[:user_claims].id).to eq("user-123")
      expect(b[:user_claims].id).to eq("user-b")
      expect(Net::HTTP).to have_received(:get_response).twice
    end

    it "raises invalid credentials when the endpoint returns non-2xx" do
      error_response = instance_double(Net::HTTPInternalServerError, body: "boom")
      allow(error_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
      allow(Net::HTTP).to receive(:get_response).with(@jwks_url).and_return(error_response)

      token = make_token
      expect {
        described_class.verify(token, env: env_with(@jwks_url))
      }.to raise_error(Supabase::Rails::AuthError) do |err|
        expect(err.code).to eq(Supabase::Rails::AuthError::INVALID_CREDENTIALS)
      end
    end

    it "raises invalid credentials when the body is not valid JWKS shape" do
      bad_response = instance_double(Net::HTTPOK, body: '{"unexpected":true}')
      allow(bad_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(Net::HTTP).to receive(:get_response).with(@jwks_url).and_return(bad_response)

      token = make_token
      expect {
        described_class.verify(token, env: env_with(@jwks_url))
      }.to raise_error(Supabase::Rails::AuthError)
    end

    it "applies a cooldown after a fetch failure (does not re-fetch immediately)" do
      error_response = instance_double(Net::HTTPInternalServerError)
      allow(error_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
      allow(Net::HTTP).to receive(:get_response).with(@jwks_url).and_return(error_response)

      token = make_token
      2.times do
        expect {
          described_class.verify(token, env: env_with(@jwks_url))
        }.to raise_error(Supabase::Rails::AuthError)
      end

      # First call hits the network; the second is short-circuited by the cooldown.
      expect(Net::HTTP).to have_received(:get_response).once
    end

    it "raises invalid credentials when the HTTP call itself blows up" do
      allow(Net::HTTP).to receive(:get_response).with(@jwks_url).and_raise(SocketError.new("dns fail"))

      token = make_token
      expect {
        described_class.verify(token, env: env_with(@jwks_url))
      }.to raise_error(Supabase::Rails::AuthError) do |err|
        expect(err.code).to eq(Supabase::Rails::AuthError::INVALID_CREDENTIALS)
      end
    end
  end

  describe "unsupported JWKS source" do
    it "raises invalid credentials when env.jwks is not a Hash or URI" do
      token = make_token
      expect {
        described_class.verify(token, env: env_with("not a jwks"))
      }.to raise_error(Supabase::Rails::AuthError)
    end
  end
end
