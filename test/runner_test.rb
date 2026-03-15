# frozen_string_literal: true

require 'test_helper'

class RunnerTest < Minitest::Test
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
      runner = Teems::Runner.new(output: custom_output)

      assert_equal custom_output, runner.output
    end
  end

  def test_configured_returns_false_when_no_tokens
    with_temp_config do
      runner = Teems::Runner.new

      refute runner.configured?
    end
  end

  def test_configured_returns_true_when_tokens_exist
    with_temp_config do |dir|
      write_tokens_file(dir, {
                          'auth_token' => 'test-auth',
                          'skype_token' => 'test-skype'
                        })
      runner = Teems::Runner.new

      assert runner.configured?
    end
  end

  def test_account_returns_account_when_configured
    with_temp_config do |dir|
      write_tokens_file(dir, {
                          'auth_token' => 'test-auth',
                          'skype_token' => 'test-skype'
                        })
      runner = Teems::Runner.new

      account = runner.account

      assert_kind_of Teems::Models::Account, account
      assert_equal 'test-auth', account.auth_token
    end
  end

  def test_account_raises_when_not_configured
    with_temp_config do
      runner = Teems::Runner.new

      assert_raises(Teems::ConfigError) { runner.account }
    end
  end

  def test_channels_api_returns_channels_api
    with_temp_config do |dir|
      write_tokens_file(dir, {
                          'auth_token' => 'test-auth',
                          'skype_token' => 'test-skype'
                        })
      runner = Teems::Runner.new

      assert_kind_of Teems::Api::Channels, runner.channels_api
    end
  end

  def test_chats_api_returns_chats_api
    with_temp_config do |dir|
      write_tokens_file(dir, {
                          'auth_token' => 'test-auth',
                          'skype_token' => 'test-skype'
                        })
      runner = Teems::Runner.new

      assert_kind_of Teems::Api::Chats, runner.chats_api
    end
  end

  def test_messages_api_returns_messages_api
    with_temp_config do |dir|
      write_tokens_file(dir, {
                          'auth_token' => 'test-auth',
                          'skype_token' => 'test-skype'
                        })
      runner = Teems::Runner.new

      assert_kind_of Teems::Api::Messages, runner.messages_api
    end
  end

  def test_message_formatter_returns_formatter
    with_temp_config do
      runner = Teems::Runner.new

      assert_kind_of Teems::Formatters::MessageFormatter, runner.message_formatter
    end
  end

  def test_token_extractor_returns_extractor
    with_temp_config do
      runner = Teems::Runner.new

      assert_kind_of Teems::Services::TokenExtractor, runner.token_extractor
    end
  end

  def test_token_refresher_returns_refresher
    with_temp_config do
      runner = Teems::Runner.new

      assert_kind_of Teems::Services::TokenRefresher, runner.token_refresher
    end
  end

  def test_refresh_tokens_delegates_to_refresher
    with_temp_config do
      store = mock_token_store
      store.define_singleton_method(:skype_spaces_token) { nil }
      runner = Teems::Runner.new(token_store: store)

      refute runner.refresh_tokens
    end
  end

  def test_log_error_delegates_to_error_logger
    with_temp_config do
      runner = Teems::Runner.new
      error = RuntimeError.new('test')

      result = runner.log_error(error)

      assert result
    end
  end

  def test_clear_api_cache_does_not_raise
    with_temp_config do
      runner = Teems::Runner.new
      runner.clear_api_cache
    end
  end

  def test_calendar_api_returns_calendar_api
    with_temp_config do |dir|
      write_tokens_file(dir, {
                          'auth_token' => 'test-auth',
                          'skype_token' => 'test-skype'
                        })
      runner = Teems::Runner.new

      assert_kind_of Teems::Api::Calendar, runner.calendar_api
    end
  end
end
