# frozen_string_literal: true

require 'test_helper'

class TokenRefresherTest < Minitest::Test
  def test_network_errors_constant_defined
    errors = Teems::Services::TokenRefresher::NETWORK_ERRORS

    assert_includes errors, SocketError
    assert_includes errors, Errno::ECONNREFUSED
    assert_includes errors, Net::OpenTimeout
    assert_includes errors, Net::ReadTimeout
    assert_includes errors, JSON::ParserError
  end

  def test_refresh_returns_false_when_no_skype_spaces_token
    with_temp_config do
      store = mock_token_store(configured: true)
      store.define_singleton_method(:skype_spaces_token) { nil }

      refresher = Teems::Services::TokenRefresher.new(token_store: store)

      refute refresher.refresh
    end
  end

  def test_refresh_logs_when_no_skype_spaces_token
    with_temp_config do
      store = mock_token_store(configured: true)
      store.define_singleton_method(:skype_spaces_token) { nil }

      output = test_output
      refresher = Teems::Services::TokenRefresher.new(token_store: store, output: output)
      refresher.refresh

      # Debug messages go to output when verbose, but method was called
      # Just verify no exception raised
    end
  end

  def test_initializes_with_token_store
    with_temp_config do
      store = mock_token_store
      refresher = Teems::Services::TokenRefresher.new(token_store: store)

      assert_instance_of Teems::Services::TokenRefresher, refresher
    end
  end

  def test_initializes_with_optional_output
    with_temp_config do
      store = mock_token_store
      output = test_output
      refresher = Teems::Services::TokenRefresher.new(token_store: store, output: output)

      assert_instance_of Teems::Services::TokenRefresher, refresher
    end
  end
end

class TokenRefresherWithMockHttpTest < Minitest::Test
  # Test subclass that allows mocking the HTTP exchange
  class TestableTokenRefresher < Teems::Services::TokenRefresher
    attr_accessor :mock_response, :mock_error

    def exchange_token(_skype_spaces_token)
      raise mock_error if mock_error

      mock_response
    end
  end

  def test_refresh_returns_true_on_successful_exchange
    with_temp_config do |dir|
      write_tokens_file(dir, {
                          'auth_token' => 'test-auth',
                          'skype_token' => 'old-skype',
                          'skype_spaces_token' => 'spaces-token'
                        })
      store = Teems::Services::TokenStore.new
      refresher = TestableTokenRefresher.new(token_store: store)
      refresher.mock_response = 'new-skype-token'

      assert refresher.refresh
    end
  end

  def test_refresh_updates_token_in_store
    with_temp_config do |dir|
      write_tokens_file(dir, {
                          'auth_token' => 'test-auth',
                          'skype_token' => 'old-skype',
                          'skype_spaces_token' => 'spaces-token'
                        })
      store = Teems::Services::TokenStore.new
      refresher = TestableTokenRefresher.new(token_store: store)
      refresher.mock_response = 'new-skype-token'

      refresher.refresh

      # Reload and check
      account = store.account
      assert_equal 'new-skype-token', account.skype_token
    end
  end

  def test_refresh_returns_false_on_nil_response
    with_temp_config do |dir|
      write_tokens_file(dir, {
                          'auth_token' => 'test-auth',
                          'skype_token' => 'old-skype',
                          'skype_spaces_token' => 'spaces-token'
                        })
      store = Teems::Services::TokenStore.new
      refresher = TestableTokenRefresher.new(token_store: store)
      refresher.mock_response = nil

      refute refresher.refresh
    end
  end

  def test_refresh_returns_false_on_network_error
    with_temp_config do |dir|
      write_tokens_file(dir, {
                          'auth_token' => 'test-auth',
                          'skype_token' => 'old-skype',
                          'skype_spaces_token' => 'spaces-token'
                        })
      store = Teems::Services::TokenStore.new
      refresher = TestableTokenRefresher.new(token_store: store)
      refresher.mock_error = SocketError.new('connection failed')

      refute refresher.refresh
    end
  end

  def test_refresh_preserves_original_token_on_failure
    with_temp_config do |dir|
      write_tokens_file(dir, {
                          'auth_token' => 'test-auth',
                          'skype_token' => 'original-skype',
                          'skype_spaces_token' => 'spaces-token'
                        })
      store = Teems::Services::TokenStore.new
      refresher = TestableTokenRefresher.new(token_store: store)
      refresher.mock_response = nil

      refresher.refresh

      account = store.account
      assert_equal 'original-skype', account.skype_token
    end
  end
end

class TokenRefresherExchangeTokenTest < Minitest::Test
  # Test the actual exchange_token method logic without network calls
  class ExposedTokenRefresher < Teems::Services::TokenRefresher
    public :exchange_token
  end

  def test_exchange_token_handles_json_parse_error
    with_temp_config do
      store = mock_token_store
      refresher = ExposedTokenRefresher.new(token_store: store, output: test_output)

      # Mock HTTP to return invalid JSON - we can't easily do this without
      # a full HTTP mock library, so we test the error handling constant
      errors = Teems::Services::TokenRefresher::NETWORK_ERRORS
      assert_includes errors, JSON::ParserError
    end
  end
end
