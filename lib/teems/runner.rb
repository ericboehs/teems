# frozen_string_literal: true

module Teems
  # Dependency injection container providing services to commands
  class Runner
    attr_reader :output, :config, :token_store, :api_client, :cache_store

    def initialize(
      output: nil,
      config: nil,
      token_store: nil,
      api_client: nil,
      cache_store: nil
    )
      @output = output || Formatters::Output.new
      @config = config || Services::Configuration.new
      @token_store = token_store || Services::TokenStore.new
      @api_client = api_client || Services::ApiClient.new
      @cache_store = cache_store || Services::CacheStore.new

      wire_up_warnings
    end

    # Account helpers
    def account
      @token_store.account or raise ConfigError, 'No account configured. Run: teems auth login'
    end

    def configured?
      @token_store.configured?
    end

    # API helpers
    def channels_api
      Api::Channels.new(@api_client, account)
    end

    def chats_api
      Api::Chats.new(@api_client, account)
    end

    def messages_api
      Api::Messages.new(@api_client, account)
    end

    # Formatter helpers
    def message_formatter
      @message_formatter ||= Formatters::MessageFormatter.new(
        output: @output,
        cache_store: @cache_store
      )
    end

    # Token extractor for Safari automation
    def token_extractor
      @token_extractor ||= Services::TokenExtractor.new
    end

    # Logging
    def log_error(error)
      Support::ErrorLogger.log(error)
    end

    private

    def wire_up_warnings
      warning_handler = ->(message) { @output.warn(message) }
      @config.on_warning = warning_handler
    end
  end
end
