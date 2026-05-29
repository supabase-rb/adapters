# frozen_string_literal: true

require_relative "lib/supabase/server/version"

Gem::Specification.new do |spec|
  spec.name = "supabase-server"
  spec.version = Supabase::Server::VERSION
  spec.authors = ["Supabase"]
  spec.email = ["support@supabase.io"]

  spec.summary = "Server-side primitives for Supabase on Ruby web frameworks"
  spec.description = "Environment resolution, credential extraction, JWT verification, " \
                     "and per-request Supabase client creation for Rails and Hanami apps."
  spec.homepage = "https://github.com/supabase-rb/server"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/supabase-rb/server"

  spec.files = Dir["lib/**/*.rb"]
  spec.require_paths = ["lib"]

  spec.add_dependency "jwt", "~> 2.0"

  spec.add_development_dependency "rspec", "~> 3.13"
end
