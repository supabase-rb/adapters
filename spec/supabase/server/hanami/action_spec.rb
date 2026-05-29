# frozen_string_literal: true

require "spec_helper"
require "json"
require "supabase/server/hanami"

RSpec.describe Supabase::Server::Hanami::Action do
  def valid_env(overrides = {})
    Supabase::Server::SupabaseEnv.new(
      url: "https://test.supabase.co",
      publishable_keys: { "default" => "sb_publishable_xyz" },
      secret_keys: { "default" => "sb_secret_xyz" },
      jwks: nil,
      **overrides
    )
  end

  # Stand-in for a Hanami::Action::Request that exposes #env.
  class FakeRequest
    def initialize(env = {})
      @env = env
    end

    attr_reader :env
  end

  # Stand-in for a Hanami::Action::Response: writable status, headers, body.
  class FakeResponse
    def initialize
      @status = 200
      @headers = {}
      @body = nil
    end

    attr_accessor :status, :body
    attr_reader :headers
  end

  # Base action class emulating the bits of Hanami::Action we touch:
  # - class-level `before(:sym)` records the registered callback
  # - class-level `handle_exception(Hash)` records exception mappings
  # - `dispatch_exception(action, request, response, error)` invokes the registered handler
  # - `run_before(action, request, response)` invokes registered before callbacks
  let(:base_class) do
    Class.new do
      class << self
        attr_accessor :before_callbacks, :exception_handlers

        def before(*names)
          self.before_callbacks ||= []
          before_callbacks.concat(names)
        end

        def handle_exception(mapping)
          self.exception_handlers ||= {}
          exception_handlers.merge!(mapping)
        end

        def dispatch_exception(action, request, response, error)
          handler = (exception_handlers || {}).find { |klass, _| error.is_a?(klass) }
          return false unless handler

          action.send(handler[1], request, response, error)
          true
        end

        def run_before(action, request, response)
          (before_callbacks || []).each { |name| action.send(name, request, response) }
        end
      end
    end
  end

  let(:action_class) do
    klass = Class.new(base_class)
    klass.include(described_class)
    klass
  end

  let(:action) { action_class.new }

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

  describe "inclusion hook" do
    it "registers _capture_supabase_request as a before callback" do
      expect(action_class.before_callbacks).to include(:_capture_supabase_request)
    end

    it "registers a handle_exception mapping for AuthError" do
      expect(action_class.exception_handlers).to include(Supabase::Server::AuthError)
      expect(action_class.exception_handlers[Supabase::Server::AuthError])
        .to eq(:_render_supabase_auth_error)
    end

    it "is a no-op on a plain class without before/handle_exception" do
      plain_class = Class.new
      expect { plain_class.include(described_class) }.not_to raise_error
    end
  end

  describe "#supabase_context" do
    it "returns the context stashed in request.env['supabase.context']" do
      stub_ctx = Object.new
      request = FakeRequest.new("supabase.context" => stub_ctx)
      action_class.run_before(action, request, FakeResponse.new)

      expect(action.supabase_context).to equal(stub_ctx)
    end

    it "returns nil when no context is set" do
      request = FakeRequest.new
      action_class.run_before(action, request, FakeResponse.new)

      expect(action.supabase_context).to be_nil
    end

    it "returns nil before the before callback has run" do
      expect(action.supabase_context).to be_nil
    end
  end

  describe "#verify_supabase_auth" do
    context "without args" do
      it "returns the existing context when present" do
        stub_ctx = Object.new
        request = FakeRequest.new("supabase.context" => stub_ctx)
        action_class.run_before(action, request, FakeResponse.new)

        expect(action.verify_supabase_auth).to equal(stub_ctx)
      end

      it "raises AuthError.invalid_credentials when context is absent" do
        request = FakeRequest.new
        action_class.run_before(action, request, FakeResponse.new)

        expect { action.verify_supabase_auth }.to raise_error(
          Supabase::Server::AuthError
        ) do |error|
          expect(error.code).to eq(Supabase::Server::AuthError::INVALID_CREDENTIALS)
          expect(error.status).to eq(401)
        end
      end
    end

    context "with auth: override" do
      it "re-resolves the context with the given auth mode and overwrites env" do
        request = FakeRequest.new(
          "supabase.context" => Object.new,
          "HTTP_APIKEY" => "sb_publishable_xyz"
        )
        action_class.run_before(action, request, FakeResponse.new)

        result = action.verify_supabase_auth(auth: :publishable, env: valid_env)

        expect(result).to be_a(Supabase::Server::SupabaseContext)
        expect(result.auth_mode).to eq(:publishable)
        expect(request.env["supabase.context"]).to equal(result)
      end

      it "raises the underlying AuthError when re-verification fails" do
        request = FakeRequest.new
        action_class.run_before(action, request, FakeResponse.new)

        expect {
          action.verify_supabase_auth(auth: :user, env: valid_env)
        }.to raise_error(Supabase::Server::AuthError) do |error|
          expect(error.code).to eq(Supabase::Server::AuthError::INVALID_CREDENTIALS)
        end
      end

      it "forwards supabase_options to create_context" do
        request = FakeRequest.new
        action_class.run_before(action, request, FakeResponse.new)

        action.verify_supabase_auth(
          auth: :none,
          env: valid_env,
          supabase_options: { db: { schema: "api" } }
        )

        ctx = request.env["supabase.context"]
        expect(ctx).to be_a(Supabase::Server::SupabaseContext)
        expect(ctx.supabase).to be_a(::Supabase::Client)
      end
    end
  end

  describe "handle_exception handler" do
    it "writes a JSON body with the AuthError code and status to the response" do
      request = FakeRequest.new
      response = FakeResponse.new
      error = Supabase::Server::AuthError.invalid_credentials

      handled = action_class.dispatch_exception(action, request, response, error)

      expect(handled).to be(true)
      expect(response.status).to eq(401)
      expect(response.headers["Content-Type"]).to eq("application/json")
      parsed = JSON.parse(response.body)
      expect(parsed["message"]).to eq(error.message)
      expect(parsed["code"]).to eq(error.code)
    end

    it "uses the error's own status (e.g. 500 for client creation failures)" do
      request = FakeRequest.new
      response = FakeResponse.new
      error = Supabase::Server::AuthError.create_supabase_client_error

      action_class.dispatch_exception(action, request, response, error)

      expect(response.status).to eq(500)
      expect(JSON.parse(response.body)["code"])
        .to eq(Supabase::Server::AuthError::CREATE_SUPABASE_CLIENT_ERROR)
    end
  end
end
