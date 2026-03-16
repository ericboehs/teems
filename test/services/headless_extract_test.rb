# frozen_string_literal: true

require 'test_helper'
require 'teems/services/headless_extract'

module HeadlessExtractTests
  # Testable class that includes all three modules, stubbing out
  # filesystem and system calls for safe unit testing.
  class TestableHeadless
    include Teems::Services::HelperBinary
    include Teems::Services::HttpSkypeExchange
    include Teems::Services::HeadlessExtract

    attr_accessor :log_messages, :file_mtime_map

    def initialize
      @log_messages = []
      @file_mtime_map = {}
    end

    # Make private methods accessible for testing
    public :ensure_helper_binary, :compile_helper, :swiftc_command,
           :helper_source_path, :helper_binary_path, :log_and_nil,
           :exchange_skype_via_http, :build_authsvc_http, :build_authsvc_request,
           :try_headless_extract, :handle_helper_result, :build_helper_args,
           :stored_login_hint, :extract_upn, :locate_token_store,
           :parse_headless_result, :build_headless_tokens

    def log(msg)
      @log_messages << msg
    end
  end

  # Shared helpers for building HTTP response stubs
  module ResponseHelper
    def build_http_response(code, message, body)
      response = Net::HTTPResponse::CODE_TO_OBJ[code].new('1.1', code, message)
      response.instance_variable_set(:@body, body)
      response.instance_variable_set(:@read, true)
      response
    end
  end

  # Shared helper for URL-safe base64 encoding (no external gem)
  module JwtHelper
    def urlsafe_b64(str)
      [str].pack('m0').tr('+/', '-_').delete('=')
    end
  end

  class HelperBinaryEnsureTest < Minitest::Test
    def test_ensure_helper_binary_returns_nil_when_no_source
      obj = TestableHeadless.new
      stub_ensure_binary(obj, source_exists: false)

      assert_nil obj.ensure_helper_binary
    end

    def test_ensure_helper_binary_returns_binary_when_up_to_date
      obj = TestableHeadless.new
      now = Time.now
      obj.file_mtime_map = { source: now - 10, binary: now }
      stub_ensure_binary(obj, source_exists: true, binary_exists: true)

      assert_equal obj.helper_binary_path, obj.ensure_helper_binary
    end

    def test_ensure_helper_binary_compiles_when_binary_outdated
      obj = TestableHeadless.new
      now = Time.now
      obj.file_mtime_map = { source: now, binary: now - 10 }
      stub_ensure_binary(obj, source_exists: true, binary_exists: true)

      assert_equal obj.helper_binary_path, obj.ensure_helper_binary
    end

    private

    def stub_ensure_binary(obj, source_exists:, binary_exists: false)
      binary_path = obj.helper_binary_path
      mtimes = obj.file_mtime_map
      obj.define_singleton_method(:ensure_helper_binary) do
        return nil unless source_exists
        return binary_path if binary_exists && mtimes[:binary] >= mtimes[:source]

        compile_helper(helper_source_path, binary_path)
      end
      obj.define_singleton_method(:compile_helper) { |_s, _b| binary_path }
    end
  end

  class HelperBinaryCompileTest < Minitest::Test
    def test_compile_helper_returns_nil_on_failure
      obj = TestableHeadless.new
      stub_compile(obj, success: false)

      assert_nil obj.compile_helper('src.swift', 'bin')
      assert_includes obj.log_messages, 'Failed to compile helper'
    end

    def test_compile_helper_returns_binary_on_success
      obj = TestableHeadless.new
      stub_compile(obj, success: true)

      assert_equal 'bin', obj.compile_helper('src.swift', 'bin')
    end

    def test_compile_helper_returns_nil_on_enoent
      obj = TestableHeadless.new
      obj.define_singleton_method(:compile_helper) do |_s, _b|
        log('Compiling headless token helper...')
        raise Errno::ENOENT
      rescue Errno::ENOENT
        log_and_nil('swiftc not found')
      end

      assert_nil obj.compile_helper('src.swift', 'bin')
      assert_includes obj.log_messages, 'swiftc not found'
    end

    private

    def stub_compile(obj, success:)
      obj.define_singleton_method(:compile_helper) do |_s, binary|
        log('Compiling headless token helper...')
        success ? binary : log_and_nil('Failed to compile helper')
      end
    end
  end

  class HelperBinaryPathsTest < Minitest::Test
    def test_swiftc_command_includes_frameworks
      cmd = TestableHeadless.new.swiftc_command('source.swift', 'output_binary')

      assert_equal 'swiftc', cmd.first
      %w[WebKit Security AppKit].each { |fw| assert_includes cmd, fw }
      assert_includes cmd, 'source.swift'
      assert_includes cmd, '-o'
      assert_includes cmd, 'output_binary'
    end

    def test_helper_paths_relative_to_source
      obj = TestableHeadless.new
      source = obj.helper_source_path
      binary = obj.helper_binary_path

      assert_predicate source, :end_with_swift?
      assert_equal source.sub(/\.swift$/, ''), binary
      assert_includes source, 'support/token_helper.swift'
    end
  end

  # String extension for predicate used in test assertion
  module SwiftPredicate
    def end_with_swift? = end_with?('.swift')
  end
  String.prepend(SwiftPredicate)

  class HttpSkypeExchangeTest < Minitest::Test
    include ResponseHelper

    def test_exchange_returns_nil_when_nil_token
      assert_nil TestableHeadless.new.exchange_skype_via_http(nil)
    end

    def test_exchange_returns_skype_token_on_success
      obj = TestableHeadless.new
      body = '{"tokens":{"skypeToken":"exchanged-skype-token"}}'
      obj.define_singleton_method(:post_authsvc_exchange) { |_t| build_resp }
      define_resp_builder(obj, '200', 'OK', body)

      assert_equal 'exchanged-skype-token', obj.exchange_skype_via_http('input-token')
    end

    def test_exchange_returns_nil_on_http_error
      obj = TestableHeadless.new
      obj.define_singleton_method(:post_authsvc_exchange) { |_t| build_resp }
      define_resp_builder(obj, '401', 'Unauthorized', '{}')

      assert_nil obj.exchange_skype_via_http('input-token')
    end

    def test_exchange_returns_nil_on_exception
      obj = TestableHeadless.new
      obj.define_singleton_method(:post_authsvc_exchange) { |_t| raise StandardError, 'network fail' }

      assert_nil obj.exchange_skype_via_http('input-token')
      assert_includes obj.log_messages, 'Skype exchange failed: network fail'
    end

    def test_build_authsvc_http_uses_ssl
      uri = URI(Teems::Services::HttpSkypeExchange::AUTHSVC_URL)
      http = TestableHeadless.new.build_authsvc_http(uri)

      assert_instance_of Net::HTTP, http
      assert http.use_ssl?
      assert_equal 10, http.open_timeout
      assert_equal 30, http.read_timeout
    end

    def test_build_authsvc_request_sets_auth_header
      uri = URI(Teems::Services::HttpSkypeExchange::AUTHSVC_URL)
      request = TestableHeadless.new.build_authsvc_request(uri, 'my-bearer-token')

      assert_instance_of Net::HTTP::Post, request
      assert_equal 'Bearer my-bearer-token', request['Authorization']
      assert_equal 'application/json', request['Content-Type']
      assert_equal '{}', request.body
    end

    private

    def define_resp_builder(obj, code, message, body)
      resp = build_http_response(code, message, body)
      obj.define_singleton_method(:build_resp) { resp }
    end
  end

  class HeadlessExtractBasicTest < Minitest::Test
    def test_try_headless_returns_nil_when_no_binary
      obj = TestableHeadless.new
      obj.define_singleton_method(:ensure_helper_binary) { nil }

      assert_nil obj.try_headless_extract
    end

    def test_try_headless_catches_standard_error
      obj = TestableHeadless.new
      obj.define_singleton_method(:ensure_helper_binary) { raise StandardError, 'boom' }

      assert_nil obj.try_headless_extract
      assert_includes obj.log_messages, 'Headless extraction error: boom'
    end

    def test_handle_helper_result_parses_success
      obj = TestableHeadless.new
      json = '{"auth_token":"parsed-auth","skype_spaces_token":"parsed-spaces"}'
      obj.define_singleton_method(:exchange_skype_via_http) { |_t| 'parsed-skype' }

      result = obj.handle_helper_result(json, 0)

      assert_equal 'parsed-auth', result[:auth_token]
      assert_equal 'parsed-skype', result[:skype_token]
    end
  end

  class HeadlessExtractSuccessTest < Minitest::Test
    def test_try_headless_returns_tokens_on_success
      obj = build_headless_with_binary
      stub_capture2_result(obj, json_output, 0)
      obj.define_singleton_method(:exchange_skype_via_http) { |_t| 'h-skype' }
      result = obj.try_headless_extract

      assert_equal 'h-auth', result[:auth_token]
      assert_equal 'h-skype', result[:skype_token]
      assert_equal 'h-spaces', result[:skype_spaces_token]
      assert_equal 'h-rt', result[:refresh_token]
    end

    def test_try_headless_returns_nil_on_needs_safari_exit
      obj = build_headless_with_binary
      stub_capture2_result(obj, '', 2)

      assert_nil obj.try_headless_extract
      assert(obj.log_messages.any? { |m| m.include?('No cached session') })
    end

    def test_try_headless_returns_nil_on_other_error
      obj = build_headless_with_binary
      stub_capture2_result(obj, '', 3)

      assert_nil obj.try_headless_extract
      assert(obj.log_messages.any? { |m| m.include?('Helper exited 3') })
    end

    private

    def json_output
      '{"auth_token":"h-auth","skype_spaces_token":"h-spaces","refresh_token":"h-rt",' \
        '"client_id":"h-cid","tenant_id":"h-tid"}'
    end

    def build_headless_with_binary
      obj = TestableHeadless.new
      obj.define_singleton_method(:ensure_helper_binary) { '/path/to/binary' }
      obj
    end

    def stub_capture2_result(obj, output, exit_code)
      obj.define_singleton_method(:try_headless_extract) do
        binary = ensure_helper_binary
        return nil unless binary

        log('Trying headless token extraction...')
        handle_helper_result(output, exit_code)
      rescue StandardError => e
        log("Headless extraction error: #{e.message}")
        nil
      end
    end
  end

  class HeadlessExtractArgsTest < Minitest::Test
    def test_build_helper_args_with_no_hint
      obj = TestableHeadless.new
      obj.define_singleton_method(:stored_login_hint) { [nil, nil] }

      assert_equal ['--timeout', '60'], obj.build_helper_args
    end

    def test_build_helper_args_with_hint_and_tenant
      obj = TestableHeadless.new
      obj.define_singleton_method(:stored_login_hint) { ['user@example.com', 'tenant-123'] }

      args = obj.build_helper_args

      assert_includes args, '--login-hint'
      assert_includes args, 'user@example.com'
      assert_includes args, '--tenant-id'
      assert_includes args, 'tenant-123'
    end
  end

  class HeadlessExtractUpnTest < Minitest::Test
    include JwtHelper

    def test_extract_upn_from_jwt
      payload = urlsafe_b64('{"upn":"alice@contoso.com"}')
      jwt = "eyJhbGciOiJSUzI1NiJ9.#{payload}.signature"

      assert_equal 'alice@contoso.com', TestableHeadless.new.extract_upn(jwt)
    end

    def test_extract_upn_returns_nil_for_invalid_jwt
      assert_nil TestableHeadless.new.extract_upn('not-a-jwt')
    end

    def test_extract_upn_returns_nil_for_nil
      assert_nil TestableHeadless.new.extract_upn(nil)
    end
  end

  class HeadlessExtractParseTest < Minitest::Test
    def test_parse_headless_result_returns_tokens
      obj = TestableHeadless.new
      obj.define_singleton_method(:exchange_skype_via_http) { |_t| 'parsed-skype' }

      json = '{"auth_token":"a","skype_spaces_token":"s","refresh_token":"r",' \
             '"client_id":"c","tenant_id":"t"}'
      result = obj.parse_headless_result(json)

      assert_equal 'a', result[:auth_token]
      assert_equal 'parsed-skype', result[:skype_token]
      assert_equal 's', result[:skype_spaces_token]
      assert_nil result[:chatsvc_token]
      assert_equal 'r', result[:refresh_token]
    end

    def test_parse_headless_result_returns_nil_on_no_auth_token
      assert_nil TestableHeadless.new.parse_headless_result('{"skype_spaces_token":"s"}')
    end

    def test_parse_headless_result_returns_nil_on_json_error
      obj = TestableHeadless.new

      assert_nil obj.parse_headless_result('not valid json {')
      assert(obj.log_messages.any? { |m| m.include?('Failed to parse headless result') })
    end
  end

  class HeadlessExtractLoginHintTest < Minitest::Test
    include JwtHelper

    def test_locate_token_store_uses_xdg
      with_temp_config do |dir|
        path = TestableHeadless.new.locate_token_store

        assert_equal File.join(dir, 'teems', 'tokens.json'), path
      end
    end

    def test_stored_login_hint_returns_nil_on_error
      obj = TestableHeadless.new
      obj.define_singleton_method(:locate_token_store) { raise StandardError, 'oops' }

      hint, tenant = obj.stored_login_hint

      assert_nil hint
      assert_nil tenant
    end

    def test_stored_login_hint_reads_tokens_file
      with_temp_config do |dir|
        payload = urlsafe_b64('{"upn":"bob@corp.com"}')
        jwt = "header.#{payload}.sig"
        write_tokens_file(dir, { 'auth_token' => jwt, 'tenant_id' => 'tid-99' })

        hint, tenant = TestableHeadless.new.stored_login_hint

        assert_equal 'bob@corp.com', hint
        assert_equal 'tid-99', tenant
      end
    end

    def test_stored_login_hint_returns_nils_when_no_file
      with_temp_config do
        hint, tenant = TestableHeadless.new.stored_login_hint

        assert_nil hint
        assert_nil tenant
      end
    end
  end
end
