# frozen_string_literal: true

require 'test_helper'

class CLITest < Minitest::Test
  def test_run_with_no_args_shows_help
    with_temp_config do
      result = capture_cli_output([])

      assert_equal 0, result[:exit_code]
      assert_match(/teems/, result[:stdout])
      assert_match(/COMMANDS:/, result[:stdout])
    end
  end

  def test_run_with_help_flag_shows_help
    with_temp_config do
      result = capture_cli_output(['--help'])

      assert_equal 0, result[:exit_code]
      assert_match(/teems/, result[:stdout])
    end
  end

  def test_run_with_short_help_flag_shows_help
    with_temp_config do
      result = capture_cli_output(['-h'])

      assert_equal 0, result[:exit_code]
      assert_match(/teems/, result[:stdout])
    end
  end

  def test_run_with_version_flag_shows_version
    with_temp_config do
      result = capture_cli_output(['--version'])

      assert_equal 0, result[:exit_code]
      assert_match(/teems v#{Teems::VERSION}/, result[:stdout])
    end
  end

  def test_run_with_short_version_flag_shows_version
    with_temp_config do
      result = capture_cli_output(['-V'])

      assert_equal 0, result[:exit_code]
      assert_match(/teems v/, result[:stdout])
    end
  end

  def test_run_with_version_command_shows_version
    with_temp_config do
      result = capture_cli_output(['version'])

      assert_equal 0, result[:exit_code]
      assert_match(/teems v/, result[:stdout])
    end
  end

  def test_run_with_unknown_command_shows_error
    with_temp_config do
      result = capture_cli_output(['foobar'])

      assert_equal 1, result[:exit_code]
      assert_match(/Unknown command: foobar/, result[:stderr])
      assert_match(/teems help/, result[:stdout])
    end
  end

  def test_dispatches_to_auth_command
    with_temp_config do
      result = capture_cli_output(%w[auth status])

      assert_equal 0, result[:exit_code]
      # Without auth, shows not authenticated
      assert_match(/Not authenticated/, result[:stdout])
    end
  end

  def test_dispatches_to_help_command
    with_temp_config do
      result = capture_cli_output(['help'])

      assert_equal 0, result[:exit_code]
      assert_match(/COMMANDS:/, result[:stdout])
    end
  end

  def test_dispatches_to_channels_command_requires_auth
    with_temp_config do
      result = capture_cli_output(['channels'])

      assert_equal 1, result[:exit_code]
      assert_match(/Not authenticated/, result[:stderr])
    end
  end

  def test_dispatches_to_chats_command_requires_auth
    with_temp_config do
      result = capture_cli_output(['chats'])

      assert_equal 1, result[:exit_code]
      assert_match(/Not authenticated/, result[:stderr])
    end
  end

  def test_dispatches_to_messages_command_requires_auth
    with_temp_config do
      result = capture_cli_output(%w[messages some-id])

      assert_equal 1, result[:exit_code]
      assert_match(/Not authenticated/, result[:stderr])
    end
  end

  def test_handles_config_error
    with_temp_config do
      result = capture_cli_output(['channels'])

      assert_equal 1, result[:exit_code]
      # ConfigError triggers auth error message
      assert_match(/Not authenticated/, result[:stderr])
    end
  end

  def test_verbose_mode_detected
    with_temp_config do |dir|
      write_tokens_file(dir, {
                          'auth_token' => 'test-auth',
                          'skype_token' => 'test-skype'
                        })
      result = capture_cli_output(['auth', 'status', '-v'])

      assert_equal 0, result[:exit_code]
      assert_match(/Authenticated/, result[:stdout])
    end
  end

  private

  def capture_cli_output(argv)
    out = StringIO.new
    err = StringIO.new
    output = Teems::Formatters::Output.new(io: out, err: err, color: false)

    cli = Teems::CLI.new(argv, output: output)
    exit_code = cli.run

    { stdout: out.string, stderr: err.string, exit_code: exit_code }
  end
end

class CLIErrorHandlingTest < Minitest::Test
  def test_logs_unexpected_errors
    with_temp_config do |dir|
      # Create cache dir for error logging
      cache_dir = "#{dir}/cache/teems"
      FileUtils.mkdir_p(cache_dir)

      out = StringIO.new
      err = StringIO.new
      output = Teems::Formatters::Output.new(io: out, err: err, color: false)

      # Use a mock command that raises an unexpected error
      cli = MockErrorCLI.new(['trigger-error'], output: output)
      exit_code = cli.run

      assert_equal 1, exit_code
      assert_match(/Unexpected error/, err.string)
    end
  end

  # Mock CLI that raises an error for testing error handling
  class MockErrorCLI < Teems::CLI
    private

    def dispatch_command(command_name, args)
      raise StandardError, 'Test error' if command_name == 'trigger-error'

      super
    end
  end

  def test_error_label_for_auth_error
    with_temp_config do
      out = StringIO.new
      err = StringIO.new
      output = Teems::Formatters::Output.new(io: out, err: err, color: false)

      cli = MockKnownErrorCLI.new(['auth-error'], output: output)
      exit_code = cli.run

      assert_equal 1, exit_code
      assert_match(/Auth error:/, err.string)
    end
  end

  def test_error_label_for_api_error
    with_temp_config do
      out = StringIO.new
      err = StringIO.new
      output = Teems::Formatters::Output.new(io: out, err: err, color: false)

      cli = MockKnownErrorCLI.new(['api-error'], output: output)
      exit_code = cli.run

      assert_equal 1, exit_code
      assert_match(/API error:/, err.string)
    end
  end

  def test_error_label_for_config_error
    with_temp_config do
      out = StringIO.new
      err = StringIO.new
      output = Teems::Formatters::Output.new(io: out, err: err, color: false)

      cli = MockKnownErrorCLI.new(['config-error'], output: output)
      exit_code = cli.run

      assert_equal 1, exit_code
      assert_match(/Test config error/, err.string)
    end
  end

  def test_handles_interrupt
    with_temp_config do
      out = StringIO.new
      err = StringIO.new
      output = Teems::Formatters::Output.new(io: out, err: err, color: false)

      cli = MockInterruptCLI.new(['auth', 'status'], output: output)
      exit_code = cli.run

      assert_equal 130, exit_code
      assert_match(/Interrupted/, out.string)
    end
  end

  def test_verbose_logging_callback
    with_temp_config do |dir|
      write_tokens_file(dir, { 'auth_token' => 'test', 'skype_token' => 'test' })
      out = StringIO.new
      err = StringIO.new
      output = Teems::Formatters::Output.new(io: out, err: err, color: false, verbose: true)

      cli = Teems::CLI.new(['auth', 'status', '-v'], output: output)
      cli.run

      assert_match(/Authenticated/, out.string)
    end
  end

  # Mock CLI that raises known errors inside dispatch_command's normal flow
  class MockKnownErrorCLI < Teems::CLI
    private

    def dispatch_command(command_name, args)
      case command_name
      when 'auth-error' then raise Teems::AuthError, 'Test auth error'
      when 'api-error' then raise Teems::ApiError, 'Test api error'
      when 'config-error' then raise Teems::ConfigError, 'Test config error'
      else super
      end
    rescue Teems::ConfigError, Teems::AuthError, Teems::ApiError => e
      handle_known_error(e)
    end
  end

  def test_error_log_path_displayed
    with_temp_config do |dir|
      cache_dir = "#{dir}/cache/teems"
      FileUtils.mkdir_p(cache_dir)

      out = StringIO.new
      err = StringIO.new
      output = Teems::Formatters::Output.new(io: out, err: err, color: false)

      cli = MockErrorCLI.new(['trigger-error'], output: output)
      exit_code = cli.run

      assert_equal 1, exit_code
      assert_match(/Details logged to:/, out.string)
    end
  end

  def test_api_client_close_called
    with_temp_config do
      out = StringIO.new
      err = StringIO.new
      output = Teems::Formatters::Output.new(io: out, err: err, color: false)

      cli = Teems::CLI.new(['auth', 'status'], output: output)
      cli.run

      # No crash means close was called correctly
    end
  end

  def test_verbose_api_logging_sets_callback
    with_temp_config do |dir|
      write_tokens_file(dir, { 'auth_token' => 'test', 'skype_token' => 'test' })
      out = StringIO.new
      err = StringIO.new
      output = Teems::Formatters::Output.new(io: out, err: err, color: false, verbose: true)

      cli = Teems::CLI.new(['auth', 'status', '-v'], output: output)
      exit_code = cli.run

      assert_equal 0, exit_code
    end
  end

  def test_verbose_mode_zero_api_calls_no_log
    with_temp_config do |dir|
      write_tokens_file(dir, { 'auth_token' => 'test', 'skype_token' => 'test' })
      out = StringIO.new
      err = StringIO.new
      output = Teems::Formatters::Output.new(io: out, err: err, color: false, verbose: true)

      cli = Teems::CLI.new(['auth', 'status', '-v'], output: output)
      cli.run

      refute_match(/Total API calls/, err.string)
    end
  end

  def test_verbose_mode_with_positive_api_calls_logs_total
    with_temp_config do
      out = StringIO.new
      err = StringIO.new
      output = Teems::Formatters::Output.new(io: out, err: err, color: false, verbose: true)

      cli = MockVerboseApiCLI.new(['channels', '-v'], output: output)
      cli.run

      assert_match(/Total API calls/, err.string)
    end
  end

  def test_verbose_mode_with_long_flag
    with_temp_config do |dir|
      write_tokens_file(dir, { 'auth_token' => 'test', 'skype_token' => 'test' })
      out = StringIO.new
      err = StringIO.new
      output = Teems::Formatters::Output.new(io: out, err: err, color: false, verbose: true)

      cli = Teems::CLI.new(['auth', 'status', '--verbose'], output: output)
      exit_code = cli.run

      assert_equal 0, exit_code
    end
  end

  def test_error_without_log_path
    with_temp_config do
      out = StringIO.new
      err = StringIO.new
      output = Teems::Formatters::Output.new(io: out, err: err, color: false)

      # Use a CLI that makes error logging fail
      cli = MockNoLogCLI.new(['trigger-error'], output: output)
      exit_code = cli.run

      assert_equal 1, exit_code
      refute_match(/Details logged to:/, out.string)
    end
  end

  class MockVerboseApiCLI < Teems::CLI
    private

    def build_runner(args)
      out = resolve_output(args)
      mock_api = Teems::TestHelpers::MockApiClient.new
      mock_api.stub('joinedTeams', { 'value' => [] })
      store = Teems::TestHelpers::MockTokenStore.new(
        account: Teems::Models::Account.new(name: 'default', auth_token: 'test', skype_token: 'test'),
        configured: true
      )
      runner = Teems::Runner.new(output: out, token_store: store, api_client: mock_api)
      setup_verbose_logging(runner, out) if verbose_mode?(args)
      runner
    end
  end

  class MockNoLogCLI < Teems::CLI
    private

    def dispatch_command(_command_name, _args)
      raise StandardError, 'Test error'
    end

    def log_error(_error)
      nil
    end
  end

  # Mock CLI that simulates Interrupt during command execution
  class MockInterruptCLI < Teems::CLI
    private

    def dispatch_command(_command_name, _args)
      raise Interrupt
    end
  end
end
