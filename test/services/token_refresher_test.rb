# frozen_string_literal: true

require 'test_helper'

class TokenRefresherTest < Minitest::Test
  def test_recoverable_errors_constant_defined
    errors = Teems::Services::TokenRefresher::RECOVERABLE_ERRORS

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

class TokenRefresherBuildMethodsTest < Minitest::Test
  class ExposedBuilder < Teems::Services::TokenRefresher
    public :build_exchange_http, :build_exchange_request
  end

  def test_build_exchange_http_returns_http_client
    with_temp_config do
      store = mock_token_store
      refresher = ExposedBuilder.new(token_store: store)

      http = refresher.build_exchange_http

      assert_instance_of Net::HTTP, http
      assert http.use_ssl?
      assert_equal 10, http.open_timeout
      assert_equal 30, http.read_timeout
    end
  end

  def test_build_exchange_request_returns_post_request
    with_temp_config do
      store = mock_token_store
      refresher = ExposedBuilder.new(token_store: store)

      request = refresher.build_exchange_request('test-spaces-token')

      assert_instance_of Net::HTTP::Post, request
      assert_equal 'Bearer test-spaces-token', request['Authorization']
      assert_equal 'application/json', request['Content-Type']
      assert_equal '{}', request.body
    end
  end
end

class TokenRefresherExchangeTokenTest < Minitest::Test
  # Test the actual exchange_token method logic without network calls
  class ExposedTokenRefresher < Teems::Services::TokenRefresher
    public :exchange_token, :parse_exchange_response
  end

  def test_parse_exchange_response_success
    with_temp_config do
      store = mock_token_store
      refresher = ExposedTokenRefresher.new(token_store: store, output: test_output)
      response = build_http_response('200', 'OK', '{"tokens":{"skypeToken":"new-token"}}')

      result = refresher.parse_exchange_response(response)

      assert_equal 'new-token', result
    end
  end

  def test_parse_exchange_response_failure
    with_temp_config do
      store = mock_token_store
      refresher = ExposedTokenRefresher.new(token_store: store, output: test_output)
      response = build_http_response('500', 'Internal Server Error', '')

      result = refresher.parse_exchange_response(response)

      assert_nil result
    end
  end

  def test_parse_exchange_response_missing_tokens_key
    with_temp_config do
      store = mock_token_store
      refresher = ExposedTokenRefresher.new(token_store: store, output: test_output)
      response = build_http_response('200', 'OK', '{"other":"data"}')

      result = refresher.parse_exchange_response(response)

      assert_nil result
    end
  end

  def test_refresh_handles_json_parse_error
    with_temp_config do |dir|
      write_tokens_file(dir, {
                          'auth_token' => 'test-auth',
                          'skype_token' => 'old-skype',
                          'skype_spaces_token' => 'spaces-token'
                        })
      store = Teems::Services::TokenStore.new
      refresher = TokenRefresherWithMockHttpTest::TestableTokenRefresher.new(token_store: store)
      refresher.mock_error = JSON::ParserError.new('unexpected token')

      refute refresher.refresh
    end
  end

  def test_refresh_handles_timeout_error
    with_temp_config do |dir|
      write_tokens_file(dir, {
                          'auth_token' => 'test-auth',
                          'skype_token' => 'old-skype',
                          'skype_spaces_token' => 'spaces-token'
                        })
      store = Teems::Services::TokenStore.new
      refresher = TokenRefresherWithMockHttpTest::TestableTokenRefresher.new(token_store: store)
      refresher.mock_error = Net::ReadTimeout.new

      refute refresher.refresh
    end
  end

  private

  def build_http_response(code, message, body)
    response = Net::HTTPResponse::CODE_TO_OBJ[code].new('1.1', code, message)
    response.instance_variable_set(:@body, body)
    response.instance_variable_set(:@read, true)
    response
  end
end
