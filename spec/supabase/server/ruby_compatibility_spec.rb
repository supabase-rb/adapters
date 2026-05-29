# frozen_string_literal: true

require "spec_helper"
require "supabase/server/rails"

RSpec.describe "Ruby compatibility (NFR-3)" do
  LIB_ROOT = File.expand_path("../../../lib/supabase/server", __dir__)
  GEMSPEC_PATH = File.expand_path("../../../supabase-server.gemspec", __dir__)

  def all_lib_files
    Dir[File.join(LIB_ROOT, "**", "*.rb")]
  end

  describe "Ruby >= 3.2 (Data.define floor)" do
    it "gemspec declares required_ruby_version >= 3.2" do
      gemspec = Gem::Specification.load(GEMSPEC_PATH)
      expect(gemspec.required_ruby_version.satisfied_by?(Gem::Version.new("3.2.0"))).to be(true)
      expect(gemspec.required_ruby_version.satisfied_by?(Gem::Version.new("3.1.6"))).to be(false)
    end

    it "runs on the current interpreter (>= 3.2)" do
      expect(Gem::Version.new(RUBY_VERSION)).to be >= Gem::Version.new("3.2.0")
    end
  end

  describe "Frozen string literals throughout" do
    it "every lib/**/*.rb file declares # frozen_string_literal: true on the first line" do
      missing = all_lib_files.reject do |path|
        File.open(path, &:readline).strip == "# frozen_string_literal: true"
      end
      expect(missing).to be_empty,
        "files missing frozen_string_literal magic comment: #{missing.inspect}"
    end

    it "module-level string constants are frozen" do
      expect(Supabase::Server::CORS::DEFAULT_HEADERS).to be_frozen
      expect(Supabase::Server::EnvError::MISSING_SUPABASE_URL).to be_frozen
      expect(Supabase::Server::AuthError::INVALID_CREDENTIALS).to be_frozen
    end
  end

  describe "No eval, no method_missing, no monkey-patches outside opt-in concerns" do
    it "no source file calls eval / instance_eval / class_eval / module_eval" do
      offenders = all_lib_files.select do |path|
        File.read(path).match?(/\b(?:instance_eval|class_eval|module_eval|^|[^.\w])eval\b/)
      end
      expect(offenders).to be_empty,
        "files using eval-family methods: #{offenders.inspect}"
    end

    it "no source file defines method_missing" do
      offenders = all_lib_files.select do |path|
        File.read(path).match?(/\bdef\s+(?:self\.)?method_missing\b/)
      end
      expect(offenders).to be_empty,
        "files defining method_missing: #{offenders.inspect}"
    end

    it "does not reopen core classes (Object/String/Hash/Array/Kernel/etc.) to monkey-patch them" do
      core_classes = %w[Object String Hash Array Kernel Numeric Integer Float Symbol Proc Module Class]
      offenders = []
      all_lib_files.each do |path|
        source = File.read(path)
        core_classes.each do |klass|
          next unless source.match?(/^\s*(?:class|module)\s+#{klass}\b(?!\s*::)/)

          offenders << "#{path}: reopens ::#{klass}"
        end
      end
      expect(offenders).to be_empty,
        "monkey-patches found:\n#{offenders.join("\n")}"
    end

    it "opt-in concerns (Rails::Controller) only mutate the including class, not core classes" do
      # Confirm the concerns are inert until explicitly included into a host class.
      bare = Class.new
      bare.include(Supabase::Server::Rails::Controller)
      expect(Object.instance_methods).not_to include(:supabase_context)
      expect(Kernel.instance_methods).not_to include(:verify_supabase_auth)
    end
  end

  describe "Public surface loads cleanly under disable_monkey_patching!" do
    it "RSpec's disable_monkey_patching! is in effect for this suite" do
      expect(RSpec.configuration.expose_dsl_globally?).to be(false)
    end

    it "core modules are reachable without any extra requires beyond `supabase/server`" do
      expect(defined?(Supabase::Server::Env)).to eq("constant")
      expect(defined?(Supabase::Server::Core)).to eq("constant")
      expect(defined?(Supabase::Server::JWT)).to eq("constant")
      expect(defined?(Supabase::Server::CORS)).to eq("constant")
      expect(defined?(Supabase::Server::EnvError)).to eq("constant")
      expect(defined?(Supabase::Server::AuthError)).to eq("constant")
    end
  end
end
