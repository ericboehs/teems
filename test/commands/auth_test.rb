# frozen_string_literal: true

require 'test_helper'

module AuthCommandTests
  module Helpers
    private

    def build_auth_runner(output:, store: nil)
      store ||= mock_token_store(account: mock_account)
      Teems::Runner.new(output: output, token_store: store, api_client: Teems::TestHelpers::MockApiClient.new)
    end

    def run_auth(action, store: nil)
      capture_output do |output|
        runner = build_auth_runner(output: output, store: store)
        args = action.empty? ? [] : [action]
        Teems::Commands::Auth.new(args, runner: runner).execute
      end
    end

    def run_auth_with_code(action, store: nil, extra_args: [])
      exit_code_holder = nil
      result = capture_output do |output|
        runner = build_auth_runner(output: output, store: store)
        args = action.empty? ? [] : [action, *extra_args]
        exit_code_holder = Teems::Commands::Auth.new(args, runner: runner).execute
      end
      [result, exit_code_holder]
    end

    def write_token_json(dir, filename, content)
      path = File.join(dir, filename)
      File.write(path, content)
      path
    end
  end

  class BasicTest < Minitest::Test
    include Helpers

    def test_shows_help_with_help_flag
      with_temp_config do
        stdout = run_auth('--help')[:stdout]
        assert_match(/teems auth/, stdout)
        assert_match(/USAGE:/, stdout)
        assert_match(/login/, stdout)
        assert_match(/logout/, stdout)
        assert_match(/status/, stdout)
      end
    end

    def test_status_when_authenticated
      with_temp_config do
        result = run_auth('status')
        assert_match(/Authenticated as: default/, result[:stdout])
      end
    end

    def test_status_when_not_configured
      with_temp_config do
        store = mock_unconfigured_store
        result = run_auth('status', store: store)
        assert_match(/Not authenticated/, result[:stdout])
      end
    end

    def test_status_when_configured_but_account_nil
      with_temp_config do
        store = mock_token_store(configured: true, account: nil)
        result, exit_code = run_auth_with_code('status', store: store)
        assert_equal 0, exit_code
        assert_match(/Token file exists but is incomplete/, result[:stdout])
        assert_match(/teems auth login/, result[:stdout])
      end
    end

    def test_status_default_action
      with_temp_config do
        result = run_auth('')
        assert_match(/Authenticated as: default/, result[:stdout])
      end
    end

    def test_logout_when_configured
      with_temp_config do
        store = mock_token_store
        result, exit_code = run_auth_with_code('logout', store: store)
        assert_equal 0, exit_code
        assert_match(/Tokens cleared/, result[:stdout])
      end
    end

    def test_logout_when_not_configured
      with_temp_config do
        store = mock_unconfigured_store
        result, exit_code = run_auth_with_code('logout', store: store)
        assert_equal 0, exit_code
        assert_match(/No tokens to clear/, result[:stdout])
      end
    end

    def test_unknown_action
      with_temp_config do
        result, exit_code = run_auth_with_code('bogus')
        assert_equal 1, exit_code
        assert_match(/Unknown auth action: bogus/, result[:stderr])
      end
    end

    def test_clear_alias_for_logout
      with_temp_config do
        store = mock_token_store
        result, exit_code = run_auth_with_code('clear', store: store)
        assert_equal 0, exit_code
        assert_match(/Tokens cleared/, result[:stdout])
      end
    end
  end

  class LoginTest < Minitest::Test
    include Helpers

    def test_login_success
      with_temp_config do
        tokens = { auth_token: 'auth-tok', skype_token: 'skype-tok', skype_spaces_token: 'spaces', chatsvc_token: nil }
        result, exit_code = run_login_with_tokens(tokens)
        assert_equal 0, exit_code
        assert_match(/Authentication successful/, result[:stdout])
      end
    end

    def test_login_failure_suggests_manual
      with_temp_config do
        result, exit_code = run_login_with_tokens(nil)
        assert_equal 1, exit_code
        assert_match(/Failed to extract tokens automatically/, result[:stderr])
        assert_match(/teems auth manual/, result[:stdout])
      end
    end

    def test_login_failure_with_partial_tokens
      with_temp_config do
        result, exit_code = run_login_with_tokens({ auth_token: 'auth-tok', skype_token: nil })
        assert_equal 1, exit_code
        assert_match(/Failed to extract/, result[:stderr])
      end
    end

    def test_manual_shows_instructions
      with_temp_config do
        result, exit_code = run_auth_with_code('manual')
        assert_equal 0, exit_code
        assert_match(/manually extract tokens/, result[:stdout])
        assert_match(/teems auth set-tokens/, result[:stdout])
      end
    end

    def test_token_age_display_recent
      with_temp_config do
        store = mock_token_store(account: mock_account)
        store.define_singleton_method(:token_age) { 3600 }
        result = run_auth('status', store: store)
        assert_match(/Token age: 1 hours/, result[:stdout])
      end
    end

    def test_token_age_display_old
      with_temp_config do
        store = mock_token_store(account: mock_account)
        store.define_singleton_method(:token_age) { 100_800 }
        result = run_auth('status', store: store)
        assert_match(/Tokens are 28 hours old/, result[:stdout])
        assert_match(/may be expired/, result[:stdout])
      end
    end

    private

    def run_login_with_tokens(tokens)
      exit_code_holder = nil
      result = capture_output do |output|
        runner = build_login_runner(output, tokens)
        exit_code_holder = Teems::Commands::Auth.new(['login'], runner: runner).execute
      end
      [result, exit_code_holder]
    end

    def build_login_runner(output, tokens)
      store = mock_token_store
      runner = Teems::Runner.new(output: output, token_store: store,
                                 api_client: Teems::TestHelpers::MockApiClient.new)
      extractor = Object.new
      extractor.define_singleton_method(:extract) { tokens }
      runner.instance_variable_set(:@token_extractor, extractor)
      runner
    end
  end

  class ImportTokensTest < Minitest::Test
    include Helpers

    def test_set_alias_for_set_tokens
      with_temp_config do |dir|
        token_file = write_token_json(dir, 'tokens.json', '{"auth_token":"test-auth","skype_token":"test-skype"}')
        result, exit_code = run_auth_with_code('set', extra_args: [token_file])
        assert_equal 0, exit_code
        assert_match(/Tokens saved successfully/, result[:stdout])
      end
    end

    def test_import_tokens_from_file_success
      with_temp_config do |dir|
        token_file = write_token_json(dir, 'tokens.json', '{"auth_token":"file-auth","skype_token":"file-skype"}')
        result, exit_code = run_auth_with_code('set-tokens', extra_args: [token_file])
        assert_equal 0, exit_code
        assert_match(/Tokens saved successfully/, result[:stdout])
      end
    end

    def test_import_tokens_from_file_not_found
      with_temp_config do
        result, exit_code = run_auth_with_code('set-tokens', extra_args: ['/nonexistent/file.json'])
        assert_equal 1, exit_code
        assert_match(/File not found/, result[:stderr])
      end
    end

    def test_import_tokens_from_file_invalid_json
      with_temp_config do |dir|
        token_file = write_token_json(dir, 'bad.json', 'not json')
        result, exit_code = run_auth_with_code('set-tokens', extra_args: [token_file])
        assert_equal 1, exit_code
        assert_match(/Invalid JSON/, result[:stderr])
      end
    end

    def test_import_tokens_missing_auth_token_key
      with_temp_config do |dir|
        token_file = write_token_json(dir, 'no_auth.json', '{"skype_token":"only-skype"}')
        result, exit_code = run_auth_with_code('set-tokens', extra_args: [token_file])
        assert_equal 1, exit_code
        assert_match(/auth_token key/, result[:stderr])
      end
    end

    def test_import_tokens_directory_path
      with_temp_config do |dir|
        result, exit_code = run_auth_with_code('set-tokens', extra_args: [dir])
        assert_equal 1, exit_code
        assert_match(/directory, not a file/, result[:stderr])
      end
    end

    def test_import_tokens_with_authtoken_key
      with_temp_config do |dir|
        token_file = write_token_json(dir, 'alt.json', '{"authtoken":"alt-auth"}')
        result, exit_code = run_auth_with_code('set-tokens', extra_args: [token_file])
        assert_equal 0, exit_code
        assert_match(/Tokens saved/, result[:stdout])
      end
    end
  end

  class SetTokensStdinTest < Minitest::Test
    def test_set_tokens_from_stdin
      with_temp_config do
        result, exit_code = run_stdin_auth("test-auth-token\n\ntest-skype-token\n\n")
        assert_equal 0, exit_code
        assert_match(/Tokens saved/, result[:stdout])
      end
    end

    def test_set_tokens_from_stdin_empty_auth_token
      with_temp_config do
        result, exit_code = run_stdin_auth("\n")
        assert_equal 1, exit_code
        assert_match(/Auth token is required/, result[:stderr])
      end
    end

    def test_set_tokens_from_stdin_eof
      with_temp_config do
        result, exit_code = run_stdin_auth('')
        assert_equal 1, exit_code
        assert_match(/Auth token is required/, result[:stderr])
      end
    end

    private

    def run_stdin_auth(stdin_content)
      exit_code_holder = nil
      result = capture_output do |output|
        store = mock_token_store
        runner = Teems::Runner.new(output: output, token_store: store,
                                   api_client: Teems::TestHelpers::MockApiClient.new)
        cmd = Teems::Commands::Auth.new(['set-tokens'], runner: runner)
        with_fake_stdin(stdin_content) { exit_code_holder = cmd.execute }
      end
      [result, exit_code_holder]
    end
  end

  class CleanTokenTest < Minitest::Test
    def test_clean_token_strips_bearer_prefix
      with_temp_config do |dir|
        result = run_set_tokens_with_file(dir, 'bearer.json', '{"auth_token":"Bearer eyJ0eXA"}')
        assert_match(/Tokens saved/, result[:stdout])
      end
    end

    def test_clean_token_strips_skypetoken_prefix
      with_temp_config do |dir|
        content = '{"auth_token":"test-auth","skype_token":"skypetoken=eyJ0eXA"}'
        result = run_set_tokens_with_file(dir, 'skype_prefix.json', content)
        assert_match(/Tokens saved/, result[:stdout])
      end
    end

    private

    def run_set_tokens_with_file(dir, filename, content)
      token_file = File.join(dir, filename)
      File.write(token_file, content)
      capture_output do |output|
        store = mock_token_store
        runner = Teems::Runner.new(output: output, token_store: store,
                                   api_client: Teems::TestHelpers::MockApiClient.new)
        Teems::Commands::Auth.new(['set-tokens', token_file], runner: runner).execute
      end
    end
  end

  class FilePermissionTest < Minitest::Test
    def test_import_unreadable_file_shows_error
      with_temp_config do |dir|
        token_file = File.join(dir, 'unreadable.json')
        File.write(token_file, '{"auth_token":"test"}')
        File.chmod(0o000, token_file)
        result = run_set_tokens(token_file)

        assert_match(/Cannot read file/, result[:stderr])
      ensure
        File.chmod(0o644, token_file)
      end
    end

    def test_import_directory_shows_error
      with_temp_config do |dir|
        dir_path = File.join(dir, 'a_directory')
        FileUtils.mkdir_p(dir_path)
        result = run_set_tokens(dir_path)

        assert_match(/Path is a directory/, result[:stderr])
      end
    end

    private

    def run_set_tokens(path)
      capture_output do |output|
        store = mock_token_store
        runner = Teems::Runner.new(output: output, token_store: store,
                                   api_client: Teems::TestHelpers::MockApiClient.new)
        Teems::Commands::Auth.new(['set-tokens', path], runner: runner).execute
      end
    end
  end
end
