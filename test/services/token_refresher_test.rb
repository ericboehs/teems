# frozen_string_literal: true

require 'test_helper'

module TokenRefresherTests
  class BasicTest < Minitest::Test
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

  class TestableTokenRefresher < Teems::Services::TokenRefresher
    attr_accessor :mock_response, :mock_error

    def exchange_token(_skype_spaces_token)
      raise mock_error if mock_error

      mock_response
    end
  end

  class MockHttpTest < Minitest::Test
    def test_refresh_returns_true_on_successful_exchange
      with_temp_config do |dir|
        refresher, = build_testable_refresher(dir, mock_response: 'new-skype-token')

        assert refresher.refresh
      end
    end

    def test_refresh_updates_token_in_store
      with_temp_config do |dir|
        refresher, store = build_testable_refresher(dir, mock_response: 'new-skype-token')

        refresher.refresh

        assert_equal 'new-skype-token', store.account.skype_token
      end
    end

    def test_refresh_returns_false_on_nil_response
      with_temp_config do |dir|
        refresher, = build_testable_refresher(dir, mock_response: nil)

        refute refresher.refresh
      end
    end

    def test_refresh_returns_false_on_network_error
      with_temp_config do |dir|
        error = SocketError.new('connection failed')
        refresher, = build_testable_refresher(dir, mock_error: error)

        refute refresher.refresh
      end
    end

    def test_refresh_preserves_original_token_on_failure
      with_temp_config do |dir|
        refresher, store = build_testable_refresher(dir, skype_token: 'original-skype')

        refresher.refresh

        assert_equal 'original-skype', store.account.skype_token
      end
    end

    private

    def build_testable_refresher(dir, skype_token: 'old-skype', mock_response: nil, mock_error: nil)
      write_tokens_file(dir, {
                          'auth_token' => 'test-auth',
                          'skype_token' => skype_token,
                          'skype_spaces_token' => 'spaces-token'
                        })
      store = Teems::Services::TokenStore.new
      refresher = TestableTokenRefresher.new(token_store: store)
      refresher.mock_response = mock_response
      refresher.mock_error = mock_error
      [refresher, store]
    end
  end

  class BuildMethodsTest < Minitest::Test
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

  class ExchangeTokenTest < Minitest::Test
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
        error = JSON::ParserError.new('unexpected token')
        refresher = build_testable_refresher(dir, mock_error: error)

        refute refresher.refresh
      end
    end

    def test_refresh_handles_timeout_error
      with_temp_config do |dir|
        refresher = build_testable_refresher(dir, mock_error: Net::ReadTimeout.new)

        refute refresher.refresh
      end
    end

    private

    def build_testable_refresher(dir, mock_error: nil)
      write_tokens_file(dir, {
                          'auth_token' => 'test-auth',
                          'skype_token' => 'old-skype',
                          'skype_spaces_token' => 'spaces-token'
                        })
      store = Teems::Services::TokenStore.new
      refresher = TestableTokenRefresher.new(token_store: store)
      refresher.mock_error = mock_error
      refresher
    end

    def build_http_response(code, message, body)
      response = Net::HTTPResponse::CODE_TO_OBJ[code].new('1.1', code, message)
      response.instance_variable_set(:@body, body)
      response.instance_variable_set(:@read, true)
      response
    end
  end

  # Testable refresher that mocks both OIDC and authsvc HTTP calls
  class OidcTestableRefresher < Teems::Services::TokenRefresher
    attr_accessor :oidc_responses, :authsvc_response, :authsvc_error

    def initialize(token_store:, output: nil)
      super
      @oidc_responses = {}
      @authsvc_response = nil
      @authsvc_error = nil
    end

    private

    def oidc_token_request(scope, _refresh_token)
      @oidc_responses[scope]
    end

    def exchange_token(_skype_spaces_token)
      raise authsvc_error if authsvc_error

      authsvc_response
    end
  end

  class OidcRefreshTest < Minitest::Test
    GRAPH = Teems::Services::TokenRefresher::GRAPH_SCOPE
    SKYPE = Teems::Services::TokenRefresher::SKYPE_SCOPE

    def test_oidc_refresh_succeeds_with_all_tokens
      with_temp_config do |dir|
        refresher, store = build_successful_oidc(dir)
        assert refresher.refresh
        assert_equal 'new-auth', store.account.auth_token
        assert_equal 'new-skype', store.account.skype_token
      end
    end

    def test_oidc_refresh_saves_new_refresh_token
      with_temp_config do |dir|
        refresher, store = build_successful_oidc(dir)
        refresher.refresh
        assert_equal 'rt3', store.refresh_token
      end
    end

    def test_oidc_refresh_saves_skype_spaces_token
      with_temp_config do |dir|
        refresher, store = build_successful_oidc(dir)
        refresher.refresh
        assert_equal 'new-spaces', store.skype_spaces_token
      end
    end

    def test_oidc_falls_back_to_authsvc_when_graph_fails
      with_temp_config do |dir|
        refresher, store = build_oidc_refresher(dir)
        refresher.oidc_responses = { GRAPH => nil, SKYPE => nil }
        refresher.authsvc_response = 'fallback-skype'

        assert refresher.refresh
        assert_equal 'fallback-skype', store.account.skype_token
      end
    end

    def test_oidc_falls_back_to_authsvc_when_skype_scope_fails
      with_temp_config do |dir|
        refresher, store = build_oidc_refresher(dir)
        refresher.oidc_responses = { GRAPH => oidc_graph_response, SKYPE => nil }
        refresher.authsvc_response = 'fallback-skype'

        assert refresher.refresh
        assert_equal 'fallback-skype', store.account.skype_token
      end
    end

    def test_oidc_falls_back_when_authsvc_exchange_fails_in_oidc_flow
      with_temp_config do |dir|
        refresher, _store = build_successful_oidc(dir)
        refresher.authsvc_response = nil
        refute refresher.refresh
      end
    end

    def test_skips_oidc_when_no_refresh_token
      with_temp_config do |dir|
        tokens = { 'auth_token' => 'old-auth', 'skype_token' => 'old-skype',
                   'skype_spaces_token' => 'spaces', 'client_id' => 'cid', 'tenant_id' => 'tid' }
        write_tokens_file(dir, tokens)
        store = Teems::Services::TokenStore.new
        refresher = OidcTestableRefresher.new(token_store: store)
        refresher.authsvc_response = 'new-skype'

        assert refresher.refresh
        assert_equal 'new-skype', store.account.skype_token
      end
    end

    def test_oidc_falls_back_on_network_error
      with_temp_config do |dir|
        refresher, store = build_oidc_refresher(dir)
        stub_oidc_network_error(refresher)
        refresher.authsvc_response = 'fallback-skype'

        assert refresher.refresh
        assert_equal 'fallback-skype', store.account.skype_token
      end
    end

    private

    def stub_oidc_network_error(refresher)
      refresher.define_singleton_method(:oidc_token_request) { |*| raise SocketError, 'fail' }
    end

    def oidc_graph_response = { 'access_token' => 'new-auth', 'refresh_token' => 'rt2' }
    def oidc_skype_response = { 'access_token' => 'new-spaces', 'refresh_token' => 'rt3' }

    def build_successful_oidc(dir)
      refresher, store = build_oidc_refresher(dir)
      refresher.oidc_responses = { GRAPH => oidc_graph_response, SKYPE => oidc_skype_response }
      refresher.authsvc_response = 'new-skype'
      [refresher, store]
    end

    def build_oidc_refresher(dir)
      write_tokens_file(dir, { 'auth_token' => 'old-auth', 'skype_token' => 'old-skype',
                               'skype_spaces_token' => 'spaces',
                               'refresh_token' => 'rt1', 'client_id' => 'cid', 'tenant_id' => 'tid' })
      store = Teems::Services::TokenStore.new
      [OidcTestableRefresher.new(token_store: store), store]
    end
  end

  class OidcBuildMethodsTest < Minitest::Test
    class ExposedOidc < Teems::Services::TokenRefresher
      public :build_oidc_request, :oidc_token_uri
    end

    def test_build_oidc_request_headers_and_body
      with_temp_config do
        request = build_test_oidc_request
        assert_instance_of Net::HTTP::Post, request
        assert_equal 'application/x-www-form-urlencoded', request['Content-Type']
        assert_equal 'https://teams.microsoft.com', request['Origin']
      end
    end

    def test_build_oidc_request_params
      with_temp_config do
        request = build_test_oidc_request
        body = request.body
        assert_includes body, 'grant_type=refresh_token'
        assert_includes body, 'client_id=test-client'
        assert_includes body, 'refresh_token=my-rt'
      end
    end

    def test_oidc_token_uri_uses_tenant_id
      with_temp_config do
        store = mock_token_store
        store.tenant_id = 'my-tenant-123'
        refresher = ExposedOidc.new(token_store: store)

        assert_equal 'https://login.microsoftonline.com/my-tenant-123/oauth2/v2.0/token',
                     refresher.oidc_token_uri.to_s
      end
    end

    private

    def build_test_oidc_request
      store = mock_token_store
      store.tenant_id = 'test-tenant'
      store.client_id = 'test-client'
      refresher = ExposedOidc.new(token_store: store)
      refresher.build_oidc_request(refresher.oidc_token_uri, 'https://graph.microsoft.com/.default', 'my-rt')
    end
  end

  class OidcTokenRequestTest < Minitest::Test
    class ExposedOidcRequest < Teems::Services::TokenRefresher
      public :oidc_token_request, :log_oidc_failure, :oidc_token_uri
    end

    def test_oidc_token_request_returns_nil_on_http_failure
      with_temp_config do
        refresher = build_exposed_refresher
        response = build_http_response('401', 'Unauthorized', '{"error":"invalid_grant"}')
        result = refresher.log_oidc_failure(response)

        assert_nil result
      end
    end

    def test_log_oidc_failure_returns_nil
      with_temp_config do
        output = test_output
        refresher = build_exposed_refresher(output: output)
        response = build_http_response('403', 'Forbidden', '')

        assert_nil refresher.log_oidc_failure(response)
      end
    end

    private

    def build_exposed_refresher(output: nil)
      store = mock_token_store
      store.tenant_id = 'test-tenant'
      store.client_id = 'test-client'
      store.refresh_token = 'test-rt'
      ExposedOidcRequest.new(token_store: store, output: output)
    end

    def build_http_response(code, message, body)
      response = Net::HTTPResponse::CODE_TO_OBJ[code].new('1.1', code, message)
      response.instance_variable_set(:@body, body)
      response.instance_variable_set(:@read, true)
      response
    end
  end

  class LogExchangeFailureTest < Minitest::Test
    class ExposedExchange < Teems::Services::TokenRefresher
      public :parse_exchange_response
    end

    def test_parse_exchange_response_logs_failure_code
      with_temp_config do
        output = test_output
        store = mock_token_store
        refresher = ExposedExchange.new(token_store: store, output: output)
        response = build_http_response('403', 'Forbidden', '')

        result = refresher.parse_exchange_response(response)

        assert_nil result
      end
    end

    def test_parse_exchange_response_handles_malformed_json
      with_temp_config do
        store = mock_token_store
        refresher = ExposedExchange.new(token_store: store, output: test_output)
        response = build_http_response('200', 'OK', 'not-json')

        assert_raises(JSON::ParserError) { refresher.parse_exchange_response(response) }
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
end
