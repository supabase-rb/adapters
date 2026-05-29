# frozen_string_literal: true

require "rails/railtie"

module Supabase
  module Rails
    class Railtie < ::Rails::Railtie
      config.supabase = ActiveSupport::OrderedOptions.new
      config.supabase.auth = :user
      config.supabase.cors = nil
      config.supabase.env = nil
      config.supabase.supabase_options = nil
      config.supabase.insert_middleware = true

      initializer "supabase.middleware" do |app|
        cfg = app.config.supabase
        next unless cfg.insert_middleware

        app.middleware.use Supabase::Rails::Middleware,
                           auth: cfg.auth,
                           env: cfg.env,
                           supabase_options: cfg.supabase_options,
                           cors: cfg.cors
      end
    end
  end
end
