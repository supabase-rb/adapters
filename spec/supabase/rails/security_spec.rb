# frozen_string_literal: true

require "spec_helper"
require "jwt"
require "openssl"
require "uri"
require "base64"
require "json"

RSpec.describe "NFR-4 Security contract" do
  Credentials = Supabase::Rails::Credentials unless defined?(Credentials)
  SupabaseEnv = Supabase::Rails::SupabaseEnv unless defined?(SupabaseEnv)

  let(:rsa_private) { OpenSSL::PKey::RSA.generate(2048) }
  let(:jwk) { ::JWT::JWK.new(rsa_private.public_key) }
  let(:jwks) { { "keys" => [jwk.export] } }

  def env_with(overrides = {})
    SupabaseEnv.new(
      url: "https://test.supabase.co",
      publishable_keys: { "default" => "sb_publishable_xyz" },
      secret_keys: { "default" => "sb_secret_xyz" },
      jwks: nil,
      **overrides
    )
  end

  before(:each) { Supabase::Rails::JWT._reset_cache! }

  describe "1. All API key comparisons constant-time" do
    it "publishable mode uses Core.secure_compare (constant-time via OpenSSL.fixed_length_secure_compare)" do
      expect(OpenSSL).to receive(:fixed_length_secure_compare).at_least(:once).and_call_original

      creds = Credentials.new(token: nil, apikey: "sb_publishable_xyz")
      result = Supabase::Rails::Core.verify_credentials(
        creds, auth: :publishable, env: env_with
      )
      expect(result.auth_mode).to eq(:publishable)
    end

    it "secret mode uses Core.secure_compare (constant-time via OpenSSL.fixed_length_secure_compare)" do
      expect(OpenSSL).to receive(:fixed_length_secure_compare).at_least(:once).and_call_original

      creds = Credentials.new(token: nil, apikey: "sb_secret_xyz")
      result = Supabase::Rails::Core.verify_credentials(
        creds, auth: :secret, env: env_with
      )
      expect(result.auth_mode).to eq(:secret)
    end

    it "Core.secure_compare returns false for length-mismatched inputs without raising" do
      # OpenSSL.fixed_length_secure_compare raises ArgumentError when sizes differ;
      # the wrapper must pre-check bytesize and return false.
      expect {
        result = Supabase::Rails::Core.secure_compare("abc", "abcdef")
        expect(result).to eq(false)
      }.not_to raise_error
    end

    it "Core.secure_compare delegates to OpenSSL.fixed_length_secure_compare for same-length inputs" do
      expect(OpenSSL).to receive(:fixed_length_secure_compare).with("abc", "abc").and_call_original
      expect(Supabase::Rails::Core.secure_compare("abc", "abc")).to eq(true)
    end

    it "never compares API keys via Ruby == (which is not constant-time)" do
      # Sanity check on source: ensure try_apikey_mode does not use plain == on the apikey value.
      core_source = File.read(File.expand_path("../../../lib/supabase/rails/core.rb", __dir__))
      # try_apikey_mode body should not contain a `value ==` or `apikey ==` comparison.
      expect(core_source).to match(/secure_compare\(apikey, value\)/)
      expect(core_source).not_to match(/apikey\s*==\s*value/)
      expect(core_source).not_to match(/value\s*==\s*apikey/)
    end
  end

  describe "2. JWT verification uses signature checks; never trusts alg: none" do
    it "restricts algorithms to the signed set RS256/ES256/HS256" do
      expect(Supabase::Rails::JWT::ALGORITHMS).to eq(%w[RS256 ES256 HS256]).and be_frozen
    end

    it "rejects a token whose alg header is 'none' (unsigned)" do
      # Build an unsigned JWT manually — payload mirrors a real Supabase token.
      header = Base64.urlsafe_encode64(JSON.generate({ alg: "none", typ: "JWT" }), padding: false)
      payload = Base64.urlsafe_encode64(
        JSON.generate({ sub: "user-attack", exp: Time.now.to_i + 3600 }),
        padding: false
      )
      unsigned_token = "#{header}.#{payload}."

      expect {
        Supabase::Rails::JWT.verify(unsigned_token, env: env_with(jwks: jwks))
      }.to raise_error(Supabase::Rails::AuthError) do |err|
        expect(err.code).to eq(Supabase::Rails::AuthError::INVALID_CREDENTIALS)
        expect(err.message).to eq("Invalid credentials")
      end
    end

    it "rejects a token signed with HS256 using the JWKS public modulus as the secret (alg-confusion attack)" do
      # Classic alg-confusion: attacker swaps the RS256 header to HS256 and signs with the public key bytes.
      jwk_n = jwk.export[:n]
      attacker_secret = Base64.urlsafe_decode64(jwk_n)
      forged = ::JWT.encode(
        { sub: "user-attack", exp: Time.now.to_i + 3600 },
        attacker_secret, "HS256", { kid: jwk.kid }
      )

      expect {
        Supabase::Rails::JWT.verify(forged, env: env_with(jwks: jwks))
      }.to raise_error(Supabase::Rails::AuthError) do |err|
        expect(err.code).to eq(Supabase::Rails::AuthError::INVALID_CREDENTIALS)
      end
    end

    it "rejects a token whose signature is stripped (third segment empty)" do
      valid = ::JWT.encode(
        { sub: "user-123", exp: Time.now.to_i + 3600 },
        rsa_private, "RS256", { kid: jwk.kid }
      )
      header, payload, _sig = valid.split(".")
      stripped = "#{header}.#{payload}."

      expect {
        Supabase::Rails::JWT.verify(stripped, env: env_with(jwks: jwks))
      }.to raise_error(Supabase::Rails::AuthError)
    end

    it "calls ::JWT.decode with verify=true (third arg)" do
      # Static check on the source — ensure no one flips signature verification off.
      jwt_source = File.read(File.expand_path("../../../lib/supabase/rails/jwt.rb", __dir__))
      expect(jwt_source).to match(/::JWT\.decode\(\s*token,\s*nil,\s*true,/)
    end
  end

  describe "3. Reject non-HTTPS JWKS URLs on non-loopback hosts" do
    it "Env.resolve drops a non-HTTPS JWKS URL pointing at an external host (env-var path)" do
      with_env(
        "SUPABASE_URL" => "https://test.supabase.co",
        "SUPABASE_PUBLISHABLE_KEY" => "sb_pub",
        "SUPABASE_SECRET_KEY" => "sb_sec",
        "SUPABASE_JWKS" => nil,
        "SUPABASE_JWKS_URL" => "http://attacker.example/.well-known/jwks.json"
      ) do
        env = Supabase::Rails::Env.resolve
        expect(env.jwks).to be_nil
      end
    end

    it "Env.resolve accepts an HTTPS JWKS URL on any host" do
      with_env(
        "SUPABASE_URL" => "https://test.supabase.co",
        "SUPABASE_PUBLISHABLE_KEY" => "sb_pub",
        "SUPABASE_SECRET_KEY" => "sb_sec",
        "SUPABASE_JWKS" => nil,
        "SUPABASE_JWKS_URL" => "https://auth.example.com/jwks.json"
      ) do
        env = Supabase::Rails::Env.resolve
        expect(env.jwks).to be_a(URI::HTTPS)
      end
    end

    it "Env.resolve accepts an HTTP JWKS URL on localhost (loopback policy)" do
      with_env(
        "SUPABASE_URL" => "http://localhost:54321",
        "SUPABASE_PUBLISHABLE_KEY" => "sb_pub",
        "SUPABASE_SECRET_KEY" => "sb_sec",
        "SUPABASE_JWKS" => nil,
        "SUPABASE_JWKS_URL" => "http://localhost:54321/.well-known/jwks.json"
      ) do
        env = Supabase::Rails::Env.resolve
        expect(env.jwks).to be_a(URI::HTTP)
        expect(env.jwks.host).to eq("localhost")
      end
    end

    it "JWT.verify rejects an HTTP JWKS URI pointed at an external host (defense-in-depth on override path)" do
      # Even if a caller bypasses Env.resolve by passing the URI directly, JWT.verify must refuse.
      bad_uri = URI("http://attacker.example/jwks.json")
      allow(Net::HTTP).to receive(:get_response).and_raise("must not be called")

      token = ::JWT.encode(
        { sub: "u1", exp: Time.now.to_i + 3600 },
        rsa_private, "RS256", { kid: jwk.kid }
      )

      expect {
        Supabase::Rails::JWT.verify(token, env: env_with(jwks: bad_uri))
      }.to raise_error(Supabase::Rails::AuthError) do |err|
        expect(err.code).to eq(Supabase::Rails::AuthError::INVALID_CREDENTIALS)
      end
      expect(Net::HTTP).not_to have_received(:get_response)
    end

    it "JWT.verify accepts an HTTPS JWKS URI on any host (when env is hand-built)" do
      uri = URI("https://auth.example.com/jwks.json")
      ok = instance_double(Net::HTTPOK, body: JSON.generate(jwks))
      allow(ok).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(Net::HTTP).to receive(:get_response).with(uri).and_return(ok)

      token = ::JWT.encode(
        { sub: "u1", exp: Time.now.to_i + 3600 },
        rsa_private, "RS256", { kid: jwk.kid }
      )

      result = Supabase::Rails::JWT.verify(token, env: env_with(jwks: uri))
      expect(result[:user_claims].id).to eq("u1")
    end

    it "JWT.verify accepts an HTTP JWKS URI on a loopback host (matches Env loopback policy)" do
      uri = URI("http://127.0.0.1:54321/jwks.json")
      ok = instance_double(Net::HTTPOK, body: JSON.generate(jwks))
      allow(ok).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(Net::HTTP).to receive(:get_response).with(uri).and_return(ok)

      token = ::JWT.encode(
        { sub: "u1", exp: Time.now.to_i + 3600 },
        rsa_private, "RS256", { kid: jwk.kid }
      )

      result = Supabase::Rails::JWT.verify(token, env: env_with(jwks: uri))
      expect(result[:user_claims].id).to eq("u1")
    end
  end

  describe "4. Default error messages do not leak which credential failed" do
    it "publishable mode failure returns generic 'Invalid credentials' message" do
      creds = Credentials.new(token: nil, apikey: "wrong_key")
      err = capture_auth_error { Supabase::Rails::Core.verify_credentials(creds, auth: :publishable, env: env_with) }
      expect(err.message).to eq("Invalid credentials")
      expect(err.code).to eq(Supabase::Rails::AuthError::INVALID_CREDENTIALS)
      expect(err.status).to eq(401)
    end

    it "secret mode failure returns generic 'Invalid credentials' message" do
      creds = Credentials.new(token: nil, apikey: "wrong_key")
      err = capture_auth_error { Supabase::Rails::Core.verify_credentials(creds, auth: :secret, env: env_with) }
      expect(err.message).to eq("Invalid credentials")
    end

    it "user-mode failure (expired token) returns generic 'Invalid credentials' message" do
      expired = ::JWT.encode(
        { sub: "u1", iat: Time.now.to_i - 7200, exp: Time.now.to_i - 3600 },
        rsa_private, "RS256", { kid: jwk.kid }
      )
      err = capture_auth_error { Supabase::Rails::JWT.verify(expired, env: env_with(jwks: jwks)) }
      expect(err.message).to eq("Invalid credentials")
    end

    it "user-mode failure (foreign signing key) returns generic 'Invalid credentials' message" do
      other = OpenSSL::PKey::RSA.generate(2048)
      forged = ::JWT.encode(
        { sub: "u1", exp: Time.now.to_i + 3600 },
        other, "RS256", { kid: jwk.kid }
      )
      err = capture_auth_error { Supabase::Rails::JWT.verify(forged, env: env_with(jwks: jwks)) }
      expect(err.message).to eq("Invalid credentials")
    end

    it "user-mode failure (malformed token) does not include parser details" do
      err = capture_auth_error { Supabase::Rails::JWT.verify("not.a.jwt.at.all", env: env_with(jwks: jwks)) }
      expect(err.message).to eq("Invalid credentials")
      # Sanity: the message must not echo the underlying jwt-gem parser error.
      expect(err.message).not_to match(/decode|parse|invalid segment|signature/i)
    end

    it "all-modes-exhausted failure returns generic 'Invalid credentials' message" do
      creds = Credentials.new(token: "sb_bogus", apikey: "wrong")
      err = capture_auth_error do
        Supabase::Rails::Core.verify_credentials(creds, auth: [:publishable, :secret], env: env_with)
      end
      expect(err.message).to eq("Invalid credentials")
    end

    it "AuthError.invalid_credentials factory always produces the generic message + 401" do
      err = Supabase::Rails::AuthError.invalid_credentials
      expect(err.message).to eq("Invalid credentials")
      expect(err.status).to eq(401)
      expect(err.code).to eq(Supabase::Rails::AuthError::INVALID_CREDENTIALS)
    end
  end

  def capture_auth_error
    yield
    raise "expected AuthError to be raised, but block completed normally"
  rescue Supabase::Rails::AuthError => e
    e
  end
end
