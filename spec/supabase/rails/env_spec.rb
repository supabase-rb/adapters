# frozen_string_literal: true

require "spec_helper"
require "json"

RSpec.describe Supabase::Rails::Env do
  # Make sure tests run with a clean Supabase env regardless of the host shell.
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

  describe ".resolve" do
    it "raises EnvError when SUPABASE_URL is missing" do
      expect { described_class.resolve }.to raise_error(Supabase::Rails::EnvError) do |err|
        expect(err.code).to eq(Supabase::Rails::EnvError::MISSING_SUPABASE_URL)
        expect(err.status).to eq(500)
      end
    end

    it "reads SUPABASE_URL from ENV" do
      with_env("SUPABASE_URL" => "https://test.supabase.co") do
        env = described_class.resolve
        expect(env.url).to eq("https://test.supabase.co")
      end
    end

    it "parses JSON publishable keys" do
      with_env(
        "SUPABASE_URL" => "https://test.supabase.co",
        "SUPABASE_PUBLISHABLE_KEYS" => JSON.generate(
          "web" => "sb_publishable_abc",
          "mobile" => "sb_publishable_def"
        )
      ) do
        env = described_class.resolve
        expect(env.publishable_keys).to eq(
          "web" => "sb_publishable_abc",
          "mobile" => "sb_publishable_def"
        )
      end
    end

    it "returns empty hash for invalid JSON keys" do
      with_env(
        "SUPABASE_URL" => "https://test.supabase.co",
        "SUPABASE_PUBLISHABLE_KEYS" => "not-json"
      ) do
        env = described_class.resolve
        expect(env.publishable_keys).to eq({})
      end
    end

    it "parses JWKS as JSON" do
      jwks = { "keys" => [{ "kty" => "RSA", "n" => "test", "e" => "AQAB" }] }
      with_env(
        "SUPABASE_URL" => "https://test.supabase.co",
        "SUPABASE_JWKS" => JSON.generate(jwks)
      ) do
        env = described_class.resolve
        expect(env.jwks).to eq(jwks)
      end
    end

    it "wraps bare JWKS array in { keys } object" do
      keys = [{ "kty" => "EC", "crv" => "P-256", "x" => "test", "y" => "test" }]
      with_env(
        "SUPABASE_URL" => "https://test.supabase.co",
        "SUPABASE_JWKS" => JSON.generate(keys)
      ) do
        env = described_class.resolve
        expect(env.jwks).to eq("keys" => keys)
      end
    end

    it "returns nil jwks for invalid JSON" do
      with_env(
        "SUPABASE_URL" => "https://test.supabase.co",
        "SUPABASE_JWKS" => "not-json"
      ) do
        env = described_class.resolve
        expect(env.jwks).to be_nil
      end
    end

    it "parses SUPABASE_JWKS_URL into a URI object" do
      with_env(
        "SUPABASE_URL" => "https://test.supabase.co",
        "SUPABASE_JWKS_URL" => "https://test.supabase.co/auth/v1/.well-known/jwks.json"
      ) do
        env = described_class.resolve
        expect(env.jwks).to be_a(URI)
        expect(env.jwks.to_s).to eq("https://test.supabase.co/auth/v1/.well-known/jwks.json")
      end
    end

    [
      ["plain hostname", "http://example.com/jwks.json"],
      ["public IP", "http://1.2.3.4/jwks.json"],
      ["private IP (non-loopback)", "http://10.0.0.1/jwks.json"],
      ["localhost prefix attack", "http://localhost.evil.com/jwks.json"]
    ].each do |label, value|
      it "rejects http SUPABASE_JWKS_URL on non-loopback host (#{label})" do
        with_env(
          "SUPABASE_URL" => "https://test.supabase.co",
          "SUPABASE_JWKS_URL" => value
        ) do
          env = described_class.resolve
          expect(env.jwks).to be_nil
        end
      end
    end

    [
      ["localhost", "http://localhost:54321/auth/v1/.well-known/jwks.json"],
      ["127.0.0.1", "http://127.0.0.1:54321/auth/v1/jwks"],
      ["127.x range", "http://127.0.0.5/jwks.json"],
      ["::1", "http://[::1]:54321/jwks.json"],
      ["*.localhost subdomain", "http://api.localhost/jwks.json"]
    ].each do |label, value|
      it "allows http SUPABASE_JWKS_URL for loopback host (#{label})" do
        with_env(
          "SUPABASE_URL" => "https://test.supabase.co",
          "SUPABASE_JWKS_URL" => value
        ) do
          env = described_class.resolve
          expect(env.jwks).to be_a(URI)
        end
      end
    end

    [
      ["unclosed IPv6 bracket", "https://[invalid"],
      ["scheme only, no host", "https://"]
    ].each do |label, value|
      it "returns nil for malformed SUPABASE_JWKS_URL (#{label})" do
        with_env(
          "SUPABASE_URL" => "https://test.supabase.co",
          "SUPABASE_JWKS_URL" => value
        ) do
          env = described_class.resolve
          expect(env.jwks).to be_nil
        end
      end
    end

    it "trims whitespace around SUPABASE_JWKS_URL values" do
      with_env(
        "SUPABASE_URL" => "https://test.supabase.co",
        "SUPABASE_JWKS_URL" => "   https://example.com/jwks.json\n"
      ) do
        env = described_class.resolve
        expect(env.jwks).to be_a(URI)
        expect(env.jwks.to_s).to eq("https://example.com/jwks.json")
      end
    end

    it "rejects a URL value placed in SUPABASE_JWKS (mixed-type protection)" do
      with_env(
        "SUPABASE_URL" => "https://test.supabase.co",
        "SUPABASE_JWKS" => "https://example.com/jwks.json"
      ) do
        env = described_class.resolve
        expect(env.jwks).to be_nil
      end
    end

    it "SUPABASE_JWKS wins over SUPABASE_JWKS_URL when both are set" do
      inline = { "keys" => [{ "kty" => "RSA", "n" => "inline", "e" => "AQAB" }] }
      with_env(
        "SUPABASE_URL" => "https://test.supabase.co",
        "SUPABASE_JWKS" => JSON.generate(inline),
        "SUPABASE_JWKS_URL" => "https://example.com/jwks.json"
      ) do
        env = described_class.resolve
        expect(env.jwks).to eq(inline)
      end
    end

    it "does not fall through to SUPABASE_JWKS_URL when SUPABASE_JWKS is malformed" do
      with_env(
        "SUPABASE_URL" => "https://test.supabase.co",
        "SUPABASE_JWKS" => "not-json",
        "SUPABASE_JWKS_URL" => "https://example.com/jwks.json"
      ) do
        env = described_class.resolve
        expect(env.jwks).to be_nil
      end
    end

    it "falls through to SUPABASE_JWKS_URL when SUPABASE_JWKS is unset or empty" do
      with_env(
        "SUPABASE_URL" => "https://test.supabase.co",
        "SUPABASE_JWKS" => "",
        "SUPABASE_JWKS_URL" => "https://example.com/jwks.json"
      ) do
        env = described_class.resolve
        expect(env.jwks).to be_a(URI)
      end
    end

    it "passes URI overrides through unchanged" do
      uri = URI.parse("https://example.com/jwks.json")
      env = described_class.resolve(url: "https://test.supabase.co", jwks: uri)
      expect(env.jwks).to be(uri)
    end

    [
      ["a primitive", "1"],
      ["an empty object", "{}"],
      ["an object with non-array keys", '{"keys":"nope"}'],
      ["a string", '"hello"'],
      ["null", "null"],
      ["a boolean", "true"]
    ].each do |label, value|
      it "returns nil jwks for valid JSON that is #{label}" do
        with_env(
          "SUPABASE_URL" => "https://test.supabase.co",
          "SUPABASE_JWKS" => value
        ) do
          env = described_class.resolve
          expect(env.jwks).to be_nil
        end
      end
    end

    it "reads singular SUPABASE_PUBLISHABLE_KEY as { default: value }" do
      with_env(
        "SUPABASE_URL" => "https://test.supabase.co",
        "SUPABASE_PUBLISHABLE_KEY" => "sb_publishable_test_123"
      ) do
        env = described_class.resolve
        expect(env.publishable_keys).to eq("default" => "sb_publishable_test_123")
      end
    end

    it "reads singular SUPABASE_SECRET_KEY as { default: value }" do
      with_env(
        "SUPABASE_URL" => "https://test.supabase.co",
        "SUPABASE_SECRET_KEY" => "sb_secret_test_456"
      ) do
        env = described_class.resolve
        expect(env.secret_keys).to eq("default" => "sb_secret_test_456")
      end
    end

    it "prefers plural over singular when both are set" do
      with_env(
        "SUPABASE_URL" => "https://test.supabase.co",
        "SUPABASE_PUBLISHABLE_KEY" => "sb_publishable_singular",
        "SUPABASE_PUBLISHABLE_KEYS" => JSON.generate(
          "web" => "sb_publishable_web",
          "mobile" => "sb_publishable_mobile"
        )
      ) do
        env = described_class.resolve
        expect(env.publishable_keys).to eq(
          "web" => "sb_publishable_web",
          "mobile" => "sb_publishable_mobile"
        )
      end
    end

    it "parses platform env vars with multiple keys and JWKS array" do
      jwks_raw = '[{"x":"aN7ek2W_m0BCBoy2vnfwd_785kEfMCcAMGznUg3ut34","y":"7vftLMpD-fRUFmhrqOIfS6ApmCzKgbE6dFsP4o5BCso","alg":"ES256","crv":"P-256","ext":true,"kid":"cb770052-bdd3-4f5e-8d6f-8836046b7c93","kty":"EC","key_ops":["verify"]},{"x":"vwGP-KLJgwv0LHlZEd-7AksGdnznPFcodh4kEKjWUV0","y":"hOyozpKPMwFu8iFGC6QJLqOmDdrNTLyBxiWhKoSSg58","alg":"ES256","crv":"P-256","ext":true,"kid":"9a9933f7-e18f-4d6f-a791-9a992845a27b","kty":"EC","key_ops":["verify"]}]'
      with_env(
        "SUPABASE_URL" => "https://test.supabase.co",
        "SUPABASE_PUBLISHABLE_KEYS" => '{"default":"sb_publishable_fake_default_key","test":"sb_publishable_fake_test_key"}',
        "SUPABASE_SECRET_KEYS" => '{"default":"sb_secret_fake_default_key_val","internal":"sb_secret_fake_internal_key"}',
        "SUPABASE_JWKS" => jwks_raw
      ) do
        env = described_class.resolve
        expect(env.publishable_keys).to eq(
          "default" => "sb_publishable_fake_default_key",
          "test" => "sb_publishable_fake_test_key"
        )
        expect(env.secret_keys).to eq(
          "default" => "sb_secret_fake_default_key_val",
          "internal" => "sb_secret_fake_internal_key"
        )
        expect(env.jwks["keys"].length).to eq(2)
        expect(env.jwks["keys"][0]["kid"]).to eq("cb770052-bdd3-4f5e-8d6f-8836046b7c93")
        expect(env.jwks["keys"][1]["kid"]).to eq("9a9933f7-e18f-4d6f-a791-9a992845a27b")
      end
    end

    it "uses overrides when provided" do
      env = described_class.resolve(
        url: "https://override.supabase.co",
        publishable_keys: { "test" => "sb_publishable_override" }
      )
      expect(env.url).to eq("https://override.supabase.co")
      expect(env.publishable_keys).to eq("test" => "sb_publishable_override")
    end
  end
end
