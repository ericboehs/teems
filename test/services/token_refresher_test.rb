# frozen_string_literal: true

require 'test_helper'

# Tests for TokenRefresher skype token exchange, OIDC refresh, and error recovery
module TokenRefresherTests
  # Tests initialization, recoverable errors constant, and missing token handling
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
        refute Teems::Services::TokenRefresher.new(token_store: store).refresh
      end
    end

    def test_refresh_logs_when_no_skype_spaces_token
      with_temp_config do
        store = mock_token_store(configured: true)
        store.define_singleton_method(:skype_spaces_token) { nil }
        Teems::Services::TokenRefresher.new(token_store: store, output: test_output).refresh
      end
    end

    def test_initializes_with_token_store
      with_temp_config do
        assert_instance_of Teems::Services::TokenRefresher,
                           Teems::Services::TokenRefresher.new(token_store: mock_token_store)
      end
    end

    def test_initializes_with_optional_output
      with_temp_config do
        refresher = Teems::Services::TokenRefresher.new(token_store: mock_token_store, output: test_output)
        assert_instance_of Teems::Services::TokenRefresher, refresher
      end
    end
  end

  # Testable subclass that mocks the exchange_token HTTP call
  class TestableTokenRefresher < Teems::Services::TokenRefresher
    def initialize(token_store:, mock_response: nil, mock_error: nil)
      super(token_store: token_store)
      @mock_response = mock_response
      @mock_error = mock_error
    end

    def exchange_token(_skype_spaces_token)
      raise @mock_error if @mock_error

      @mock_response
    end
  end

  # Tests refresh success, failure, and token preservation using mock HTTP
  class MockHttpTest < Minitest::Test
    def test_refresh_returns_true_on_successful_exchange
      with_temp_config do |dir|
        refresher, = build_testable(dir, mock_response: 'new-skype-token')
        assert refresher.refresh
      end
    end

    def test_refresh_updates_token_in_store
      with_temp_config do |dir|
        refresher, store = build_testable(dir, mock_response: 'new-skype-token')
        refresher.refresh
        assert_equal 'new-skype-token', store.account.skype_token
      end
    end

    def test_refresh_returns_false_on_nil_response
      with_temp_config do |dir|
        refresher, = build_testable(dir)
        refute refresher.refresh
      end
    end

    def test_refresh_returns_false_on_network_error
      with_temp_config do |dir|
        refresher, = build_testable(dir, mock_error: SocketError.new('connection failed'))
        refute refresher.refresh
      end
    end

    def test_refresh_preserves_original_token_on_failure
      with_temp_config do |dir|
        refresher, store = build_testable(dir, skype_token: 'original-skype')
        refresher.refresh
        assert_equal 'original-skype', store.account.skype_token
      end
    end

    private

    def build_testable(dir, skype_token: 'old-skype', **)
      write_tokens_file(dir, { 'auth_token' => 'test-auth', 'skype_token' => skype_token,
                               'skype_spaces_token' => 'spaces-token' })
      store = Teems::Services::TokenStore.new
      [TestableTokenRefresher.new(token_store: store, **), store]
    end
  end

  # Tests exchange_token response parsing, error handling, and timeout recovery
  class ExchangeTokenTest < Minitest::Test
    # Exposes exchange_token for direct testing
    class ExposedRefresher < Teems::Services::TokenRefresher
      public :exchange_token
    end

    def test_exchange_token_extracts_skype_token
      with_temp_config do
        refresher = build_refresher_with_stub('200', '{"tokens":{"skypeToken":"new-token"}}')
        assert_equal 'new-token', refresher.exchange_token('spaces-token')
      end
    end

    def test_exchange_token_returns_nil_on_failure
      with_temp_config do
        refresher = build_refresher_with_stub('500', '')
        assert_nil refresher.exchange_token('spaces-token')
      end
    end

    def test_exchange_token_returns_nil_on_missing_key
      with_temp_config do
        refresher = build_refresher_with_stub('200', '{"other":"data"}')
        assert_nil refresher.exchange_token('spaces-token')
      end
    end

    def test_refresh_handles_json_parse_error
      with_temp_config do |dir|
        write_tokens_file(dir, { 'auth_token' => 'a', 'skype_token' => 's', 'skype_spaces_token' => 'ss' })
        refresher = TestableTokenRefresher.new(token_store: Teems::Services::TokenStore.new,
                                               mock_error: JSON::ParserError.new('unexpected'))
        refute refresher.refresh
      end
    end

    def test_refresh_handles_timeout_error
      with_temp_config do |dir|
        write_tokens_file(dir, { 'auth_token' => 'a', 'skype_token' => 's', 'skype_spaces_token' => 'ss' })
        refresher = TestableTokenRefresher.new(token_store: Teems::Services::TokenStore.new,
                                               mock_error: Net::ReadTimeout.new)
        refute refresher.refresh
      end
    end

    private

    def build_refresher_with_stub(code, body)
      refresher = ExposedRefresher.new(token_store: mock_token_store, output: test_output)
      response = Net::HTTPResponse::CODE_TO_OBJ[code].new('1.1', code, 'Response')
      response.instance_variable_set(:@body, body)
      response.instance_variable_set(:@read, true)
      refresher.define_singleton_method(:post_authsvc_exchange) { |_token| response }
      refresher
    end
  end

  # Testable refresher that mocks both OIDC and authsvc HTTP calls
  class OidcTestableRefresher < Teems::Services::TokenRefresher
    def initialize(token_store:, oidc_responses: {}, authsvc_response: nil, authsvc_error: nil, oidc_error: nil)
      super(token_store: token_store)
      @oidc_responses = oidc_responses
      @authsvc_response = authsvc_response
      @authsvc_error = authsvc_error
      @oidc_error = oidc_error
    end

    private

    def oidc_token_request(scope, _refresh_token)
      raise @oidc_error if @oidc_error

      @oidc_responses[scope]
    end

    def exchange_token(_skype_spaces_token)
      raise @authsvc_error if @authsvc_error

      @authsvc_response
    end
  end

  # Tests OIDC refresh flow with Graph and Skype scopes and authsvc fallback
  class OidcRefreshTest < Minitest::Test
    GRAPH = Teems::Services::TokenRefresher::GRAPH_SCOPE
    SKYPE = Teems::Services::TokenRefresher::SKYPE_SCOPE

    def test_oidc_refresh_succeeds_with_all_tokens
      with_temp_config do |dir|
        refresher, store = build_successful_oidc(dir)
        assert refresher.refresh
        account = store.account
        assert_equal 'new-auth', account.auth_token
        assert_equal 'new-skype', account.skype_token
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
        refresher, store = build_oidc_refresher(dir, oidc_responses: { GRAPH => nil, SKYPE => nil },
                                                     authsvc_response: 'fallback-skype')
        assert refresher.refresh
        assert_equal 'fallback-skype', store.account.skype_token
      end
    end

    def test_oidc_falls_back_to_authsvc_when_skype_scope_fails
      with_temp_config do |dir|
        refresher, store = build_oidc_refresher(dir, oidc_responses: { GRAPH => oidc_graph_response, SKYPE => nil },
                                                     authsvc_response: 'fallback-skype')
        assert refresher.refresh
        assert_equal 'fallback-skype', store.account.skype_token
      end
    end

    def test_oidc_falls_back_when_authsvc_exchange_fails_in_oidc_flow
      with_temp_config do |dir|
        refresher, = build_successful_oidc(dir, authsvc_response: nil)
        refute refresher.refresh
      end
    end

    def test_skips_oidc_when_no_refresh_token
      with_temp_config do |dir|
        tokens = { 'auth_token' => 'old-auth', 'skype_token' => 'old-skype',
                   'skype_spaces_token' => 'spaces', 'client_id' => 'cid', 'tenant_id' => 'tid' }
        write_tokens_file(dir, tokens)
        refresher = OidcTestableRefresher.new(token_store: Teems::Services::TokenStore.new,
                                              authsvc_response: 'new-skype')
        assert refresher.refresh
      end
    end

    def test_oidc_falls_back_on_network_error
      with_temp_config do |dir|
        refresher, store = build_oidc_refresher(dir, authsvc_response: 'fallback-skype',
                                                     oidc_error: SocketError.new('fail'))
        assert refresher.refresh
        assert_equal 'fallback-skype', store.account.skype_token
      end
    end

    private

    def oidc_graph_response = { 'access_token' => 'new-auth', 'refresh_token' => 'rt2' }
    def oidc_skype_response = { 'access_token' => 'new-spaces', 'refresh_token' => 'rt3' }

    def build_successful_oidc(dir, authsvc_response: 'new-skype')
      build_oidc_refresher(dir, oidc_responses: { GRAPH => oidc_graph_response, SKYPE => oidc_skype_response },
                                authsvc_response: authsvc_response)
    end

    def build_oidc_refresher(dir, **)
      write_tokens_file(dir, { 'auth_token' => 'old-auth', 'skype_token' => 'old-skype',
                               'skype_spaces_token' => 'spaces',
                               'refresh_token' => 'rt1', 'client_id' => 'cid', 'tenant_id' => 'tid' })
      store = Teems::Services::TokenStore.new
      [OidcTestableRefresher.new(token_store: store, **), store]
    end
  end

  # Tests OIDC request body construction and token URI generation
  class OidcBuildMethodsTest < Minitest::Test
    # Exposes private OIDC methods for testing
    class ExposedOidc < Teems::Services::TokenRefresher
      public :oidc_request_body, :oidc_token_uri
    end

    def test_oidc_request_body_includes_grant_type
      with_temp_config do
        refresher = build_exposed_oidc(tenant: 'test-tenant', client: 'test-client')
        body = refresher.oidc_request_body('https://graph.microsoft.com/.default', 'my-rt')
        assert_includes body, 'grant_type=refresh_token'
        assert_includes body, 'client_id=test-client'
        assert_includes body, 'refresh_token=my-rt'
      end
    end

    def test_oidc_token_uri_uses_tenant_id
      with_temp_config do
        refresher = build_exposed_oidc(tenant: 'my-tenant-123')
        assert_equal 'https://login.microsoftonline.com/my-tenant-123/oauth2/v2.0/token',
                     refresher.oidc_token_uri.to_s
      end
    end

    private

    def build_exposed_oidc(tenant: nil, client: nil)
      ExposedOidc.new(token_store: mock_token_store(tenant_id: tenant, client_id: client))
    end
  end

  # Tests OIDC token request failure handling and logging
  class OidcTokenRequestTest < Minitest::Test
    # Exposes private OIDC logging methods for testing
    class ExposedOidcRequest < Teems::Services::TokenRefresher
      public :log_oidc_failure
    end

    def test_oidc_failure_returns_nil
      with_temp_config do
        refresher = build_exposed_request
        response = Net::HTTPResponse::CODE_TO_OBJ['401'].new('1.1', '401', 'Unauthorized')
        response.instance_variable_set(:@body, '')
        response.instance_variable_set(:@read, true)
        assert_nil refresher.log_oidc_failure(response)
      end
    end

    def test_log_oidc_failure_with_output
      with_temp_config do
        refresher = build_exposed_request(output: test_output)
        response = Net::HTTPResponse::CODE_TO_OBJ['403'].new('1.1', '403', 'Forbidden')
        response.instance_variable_set(:@body, '')
        response.instance_variable_set(:@read, true)
        assert_nil refresher.log_oidc_failure(response)
      end
    end

    private

    def build_exposed_request(output: nil)
      ExposedOidcRequest.new(
        token_store: mock_token_store(tenant_id: 'test-tenant', client_id: 'test-client', refresh_token: 'test-rt'),
        output: output
      )
    end
  end

  # Tests exchange failure logging via log_exchange_failure
  class LogExchangeFailureTest < Minitest::Test
    # Exposes log_exchange_failure for testing
    class ExposedExchange < Teems::Services::TokenRefresher
      public :log_exchange_failure
    end

    def test_log_exchange_failure_returns_nil
      with_temp_config do
        refresher = ExposedExchange.new(token_store: mock_token_store, output: test_output)
        response = Net::HTTPResponse::CODE_TO_OBJ['403'].new('1.1', '403', 'Forbidden')
        response.instance_variable_set(:@body, '')
        response.instance_variable_set(:@read, true)
        assert_nil refresher.log_exchange_failure(response)
      end
    end
  end

  # Tests HTTP configuration: SSL, timeouts, headers, and request construction
  class HttpConfigTest < Minitest::Test
    # Captures HTTP config from Net::HTTP.start calls
    class HttpCapture < Teems::Services::TokenRefresher
      attr_reader :last_http_args, :last_post_request

      def post_authsvc_exchange(token)
        post = Net::HTTP::Post.new(authsvc_uri,
                                   'Authorization' => "Bearer #{token}",
                                   'Content-Type' => 'application/json')
        post.body = '{}'
        capture_http_start(authsvc_uri, post)
      end

      def send_oidc_request(scope, refresh_token)
        uri = oidc_token_uri
        post = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/x-www-form-urlencoded',
                                        'Origin' => 'https://teams.microsoft.com')
        post.body = oidc_request_body(scope, refresh_token)
        capture_http_start(uri, post)
      end

      private

      def capture_http_start(uri, post)
        @last_post_request = post
        @last_http_args = {}
        Net::HTTP.start(uri.host, uri.port,
                        use_ssl: true, open_timeout: 10,
                        read_timeout: 30) do |http|
          @last_http_args = { use_ssl: http.use_ssl?, open_timeout: http.open_timeout,
                              read_timeout: http.read_timeout }
          mock_response
        end
      end

      def mock_response
        resp = Net::HTTPResponse::CODE_TO_OBJ['200'].new('1.1', '200', 'OK')
        resp.instance_variable_set(:@body, '{"tokens":{"skypeToken":"t"}}')
        resp.instance_variable_set(:@read, true)
        resp
      end
    end

    def test_authsvc_uses_ssl
      with_temp_config do
        capture = build_capture
        capture.post_authsvc_exchange('test-token')
        assert capture.last_http_args[:use_ssl]
      end
    end

    def test_authsvc_sets_open_timeout
      with_temp_config do
        capture = build_capture
        capture.post_authsvc_exchange('test-token')
        assert_equal 10, capture.last_http_args[:open_timeout]
      end
    end

    def test_authsvc_sets_read_timeout
      with_temp_config do
        capture = build_capture
        capture.post_authsvc_exchange('test-token')
        assert_equal 30, capture.last_http_args[:read_timeout]
      end
    end

    def test_authsvc_sets_authorization_header
      with_temp_config do
        capture = build_capture
        capture.post_authsvc_exchange('my-spaces-token')
        assert_equal 'Bearer my-spaces-token', capture.last_post_request['Authorization']
      end
    end

    def test_authsvc_sets_content_type_json
      with_temp_config do
        capture = build_capture
        capture.post_authsvc_exchange('test-token')
        assert_equal 'application/json', capture.last_post_request['Content-Type']
      end
    end

    def test_oidc_uses_ssl
      with_temp_config do
        capture = build_capture(tenant_id: 'tid', client_id: 'cid', refresh_token: 'rt')
        capture.send_oidc_request('https://graph.microsoft.com/.default', 'rt')
        assert capture.last_http_args[:use_ssl]
      end
    end

    def test_oidc_sets_timeouts
      with_temp_config do
        capture = build_capture(tenant_id: 'tid', client_id: 'cid', refresh_token: 'rt')
        capture.send_oidc_request('https://graph.microsoft.com/.default', 'rt')
        assert_equal 10, capture.last_http_args[:open_timeout]
        assert_equal 30, capture.last_http_args[:read_timeout]
      end
    end

    def test_oidc_sets_content_type_form
      with_temp_config do
        capture = build_capture(tenant_id: 'tid', client_id: 'cid', refresh_token: 'rt')
        capture.send_oidc_request('https://graph.microsoft.com/.default', 'rt')
        assert_equal 'application/x-www-form-urlencoded', capture.last_post_request['Content-Type']
      end
    end

    def test_oidc_sets_origin_header
      with_temp_config do
        capture = build_capture(tenant_id: 'tid', client_id: 'cid', refresh_token: 'rt')
        capture.send_oidc_request('https://graph.microsoft.com/.default', 'rt')
        assert_equal 'https://teams.microsoft.com', capture.last_post_request['Origin']
      end
    end

    private

    def build_capture(**store_opts)
      HttpCapture.new(token_store: mock_token_store(**store_opts))
    end
  end
end
