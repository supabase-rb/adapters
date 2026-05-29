# frozen_string_literal: true

require_relative "lib/supabase/rails/version"

Gem::Specification.new do |spec|
  spec.name = "supabase-rails"
  spec.version = Supabase::Rails::VERSION
  spec.authors = ["Supabase"]
  spec.email = ["support@supabase.io"]

  spec.summary = "Supabase integration for Ruby on Rails"
  spec.description = "Rack middleware and controller concern that resolve a per-request " \
                     "Supabase context — JWT verification, API-key validation, and RLS-scoped " \
                     "clients — for Rails apps."
  spec.homepage = "https://github.com/supabase-ruby/supabase-rails"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/supabase-ruby/supabase-rails"

  spec.files = Dir["lib/**/*.rb"]
  spec.require_paths = ["lib"]

  spec.add_dependency "jwt", "~> 2.0"

  spec.add_development_dependency "rspec", "~> 3.13"
end
