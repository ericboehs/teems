# frozen_string_literal: true

require 'test_helper'

# Tests for Runner initialization, service wiring, and API accessor methods
module RunnerTests
  # Tests Runner default initialization and delegated service methods
  class BasicTest < Minitest::Test
    def test_initializes_with_default_services
      with_temp_config do
        runner = Teems::Runner.new
        assert_kind_of Teems::Formatters::Output, runner.output
        assert_kind_of Teems::Services::Configuration, runner.config
        assert_kind_of Teems::Services::TokenStore, runner.token_store
        assert_kind_of Teems::Services::ApiClient, runner.api_client
        assert_kind_of Teems::Services::CacheStore, runner.cache_store
      end
    end

    def test_initializes_with_custom_output
      with_temp_config do
        custom_output = test_output
        assert_equal custom_output, Teems::Runner.new(output: custom_output).output
      end
    end

    def test_configured_returns_false_when_no_tokens
      with_temp_config do
        refute Teems::Runner.new.configured?
      end
    end

    def test_configured_returns_true_when_tokens_exist
      with_temp_config do |dir|
        write_tokens_file(dir, { 'auth_token' => 'test-auth', 'skype_token' => 'test-skype' })
        assert Teems::Runner.new.configured?
      end
    end

    def test_account_returns_account_when_configured
      with_temp_config do |dir|
        write_tokens_file(dir, { 'auth_token' => 'test-auth', 'skype_token' => 'test-skype' })
        account = Teems::Runner.new.account
        assert_kind_of Teems::Models::Account, account
        assert_equal 'test-auth', account.auth_token
      end
    end

    def test_account_raises_when_not_configured
      with_temp_config do
        assert_raises(Teems::ConfigError) { Teems::Runner.new.account }
      end
    end

    def test_message_formatter_returns_formatter
      with_temp_config do
        assert_kind_of Teems::Formatters::MessageFormatter, Teems::Runner.new.message_formatter
      end
    end

    def test_token_extractor_returns_extractor
      with_temp_config do
        assert_kind_of Teems::Services::TokenExtractor, Teems::Runner.new.token_extractor
      end
    end

    def test_token_refresher_returns_refresher
      with_temp_config do
        assert_kind_of Teems::Services::TokenRefresher, Teems::Runner.new.token_refresher
      end
    end

    def test_refresh_tokens_delegates_to_refresher
      with_temp_config do
        store = mock_token_store
        store.define_singleton_method(:skype_spaces_token) { nil }
        refute Teems::Runner.new(token_store: store).refresh_tokens
      end
    end

    def test_clear_api_cache_does_not_raise
      with_temp_config { Teems::Runner.new.clear_api_cache }
    end
  end

  # Tests that Runner returns the correct API instances for each resource type
  class ApiTest < Minitest::Test
    def test_channels_api_returns_channels_api
      with_temp_config do |dir|
        write_tokens_file(dir, { 'auth_token' => 'test-auth', 'skype_token' => 'test-skype' })
        assert_kind_of Teems::Api::Channels, Teems::Runner.new.channels_api
      end
    end

    def test_chats_api_returns_chats_api
      with_temp_config do |dir|
        write_tokens_file(dir, { 'auth_token' => 'test-auth', 'skype_token' => 'test-skype' })
        assert_kind_of Teems::Api::Chats, Teems::Runner.new.chats_api
      end
    end

    def test_messages_api_returns_messages_api
      with_temp_config do |dir|
        write_tokens_file(dir, { 'auth_token' => 'test-auth', 'skype_token' => 'test-skype' })
        assert_kind_of Teems::Api::Messages, Teems::Runner.new.messages_api
      end
    end

    def test_calendar_api_returns_calendar_api
      with_temp_config do |dir|
        write_tokens_file(dir, { 'auth_token' => 'test-auth', 'skype_token' => 'test-skype' })
        assert_kind_of Teems::Api::Calendar, Teems::Runner.new.calendar_api
      end
    end

    def test_files_api_returns_files_api
      with_temp_config do |dir|
        write_tokens_file(dir, { 'auth_token' => 'test-auth', 'skype_token' => 'test-skype' })
        assert_kind_of Teems::Api::Files, Teems::Runner.new.files_api
      end
    end
  end
end
