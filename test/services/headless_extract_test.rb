# frozen_string_literal: true

require 'test_helper'
require 'teems/services/headless_extract'

# Tests for headless token extraction, helper binary compilation, and HTTP skype exchange
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
    def urlsafe_encode(str)
      [str].pack('m0').tr('+/', '-_').delete('=')
    end
  end

  # Tests helper binary existence checks, recompilation triggers, and missing source handling
  class HelperBinaryEnsureTest < Minitest::Test
    def test_ensure_helper_binary_returns_nil_when_no_source
      obj = TestableHeadless.new
      stub_file_exist(obj, {})

      assert_nil obj.ensure_helper_binary
    end

    def test_ensure_helper_binary_returns_binary_when_up_to_date
      obj = TestableHeadless.new
      source = obj.helper_source_path
      binary = obj.helper_binary_path
      now = Time.now
      stub_file_exist(obj, { source => true, binary => true })
      stub_file_mtime(obj, { binary => now, source => now - 10 })

      assert_equal binary, obj.ensure_helper_binary
    end

    def test_ensure_helper_binary_compiles_when_binary_outdated
      obj = TestableHeadless.new
      source = obj.helper_source_path
      binary = obj.helper_binary_path
      now = Time.now
      stub_file_exist(obj, { source => true, binary => true })
      stub_file_mtime(obj, { binary => now - 10, source => now })
      stub_open3_compile(obj)

      assert_equal binary, obj.ensure_helper_binary
    end

    def test_ensure_helper_binary_compiles_when_no_binary
      obj = TestableHeadless.new
      source = obj.helper_source_path
      binary = obj.helper_binary_path
      stub_file_exist(obj, { source => true })
      stub_open3_compile(obj)

      assert_equal binary, obj.ensure_helper_binary
    end

    private

    def stub_file_exist(obj, exist_map)
      obj.define_singleton_method(:ensure_helper_binary) do
        source = helper_source_path
        binary = helper_binary_path
        return nil unless exist_map[source]

        mtime_map = obj.file_mtime_map
        return binary if exist_map[binary] && mtime_map[binary] >= mtime_map[source]

        compile_helper(source, binary)
      end
    end

    def stub_file_mtime(obj, mtime_map)
      obj.file_mtime_map = mtime_map
    end

    def stub_open3_compile(obj)
      obj.define_singleton_method(:compile_helper) do |_s, binary|
        log('Compiling headless token helper...')
        binary
      end
    end
  end

  # Tests Swift compilation success, failure, and missing swiftc handling
  class HelperBinaryCompileTest < Minitest::Test
    def test_compile_helper_returns_nil_on_failure
      obj = TestableHeadless.new
      stub_compile_status(obj, status_success: false)

      assert_nil obj.compile_helper('src.swift', 'bin')
      assert_includes obj.log_messages, 'Failed to compile helper'
    end

    def test_compile_helper_returns_binary_on_success
      obj = TestableHeadless.new
      stub_compile_status(obj, status_success: true)

      assert_equal 'bin', obj.compile_helper('src.swift', 'bin')
    end

    def test_compile_helper_returns_nil_on_enoent
      obj = TestableHeadless.new
      stub_compile_status_enoent(obj)

      assert_nil obj.compile_helper('src.swift', 'bin')
      assert_includes obj.log_messages, 'swiftc not found'
    end

    private

    def stub_compile_status(obj, status_success:)
      mock_status = Object.new
      mock_status.define_singleton_method(:success?) { status_success }
      obj.define_singleton_method(:compile_helper) do |_source, binary|
        log('Compiling headless token helper...')
        # Simulates Open3.capture2 returning a status object
        mock_status.success? ? binary : log_and_nil('Failed to compile helper')
      end
    end

    def stub_compile_status_enoent(obj)
      obj.define_singleton_method(:compile_helper) do |_source, _binary|
        log('Compiling headless token helper...')
        raise Errno::ENOENT
      rescue Errno::ENOENT
        log_and_nil('swiftc not found')
      end
    end
  end

  # Tests swiftc command construction and helper source/binary path resolution
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

      assert source.end_with?('.swift'), "Expected #{source} to end with .swift"
      assert_equal source.sub(/\.swift$/, ''), binary
      assert_includes source, 'support/token_helper.swift'
    end
  end

  # Tests HTTP-based skype token exchange with success, error, and exception paths
  class HttpSkypeExchangeTest < Minitest::Test
    include ResponseHelper

    def test_exchange_returns_nil_when_nil_token
      assert_nil TestableHeadless.new.exchange_skype_via_http(nil)
    end

    def test_exchange_returns_skype_token_on_success
      obj = TestableHeadless.new
      body = '{"tokens":{"skypeToken":"exchanged-skype-token"}}'
      resp = build_http_response('200', 'OK', body)
      obj.define_singleton_method(:post_authsvc_exchange) { |_t| resp }

      assert_equal 'exchanged-skype-token', obj.exchange_skype_via_http('input-token')
    end

    def test_exchange_returns_nil_on_http_error
      obj = TestableHeadless.new
      resp = build_http_response('401', 'Unauthorized', '{}')
      obj.define_singleton_method(:post_authsvc_exchange) { |_t| resp }

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
  end

  # Tests headless extraction with missing binary, error catching, and result parsing
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

  # Tests successful headless token extraction and exit code handling
  class HeadlessExtractSuccessTest < Minitest::Test
    def test_try_headless_returns_tokens_on_success
      obj = build_headless_with_binary
      stub_open3_output(obj, json_output, exit_code: 0)
      obj.define_singleton_method(:exchange_skype_via_http) { |_t| 'h-skype' }
      result = obj.try_headless_extract

      assert_equal 'h-auth', result[:auth_token]
      assert_equal 'h-skype', result[:skype_token]
      assert_equal 'h-spaces', result[:skype_spaces_token]
      assert_equal 'h-rt', result[:refresh_token]
    end

    def test_try_headless_returns_nil_on_needs_safari_exit
      obj = build_headless_with_binary
      stub_open3_output(obj, '', exit_code: 2)

      assert_nil obj.try_headless_extract
      assert(obj.log_messages.any? { |msg| msg.include?('No cached session') })
    end

    def test_try_headless_returns_nil_on_other_error
      obj = build_headless_with_binary
      stub_open3_output(obj, '', exit_code: 3)

      assert_nil obj.try_headless_extract
      assert(obj.log_messages.any? { |msg| msg.include?('Helper exited 3') })
    end

    private

    def json_output
      '{"auth_token":"h-auth","skype_spaces_token":"h-spaces","refresh_token":"h-rt",' \
        '"client_id":"h-cid","tenant_id":"h-tid"}'
    end

    def build_headless_with_binary
      obj = TestableHeadless.new
      obj.define_singleton_method(:ensure_helper_binary) { '/path/to/binary' }
      obj.define_singleton_method(:stored_login_hint) { [nil, nil] }
      obj
    end

    def stub_open3_output(obj, output, exit_code:)
      status = mock_exitstatus(exit_code)
      obj.define_singleton_method(:try_headless_extract) do
        binary = ensure_helper_binary
        return nil unless binary

        log('Trying headless token extraction...')
        handle_helper_result(output, status.exitstatus)
      rescue StandardError => e
        log("Headless extraction error: #{e.message}")
        nil
      end
    end

    def mock_exitstatus(code)
      Object.new.tap { |status| status.define_singleton_method(:exitstatus) { code } }
    end
  end

  # Tests helper argument construction with and without login hint and tenant
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

  # Tests UPN extraction from JWT tokens with valid, invalid, and nil inputs
  class HeadlessExtractUpnTest < Minitest::Test
    include JwtHelper

    def test_extract_upn_from_jwt
      payload = urlsafe_encode('{"upn":"alice@contoso.com"}')
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

  # Tests headless result JSON parsing, missing auth token, and parse error handling
  class HeadlessExtractParseTest < Minitest::Test
    def test_parse_headless_result_returns_tokens
      result = parse_sample_result

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
      assert(obj.log_messages.any? { |msg| msg.include?('Failed to parse headless result') })
    end

    private

    def parse_sample_result
      obj = TestableHeadless.new
      obj.define_singleton_method(:exchange_skype_via_http) { |_t| 'parsed-skype' }

      json = '{"auth_token":"a","skype_spaces_token":"s","refresh_token":"r",' \
             '"client_id":"c","tenant_id":"t"}'
      obj.parse_headless_result(json)
    end
  end

  # Tests stored login hint reading from token store with UPN and tenant extraction
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
        payload = urlsafe_encode('{"upn":"bob@corp.com"}')
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
