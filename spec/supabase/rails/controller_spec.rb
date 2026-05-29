# frozen_string_literal: true

require "spec_helper"
require "json"
require "supabase/rails"

RSpec.describe Supabase::Rails::Controller do
  def valid_env(overrides = {})
    Supabase::Rails::SupabaseEnv.new(
      url: "https://test.supabase.co",
      publishable_keys: { "default" => "sb_publishable_xyz" },
      secret_keys: { "default" => "sb_secret_xyz" },
      jwks: nil,
      **overrides
    )
  end

  # Minimal stand-in for an ActionDispatch::Request that exposes #env and #headers.
  # #headers returns a hash-like that mirrors ActionDispatch::Http::Headers#[] —
  # `headers["apikey"]` reads `env["HTTP_APIKEY"]`, etc.
  class FakeHeaders
    def initialize(env)
      @env = env
    end

    def [](name)
      @env["HTTP_#{name.upcase.tr('-', '_')}"]
    end
  end

  class FakeRequest
    def initialize(env = {})
      @env = env
    end

    attr_reader :env

    def headers
      FakeHeaders.new(@env)
    end
  end

  let(:rendered) { [] }

  # Base controller class that emulates the bits of ActionController we need:
  # - a `request` accessor returning a FakeRequest
  # - a `render` method that captures the rendered payload
  # - class-level `helper_method` / `rescue_from` that record their calls and
  #   trigger rescue dispatch on raised errors.
  let(:base_class) do
    rendered_log = rendered
    Class.new do
      class << self
        attr_accessor :helper_methods, :rescue_handlers

        def helper_method(*names)
          self.helper_methods ||= []
          helper_methods.concat(names)
        end

        def rescue_from(error_class, with:)
          self.rescue_handlers ||= {}
          rescue_handlers[error_class] = with
        end
      end

      attr_accessor :request

      define_method(:render) do |payload|
        rendered_log << payload
      end

      def self.dispatch_rescue(controller, error)
        handler = (rescue_handlers || {}).find { |klass, _| error.is_a?(klass) }
        return false unless handler

        controller.send(handler[1], error)
        true
      end
    end
  end

  let(:controller_class) do
    klass = Class.new(base_class)
    klass.include(described_class)
    klass
  end

  let(:controller) { controller_class.new }

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
    it "registers supabase_context as a helper method" do
      expect(controller_class.helper_methods).to include(:supabase_context)
    end

    it "registers a rescue_from handler for AuthError" do
      expect(controller_class.rescue_handlers).to include(Supabase::Rails::AuthError)
      expect(controller_class.rescue_handlers[Supabase::Rails::AuthError])
        .to eq(:render_supabase_auth_error)
    end

    it "is a no-op on a plain module without helper_method/rescue_from" do
      plain_class = Class.new
      expect { plain_class.include(described_class) }.not_to raise_error
    end
  end

  describe "#supabase_context" do
    it "returns the context stashed in request.env['supabase.context']" do
      stub_ctx = Object.new
      controller.request = FakeRequest.new("supabase.context" => stub_ctx)

      expect(controller.supabase_context).to equal(stub_ctx)
    end

    it "returns nil when no context is set" do
      controller.request = FakeRequest.new

      expect(controller.supabase_context).to be_nil
    end
  end

  describe "#verify_supabase_auth" do
    context "without args" do
      it "returns the existing context when present" do
        stub_ctx = Object.new
        controller.request = FakeRequest.new("supabase.context" => stub_ctx)

        expect(controller.verify_supabase_auth).to equal(stub_ctx)
      end

      it "raises AuthError.invalid_credentials when context is absent" do
        controller.request = FakeRequest.new

        expect { controller.verify_supabase_auth }.to raise_error(
          Supabase::Rails::AuthError
        ) do |error|
          expect(error.code).to eq(Supabase::Rails::AuthError::INVALID_CREDENTIALS)
          expect(error.status).to eq(401)
        end
      end
    end

    context "with auth: override" do
      it "re-resolves the context with the given auth mode and overwrites env" do
        controller.request = FakeRequest.new(
          "supabase.context" => Object.new,
          "HTTP_APIKEY" => "sb_publishable_xyz"
        )

        result = controller.verify_supabase_auth(auth: :publishable, env: valid_env)

        expect(result).to be_a(Supabase::Rails::SupabaseContext)
        expect(result.auth_mode).to eq(:publishable)
        expect(controller.request.env["supabase.context"]).to equal(result)
      end

      it "raises the underlying AuthError when re-verification fails" do
        controller.request = FakeRequest.new

        expect {
          controller.verify_supabase_auth(auth: :user, env: valid_env)
        }.to raise_error(Supabase::Rails::AuthError) do |error|
          expect(error.code).to eq(Supabase::Rails::AuthError::INVALID_CREDENTIALS)
        end
      end

      it "forwards supabase_options to create_context" do
        controller.request = FakeRequest.new

        controller.verify_supabase_auth(
          auth: :none,
          env: valid_env,
          supabase_options: { db: { schema: "api" } }
        )

        ctx = controller.request.env["supabase.context"]
        expect(ctx).to be_a(Supabase::Rails::SupabaseContext)
        expect(ctx.supabase).to be_a(::Supabase::Client)
      end
    end
  end

  describe "rescue_from handler" do
    it "renders the auth error as JSON with the error status" do
      controller.request = FakeRequest.new
      error = Supabase::Rails::AuthError.invalid_credentials

      handled = controller_class.dispatch_rescue(controller, error)

      expect(handled).to be(true)
      expect(rendered.length).to eq(1)
      payload = rendered.first
      expect(payload[:status]).to eq(401)
      expect(payload[:json]).to eq(
        message: error.message,
        code: error.code
      )
    end

    it "uses the error's own status (e.g. 500 for client creation failures)" do
      controller.request = FakeRequest.new
      error = Supabase::Rails::AuthError.create_supabase_client_error

      controller_class.dispatch_rescue(controller, error)

      payload = rendered.first
      expect(payload[:status]).to eq(500)
      expect(payload[:json][:code]).to eq(
        Supabase::Rails::AuthError::CREATE_SUPABASE_CLIENT_ERROR
      )
    end
  end
end
