# frozen_string_literal: true

module Supabase
  module Server
    module Logging
      @mutex = Mutex.new
      @logger = nil

      class << self
        def logger
          @mutex.synchronize { @logger }
        end

        def logger=(value)
          @mutex.synchronize { @logger = value }
        end

        def log(level, message)
          current = logger
          return if current.nil?
          return unless current.respond_to?(level)

          current.public_send(level, message)
        rescue StandardError
          nil
        end
      end
    end

    def self.logger
      Logging.logger
    end

    def self.logger=(value)
      Logging.logger = value
    end
  end
end
