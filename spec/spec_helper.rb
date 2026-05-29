# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift File.expand_path("../../supabase-rb/lib", __dir__)

require "supabase/rails"

module EnvStub
  def with_env(vars)
    saved = {}
    vars.each do |name, value|
      saved[name] = ENV[name]
      if value.nil?
        ENV.delete(name)
      else
        ENV[name] = value
      end
    end
    yield
  ensure
    saved.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
  end
end

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |m|
    m.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed

  config.include EnvStub
end
