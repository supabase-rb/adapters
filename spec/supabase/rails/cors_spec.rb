# frozen_string_literal: true

require "spec_helper"

RSpec.describe Supabase::Rails::CORS do
  describe ".build_headers" do
    it "returns supabase-js defaults when config is true" do
      headers = described_class.build_headers(true)
      expect(headers["Access-Control-Allow-Origin"]).to eq("*")
      expect(headers["Access-Control-Allow-Methods"]).to include("GET")
      expect(headers["Access-Control-Allow-Headers"]).to include("authorization")
    end

    it "returns supabase-js defaults when config is nil" do
      headers = described_class.build_headers(nil)
      expect(headers["Access-Control-Allow-Origin"]).to eq("*")
    end

    it "returns supabase-js defaults when no argument is given" do
      headers = described_class.build_headers
      expect(headers["Access-Control-Allow-Origin"]).to eq("*")
    end

    it "returns empty hash when config is false" do
      expect(described_class.build_headers(false)).to eq({})
    end

    it "returns custom headers as-is (same object identity)" do
      custom = {
        "Access-Control-Allow-Origin" => "https://example.com",
        "Access-Control-Allow-Headers" => "X-Custom"
      }
      result = described_class.build_headers(custom)
      expect(result).to equal(custom)
    end

    it "exposes the default headers as a frozen constant" do
      expect(described_class::DEFAULT_HEADERS).to be_frozen
      expect(described_class::DEFAULT_HEADERS["Access-Control-Allow-Origin"]).to eq("*")
      expect(described_class::DEFAULT_HEADERS["Access-Control-Allow-Headers"]).to eq(
        "authorization, x-client-info, apikey, content-type, x-retry-count"
      )
      expect(described_class::DEFAULT_HEADERS["Access-Control-Allow-Methods"]).to eq(
        "GET, POST, PUT, PATCH, DELETE, OPTIONS"
      )
    end
  end

  describe ".add_headers" do
    it "adds default CORS headers to response headers" do
      result = described_class.add_headers({ "Content-Type" => "text/plain" }, true)
      expect(result["Access-Control-Allow-Origin"]).to eq("*")
      expect(result["Content-Type"]).to eq("text/plain")
    end

    it "adds default CORS headers when config is nil" do
      result = described_class.add_headers({}, nil)
      expect(result["Access-Control-Allow-Origin"]).to eq("*")
    end

    it "returns headers unchanged when config is false" do
      original = { "Content-Type" => "text/plain" }
      result = described_class.add_headers(original, false)
      expect(result).to equal(original)
      expect(result["Access-Control-Allow-Origin"]).to be_nil
    end

    it "adds custom CORS headers to response headers" do
      result = described_class.add_headers(
        {},
        { "Access-Control-Allow-Origin" => "https://example.com" }
      )
      expect(result["Access-Control-Allow-Origin"]).to eq("https://example.com")
    end

    it "overwrites existing CORS headers" do
      result = described_class.add_headers(
        { "Access-Control-Allow-Origin" => "https://old.com" },
        { "Access-Control-Allow-Origin" => "https://new.com" }
      )
      expect(result["Access-Control-Allow-Origin"]).to eq("https://new.com")
    end

    it "does not mutate the caller's headers hash" do
      original = { "Content-Type" => "text/plain" }
      described_class.add_headers(original, true)
      expect(original).to eq({ "Content-Type" => "text/plain" })
    end
  end
end
