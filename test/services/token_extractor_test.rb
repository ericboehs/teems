# frozen_string_literal: true

require 'test_helper'

module TokenExtractorTests
  class TestableTokenExtractor < Teems::Services::TokenExtractor
    attr_accessor :applescript_results, :system_result, :applescript_call_count

    def initialize(output: nil)
      super
      @applescript_results = []
      @applescript_call_count = 0
      @system_result = true
    end

    private

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

  module Helpers
    TEAMS_URL = 'https://teams.microsoft.com/v2/|complete'
    LOGIN_URL = 'https://login.microsoftonline.com/|loading'

    def build_extractor(output: nil)
      e = TestableTokenExtractor.new(output: output)
      e.system_result = true
      e
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
      extractor.applescript_results << 'started'
      extractor.applescript_results << '{"auth_token":"v2-auth","skype_spaces_token":"v2-skype-spaces"}'
      # extract_v1_refresh_data runs EXTRACT_TOKENS_JS to grab refresh token (always V1)
      extractor.applescript_results << '{"auth_token":null,"skype_spaces_token":null,' \
                                       '"refresh_token":null,"client_id":null,"tenant_id":null}'
      extractor.applescript_results << '{"skype_token":"v2-skype","region":"us","chat_service":"https://chat.com"}'
      extractor.applescript_results << nil
    end

    # v2 failure: bad first-token response, then exhaust polling
    def add_v2_failure(extractor, first_result:)
      extractor.applescript_results << 'started'
      extractor.applescript_results << first_result
      24.times { extractor.applescript_results << nil }
      extractor.applescript_results << nil
    end

    # v1 success tokens
    def add_v1_tokens(extractor, auth: 'v1-auth', spaces: 'v1-spaces',
                      skype: 'v1-skype', chat: 'https://chat.com')
      extractor.applescript_results << %({"auth_token":"#{auth}","skype_spaces_token":"#{spaces}"})
      extractor.applescript_results << %({"skype_token":"#{skype}","region":"us","chat_service":"#{chat}"})
      extractor.applescript_results << nil
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
      extractor.applescript_results << '{"auth_token":"test-auth","skype_spaces_token":"test-skype-spaces"}'
      extractor.applescript_results << '{"skype_token":"test-skype","region":"us","chat_service":"https://chat.com"}'
      extractor.applescript_results << nil
      result = extractor.extract
      assert_equal 'test-auth', result[:auth_token]
      assert_equal 'test-skype', result[:skype_token]
      assert_equal 'test-skype-spaces', result[:skype_spaces_token]
    end

    def test_extract_returns_nil_when_tokens_not_found
      extractor = build_extractor
      add_preamble(extractor)
      60.times { extractor.applescript_results << nil }
      extractor.applescript_results << nil

      assert_nil extractor.extract
    end

    def test_manual_instructions_returns_string
      instructions = build_extractor.manual_instructions
      assert_includes instructions, 'manually extract tokens'
      assert_includes instructions, 'localStorage'
    end
  end

  class V2DecryptorTest < Minitest::Test
    include Helpers

    def test_extract_tokens_v2_returns_nil_on_no_key
      extractor = build_extractor
      add_v2_preamble(extractor)
      extractor.applescript_results << 'no_key'
      24.times { extractor.applescript_results << nil }
      extractor.applescript_results << nil

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
      extractor.applescript_results << 'started'
      10.times { extractor.applescript_results << '' }
      24.times { extractor.applescript_results << nil }
      extractor.applescript_results << nil

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

  class ExchangerTest < Minitest::Test
    include Helpers

    def test_exchange_returns_nil_when_no_skype_spaces_token
      extractor = build_extractor
      add_preamble(extractor)
      extractor.applescript_results << '{"auth_token":"test-auth","skype_spaces_token":null}'
      extractor.applescript_results << nil
      result = extractor.extract
      assert_equal 'test-auth', result[:auth_token]
      assert_nil result[:skype_token]
    end

    def test_exchange_handles_empty_result
      extractor = build_extractor
      add_preamble(extractor)
      extractor.applescript_results << '{"auth_token":"test-auth","skype_spaces_token":"test-spaces"}'
      extractor.applescript_results << ''
      extractor.applescript_results << nil
      result = extractor.extract
      assert_equal 'test-auth', result[:auth_token]
      assert_nil result[:skype_token]
    end

    def test_exchange_handles_error_response
      extractor = build_extractor
      add_preamble(extractor)
      extractor.applescript_results << '{"auth_token":"test-auth","skype_spaces_token":"test-spaces"}'
      extractor.applescript_results << '{"error":"Exchange failed"}'
      extractor.applescript_results << nil
      result = extractor.extract
      assert_nil result[:skype_token]
    end

    def test_exchange_handles_json_parse_error
      extractor = build_extractor
      add_preamble(extractor)
      extractor.applescript_results << '{"auth_token":"test-auth","skype_spaces_token":"test-spaces"}'
      extractor.applescript_results << 'not-json'
      extractor.applescript_results << nil
      result = extractor.extract
      assert_nil result[:skype_token]
    end
  end

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
      add_v1_tokens(extractor, chat: 'https://c.com')
      result = extractor.extract
      assert_equal 'v1-auth', result[:auth_token]
    end

    def test_v1_returns_nil_on_no_auth_token
      extractor = build_extractor
      add_preamble(extractor)
      extractor.applescript_results << '{"auth_token":null}'
      35.times { extractor.applescript_results << nil }
      extractor.applescript_results << 'no_key'
      30.times { extractor.applescript_results << nil }
      extractor.applescript_results << nil

      assert_nil extractor.extract
    end
  end

  class PageReadyTest < Minitest::Test
    include Helpers

    def test_page_ready_requires_teams_url
      extractor = build_extractor
      add_open_safari(extractor)
      extractor.applescript_results << 'https://login.microsoftonline.com/|complete'
      add_ready_sequence(extractor)
      extractor.applescript_results << '{"auth_token":"ready-auth","skype_spaces_token":null}'
      extractor.applescript_results << nil
      result = extractor.extract
      assert_equal 'ready-auth', result[:auth_token]
    end

    def test_page_ready_requires_complete_state
      extractor = build_extractor
      add_open_safari(extractor)
      extractor.applescript_results << 'https://teams.microsoft.com/v2/|loading'
      add_ready_sequence(extractor)
      extractor.applescript_results << '{"auth_token":"ready-auth","skype_spaces_token":null}'
      extractor.applescript_results << nil
      result = extractor.extract
      assert_equal 'ready-auth', result[:auth_token]
    end

    def test_page_ready_returns_false_for_nil
      extractor = build_extractor
      add_open_safari(extractor)
      extractor.applescript_results << nil
      add_ready_sequence(extractor)
      extractor.applescript_results << '{"auth_token":"test","skype_spaces_token":null}'
      extractor.applescript_results << nil
      assert extractor.extract
    end
  end

  class WaitForLoginTest < Minitest::Test
    include Helpers

    def test_wait_for_login_logs_progress_every_ten_seconds
      extractor, err = build_verbose_extractor
      add_login_wait_preamble(extractor)
      extractor.applescript_results << '{"auth_token":"delayed-auth","skype_spaces_token":null}'
      extractor.applescript_results << nil
      result = extractor.extract
      assert_equal 'delayed-auth', result[:auth_token]
      assert_match(/Waiting.*10s/, err.string)
    end
  end

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
end
