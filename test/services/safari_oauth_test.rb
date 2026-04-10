# frozen_string_literal: true

require 'test_helper'
require 'teems/services/safari_oauth'

module SafariOAuthTests
  # Test harness that includes the Safari OAuth modules with mocked dependencies
  class TestableSafariOAuth
    include Teems::Services::OAuthUrlBuilder
    include Teems::Services::OAuthCodeExchange
    include Teems::Services::SafariOAuthPolling
    include Teems::Services::SafariOAuth

    attr_accessor :applescript_results, :http_responses, :stored_hint, :log_messages,
                  :skype_exchange_result

    def initialize
      @applescript_results = []
      @http_responses = []
      @stored_hint = [nil, nil]
      @log_messages = []
      @skype_exchange_result = nil
      @auth_mode = :default
    end

    # Expose private methods for testing
    public :build_authorize_url, :generate_pkce, :decode_jwt, :parse_oauth_params,
           :try_safari_oauth, :safari_code_flow, :exchange_graph_code,
           :poll_safari_query_redirect, :fetch_skype_via_refresh, :refresh_for_resource,
           :assemble_safari_result

    private

    def run_applescript(_script) = @applescript_results.shift
    def stored_login_hint = @stored_hint
    def close_teams_tab = nil
    def exchange_skype_via_http(token) = @skype_exchange_result || "skype-#{token}"
    def log(message) = @log_messages << message

    def post_token_exchange(_exchange)
      @http_responses.shift || mock_http_error(400)
    end

    def post_refresh_request(_grant)
      @http_responses.shift || mock_http_error(400)
    end

    def mock_http_error(code)
      Net::HTTPResponse::CODE_TO_OBJ[code.to_s].new('1.1', code.to_s, '').tap do |resp|
        resp.instance_variable_set(:@body, '{"error":"test"}')
        resp.instance_variable_set(:@read, true)
      end
    end
  end

  # Shared HTTP response helpers
  module ResponseHelpers
    private

    def mock_success(body)
      Net::HTTPOK.new('1.1', '200', 'OK').tap do |resp|
        resp.instance_variable_set(:@body, body)
        resp.instance_variable_set(:@read, true)
      end
    end

    def mock_error(code)
      Net::HTTPResponse::CODE_TO_OBJ[code.to_s].new('1.1', code.to_s, '').tap do |resp|
        resp.instance_variable_set(:@body, '{"error":"fail"}')
        resp.instance_variable_set(:@read, true)
      end
    end
  end

  # Tests for OAuthUrlBuilder module
  class UrlBuilderTest < Minitest::Test
    def setup
      @obj = TestableSafariOAuth.new
    end

    def test_build_authorize_url_basic
      url = @obj.build_authorize_url({ tenant: 'test-tenant', hint: nil }, 'code')
      assert_includes url, 'login.microsoftonline.com/test-tenant/oauth2/authorize'
      assert_includes url, 'response_type=code'
      assert_includes url, 'client_id=5e3ce6c0'
    end

    def test_build_authorize_url_with_hint
      url = @obj.build_authorize_url({ tenant: 't', hint: 'user@example.com' }, 'id_token')
      assert_includes url, 'login_hint=user%40example.com'
      assert_includes url, 'domain_hint=example.com'
    end

    def test_build_authorize_url_with_resource_and_pkce
      pkce = { challenge: 'test-challenge' }
      url = @obj.build_authorize_url({ tenant: 't', hint: nil }, 'code',
                                     resource: 'https://api.example.com', pkce: pkce)
      assert_includes url, 'resource=https'
      assert_includes url, 'code_challenge=test-challenge'
    end

    def test_build_authorize_url_without_hint
      url = @obj.build_authorize_url({ tenant: 't', hint: nil }, 'code')
      refute_includes url, 'login_hint'
    end
  end

  # Tests for OAuthCodeExchange module
  class CodeExchangeTest < Minitest::Test
    include ResponseHelpers

    def setup
      @obj = TestableSafariOAuth.new
    end

    def test_generate_pkce_produces_url_safe_values
      pkce = @obj.generate_pkce
      assert pkce[:verifier].length > 20
      assert pkce[:challenge].length > 20
      refute_includes pkce[:verifier], '='
    end

    def test_decode_jwt_valid
      payload = [+'{"tid":"t1","upn":"u@t.com"}'].pack('m0').tr('+/', '-_').delete('=')
      result = @obj.decode_jwt("h.#{payload}.s")
      assert_equal 't1', result['tid']
    end

    def test_decode_jwt_invalid
      assert_nil @obj.decode_jwt('not-a-jwt')
      assert_nil @obj.decode_jwt('')
    end

    def test_exchange_graph_code_success
      @obj.http_responses << mock_success('{"access_token":"at","refresh_token":"rt"}')
      result = @obj.exchange_graph_code(code: 'c', verifier: 'v', tenant: 't')
      assert_equal 'at', result['access_token']
    end

    def test_exchange_graph_code_failure
      @obj.http_responses << mock_error(400)
      assert_nil @obj.exchange_graph_code(code: 'c', verifier: 'v', tenant: 't')
    end
  end

  # Tests for SafariOAuthPolling module
  class PollingTest < Minitest::Test
    def setup
      @obj = TestableSafariOAuth.new
    end

    def test_parse_oauth_params
      result = @obj.parse_oauth_params('code=abc&state=xyz')
      assert_equal 'abc', result['code']
      assert_equal 'xyz', result['state']
    end

    def test_parse_oauth_params_url_encoded
      result = @obj.parse_oauth_params('code=a%20b')
      assert_equal 'a b', result['code']
    end

    def test_poll_safari_query_redirect_success
      @obj.applescript_results << 'code=test-code&state=s1'
      result = @obj.poll_safari_query_redirect
      assert_equal 'test-code', result['code']
    end

    def test_poll_safari_query_redirect_timeout
      @obj.applescript_results << 'timeout'
      assert_nil @obj.poll_safari_query_redirect
      assert_includes @obj.log_messages.join, 'fast capture missed'
    end

    def test_poll_safari_query_redirect_empty
      @obj.applescript_results << ''
      assert_nil @obj.poll_safari_query_redirect
    end
  end

  # Tests for SafariOAuth orchestration
  class FlowTest < Minitest::Test
    include ResponseHelpers

    def setup
      @obj = TestableSafariOAuth.new
    end

    def test_try_safari_oauth_returns_nil_without_tenant
      @obj.stored_hint = [nil, nil]
      assert_nil @obj.try_safari_oauth
    end

    def test_try_safari_oauth_returns_nil_with_hint_only
      @obj.stored_hint = ['user@test.com', nil]
      assert_nil @obj.try_safari_oauth
    end

    def test_try_safari_oauth_rescues_errors
      @obj.stored_hint = ['user@test.com', 'tenant-1']
      @obj.applescript_results << 'timeout'
      assert_nil @obj.try_safari_oauth
    end

    def test_safari_code_flow_nil_when_graph_fails
      @obj.applescript_results << 'timeout'
      assert_nil @obj.safari_code_flow({ tenant: 't', hint: 'u@t.com' })
    end

    def test_safari_code_flow_nil_when_skype_fails
      stub_graph_success
      @obj.http_responses << mock_error(400) # skype refresh fails
      assert_nil @obj.safari_code_flow({ tenant: 't', hint: 'u@t.com' })
    end

    def test_safari_code_flow_full_success
      stub_graph_success
      @obj.http_responses << mock_success('{"access_token":"sk-at","refresh_token":"sk-rt"}')

      result = @obj.safari_code_flow({ tenant: 't', hint: 'u@t.com' })
      assert_equal 'g-at', result[:auth_token]
      assert_equal 'sk-at', result[:skype_spaces_token]
      assert_equal 'sk-rt', result[:refresh_token]
    end

    def test_fetch_skype_nil_without_refresh_token
      assert_nil @obj.fetch_skype_via_refresh({}, 't')
    end

    def test_fetch_skype_nil_on_http_error
      @obj.http_responses << mock_error(400)
      assert_nil @obj.fetch_skype_via_refresh({ 'refresh_token' => 'rt' }, 't')
    end

    def test_refresh_for_resource_handles_exception
      @obj.define_singleton_method(:post_refresh_request) { |_| raise SocketError, 'test' }
      assert_nil @obj.refresh_for_resource(token: 'rt', tenant: 't', resource: 'r')
    end

    def test_assemble_safari_result_structure
      graph = { 'access_token' => 'g-at' }
      skype = { spaces_token: 'sk-sp', refresh_token: 'sk-rt' }
      result = @obj.assemble_safari_result({ tenant: 't1' }, graph, skype)

      assert_equal 'g-at', result[:auth_token]
      assert_equal 'sk-sp', result[:skype_spaces_token]
      assert_equal 'sk-rt', result[:refresh_token]
      assert_equal 't1', result[:tenant_id]
    end

    private

    def stub_graph_success
      @obj.applescript_results << nil # open_safari_to
      @obj.applescript_results << 'code=c1&state=s1' # poll
      @obj.http_responses << mock_success('{"access_token":"g-at","refresh_token":"g-rt"}')
    end
  end
end
