# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Supabase::Rails error types" do
  describe Supabase::Rails::EnvError do
    it "inherits from StandardError" do
      expect(described_class.ancestors).to include(StandardError)
    end

    it "exposes #status as an Integer" do
      error = described_class.new("boom")
      expect(error.status).to be_a(Integer)
      expect(error.status).to eq(500)
    end

    it "exposes #code as a String" do
      error = described_class.new("boom")
      expect(error.code).to be_a(String)
    end

    it "exposes #message as a String" do
      error = described_class.new("boom")
      expect(error.message).to be_a(String)
      expect(error.message).to eq("boom")
    end

    it "defaults #code to ENV_ERROR" do
      expect(described_class.new("boom").code).to eq("ENV_ERROR")
    end

    it "accepts a custom code via the constructor" do
      error = described_class.new("boom", described_class::MISSING_SUPABASE_URL)
      expect(error.code).to eq("MISSING_SUPABASE_URL")
    end

    describe "code constants" do
      it "defines MISSING_SUPABASE_URL" do
        expect(described_class::MISSING_SUPABASE_URL).to eq("MISSING_SUPABASE_URL")
      end

      it "defines MISSING_PUBLISHABLE_KEY" do
        expect(described_class::MISSING_PUBLISHABLE_KEY).to eq("MISSING_PUBLISHABLE_KEY")
      end

      it "defines MISSING_DEFAULT_PUBLISHABLE_KEY" do
        expect(described_class::MISSING_DEFAULT_PUBLISHABLE_KEY).to eq("MISSING_DEFAULT_PUBLISHABLE_KEY")
      end

      it "defines MISSING_SECRET_KEY" do
        expect(described_class::MISSING_SECRET_KEY).to eq("MISSING_SECRET_KEY")
      end

      it "defines MISSING_DEFAULT_SECRET_KEY" do
        expect(described_class::MISSING_DEFAULT_SECRET_KEY).to eq("MISSING_DEFAULT_SECRET_KEY")
      end
    end

    describe "factory methods" do
      it ".missing_supabase_url produces a 500 error with the right code and message" do
        error = described_class.missing_supabase_url
        expect(error).to be_a(described_class)
        expect(error.status).to eq(500)
        expect(error.code).to eq("MISSING_SUPABASE_URL")
        expect(error.message).to eq("SUPABASE_URL is required but not set")
      end

      it ".missing_publishable_key includes the key name in the message" do
        error = described_class.missing_publishable_key("mobile")
        expect(error.status).to eq(500)
        expect(error.code).to eq("MISSING_PUBLISHABLE_KEY")
        expect(error.message).to include(%("mobile"))
        expect(error.message).to include("SUPABASE_PUBLISHABLE_KEYS")
      end

      it ".missing_default_publishable_key produces the right code and message" do
        error = described_class.missing_default_publishable_key
        expect(error.status).to eq(500)
        expect(error.code).to eq("MISSING_DEFAULT_PUBLISHABLE_KEY")
        expect(error.message).to include("default publishable key")
      end

      it ".missing_secret_key includes the key name in the message" do
        error = described_class.missing_secret_key("worker")
        expect(error.status).to eq(500)
        expect(error.code).to eq("MISSING_SECRET_KEY")
        expect(error.message).to include(%("worker"))
        expect(error.message).to include("SUPABASE_SECRET_KEYS")
      end

      it ".missing_default_secret_key produces the right code and message" do
        error = described_class.missing_default_secret_key
        expect(error.status).to eq(500)
        expect(error.code).to eq("MISSING_DEFAULT_SECRET_KEY")
        expect(error.message).to include("default secret key")
      end
    end

    it "can be rescued as StandardError" do
      expect { raise described_class.missing_supabase_url }.to raise_error(StandardError)
    end
  end

  describe Supabase::Rails::AuthError do
    it "inherits from StandardError" do
      expect(described_class.ancestors).to include(StandardError)
    end

    it "exposes #status as an Integer" do
      error = described_class.new("boom")
      expect(error.status).to be_a(Integer)
    end

    it "exposes #code as a String" do
      error = described_class.new("boom")
      expect(error.code).to be_a(String)
    end

    it "exposes #message as a String" do
      error = described_class.new("boom")
      expect(error.message).to be_a(String)
      expect(error.message).to eq("boom")
    end

    it "defaults #status to 401" do
      expect(described_class.new("boom").status).to eq(401)
    end

    it "defaults #code to AUTH_ERROR" do
      expect(described_class.new("boom").code).to eq("AUTH_ERROR")
    end

    it "accepts a custom code and status via the constructor" do
      error = described_class.new("boom", "CUSTOM_CODE", 500)
      expect(error.code).to eq("CUSTOM_CODE")
      expect(error.status).to eq(500)
    end

    describe "code constants" do
      it "defines AUTH_GENERIC_ERROR with the value AUTH_ERROR" do
        expect(described_class::AUTH_GENERIC_ERROR).to eq("AUTH_ERROR")
      end

      it "defines INVALID_CREDENTIALS" do
        expect(described_class::INVALID_CREDENTIALS).to eq("INVALID_CREDENTIALS")
      end

      it "defines CREATE_SUPABASE_CLIENT_ERROR" do
        expect(described_class::CREATE_SUPABASE_CLIENT_ERROR).to eq("CREATE_SUPABASE_CLIENT_ERROR")
      end
    end

    describe "factory methods" do
      it ".invalid_credentials produces a 401 error with the right code and message" do
        error = described_class.invalid_credentials
        expect(error).to be_a(described_class)
        expect(error.status).to eq(401)
        expect(error.code).to eq("INVALID_CREDENTIALS")
        expect(error.message).to eq("Invalid credentials")
      end

      it ".create_supabase_client_error produces a 500 error with the right code and message" do
        error = described_class.create_supabase_client_error
        expect(error.status).to eq(500)
        expect(error.code).to eq("CREATE_SUPABASE_CLIENT_ERROR")
        expect(error.message).to eq("Failed to create Supabase client")
      end
    end

    it "can be rescued as StandardError" do
      expect { raise described_class.invalid_credentials }.to raise_error(StandardError)
    end
  end
end
