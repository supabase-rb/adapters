# frozen_string_literal: true

require_relative "rails/version"
require_relative "rails/errors"
require_relative "rails/logging"
require_relative "rails/env"
require_relative "rails/jwt"
require_relative "rails/core"
require_relative "rails/context"
require_relative "rails/cors"

module Supabase
  module Rails
    CONTEXT_KEY = "supabase.context"
  end
end

require_relative "rails/middleware"
require_relative "rails/controller"
require_relative "rails/railtie" if defined?(::Rails::Railtie)
