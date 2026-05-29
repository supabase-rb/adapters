# frozen_string_literal: true

require_relative "server/version"
require_relative "server/errors"
require_relative "server/logging"
require_relative "server/env"
require_relative "server/jwt"
require_relative "server/core"
require_relative "server/context"
require_relative "server/cors"

module Supabase
  module Server
    CONTEXT_KEY = "supabase.context"
  end
end
