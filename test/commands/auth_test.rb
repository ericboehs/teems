# frozen_string_literal: true

require 'test_helper'

class AuthCommandTest < Minitest::Test
  def test_shows_help_with_help_flag
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        cmd = Teems::Commands::Auth.new(['--help'], runner: runner)
        cmd.execute
      end

      assert_match(/teems auth/, result[:stdout])
      assert_match(/USAGE:/, result[:stdout])
      assert_match(/login/, result[:stdout])
      assert_match(/logout/, result[:stdout])
      assert_match(/status/, result[:stdout])
    end
  end

  def test_status_when_authenticated
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        cmd = Teems::Commands::Auth.new(['status'], runner: runner)
        cmd.execute
      end

      assert_match(/Authenticated as: default/, result[:stdout])
    end
  end

  def test_status_when_not_configured
    with_temp_config do
      result = capture_output do |output|
        store = mock_token_store(configured: false)
        runner = Teems::Runner.new(output: output, token_store: store)
        cmd = Teems::Commands::Auth.new(['status'], runner: runner)
        cmd.execute
      end

      assert_match(/Not authenticated/, result[:stdout])
    end
  end

  def test_status_when_configured_but_account_nil
    with_temp_config do
      result = capture_output do |output|
        store = mock_token_store(configured: true, account: nil)
        runner = Teems::Runner.new(output: output, token_store: store)
        cmd = Teems::Commands::Auth.new(['status'], runner: runner)
        exit_code = cmd.execute

        assert_equal 0, exit_code
      end

      assert_match(/Token file exists but is incomplete/, result[:stdout])
      assert_match(/teems auth login/, result[:stdout])
    end
  end

  def test_status_default_action
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        cmd = Teems::Commands::Auth.new([], runner: runner)
        cmd.execute
      end

      assert_match(/Authenticated as: default/, result[:stdout])
    end
  end

  def test_logout_when_configured
    with_temp_config do
      result = capture_output do |output|
        store = mock_token_store
        runner = Teems::Runner.new(output: output, token_store: store)
        cmd = Teems::Commands::Auth.new(['logout'], runner: runner)
        exit_code = cmd.execute

        assert_equal 0, exit_code
      end

      assert_match(/Tokens cleared/, result[:stdout])
    end
  end

  def test_logout_when_not_configured
    with_temp_config do
      result = capture_output do |output|
        store = mock_token_store(configured: false)
        runner = Teems::Runner.new(output: output, token_store: store)
        cmd = Teems::Commands::Auth.new(['logout'], runner: runner)
        exit_code = cmd.execute

        assert_equal 0, exit_code
      end

      assert_match(/No tokens to clear/, result[:stdout])
    end
  end

  def test_unknown_action
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        cmd = Teems::Commands::Auth.new(['bogus'], runner: runner)
        exit_code = cmd.execute

        assert_equal 1, exit_code
      end

      assert_match(/Unknown auth action: bogus/, result[:stderr])
    end
  end

  def test_clear_alias_for_logout
    with_temp_config do
      result = capture_output do |output|
        store = mock_token_store
        runner = Teems::Runner.new(output: output, token_store: store)
        cmd = Teems::Commands::Auth.new(['clear'], runner: runner)
        exit_code = cmd.execute

        assert_equal 0, exit_code
      end

      assert_match(/Tokens cleared/, result[:stdout])
    end
  end

  def test_login_success
    with_temp_config do
      result = capture_output do |output|
        store = mock_token_store
        runner = Teems::Runner.new(output: output, token_store: store, api_client: Teems::TestHelpers::MockApiClient.new)
        extractor = Object.new
        extractor.define_singleton_method(:extract) do
          { auth_token: 'auth-tok', skype_token: 'skype-tok', skype_spaces_token: 'spaces', chatsvc_token: nil }
        end
        runner.instance_variable_set(:@token_extractor, extractor)

        cmd = Teems::Commands::Auth.new(['login'], runner: runner)
        exit_code = cmd.execute

        assert_equal 0, exit_code
      end

      assert_match(/Authentication successful/, result[:stdout])
    end
  end

  def test_login_failure_suggests_manual
    with_temp_config do
      result = capture_output do |output|
        store = mock_token_store
        runner = Teems::Runner.new(output: output, token_store: store, api_client: Teems::TestHelpers::MockApiClient.new)
        extractor = Object.new
        extractor.define_singleton_method(:extract) { nil }
        runner.instance_variable_set(:@token_extractor, extractor)

        cmd = Teems::Commands::Auth.new(['login'], runner: runner)
        exit_code = cmd.execute

        assert_equal 1, exit_code
      end

      assert_match(/Failed to extract tokens automatically/, result[:stderr])
      assert_match(/teems auth manual/, result[:stdout])
    end
  end

  def test_login_failure_with_partial_tokens
    with_temp_config do
      result = capture_output do |output|
        store = mock_token_store
        runner = Teems::Runner.new(output: output, token_store: store, api_client: Teems::TestHelpers::MockApiClient.new)
        extractor = Object.new
        extractor.define_singleton_method(:extract) do
          { auth_token: 'auth-tok', skype_token: nil }
        end
        runner.instance_variable_set(:@token_extractor, extractor)

        cmd = Teems::Commands::Auth.new(['login'], runner: runner)
        exit_code = cmd.execute

        assert_equal 1, exit_code
      end

      assert_match(/Failed to extract/, result[:stderr])
    end
  end

  def test_manual_shows_instructions
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        cmd = Teems::Commands::Auth.new(['manual'], runner: runner)
        exit_code = cmd.execute

        assert_equal 0, exit_code
      end

      assert_match(/manually extract tokens/, result[:stdout])
      assert_match(/teems auth set-tokens/, result[:stdout])
    end
  end

  def test_set_alias_for_set_tokens
    with_temp_config do |dir|
      token_file = File.join(dir, 'tokens.json')
      File.write(token_file, '{"auth_token":"test-auth","skype_token":"test-skype"}')

      result = capture_output do |output|
        store = mock_token_store
        runner = Teems::Runner.new(output: output, token_store: store, api_client: Teems::TestHelpers::MockApiClient.new)
        cmd = Teems::Commands::Auth.new(['set', token_file], runner: runner)
        exit_code = cmd.execute

        assert_equal 0, exit_code
      end

      assert_match(/Tokens saved successfully/, result[:stdout])
    end
  end

  def test_import_tokens_from_file_success
    with_temp_config do |dir|
      token_file = File.join(dir, 'tokens.json')
      File.write(token_file, '{"auth_token":"file-auth","skype_token":"file-skype"}')

      result = capture_output do |output|
        store = mock_token_store
        runner = Teems::Runner.new(output: output, token_store: store, api_client: Teems::TestHelpers::MockApiClient.new)
        cmd = Teems::Commands::Auth.new(['set-tokens', token_file], runner: runner)
        exit_code = cmd.execute

        assert_equal 0, exit_code
      end

      assert_match(/Tokens saved successfully/, result[:stdout])
    end
  end

  def test_import_tokens_from_file_not_found
    with_temp_config do
      result = capture_output do |output|
        store = mock_token_store
        runner = Teems::Runner.new(output: output, token_store: store, api_client: Teems::TestHelpers::MockApiClient.new)
        cmd = Teems::Commands::Auth.new(['set-tokens', '/nonexistent/file.json'], runner: runner)
        exit_code = cmd.execute

        assert_equal 1, exit_code
      end

      assert_match(/File not found/, result[:stderr])
    end
  end

  def test_import_tokens_from_file_invalid_json
    with_temp_config do |dir|
      token_file = File.join(dir, 'bad.json')
      File.write(token_file, 'not json')

      result = capture_output do |output|
        store = mock_token_store
        runner = Teems::Runner.new(output: output, token_store: store, api_client: Teems::TestHelpers::MockApiClient.new)
        cmd = Teems::Commands::Auth.new(['set-tokens', token_file], runner: runner)
        exit_code = cmd.execute

        assert_equal 1, exit_code
      end

      assert_match(/Invalid JSON/, result[:stderr])
    end
  end

  def test_import_tokens_missing_auth_token_key
    with_temp_config do |dir|
      token_file = File.join(dir, 'no_auth.json')
      File.write(token_file, '{"skype_token":"only-skype"}')

      result = capture_output do |output|
        store = mock_token_store
        runner = Teems::Runner.new(output: output, token_store: store, api_client: Teems::TestHelpers::MockApiClient.new)
        cmd = Teems::Commands::Auth.new(['set-tokens', token_file], runner: runner)
        exit_code = cmd.execute

        assert_equal 1, exit_code
      end

      assert_match(/auth_token key/, result[:stderr])
    end
  end

  def test_import_tokens_directory_path
    with_temp_config do |dir|
      result = capture_output do |output|
        store = mock_token_store
        runner = Teems::Runner.new(output: output, token_store: store, api_client: Teems::TestHelpers::MockApiClient.new)
        cmd = Teems::Commands::Auth.new(['set-tokens', dir], runner: runner)
        exit_code = cmd.execute

        assert_equal 1, exit_code
      end

      assert_match(/directory, not a file/, result[:stderr])
    end
  end

  def test_import_tokens_with_authtoken_key
    with_temp_config do |dir|
      token_file = File.join(dir, 'alt.json')
      File.write(token_file, '{"authtoken":"alt-auth"}')

      result = capture_output do |output|
        store = mock_token_store
        runner = Teems::Runner.new(output: output, token_store: store, api_client: Teems::TestHelpers::MockApiClient.new)
        cmd = Teems::Commands::Auth.new(['set-tokens', token_file], runner: runner)
        exit_code = cmd.execute

        assert_equal 0, exit_code
      end

      assert_match(/Tokens saved/, result[:stdout])
    end
  end

  def test_token_age_display_recent
    with_temp_config do
      result = capture_output do |output|
        store = mock_token_store(account: mock_account)
        store.define_singleton_method(:token_age) { 3600 } # 1 hour
        runner = Teems::Runner.new(output: output, token_store: store)
        cmd = Teems::Commands::Auth.new(['status'], runner: runner)
        cmd.execute
      end

      assert_match(/Token age: 1 hours/, result[:stdout])
    end
  end

  def test_token_age_display_old
    with_temp_config do
      result = capture_output do |output|
        store = mock_token_store(account: mock_account)
        store.define_singleton_method(:token_age) { 100_800 } # 28 hours
        runner = Teems::Runner.new(output: output, token_store: store)
        cmd = Teems::Commands::Auth.new(['status'], runner: runner)
        cmd.execute
      end

      assert_match(/Tokens are 28 hours old/, result[:stdout])
      assert_match(/may be expired/, result[:stdout])
    end
  end
end

class AuthSetTokensStdinTest < Minitest::Test
  def test_set_tokens_from_stdin
    with_temp_config do
      result = capture_output do |output|
        store = mock_token_store
        runner = Teems::Runner.new(output: output, token_store: store, api_client: Teems::TestHelpers::MockApiClient.new)
        cmd = Teems::Commands::Auth.new(['set-tokens'], runner: runner)

        with_fake_stdin("test-auth-token\n\ntest-skype-token\n\n") do
          exit_code = cmd.execute
          assert_equal 0, exit_code
        end
      end

      assert_match(/Tokens saved/, result[:stdout])
    end
  end

  def test_set_tokens_from_stdin_empty_auth_token
    with_temp_config do
      result = capture_output do |output|
        store = mock_token_store
        runner = Teems::Runner.new(output: output, token_store: store, api_client: Teems::TestHelpers::MockApiClient.new)
        cmd = Teems::Commands::Auth.new(['set-tokens'], runner: runner)

        with_fake_stdin("\n") do
          exit_code = cmd.execute
          assert_equal 1, exit_code
        end
      end

      assert_match(/Auth token is required/, result[:stderr])
    end
  end

  def test_set_tokens_from_stdin_eof
    with_temp_config do
      result = capture_output do |output|
        store = mock_token_store
        runner = Teems::Runner.new(output: output, token_store: store, api_client: Teems::TestHelpers::MockApiClient.new)
        cmd = Teems::Commands::Auth.new(['set-tokens'], runner: runner)

        with_fake_stdin('') do
          exit_code = cmd.execute
          assert_equal 1, exit_code
        end
      end

      assert_match(/Auth token is required/, result[:stderr])
    end
  end
end

class AuthCleanTokenTest < Minitest::Test
  def test_clean_token_strips_bearer_prefix
    with_temp_config do |dir|
      token_file = File.join(dir, 'bearer.json')
      File.write(token_file, '{"auth_token":"Bearer eyJ0eXA"}')

      result = capture_output do |output|
        store = mock_token_store
        runner = Teems::Runner.new(output: output, token_store: store, api_client: Teems::TestHelpers::MockApiClient.new)
        cmd = Teems::Commands::Auth.new(['set-tokens', token_file], runner: runner)
        cmd.execute
      end

      assert_match(/Tokens saved/, result[:stdout])
    end
  end

  def test_clean_token_strips_skypetoken_prefix
    with_temp_config do |dir|
      token_file = File.join(dir, 'skype_prefix.json')
      File.write(token_file, '{"auth_token":"test-auth","skype_token":"skypetoken=eyJ0eXA"}')

      result = capture_output do |output|
        store = mock_token_store
        runner = Teems::Runner.new(output: output, token_store: store, api_client: Teems::TestHelpers::MockApiClient.new)
        cmd = Teems::Commands::Auth.new(['set-tokens', token_file], runner: runner)
        cmd.execute
      end

      assert_match(/Tokens saved/, result[:stdout])
    end
  end
end
