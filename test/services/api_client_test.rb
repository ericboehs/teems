# frozen_string_literal: true

require 'test_helper'

# Tests for the ApiClient service
module ApiClientTests
  # Tests basic ApiClient initialization, constants, and callbacks
  class BasicTest < Minitest::Test
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

      client.close
      pass
    end
  end

  # Tests HTTP response handling, auth application, and endpoint resolution
  class HandleResponseTest < Minitest::Test
    # Exposes private response handling and auth methods for testing
    class ExposedApiClient < Teems::Services::ApiClient
      public :handle_response, :apply_auth, :resolve_endpoint
    end

    def test_handle_response_401_raises_unauthorized
      client = ExposedApiClient.new
      response = build_http_response('401', 'Unauthorized', '')

      error = assert_raises(Teems::ApiError) { client.handle_response(response) }

      assert_equal 401, error.status_code
      assert error.unauthorized?
    end

    def test_handle_response_403_raises_forbidden
      client = ExposedApiClient.new
      response = build_http_response('403', 'Forbidden', '')

      error = assert_raises(Teems::ApiError) { client.handle_response(response) }

      assert_equal 403, error.status_code
      assert error.forbidden?
    end

    def test_handle_response_429_raises_rate_limited
      client = ExposedApiClient.new
      response = build_http_response('429', 'Too Many Requests', '', headers: { 'Retry-After' => '30' })

      error = assert_raises(Teems::ApiError) { client.handle_response(response) }

      assert_equal 429, error.status_code
      assert error.rate_limited?
      assert_match(/retry after 30/, error.message)
    end

    def test_handle_response_500_raises_with_status_code
      client = ExposedApiClient.new
      response = build_http_response('500', 'Internal Server Error', '')

      error = assert_raises(Teems::ApiError) { client.handle_response(response) }

      assert_equal 500, error.status_code
      assert_match(/HTTP 500/, error.message)
    end

    def test_handle_response_200_parses_json
      client = ExposedApiClient.new
      response = build_http_response('200', 'OK', '{"key":"value"}')

      result = client.handle_response(response)

      assert_equal({ 'key' => 'value' }, result)
    end

    def test_apply_auth_graph_uses_bearer
      client = ExposedApiClient.new
      account = mock_account
      request = Net::HTTP::Get.new('/')

      client.apply_auth(request, account, :graph)

      assert request['Authorization'].start_with?('Bearer ')
      assert_equal 'application/json', request['Content-Type']
    end

    def test_apply_auth_msgservice_uses_skype
      client = ExposedApiClient.new
      account = mock_account
      request = Net::HTTP::Get.new('/')

      client.apply_auth(request, account, :msgservice)

      assert request['Authentication'].start_with?('skypetoken=')
    end

    def test_apply_auth_teams_uses_bearer_skype_token
      client = ExposedApiClient.new
      account = mock_account
      request = Net::HTTP::Get.new('/')

      client.apply_auth(request, account, :teams)

      assert request['Authorization'].start_with?('Bearer ')
    end

    def test_resolve_endpoint_raises_for_unknown
      client = ExposedApiClient.new

      assert_raises(ArgumentError) { client.resolve_endpoint(:unknown) }
    end

    def build_http_response(code, message, body, headers: {})
      response = Net::HTTPResponse::CODE_TO_OBJ[code].new('1.1', code, message)
      response.instance_variable_set(:@body, body)
      response.instance_variable_set(:@read, true)
      headers.each { |header_name, header_value| response[header_name] = header_value }
      response
    end
  end

  # Tests on_request and on_response callback invocation
  class CallbacksTest < Minitest::Test
    def test_on_request_callback_receives_path_and_count
      calls = []
      client = build_mock_client_with_callback(:on_request) { |path, count| calls << [path, count] }
      Teems::Api::Channels.new(client, mock_account).list_teams

      first_call = calls.first
      assert_equal 1, calls.length
      assert_includes first_call[0], 'joinedTeams'
      assert_equal 1, first_call[1]
    end

    def test_on_response_callback_receives_path_and_status
      calls = []
      client = build_mock_client_with_callback(:on_response) { |path, code| calls << [path, code] }
      Teems::Api::Channels.new(client, mock_account).list_teams

      assert_equal 1, calls.length
      assert_equal '200', calls.first[1]
    end

    private

    def build_mock_client_with_callback(callback_name, &block)
      client = Teems::TestHelpers::MockApiClient.new
      client.stub('joinedTeams', { 'value' => [] })
      client.send(:"#{callback_name}=", block)
      client
    end
  end

  # Tests JSON body parsing and rate-limit error raising
  class ResponseHandlingTest < Minitest::Test
    # Exposes private parse and rate-limit methods for testing
    class TestableApiClient < Teems::Services::ApiClient
      public :parse_json_body, :raise_rate_limit
    end

    def test_parse_json_body_handles_json
      client = TestableApiClient.new
      response = MockBody.new('{"key": "value"}')

      result = client.parse_json_body(response)

      assert_equal({ 'key' => 'value' }, result)
    end

    def test_parse_json_body_handles_empty_body
      client = TestableApiClient.new
      response = MockBody.new('')

      result = client.parse_json_body(response)

      assert_equal({}, result)
    end

    def test_parse_json_body_handles_nil_body
      client = TestableApiClient.new
      response = MockBody.new(nil)

      result = client.parse_json_body(response)

      assert_equal({}, result)
    end

    def test_parse_json_body_raises_on_invalid_json
      client = TestableApiClient.new
      response = MockBody.new('not json')

      error = assert_raises(Teems::ApiError) do
        client.parse_json_body(response)
      end

      assert_match(/Invalid JSON/, error.message)
    end

    def test_raise_rate_limit_with_retry_after
      client = TestableApiClient.new
      response = MockRateLimit.new('60')

      error = assert_raises(Teems::ApiError) do
        client.raise_rate_limit(response)
      end

      assert_match(/retry after 60/, error.message)
      assert_equal 429, error.status_code
    end

    def test_raise_rate_limit_without_retry_after
      client = TestableApiClient.new
      response = MockRateLimit.new(nil)

      error = assert_raises(Teems::ApiError) do
        client.raise_rate_limit(response)
      end

      assert_match(/Rate limited/, error.message)
      assert_equal 429, error.status_code
    end

    # Mock HTTP response body for testing parse_json_body
    class MockBody
      attr_reader :body

      def initialize(body)
        @body = body
      end
    end

    # Mock HTTP response with Retry-After header for rate-limit testing
    class MockRateLimit
      def initialize(retry_after)
        @headers = { 'Retry-After' => retry_after }.freeze
      end

      def [](header_name)
        @headers[header_name]
      end
    end
  end

  # Tests ApiError status code predicates and message handling
  class ErrorTest < Minitest::Test
    def test_status_code_is_nil_by_default
      error = Teems::ApiError.new('Some error')
      assert_nil error.status_code
    end

    def test_status_code_can_be_set
      error = Teems::ApiError.new('Not Found', status_code: 404)
      assert_equal 404, error.status_code
    end

    def test_not_found_predicate
      assert Teems::ApiError.new('Not Found', status_code: 404).not_found?
      refute Teems::ApiError.new('Server Error', status_code: 500).not_found?
      refute Teems::ApiError.new('No status').not_found?
    end

    def test_unauthorized_predicate
      assert Teems::ApiError.new('Unauthorized', status_code: 401).unauthorized?
      refute Teems::ApiError.new('Not Found', status_code: 404).unauthorized?
    end

    def test_forbidden_predicate
      assert Teems::ApiError.new('Forbidden', status_code: 403).forbidden?
      refute Teems::ApiError.new('Not Found', status_code: 404).forbidden?
    end

    def test_rate_limited_predicate
      assert Teems::ApiError.new('Rate limited', status_code: 429).rate_limited?
      refute Teems::ApiError.new('Not Found', status_code: 404).rate_limited?
    end

    def test_message_is_preserved
      error = Teems::ApiError.new('HTTP 404: Not Found', status_code: 404)
      assert_equal 'HTTP 404: Not Found', error.message
    end

    def test_backwards_compatible_with_positional_message
      error = Teems::ApiError.new('Legacy error')
      assert_equal 'Legacy error', error.message
      assert_nil error.status_code
    end
  end

  # Tests HTTP connection pooling, SSL configuration, and caching
  class ConnectionPoolTest < Minitest::Test
    # Exposes private connection pool and SSL methods for testing
    class ExposedPool < Teems::Services::ApiClient
      public :get_http_for_endpoint, :start_http, :configure_http, :configure_ssl
    end

    def test_configure_http_sets_timeouts
      client = ExposedPool.new
      http = Net::HTTP.new('example.com', 443)

      client.configure_http(http, false)

      assert_equal 10, http.open_timeout
      assert_equal 30, http.read_timeout
      assert_equal 30, http.keep_alive_timeout
    end

    def test_configure_http_enables_ssl_when_requested
      client = ExposedPool.new
      http = Net::HTTP.new('example.com', 443)

      client.configure_http(http, true)

      assert http.use_ssl?
      assert_equal OpenSSL::SSL::VERIFY_PEER, http.verify_mode
    end

    def test_configure_http_skips_ssl_when_not_requested
      client = ExposedPool.new
      http = Net::HTTP.new('example.com', 80)

      client.configure_http(http, false)

      refute http.use_ssl?
    end

    def test_configure_ssl_sets_verify_peer
      client = ExposedPool.new
      http = Net::HTTP.new('example.com', 443)

      client.configure_ssl(http)

      assert_equal OpenSSL::SSL::VERIFY_PEER, http.verify_mode
      assert_instance_of OpenSSL::X509::Store, http.cert_store
    end

    def test_get_http_for_endpoint_returns_http
      client = ExposedPool.new
      http = client.get_http_for_endpoint(:graph)

      assert_instance_of Net::HTTP, http
      assert http.started?
    ensure
      client.close
    end

    def test_start_http_creates_started_http
      client = ExposedPool.new
      uri = URI('https://graph.microsoft.com')
      http = client.start_http(uri)

      assert_instance_of Net::HTTP, http
      assert http.started?
      assert http.use_ssl?
    ensure
      http&.finish if http&.started?
    end

    def test_get_http_caches_connection
      client = ExposedPool.new
      first = client.get_http_for_endpoint(:graph)
      second = client.get_http_for_endpoint(:graph)

      assert_same first, second
    ensure
      client.close
    end
  end

  # Tests connection cleanup and error handling during close
  class CloseTest < Minitest::Test
    def test_close_handles_io_error_gracefully
      client, cache = build_client_with_cache
      cache['broken:443'] = build_fake_http { raise IOError, 'stream closed' }

      client.close
      assert_empty cache
    end

    def test_close_finishes_started_connections
      client, cache = build_client_with_cache
      finished = false
      cache['fake:443'] = build_fake_http { finished = true }

      client.close

      assert finished
      assert_empty cache
    end

    private

    def build_client_with_cache
      client = Teems::Services::ApiClient.new
      cache = client.instance_variable_get(:@http_cache)
      [client, cache]
    end

    def build_fake_http(&on_finish)
      Object.new.tap do |http|
        http.define_singleton_method(:started?) { true }
        http.define_singleton_method(:finish, &on_finish)
      end
    end
  end

  # Tests the HTTP DELETE method on ApiClient
  class DeleteMethodTest < Minitest::Test
    def test_delete_raises_for_unknown_endpoint
      client = Teems::Services::ApiClient.new
      account = mock_account

      error = assert_raises(ArgumentError) do
        client.delete(:unknown, '/path', account: account)
      end

      assert_match(/Unknown endpoint/, error.message)
    end

    def test_delete_sends_delete_request
      client = StubbedApiClient.new
      account = mock_account

      client.delete(:graph, '/v1.0/me/chats/123', account: account)

      assert_equal 1, client.call_count
      assert_instance_of Net::HTTP::Delete, client.last_request
    end
  end

  # Tests presence endpoint auth header formatting
  class PresenceAuthTest < Minitest::Test
    # Exposes private apply_auth method for testing presence auth
    class ExposedAuth < Teems::Services::ApiClient
      public :apply_auth
    end

    def test_apply_auth_presence_uses_bearer_presence_token
      client = ExposedAuth.new
      account = Teems::Models::Account.new(
        name: 'test', auth_token: 'auth123', skype_token: 'skype456', presence_token: 'presence789'
      )
      request = Net::HTTP::Get.new('/')

      client.apply_auth(request, account, :presence)

      assert_equal 'Bearer presence789', request['Authorization']
    end
  end

  # Tests URI resolution for relative paths, absolute URLs, and query params
  class ResolveUriTest < Minitest::Test
    # Exposes private resolve_uri method for testing
    class ExposedUri < Teems::Services::ApiClient
      public :resolve_uri
    end

    def test_resolve_uri_prepends_endpoint_for_relative_path
      client = ExposedUri.new
      uri = client.resolve_uri(:graph, '/v1.0/me', {})

      assert_equal 'https://graph.microsoft.com/v1.0/me', uri.to_s
    end

    def test_resolve_uri_uses_absolute_url_when_given
      client = ExposedUri.new
      uri = client.resolve_uri(:graph, 'https://custom.example.com/api', {})

      assert_equal 'https://custom.example.com/api', uri.to_s
    end

    def test_resolve_uri_adds_query_params
      client = ExposedUri.new
      uri = client.resolve_uri(:graph, '/v1.0/me', { '$top' => '10', '$skip' => '0' })

      uri_string = uri.to_s
      assert_includes uri_string, '%24top=10'
      assert_includes uri_string, '%24skip=0'
    end

    def test_resolve_uri_skips_params_when_empty
      client = ExposedUri.new
      uri = client.resolve_uri(:graph, '/v1.0/me', {})

      assert_nil uri.query
    end
  end

  # Tests request execution, call counting, and network error wrapping
  class RunRequestTest < Minitest::Test
    def test_run_request_increments_call_count
      client = StubbedApiClient.new
      account = mock_account

      client.get(:graph, '/v1.0/me', account: account)

      assert_equal 1, client.call_count
    end

    def test_run_request_calls_on_request_callback
      client = StubbedApiClient.new
      account = mock_account
      received = []
      client.on_request = ->(path, count) { received << [path, count] }

      client.get(:graph, '/v1.0/me', account: account)

      first_received = received.first
      assert_equal 1, received.length
      assert_equal '/v1.0/me', first_received[0]
      assert_equal 1, first_received[1]
    end

    def test_run_request_calls_on_response_callback
      client = StubbedApiClient.new
      account = mock_account
      received = []
      client.on_response = ->(path, code) { received << [path, code] }

      client.get(:graph, '/v1.0/me', account: account)

      first_received = received.first
      assert_equal 1, received.length
      assert_equal '/v1.0/me', first_received[0]
      assert_equal '200', first_received[1]
    end

    def test_run_request_wraps_network_error_as_api_error
      client = NetworkErrorApiClient.new
      account = mock_account

      error = assert_raises(Teems::ApiError) do
        client.get(:graph, '/v1.0/me', account: account)
      end

      assert_match(/Network error/, error.message)
    end
  end

  # Tests custom header application on HTTP requests
  class ApplyHeadersTest < Minitest::Test
    def test_apply_headers_sets_custom_headers_on_request
      client = StubbedApiClient.new
      account = mock_account

      client.get(:graph, '/v1.0/me', account: account, headers: { 'X-Custom' => 'value', 'Accept' => 'text/plain' })

      assert_equal 'value', client.last_request['X-Custom']
      assert_equal 'text/plain', client.last_request['Accept']
    end
  end

  # Tests the HTTP POST method with JSON body serialization
  class PostMethodTest < Minitest::Test
    def test_post_sends_json_body
      client = StubbedApiClient.new
      account = mock_account

      client.post(:graph, '/v1.0/me/sendMail', account: account, body: { key: 'value' })

      last_request = client.last_request
      assert_equal 1, client.call_count
      assert_instance_of Net::HTTP::Post, last_request
      assert_equal '{"key":"value"}', last_request.body
    end

    def test_post_sends_without_body_when_nil
      client = StubbedApiClient.new
      account = mock_account

      client.post(:graph, '/v1.0/me/sendMail', account: account)

      assert_nil client.last_request.body
    end
  end

  # Tests the HTTP GET method with headers and query params
  class GetMethodTest < Minitest::Test
    def test_get_sends_request_with_headers
      client = StubbedApiClient.new
      account = mock_account

      client.get(:graph, '/v1.0/me', account: account, headers: { 'X-Test' => 'yes' })

      assert_equal 'yes', client.last_request['X-Test']
    end

    def test_get_sends_request_with_params
      client = StubbedApiClient.new
      account = mock_account

      client.get(:graph, '/v1.0/me', account: account, params: { '$top' => '5' })

      assert_includes client.last_request.path, '%24top=5'
    end
  end

  # Shared test helper: ApiClient subclass that stubs HTTP to capture requests
  class StubbedApiClient < Teems::Services::ApiClient
    attr_reader :last_request

    private

    def get_http_for_endpoint(_endpoint_key)
      @get_http_for_endpoint ||= FakeHttp.new(self)
    end

    # Minimal fake HTTP that records requests and returns a 200 JSON response
    class FakeHttp
      def initialize(client)
        @client = client
      end

      def request(req)
        @client.instance_variable_set(:@last_request, req)
        response = Net::HTTPResponse::CODE_TO_OBJ['200'].new('1.1', '200', 'OK')
        response.instance_variable_set(:@body, '{}')
        response.instance_variable_set(:@read, true)
        response
      end
    end
  end

  # ApiClient subclass that raises SocketError on any request
  class NetworkErrorApiClient < Teems::Services::ApiClient
    private

    def get_http_for_endpoint(_endpoint_key)
      FakeErrorHttp.new
    end

    # Fake HTTP connection that raises SocketError on every request
    class FakeErrorHttp
      def request(_req)
        raise SocketError, 'getaddrinfo: Name or service not known'
      end
    end
  end
end
