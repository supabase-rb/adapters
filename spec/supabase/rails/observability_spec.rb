# frozen_string_literal: true

require "spec_helper"
require "logger"
require "stringio"
require "jwt"
require "openssl"

RSpec.describe "NFR-5 Observability contract" do
  Credentials = Supabase::Rails::Credentials unless defined?(Credentials)
  SupabaseEnv = Supabase::Rails::SupabaseEnv unless defined?(SupabaseEnv)

  def env_with(overrides = {})
    SupabaseEnv.new(
      url: "https://test.supabase.co",
      publishable_keys: { "default" => "sb_publishable_xyz" },
      secret_keys: { "default" => "sb_secret_xyz" },
      jwks: nil,
      **overrides
    )
  end

  around(:each) do |example|
    saved = Supabase::Rails.logger
    example.run
  ensure
    Supabase::Rails.logger = saved
  end

  describe "1. Errors carry code for log filtering" do
    it "EnvError exposes #code returning a String" do
      e = Supabase::Rails::EnvError.missing_supabase_url
      expect(e.code).to be_a(String)
      expect(e.code).to eq(Supabase::Rails::EnvError::MISSING_SUPABASE_URL)
    end

    it "AuthError exposes #code returning a String" do
      e = Supabase::Rails::AuthError.invalid_credentials
      expect(e.code).to be_a(String)
      expect(e.code).to eq(Supabase::Rails::AuthError::INVALID_CREDENTIALS)
    end

    it "create_context failure exposes .error.code on the Result" do
      result = Supabase::Rails.create_context(
        { "Authorization" => "Bearer bogus" },
        auth: :user, env: env_with(jwks: { "keys" => [] })
      )

      expect(result.error).to be_a(Supabase::Rails::AuthError)
      expect(result.error.code).to eq(Supabase::Rails::AuthError::INVALID_CREDENTIALS)
    end
  end

  describe "2. Optional Supabase::Rails.logger hook" do
    it "defaults to nil" do
      Supabase::Rails.logger = nil
      expect(Supabase::Rails.logger).to be_nil
    end

    it "can be set and read back via the module-level accessors" do
      io = StringIO.new
      my_logger = Logger.new(io)
      Supabase::Rails.logger = my_logger
      expect(Supabase::Rails.logger).to equal(my_logger)
    end

    it "does not log anything by default (nil logger is a no-op)" do
      Supabase::Rails.logger = nil

      # If the default leaked any logging, it would write to STDOUT/STDERR.
      # Use a side-effect tap instead: a fake logger should *not* be called
      # because logger is nil.
      taps = []
      fake = Class.new do
        define_method(:warn) { |msg| taps << [:warn, msg] }
        define_method(:error) { |msg| taps << [:error, msg] }
      end.new

      # Sanity: the fake records when called.
      Supabase::Rails.logger = fake
      Supabase::Rails.create_context(
        { "Authorization" => "Bearer junk" },
        auth: :user, env: env_with(jwks: { "keys" => [] })
      )
      expect(taps).not_to be_empty

      # With logger reset to nil, the same call must not raise and must not
      # write anywhere observable.
      Supabase::Rails.logger = nil
      taps.clear

      expect {
        Supabase::Rails.create_context(
          { "Authorization" => "Bearer junk" },
          auth: :user, env: env_with(jwks: { "keys" => [] })
        )
      }.not_to raise_error
      expect(taps).to be_empty
    end

    it "logs create_context auth failures at :warn with the error code in the message" do
      io = StringIO.new
      Supabase::Rails.logger = Logger.new(io)

      result = Supabase::Rails.create_context(
        { "Authorization" => "Bearer bogus" },
        auth: :user, env: env_with(jwks: { "keys" => [] })
      )

      expect(result.error.code).to eq("INVALID_CREDENTIALS")
      output = io.string
      expect(output).to include("WARN")
      expect(output).to include("INVALID_CREDENTIALS")
    end

    it "logs create_context EnvError-during-client-build failures at :error with the error code" do
      # Trigger an EnvError during build_context_result by passing valid auth
      # but a SupabaseEnv whose publishable_keys are empty.
      taps = []
      Supabase::Rails.logger = Class.new do
        define_method(:warn) { |msg| taps << [:warn, msg] }
        define_method(:error) { |msg| taps << [:error, msg] }
      end.new

      env = env_with(publishable_keys: {})
      result = Supabase::Rails.create_context(
        { "apikey" => "sb_secret_xyz" }, # auth :secret resolves; then context client build hits empty publishable_keys
        auth: :secret, env: env
      )

      expect(result.error.status).to eq(500)
      expect(taps.map(&:first)).to include(:error)
      error_msg = taps.find { |(level, _)| level == :error }.last
      expect(error_msg).to include(result.error.code)
    end

    it "does not crash when the logger itself raises (defensive)" do
      bad_logger = Class.new do
        def warn(_msg); raise "logger died"; end
        def error(_msg); raise "logger died"; end
      end.new
      Supabase::Rails.logger = bad_logger

      expect {
        Supabase::Rails.create_context(
          { "Authorization" => "Bearer bogus" },
          auth: :user, env: env_with(jwks: { "keys" => [] })
        )
      }.not_to raise_error
    end

    it "skips loggers that do not respond to the requested level (duck-typed)" do
      stub_without_warn = Object.new # responds to neither :warn nor :error
      Supabase::Rails.logger = stub_without_warn

      expect {
        Supabase::Rails.create_context(
          { "Authorization" => "Bearer bogus" },
          auth: :user, env: env_with(jwks: { "keys" => [] })
        )
      }.not_to raise_error
    end

    it "is thread-safe under concurrent reads and writes" do
      writers = Array.new(8) do |i|
        Thread.new do
          50.times { Supabase::Rails.logger = Logger.new(StringIO.new).tap { |l| l.progname = "w#{i}" } }
        end
      end
      readers = Array.new(8) do
        Thread.new do
          50.times { Supabase::Rails.logger }
        end
      end

      expect { (writers + readers).each(&:join) }.not_to raise_error
    end

    it "exposes module-level state on Logging — NOT on Supabase::Rails itself" do
      # Server must keep zero module-level ivars (NFR-1 contract). Logger
      # storage lives in the Logging sub-module so that the request-path
      # invariant survives.
      Supabase::Rails.logger = Logger.new(StringIO.new)
      expect(Supabase::Rails.instance_variables).to eq([])
      expect(Supabase::Rails::Logging.instance_variables).to contain_exactly(:@mutex, :@logger)
      expect(Supabase::Rails::Logging.instance_variable_get(:@mutex)).to be_a(Mutex)
    end
  end

  describe "3. No telemetry, no phone-home" do
    LIB_FILES = Dir[File.expand_path("../../../lib/**/*.rb", __dir__)].freeze

    it "no telemetry / analytics / phone-home gem imports in lib/" do
      forbidden_requires = %w[
        excon httparty rest-client typhoeus telemetry analytics segment
        rollbar sentry-ruby honeybadger bugsnag newrelic_rpm scout_apm
      ]

      LIB_FILES.each do |path|
        source = File.read(path)
        forbidden_requires.each do |gem_name|
          expect(source).not_to match(/^\s*require\s+["']#{Regexp.escape(gem_name)}/),
            "#{path} requires '#{gem_name}' — NFR-5 forbids telemetry/phone-home deps"
        end
      end
    end

    it "the only outbound HTTP call site in lib/ is the JWKS fetch in jwt.rb" do
      # PRD NFR-5: "No telemetry, no phone-home." The library makes exactly
      # ONE network call — Net::HTTP.get_response inside JWT.resolve_jwks for
      # remote JWKS endpoints. Any other Net::HTTP.* / Faraday.* / etc. usage
      # in lib/ is a regression.
      http_call_pattern = /\b(?:Net::HTTP|Faraday|HTTParty|RestClient|Excon|Typhoeus|OpenURI)\b/

      offenders = LIB_FILES.each_with_object({}) do |path, acc|
            source = File.read(path)
            matches = source.scan(http_call_pattern).uniq
            acc[path] = matches if matches.any?
          end

      # Only jwt.rb may contain Net::HTTP references (for the JWKS fetch).
      offenders.each do |path, matches|
        expect(File.basename(path)).to eq("jwt.rb"),
          "Unexpected HTTP client reference in #{path}: #{matches.inspect}. " \
          "Per NFR-5, only lib/supabase/rails/jwt.rb may call out (JWKS fetch)."
        expect(matches).to eq(["Net::HTTP"]),
          "jwt.rb may only use Net::HTTP, got #{matches.inspect}"
      end
    end

    it "no telemetry-looking URLs or hostnames in lib/" do
      suspicious_url_pattern = %r{https?://[^"'\s]*(analytics|telemetry|metrics\.|tracking\.|phone-?home)}i

      LIB_FILES.each do |path|
        source = File.read(path)
        expect(source).not_to match(suspicious_url_pattern),
          "#{path} contains a suspicious telemetry-looking URL"
      end
    end

    it "Logging.log#default behavior never opens a network connection" do
      # Belt-and-suspenders: even with a custom logger, Logging.log only forwards
      # to the user's logger via duck-typed level call — it must not implicitly
      # touch the network.
      io = StringIO.new
      Supabase::Rails.logger = Logger.new(io)

      # If anyone added a phone-home in Logging.log, this would fail with
      # something like Errno::ECONNREFUSED. The strict assertion is a smoke
      # test: no Net::HTTP allocation during log emission.
      expect(Net::HTTP).not_to receive(:new) if defined?(Net::HTTP)
      expect(Net::HTTP).not_to receive(:start) if defined?(Net::HTTP)

      Supabase::Rails::Logging.log(:warn, "test message")
      expect(io.string).to include("test message")
    end
  end
end
