# frozen_string_literal: true

require 'test_helper'

class ApiClientTest < Minitest::Test
  def test_endpoints_constant_defined
    endpoints = Teems::Services::ApiClient::ENDPOINTS

    assert_equal 'https://graph.microsoft.com', endpoints[:graph]
    assert_equal 'https://teams.microsoft.com', endpoints[:teams]
    assert_equal 'https://ng.msg.gcc.teams.microsoft.com', endpoints[:msgservice]
  end

  def test_network_errors_constant_defined
    errors = Teems::Services::ApiClient::NETWORK_ERRORS

    assert_includes errors, SocketError
    assert_includes errors, Errno::ECONNREFUSED
    assert_includes errors, Net::OpenTimeout
    assert_includes errors, Net::ReadTimeout
  end

  def test_initializes_with_zero_call_count
    client = Teems::Services::ApiClient.new
    assert_equal 0, client.call_count
  end

  def test_get_raises_for_unknown_endpoint
    client = Teems::Services::ApiClient.new
    account = mock_account

    error = assert_raises(ArgumentError) do
      client.get(:unknown, '/path', account: account)
    end

    assert_match(/Unknown endpoint/, error.message)
  end

  def test_post_raises_for_unknown_endpoint
    client = Teems::Services::ApiClient.new
    account = mock_account

    error = assert_raises(ArgumentError) do
      client.post(:unknown, '/path', account: account)
    end

    assert_match(/Unknown endpoint/, error.message)
  end

  def test_on_request_callback_can_be_set
    client = Teems::Services::ApiClient.new
    callback = ->(path, count) { "#{path} #{count}" }

    client.on_request = callback

    assert_equal callback, client.on_request
  end

  def test_on_response_callback_can_be_set
    client = Teems::Services::ApiClient.new
    callback = ->(path, code) { "#{path} #{code}" }

    client.on_response = callback

    assert_equal callback, client.on_response
  end

  def test_close_does_not_raise
    client = Teems::Services::ApiClient.new

    # Should not raise even when no connections exist
    # close returns the cleared hash (empty)
    client.close
    # If we get here without exception, test passes
    pass
  end
end

class ApiClientResponseHandlingTest < Minitest::Test
  # Test subclass to expose private methods for testing
  class TestableApiClient < Teems::Services::ApiClient
    public :parse_success_response, :handle_rate_limit
  end

  def test_parse_success_response_handles_json
    client = TestableApiClient.new
    response = MockBody.new('{"key": "value"}')

    result = client.parse_success_response(response)

    assert_equal({ 'key' => 'value' }, result)
  end

  def test_parse_success_response_handles_empty_body
    client = TestableApiClient.new
    response = MockBody.new('')

    result = client.parse_success_response(response)

    assert_equal({}, result)
  end

  def test_parse_success_response_handles_nil_body
    client = TestableApiClient.new
    response = MockBody.new(nil)

    result = client.parse_success_response(response)

    assert_equal({}, result)
  end

  def test_parse_success_response_raises_on_invalid_json
    client = TestableApiClient.new
    response = MockBody.new('not json')

    error = assert_raises(Teems::ApiError) do
      client.parse_success_response(response)
    end

    assert_match(/Invalid JSON/, error.message)
  end

  def test_handle_rate_limit_with_retry_after
    client = TestableApiClient.new
    response = MockRateLimit.new('60')

    error = assert_raises(Teems::ApiError) do
      client.handle_rate_limit(response)
    end

    assert_match(/retry after 60/, error.message)
  end

  def test_handle_rate_limit_without_retry_after
    client = TestableApiClient.new
    response = MockRateLimit.new(nil)

    error = assert_raises(Teems::ApiError) do
      client.handle_rate_limit(response)
    end

    assert_match(/Rate limited/, error.message)
  end

  # Simple mocks for response body testing
  class MockBody
    attr_reader :body

    def initialize(body)
      @body = body
    end
  end

  class MockRateLimit
    def initialize(retry_after)
      @retry_after = retry_after
    end

    def [](key)
      @retry_after if key == 'Retry-After'
    end
  end
end
