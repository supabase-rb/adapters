# frozen_string_literal: true

require "spec_helper"

RSpec.describe Supabase::Rails::Core do
  describe ".extract_credentials" do
    it "extracts Bearer token from Authorization header" do
      creds = described_class.extract_credentials("Authorization" => "Bearer test-token")
      expect(creds.token).to eq("test-token")
      expect(creds.apikey).to be_nil
    end

    it "extracts apikey header" do
      creds = described_class.extract_credentials("apikey" => "my-api-key")
      expect(creds.token).to be_nil
      expect(creds.apikey).to eq("my-api-key")
    end

    it "extracts both token and apikey" do
      creds = described_class.extract_credentials(
        "Authorization" => "Bearer test-token",
        "apikey" => "my-api-key"
      )
      expect(creds.token).to eq("test-token")
      expect(creds.apikey).to eq("my-api-key")
    end

    it "returns nils when no credentials present" do
      creds = described_class.extract_credentials({})
      expect(creds.token).to be_nil
      expect(creds.apikey).to be_nil
    end

    it "returns nils when headers is nil" do
      creds = described_class.extract_credentials(nil)
      expect(creds.token).to be_nil
      expect(creds.apikey).to be_nil
    end

    it "ignores non-Bearer Authorization headers" do
      creds = described_class.extract_credentials("Authorization" => "Basic dXNlcjpwYXNz")
      expect(creds.token).to be_nil
    end

    it "returns nil for empty Bearer token" do
      creds = described_class.extract_credentials("Authorization" => "Bearer ")
      expect(creds.token).to be_nil
    end

    it "returns nil for whitespace-only Bearer token" do
      creds = described_class.extract_credentials("Authorization" => "Bearer   ")
      expect(creds.token).to be_nil
    end

    it "strips surrounding whitespace from Bearer token" do
      creds = described_class.extract_credentials("Authorization" => "Bearer   abc123  ")
      expect(creds.token).to eq("abc123")
    end

    it "matches Bearer scheme case-insensitively" do
      %w[Bearer bearer BEARER BeArEr].each do |scheme|
        creds = described_class.extract_credentials("Authorization" => "#{scheme} test-token")
        expect(creds.token).to eq("test-token"), "expected '#{scheme}' to match"
      end
    end

    it "returns nil for Authorization without a space after the scheme" do
      creds = described_class.extract_credentials("Authorization" => "Bearertoken")
      expect(creds.token).to be_nil
    end

    it "returns nil when Authorization header value is empty" do
      creds = described_class.extract_credentials("Authorization" => "")
      expect(creds.token).to be_nil
    end

    it "looks up Authorization header case-insensitively" do
      %w[authorization Authorization AUTHORIZATION aUtHoRiZaTiOn].each do |name|
        creds = described_class.extract_credentials(name => "Bearer test-token")
        expect(creds.token).to eq("test-token"), "expected '#{name}' to be found"
      end
    end

    it "looks up apikey header case-insensitively" do
      %w[apikey ApiKey APIKEY ApIkEy].each do |name|
        creds = described_class.extract_credentials(name => "my-api-key")
        expect(creds.apikey).to eq("my-api-key"), "expected '#{name}' to be found"
      end
    end

    it "supports symbol keys" do
      creds = described_class.extract_credentials(authorization: "Bearer test-token", apikey: "my-api-key")
      expect(creds.token).to eq("test-token")
      expect(creds.apikey).to eq("my-api-key")
    end

    it "returns nil apikey for empty string value" do
      creds = described_class.extract_credentials("apikey" => "")
      expect(creds.apikey).to be_nil
    end

    it "returns a Credentials struct" do
      creds = described_class.extract_credentials({})
      expect(creds).to be_a(Supabase::Rails::Credentials)
      expect(creds).to respond_to(:token, :apikey)
    end

    it "works with arbitrary objects that respond to each_pair" do
      headers_like = Class.new do
        def initialize(hash) = @hash = hash
        def each_pair(&block) = @hash.each_pair(&block)
      end.new("Authorization" => "Bearer xyz")

      creds = described_class.extract_credentials(headers_like)
      expect(creds.token).to eq("xyz")
    end
  end
end
