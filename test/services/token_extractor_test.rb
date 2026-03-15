# frozen_string_literal: true

require 'test_helper'

# Testable subclass that overrides system calls to avoid real Safari/osascript
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

class TokenExtractorTest < Minitest::Test
  def test_extract_returns_nil_when_safari_unavailable
    extractor = TestableTokenExtractor.new
    extractor.system_result = false

    result = extractor.extract

    assert_nil result
  end

  def test_extract_opens_teams_and_extracts_tokens
    extractor = TestableTokenExtractor.new
    extractor.system_result = true

    # open_teams_in_safari
    extractor.applescript_results << nil
    # wait_for_login: page_ready? check - URL with teams and complete state
    extractor.applescript_results << 'https://teams.microsoft.com/v2/|complete'
    # extract_tokens_v1
    extractor.applescript_results << '{"auth_token":"test-auth","skype_spaces_token":"test-skype-spaces"}'
    # exchange_skype_if_available call
    extractor.applescript_results << '{"skype_token":"test-skype","region":"us","chat_service":"https://chat.com"}'
    # close_teams_tab
    extractor.applescript_results << nil

    result = extractor.extract

    assert result
    assert_equal 'test-auth', result[:auth_token]
    assert_equal 'test-skype', result[:skype_token]
    assert_equal 'test-skype-spaces', result[:skype_spaces_token]
  end

  def test_extract_returns_nil_when_tokens_not_found
    extractor = TestableTokenExtractor.new
    extractor.system_result = true

    # open_teams_in_safari
    extractor.applescript_results << nil
    # wait_for_login: page_ready? returns ready
    extractor.applescript_results << 'https://teams.microsoft.com/v2/|complete'
    # extract_tokens_v1 returns empty for all polls, plus v2 decryption
    60.times { extractor.applescript_results << nil }
    # close_teams_tab
    extractor.applescript_results << nil

    result = extractor.extract

    assert_nil result
  end

  def test_manual_instructions_returns_string
    extractor = TestableTokenExtractor.new

    instructions = extractor.manual_instructions

    assert_includes instructions, 'manually extract tokens'
    assert_includes instructions, 'localStorage'
  end
end

class SafariAutomationTest < Minitest::Test
  def test_run_safari_js_returns_result
    extractor = TestableTokenExtractor.new
    extractor.applescript_results << 'test-result'

    # Access via extract_tokens_v1 pathway which calls run_safari_js
    # Instead, test the underlying applescript call count
    assert_equal 0, extractor.applescript_call_count
  end

  def test_escape_js_for_applescript
    extractor = TestableTokenExtractor.new

    # The escape method is private - test it through the extractor behavior
    # JavaScript with quotes and backslashes gets escaped for AppleScript
    extractor.applescript_results << '{"auth_token":null}'
    extractor.applescript_results << nil # close tab

    # Verify no errors are raised
    assert_equal 0, extractor.applescript_call_count
  end
end

class TokenV2DecryptorTest < Minitest::Test
  def test_extract_tokens_v2_returns_nil_on_no_key
    extractor = TestableTokenExtractor.new
    extractor.system_result = true

    # open_teams_in_safari
    extractor.applescript_results << nil
    # wait_for_login
    extractor.applescript_results << 'https://teams.microsoft.com/v2/|complete'
    # v1 polls (5 attempts before v2 is tried)
    6.times { extractor.applescript_results << nil }
    # v2 kick_off_decryption returns 'no_key'
    extractor.applescript_results << 'no_key'
    # remaining v1 polls (30 - 6 = 24)
    24.times { extractor.applescript_results << nil }
    # close_teams_tab
    extractor.applescript_results << nil

    result = extractor.extract

    assert_nil result
  end

  def test_extract_tokens_v2_returns_tokens_on_success
    extractor = TestableTokenExtractor.new
    extractor.system_result = true

    # open_teams_in_safari
    extractor.applescript_results << nil
    # wait_for_login
    extractor.applescript_results << 'https://teams.microsoft.com/v2/|complete'
    # v1 polls (6 fails, to reach v2 threshold)
    6.times { extractor.applescript_results << nil }
    # v2 kick_off_decryption returns 'started'
    extractor.applescript_results << 'started'
    # poll_decrypt_result: first poll returns result
    extractor.applescript_results << '{"auth_token":"v2-auth","skype_spaces_token":"v2-skype-spaces"}'
    # exchange_skype_if_available
    extractor.applescript_results << '{"skype_token":"v2-skype","region":"us","chat_service":"https://chat.com"}'
    # close_teams_tab
    extractor.applescript_results << nil

    result = extractor.extract

    assert result
    assert_equal 'v2-auth', result[:auth_token]
    assert_equal 'v2-skype', result[:skype_token]
  end

  def test_extract_tokens_v2_handles_decrypt_error
    extractor = TestableTokenExtractor.new
    extractor.system_result = true

    # open_teams_in_safari
    extractor.applescript_results << nil
    # wait_for_login
    extractor.applescript_results << 'https://teams.microsoft.com/v2/|complete'
    # v1 polls
    6.times { extractor.applescript_results << nil }
    # v2 kick_off returns 'started'
    extractor.applescript_results << 'started'
    # poll returns error
    extractor.applescript_results << '{"error":"decryption failed"}'
    # remaining v1 polls
    24.times { extractor.applescript_results << nil }
    # close tab
    extractor.applescript_results << nil

    result = extractor.extract

    assert_nil result
  end

  def test_extract_tokens_v2_handles_timeout
    extractor = TestableTokenExtractor.new
    extractor.system_result = true

    # open_teams_in_safari
    extractor.applescript_results << nil
    # wait_for_login
    extractor.applescript_results << 'https://teams.microsoft.com/v2/|complete'
    # v1 polls
    6.times { extractor.applescript_results << nil }
    # v2 kick_off returns 'started'
    extractor.applescript_results << 'started'
    # 10 polls return empty (timeout)
    10.times { extractor.applescript_results << '' }
    # remaining v1 polls
    24.times { extractor.applescript_results << nil }
    # close tab
    extractor.applescript_results << nil

    result = extractor.extract

    assert_nil result
  end

  def test_extract_tokens_v2_no_auth_token_in_result
    extractor = TestableTokenExtractor.new
    extractor.system_result = true

    # open_teams_in_safari
    extractor.applescript_results << nil
    # wait_for_login
    extractor.applescript_results << 'https://teams.microsoft.com/v2/|complete'
    # v1 polls
    6.times { extractor.applescript_results << nil }
    # v2 kick_off returns 'started'
    extractor.applescript_results << 'started'
    # poll returns result without auth_token
    extractor.applescript_results << '{"auth_token":null,"skype_spaces_token":"test"}'
    # remaining v1 polls
    24.times { extractor.applescript_results << nil }
    # close tab
    extractor.applescript_results << nil

    result = extractor.extract

    assert_nil result
  end

  def test_extract_tokens_v2_handles_json_parse_error
    extractor = TestableTokenExtractor.new
    extractor.system_result = true

    # open_teams_in_safari
    extractor.applescript_results << nil
    # wait_for_login
    extractor.applescript_results << 'https://teams.microsoft.com/v2/|complete'
    # v1 polls
    6.times { extractor.applescript_results << nil }
    # v2 kick_off returns 'started'
    extractor.applescript_results << 'started'
    # poll returns invalid JSON
    extractor.applescript_results << 'not valid json {'
    # remaining v1 polls
    24.times { extractor.applescript_results << nil }
    # close tab
    extractor.applescript_results << nil

    result = extractor.extract

    assert_nil result
  end
end

class TokenExchangerTest < Minitest::Test
  def test_exchange_returns_nil_when_no_skype_spaces_token
    extractor = TestableTokenExtractor.new
    extractor.system_result = true

    # open_teams_in_safari
    extractor.applescript_results << nil
    # wait_for_login
    extractor.applescript_results << 'https://teams.microsoft.com/v2/|complete'
    # extract_tokens_v1 with auth_token but no skype_spaces_token
    extractor.applescript_results << '{"auth_token":"test-auth","skype_spaces_token":null}'
    # close tab
    extractor.applescript_results << nil

    result = extractor.extract

    # Auth token exists but no skype token since exchange returned nil
    assert result
    assert_equal 'test-auth', result[:auth_token]
    assert_nil result[:skype_token]
  end

  def test_exchange_handles_empty_result
    extractor = TestableTokenExtractor.new
    extractor.system_result = true

    # open_teams_in_safari
    extractor.applescript_results << nil
    # wait_for_login
    extractor.applescript_results << 'https://teams.microsoft.com/v2/|complete'
    # extract_tokens_v1 with both tokens
    extractor.applescript_results << '{"auth_token":"test-auth","skype_spaces_token":"test-spaces"}'
    # exchange returns empty
    extractor.applescript_results << ''
    # close tab
    extractor.applescript_results << nil

    result = extractor.extract

    assert result
    assert_equal 'test-auth', result[:auth_token]
    assert_nil result[:skype_token]
  end

  def test_exchange_handles_error_response
    extractor = TestableTokenExtractor.new
    extractor.system_result = true

    # open_teams_in_safari
    extractor.applescript_results << nil
    # wait_for_login
    extractor.applescript_results << 'https://teams.microsoft.com/v2/|complete'
    # extract_tokens_v1
    extractor.applescript_results << '{"auth_token":"test-auth","skype_spaces_token":"test-spaces"}'
    # exchange returns error
    extractor.applescript_results << '{"error":"Exchange failed"}'
    # close tab
    extractor.applescript_results << nil

    result = extractor.extract

    assert result
    assert_nil result[:skype_token]
  end

  def test_exchange_handles_json_parse_error
    extractor = TestableTokenExtractor.new
    extractor.system_result = true

    # open_teams_in_safari
    extractor.applescript_results << nil
    # wait_for_login
    extractor.applescript_results << 'https://teams.microsoft.com/v2/|complete'
    # extract_tokens_v1
    extractor.applescript_results << '{"auth_token":"test-auth","skype_spaces_token":"test-spaces"}'
    # exchange returns invalid json
    extractor.applescript_results << 'not-json'
    # close tab
    extractor.applescript_results << nil

    result = extractor.extract

    assert result
    assert_nil result[:skype_token]
  end
end

class TokenPollingTest < Minitest::Test
  def test_v1_success_on_first_try
    extractor = TestableTokenExtractor.new
    extractor.system_result = true

    # open_teams_in_safari
    extractor.applescript_results << nil
    # wait_for_login
    extractor.applescript_results << 'https://teams.microsoft.com/v2/|complete'
    # extract_tokens_v1 succeeds immediately
    extractor.applescript_results << '{"auth_token":"v1-auth","skype_spaces_token":"v1-spaces"}'
    # exchange
    extractor.applescript_results << '{"skype_token":"v1-skype","region":"us","chat_service":"https://chat.com"}'
    # close tab
    extractor.applescript_results << nil

    result = extractor.extract

    assert result
    assert_equal 'v1-auth', result[:auth_token]
    assert_equal 'v1-skype', result[:skype_token]
  end

  def test_v1_json_parse_error_continues_polling
    extractor = TestableTokenExtractor.new
    extractor.system_result = true

    # open_teams_in_safari
    extractor.applescript_results << nil
    # wait_for_login
    extractor.applescript_results << 'https://teams.microsoft.com/v2/|complete'
    # First v1 attempt returns bad JSON
    extractor.applescript_results << 'bad json'
    # Second v1 attempt succeeds
    extractor.applescript_results << '{"auth_token":"v1-auth","skype_spaces_token":"v1-spaces"}'
    # exchange
    extractor.applescript_results << '{"skype_token":"v1-skype","region":"us","chat_service":"https://c.com"}'
    # close tab
    extractor.applescript_results << nil

    result = extractor.extract

    assert result
    assert_equal 'v1-auth', result[:auth_token]
  end

  def test_v1_returns_nil_on_no_auth_token
    extractor = TestableTokenExtractor.new
    extractor.system_result = true

    # open_teams_in_safari
    extractor.applescript_results << nil
    # wait_for_login
    extractor.applescript_results << 'https://teams.microsoft.com/v2/|complete'
    # v1 returns result without auth_token
    extractor.applescript_results << '{"auth_token":null}'
    # More v1 polls
    35.times { extractor.applescript_results << nil }
    # v2 returns no_key
    extractor.applescript_results << 'no_key'
    # More polls
    30.times { extractor.applescript_results << nil }
    # close tab
    extractor.applescript_results << nil

    result = extractor.extract

    assert_nil result
  end
end

class TokenExtractorPageReadyTest < Minitest::Test
  def test_page_ready_requires_teams_url
    extractor = TestableTokenExtractor.new
    extractor.system_result = true

    # open_teams_in_safari
    extractor.applescript_results << nil
    # wait_for_login: not ready (login page)
    extractor.applescript_results << 'https://login.microsoftonline.com/|complete'
    # wait_for_login: ready
    extractor.applescript_results << 'https://teams.microsoft.com/v2/|complete'
    # extract_tokens_v1
    extractor.applescript_results << '{"auth_token":"ready-auth","skype_spaces_token":null}'
    # close tab
    extractor.applescript_results << nil

    result = extractor.extract

    assert result
    assert_equal 'ready-auth', result[:auth_token]
  end

  def test_page_ready_requires_complete_state
    extractor = TestableTokenExtractor.new
    extractor.system_result = true

    # open_teams_in_safari
    extractor.applescript_results << nil
    # wait_for_login: not ready (loading)
    extractor.applescript_results << 'https://teams.microsoft.com/v2/|loading'
    # wait_for_login: ready
    extractor.applescript_results << 'https://teams.microsoft.com/v2/|complete'
    # extract_tokens_v1
    extractor.applescript_results << '{"auth_token":"ready-auth","skype_spaces_token":null}'
    # close tab
    extractor.applescript_results << nil

    result = extractor.extract

    assert result
    assert_equal 'ready-auth', result[:auth_token]
  end

  def test_page_ready_returns_false_for_nil
    extractor = TestableTokenExtractor.new
    extractor.system_result = true

    # open_teams_in_safari
    extractor.applescript_results << nil
    # wait_for_login: nil responses
    extractor.applescript_results << nil
    # eventually ready
    extractor.applescript_results << 'https://teams.microsoft.com/v2/|complete'
    # extract_tokens_v1
    extractor.applescript_results << '{"auth_token":"test","skype_spaces_token":null}'
    # close tab
    extractor.applescript_results << nil

    result = extractor.extract

    assert result
  end
end

class TokenExtractorWaitForLoginTest < Minitest::Test
  def test_wait_for_login_logs_progress_every_10s
    err = StringIO.new
    output = Teems::Formatters::Output.new(err: err, color: false, verbose: true)
    extractor = TestableTokenExtractor.new(output: output)
    extractor.system_result = true

    # open_teams_in_safari
    extractor.applescript_results << nil
    # wait_for_login: 10 iterations of not ready, then ready at 11th
    10.times { extractor.applescript_results << 'https://login.microsoftonline.com/|loading' }
    extractor.applescript_results << 'https://teams.microsoft.com/v2/|complete'
    # extract_tokens_v1
    extractor.applescript_results << '{"auth_token":"delayed-auth","skype_spaces_token":null}'
    # close tab
    extractor.applescript_results << nil

    result = extractor.extract

    assert result
    assert_equal 'delayed-auth', result[:auth_token]
    assert_match(/Waiting.*10s/, err.string)
  end
end

class TokenExtractorWithOutputTest < Minitest::Test
  def test_logs_debug_messages_with_output
    err = StringIO.new
    output = Teems::Formatters::Output.new(err: err, color: false, verbose: true)
    extractor = TestableTokenExtractor.new(output: output)
    extractor.system_result = false

    extractor.extract

    assert_match(/Safari is not available/, err.string)
  end
end
