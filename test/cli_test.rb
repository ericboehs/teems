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
end
