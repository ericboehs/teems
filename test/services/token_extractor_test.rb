# frozen_string_literal: true

require 'test_helper'

# Tests for TokenExtractor Safari automation, v1/v2 token paths, and login waiting
module TokenExtractorTests
  # Testable subclass that stubs AppleScript, system calls, and sleep for safe testing
  class TestableTokenExtractor < Teems::Services::TokenExtractor
    attr_accessor :applescript_results, :system_result, :applescript_call_count

    def initialize(output: nil)
      super
      @applescript_results = []
      @applescript_call_count = 0
      @system_result = true
    end

    private

    def try_headless_extract
      nil # Skip headless in tests, always use Safari path
    end

    def try_safari_oauth
      nil # Skip Safari OAuth in tests, always use legacy Safari path
    end

    def run_applescript(_script)
      @applescript_call_count += 1
      @applescript_results.shift
    end

    def system(*_args, **_opts)
      @system_result
    end

    def sleep(_seconds)
      # no-op
    end
  end

  # Shared builders for extractor instances, token sequences, and verbose output
  module Helpers
    module_function

    TEAMS_URL = 'https://teams.microsoft.com/v2/|complete'
    LOGIN_URL = 'https://login.microsoftonline.com/|loading'

    def build_extractor(output: nil)
      extractor = TestableTokenExtractor.new(output: output)
      extractor.system_result = true
      extractor
    end

    def add_open_safari(extractor)
      extractor.applescript_results << nil
    end

    def add_ready_sequence(extractor, count: 3)
      count.times { extractor.applescript_results << TEAMS_URL }
    end

    # open safari + wait-for-login (ready 3x)
    def add_preamble(extractor)
      add_open_safari(extractor)
      add_ready_sequence(extractor)
    end

    # open safari + ready 3x + 6 v1-poll nils (triggers v2 path)
    def add_v2_preamble(extractor)
      add_preamble(extractor)
      6.times { extractor.applescript_results << nil }
    end

    # v2 success tokens
    def add_v2_tokens(extractor)
      results = extractor.applescript_results
      results << 'started'
      results << '{"auth_token":"v2-auth","skype_spaces_token":"v2-skype-spaces"}'
      # extract_v1_refresh_data runs EXTRACT_TOKENS_JS to grab refresh token (always V1)
      results << '{"auth_token":null,"skype_spaces_token":null,' \
                 '"refresh_token":null,"client_id":null,"tenant_id":null}'
      results << '{"skype_token":"v2-skype","region":"us","chat_service":"https://chat.com"}'
      results << nil
    end

    # v2 timeout: started but never completes decryption
    def add_v2_timeout(extractor)
      results = extractor.applescript_results
      results << 'started'
      results.push(*Array.new(10, ''), *Array.new(24), nil)
    end

    # v2 failure: bad first-token response, then exhaust polling
    def add_v2_failure(extractor, first_result:)
      results = extractor.applescript_results
      results << 'started'
      results << first_result
      25.times { results << nil }
    end

    # v1 success tokens
    def add_v1_tokens(extractor, tokens: {})
      auth = tokens.fetch(:auth, 'v1-auth')
      spaces = tokens.fetch(:spaces, 'v1-spaces')
      results = extractor.applescript_results
      results << %({"auth_token":"#{auth}","skype_spaces_token":"#{spaces}"})
      skype = tokens.fetch(:skype, 'v1-skype')
      chat = tokens.fetch(:chat, 'https://chat.com')
      results << %({"skype_token":"#{skype}","region":"us","chat_service":"#{chat}"})
      results << nil
    end

    # returns [extractor, err_io] with verbose output attached
    def build_verbose_extractor
      err = StringIO.new
      output = Teems::Formatters::Output.new(err: err, color: false, mode: :verbose)
      [build_extractor(output: output), err]
    end

    # open safari + N login-wait polls + ready sequence
    def add_login_wait_preamble(extractor, login_polls: 10)
      add_open_safari(extractor)
      login_polls.times { extractor.applescript_results << LOGIN_URL }
      add_ready_sequence(extractor)
    end
  end

  # Tests Safari availability check, token extraction, and manual instruction output
  class BasicTest < Minitest::Test
    include Helpers

    def test_extract_returns_nil_when_safari_unavailable
      extractor = TestableTokenExtractor.new
      extractor.system_result = false

      assert_nil extractor.extract
    end

    def test_extract_opens_teams_and_extracts_tokens
      extractor = build_extractor
      add_preamble(extractor)
      add_v1_tokens(extractor, tokens: { auth: 'test-auth', spaces: 'test-skype-spaces', skype: 'test-skype' })
      result = extractor.extract
      assert_equal 'test-auth', result[:auth_token]
      assert_equal 'test-skype', result[:skype_token]
      assert_equal 'test-skype-spaces', result[:skype_spaces_token]
    end

    def test_extract_returns_nil_when_tokens_not_found
      extractor = build_extractor
      add_preamble(extractor)
      results = extractor.applescript_results
      61.times { results << nil }

      assert_nil extractor.extract
    end

    def test_manual_instructions_returns_string
      instructions = build_extractor.manual_instructions
      assert_includes instructions, 'manually extract tokens'
      assert_includes instructions, 'localStorage'
    end
  end

  # Tests v2 encrypted token decryption path including success, timeout, and error cases
  class V2DecryptorTest < Minitest::Test
    include Helpers

    def test_extract_tokens_v2_returns_nil_on_no_key
      extractor = build_extractor
      add_v2_preamble(extractor)
      results = extractor.applescript_results
      results << 'no_key'
      25.times { results << nil }

      assert_nil extractor.extract
    end

    def test_extract_tokens_v2_returns_tokens_on_success
      extractor = build_extractor
      add_v2_preamble(extractor)
      add_v2_tokens(extractor)
      result = extractor.extract
      assert_equal 'v2-auth', result[:auth_token]
      assert_equal 'v2-skype', result[:skype_token]
    end

    def test_extract_tokens_v2_handles_decrypt_error
      extractor = build_extractor
      add_v2_preamble(extractor)
      add_v2_failure(extractor, first_result: '{"error":"decryption failed"}')

      assert_nil extractor.extract
    end

    def test_extract_tokens_v2_handles_timeout
      extractor = build_extractor
      add_v2_preamble(extractor)
      add_v2_timeout(extractor)

      assert_nil extractor.extract
    end

    def test_extract_tokens_v2_no_auth_token_in_result
      extractor = build_extractor
      add_v2_preamble(extractor)
      add_v2_failure(extractor, first_result: '{"auth_token":null,"skype_spaces_token":"test"}')

      assert_nil extractor.extract
    end

    def test_extract_tokens_v2_handles_json_parse_error
      extractor = build_extractor
      add_v2_preamble(extractor)
      add_v2_failure(extractor, first_result: 'not valid json {')

      assert_nil extractor.extract
    end
  end

  # Tests skype token exchange handling for nil, empty, error, and JSON parse failures
  class ExchangerTest < Minitest::Test
    include Helpers

    def test_exchange_returns_nil_when_no_skype_spaces_token
      extractor = build_extractor
      add_preamble(extractor)
      results = extractor.applescript_results
      results << '{"auth_token":"test-auth","skype_spaces_token":null}'
      results << nil
      result = extractor.extract
      assert_equal 'test-auth', result[:auth_token]
      assert_nil result[:skype_token]
    end

    def test_exchange_handles_empty_result
      extractor = build_extractor
      add_preamble(extractor)
      results = extractor.applescript_results
      results << '{"auth_token":"test-auth","skype_spaces_token":"test-spaces"}'
      results << ''
      results << nil
      result = extractor.extract
      assert_equal 'test-auth', result[:auth_token]
      assert_nil result[:skype_token]
    end

    def test_exchange_handles_error_response
      extractor = build_extractor
      add_preamble(extractor)
      results = extractor.applescript_results
      results << '{"auth_token":"test-auth","skype_spaces_token":"test-spaces"}'
      results << '{"error":"Exchange failed"}'
      results << nil
      result = extractor.extract
      assert_nil result[:skype_token]
    end

    def test_exchange_handles_json_parse_error
      extractor = build_extractor
      add_preamble(extractor)
      results = extractor.applescript_results
      results << '{"auth_token":"test-auth","skype_spaces_token":"test-spaces"}'
      results << 'not-json'
      results << nil
      result = extractor.extract
      assert_nil result[:skype_token]
    end
  end

  # Tests v1 token polling with success, JSON parse error recovery, and exhaustion
  class PollingTest < Minitest::Test
    include Helpers

    def test_v1_success_on_first_try
      extractor = build_extractor
      add_preamble(extractor)
      add_v1_tokens(extractor)
      result = extractor.extract
      assert_equal 'v1-auth', result[:auth_token]
      assert_equal 'v1-skype', result[:skype_token]
    end

    def test_v1_json_parse_error_continues_polling
      extractor = build_extractor
      add_preamble(extractor)
      extractor.applescript_results << 'bad json'
      add_v1_tokens(extractor, tokens: { chat: 'https://c.com' })
      result = extractor.extract
      assert_equal 'v1-auth', result[:auth_token]
    end

    def test_v1_returns_nil_on_no_auth_token
      extractor = build_extractor
      add_preamble(extractor)
      add_exhausted_v1_v2_polling(extractor)

      assert_nil extractor.extract
    end

    private

    def add_exhausted_v1_v2_polling(extractor)
      results = extractor.applescript_results
      results.push('{"auth_token":null}', *Array.new(35), 'no_key', *Array.new(30), nil)
    end
  end

  # Tests page ready detection requiring Teams URL and complete load state
  class PageReadyTest < Minitest::Test
    include Helpers

    def test_page_ready_requires_teams_url
      extractor = build_extractor
      add_open_safari(extractor)
      results = extractor.applescript_results
      results << 'https://login.microsoftonline.com/|complete'
      add_ready_sequence(extractor)
      results << '{"auth_token":"ready-auth","skype_spaces_token":null}'
      results << nil
      result = extractor.extract
      assert_equal 'ready-auth', result[:auth_token]
    end

    def test_page_ready_requires_complete_state
      extractor = build_extractor
      add_open_safari(extractor)
      results = extractor.applescript_results
      results << 'https://teams.microsoft.com/v2/|loading'
      add_ready_sequence(extractor)
      results << '{"auth_token":"ready-auth","skype_spaces_token":null}'
      results << nil
      result = extractor.extract
      assert_equal 'ready-auth', result[:auth_token]
    end

    def test_page_ready_returns_false_for_nil
      extractor = build_extractor
      add_open_safari(extractor)
      results = extractor.applescript_results
      results << nil
      add_ready_sequence(extractor)
      results.push('{"auth_token":"test","skype_spaces_token":null}', nil)
      assert extractor.extract
    end
  end

  # Tests login wait progress logging during authentication redirect polling
  class WaitForLoginTest < Minitest::Test
    include Helpers

    def test_wait_for_login_logs_progress_every_ten_seconds
      extractor, err = build_verbose_extractor
      add_login_wait_preamble(extractor)
      results = extractor.applescript_results
      results.push('{"auth_token":"delayed-auth","skype_spaces_token":null}', nil)
      result = extractor.extract
      assert_equal 'delayed-auth', result[:auth_token]
      assert_match(/Waiting.*10s/, err.string)
    end
  end

  # Tests debug message logging when verbose output is attached
  class WithOutputTest < Minitest::Test
    include Helpers

    def test_logs_debug_messages_with_output
      err = StringIO.new
      output = Teems::Formatters::Output.new(err: err, color: false, mode: :verbose)
      extractor = TestableTokenExtractor.new(output: output)
      extractor.system_result = false
      extractor.extract
      assert_match(/Safari is not available/, err.string)
    end
  end

  # Tests AppleScript error handling for exit failures, IO errors, and missing osascript
  class AppleScriptErrorTest < Minitest::Test
    # Exposes private AppleScript error methods for testing
    class ExposedAutomation < Teems::Services::TokenExtractor
      public :applescript_failure, :log_applescript_error, :format_applescript_error

      private

      def try_headless_extract = nil
      def safari_available? = true
      def sleep(_seconds) = nil
    end

    def test_applescript_failure_returns_nil
      extractor = ExposedAutomation.new
      status = Minitest::Mock.new
      status.expect(:exitstatus, 1)
      assert_nil extractor.applescript_failure(status)
      status.verify
    end

    def test_log_applescript_error_returns_nil
      extractor = ExposedAutomation.new
      error = IOError.new('stream closed')
      assert_nil extractor.log_applescript_error(error)
    end

    def test_format_applescript_error_for_enoent
      extractor = ExposedAutomation.new
      error = Errno::ENOENT.new('osascript')
      result = extractor.format_applescript_error(error)
      assert_includes result, 'osascript not found'
    end

    def test_format_applescript_error_for_io_error
      extractor = ExposedAutomation.new
      error = IOError.new('stream closed')
      result = extractor.format_applescript_error(error)
      assert_includes result, 'AppleScript I/O error'
      assert_includes result, 'stream closed'
    end
  end

  # Tests v2 extraction path with unparseable v1 refresh data fallback
  class V1RefreshDataTest < Minitest::Test
    include Helpers

    def test_v2_with_unparseable_v1_refresh_data
      extractor = build_extractor
      add_v2_preamble(extractor)
      add_v2_tokens_with_bad_refresh(extractor)
      result = extractor.extract
      assert_equal 'v2-auth', result[:auth_token]
    end

    private

    def add_v2_tokens_with_bad_refresh(extractor)
      results = extractor.applescript_results
      results << 'started'
      results << '{"auth_token":"v2-auth","skype_spaces_token":"v2-spaces"}'
      results << 'not valid json'
      results << '{"skype_token":"v2-skype","region":"us","chat_service":"https://c.com"}'
      results << nil
    end
  end

  # Exercises the real run_applescript wrapper with capture3 stubbed, so both branches are
  # covered on Linux (where osascript does not exist) as well as macOS.
  class RunAppleScriptTest < Minitest::Test
    FakeStatus = Struct.new(:success?, :exitstatus)

    def test_returns_stripped_output_on_success
      result = with_capture3(['  hi  ', '', FakeStatus.new(true, 0)]) do |extractor|
        extractor.send(:run_applescript, 'return "hi"')
      end

      assert_equal 'hi', result
    end

    def test_returns_nil_and_logs_on_failure
      err = StringIO.new
      out = Teems::Formatters::Output.new(io: StringIO.new, err: err, color: false, mode: :verbose)
      result = with_capture3(['', 'boom', FakeStatus.new(false, 1)], output: out) do |extractor|
        extractor.send(:run_applescript, 'bad script')
      end

      assert_nil result
      assert_includes err.string, 'AppleScript execution failed with status 1'
    end

    private

    def with_capture3(response, output: nil)
      extractor = Teems::Services::TokenExtractor.new(output: output)
      Teems::Support::Subprocess.stub(:capture3, ->(*_args) { response }) do
        yield extractor
      end
    end
  end

  # notify surfaces sign-in progress outside verbose mode and must tolerate a nil output
  class NotifyTest < Minitest::Test
    def test_notify_writes_to_output
      io = StringIO.new
      out = Teems::Formatters::Output.new(io: io, err: StringIO.new, color: false)
      Teems::Services::TokenExtractor.new(output: out).send(:notify, 'signing in')

      assert_includes io.string, 'signing in'
    end

    def test_notify_without_output_is_a_no_op
      assert_nil Teems::Services::TokenExtractor.new.send(:notify, 'signing in')
    end
  end

  # V1 localStorage does not always carry refresh token data
  class V1ExtrasTest < Minitest::Test
    include Helpers

    def test_extract_v1_refresh_data_without_refresh_token
      extractor = build_extractor
      extractor.applescript_results << '{"auth_token":"a"}'

      assert_empty extractor.send(:extract_v1_refresh_data)
    end
  end
end
