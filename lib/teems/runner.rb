# frozen_string_literal: true

module Teems
  # API factory methods for Runner, extracted to keep method count manageable
  module ApiFactories
    def channels_api = Api::Channels.new(api_client, account)
    def chats_api = Api::Chats.new(api_client, account)
    def messages_api = Api::Messages.new(api_client, account)
    def calendar_api = Api::Calendar.new(api_client, account)
    def users_api = Api::Users.new(api_client, account)
    def files_api = Api::Files.new(api_client, account)
  end

  # Dependency injection container providing services to commands
  class Runner
    include ApiFactories

    attr_reader :output, :config, :token_store, :api_client, :cache_store

    def initialize(
      output: Formatters::Output.new,
      config: Services::Configuration.new,
      token_store: Services::TokenStore.new,
      api_client: Services::ApiClient.new,
      cache_store: Services::CacheStore.new
    )
      @output = output
      @config = config
      @token_store = token_store
      @api_client = api_client
      @cache_store = cache_store

      wire_up_warnings
    end

    # Account helpers - always get fresh from token_store (important for token refresh)
    def account
      @token_store.account or raise ConfigError, 'No account configured. Run: teems auth login'
    end

    def configured?
      @token_store.configured?
    end

    # Clear any cached API instances after token refresh
    def clear_api_cache
      # API instances are not cached, but account is fetched fresh each time
      # This method exists for future extensibility
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
      @token_extractor ||= Services::TokenExtractor.new(output: @output)
    end

    # Token refresher for automatic token refresh
    def token_refresher
      @token_refresher ||= Services::TokenRefresher.new(
        token_store: @token_store,
        output: @output
      )
    end

    # Attempt to refresh the skype_token
    def refresh_tokens
      token_refresher.refresh
    end

    private

    def wire_up_warnings
      warning_handler = ->(message) { @output.warn(message) }
      @config.register_warning_handler(warning_handler)
    end
  end
end
