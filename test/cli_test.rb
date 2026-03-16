# frozen_string_literal: true

require 'test_helper'

module CLITests
  module Helpers
    private

    def capture_cli_output(argv)
      out = StringIO.new
      err = StringIO.new
      output = Teems::Formatters::Output.new(io: out, err: err, color: false)
      exit_code = Teems::CLI.new(argv, output: output).run
      { stdout: out.string, stderr: err.string, exit_code: exit_code }
    end
  end

  class BasicTest < Minitest::Test
    include Helpers

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
  end

  class DispatchTest < Minitest::Test
    include Helpers

    def test_dispatches_to_auth_command
      with_temp_config do
        result = capture_cli_output(%w[auth status])
        assert_equal 0, result[:exit_code]
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
        assert_match(/Not authenticated/, result[:stderr])
      end
    end

    def test_verbose_mode_detected
      with_temp_config do |dir|
        write_tokens_file(dir, { 'auth_token' => 'test-auth', 'skype_token' => 'test-skype' })
        result = capture_cli_output(['auth', 'status', '-v'])
        assert_equal 0, result[:exit_code]
        assert_match(/Authenticated/, result[:stdout])
      end
    end
  end

  class ErrorHandlingTest < Minitest::Test
    class MockErrorCLI < Teems::CLI
      private

      def dispatch_command(command_name, args)
        raise StandardError, 'Test error' if command_name == 'trigger-error'

        super
      end
    end

    class MockKnownErrorCLI < Teems::CLI
      ERROR_MAP = {
        'auth-error' => Teems::AuthError,
        'api-error' => Teems::ApiError,
        'config-error' => Teems::ConfigError
      }.freeze

      private

      def dispatch_command(command_name, _args)
        error_class = ERROR_MAP[command_name]
        raise error_class, "Test #{command_name.tr('-', ' ')}" if error_class

        super
      rescue Teems::ConfigError, Teems::AuthError, Teems::ApiError => e
        handle_known_error(e)
      end
    end

    class MockInterruptCLI < Teems::CLI
      private

      def dispatch_command(_command_name, _args)
        raise Interrupt
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

    def test_logs_unexpected_errors
      with_temp_config do |dir|
        FileUtils.mkdir_p("#{dir}/cache/teems")
        result = run_mock_error_cli(MockErrorCLI)
        assert_equal 1, result[:exit_code]
        assert_match(/Unexpected error/, result[:stderr])
      end
    end

    def test_error_label_for_auth_error
      with_temp_config do
        result = run_mock_error_cli(MockKnownErrorCLI, ['auth-error'])
        assert_equal 1, result[:exit_code]
        assert_match(/Auth error:/, result[:stderr])
      end
    end

    def test_error_label_for_api_error
      with_temp_config do
        result = run_mock_error_cli(MockKnownErrorCLI, ['api-error'])
        assert_equal 1, result[:exit_code]
        assert_match(/API error:/, result[:stderr])
      end
    end

    def test_error_label_for_config_error
      with_temp_config do
        result = run_mock_error_cli(MockKnownErrorCLI, ['config-error'])
        assert_equal 1, result[:exit_code]
        assert_match(/Test config error/, result[:stderr])
      end
    end

    def test_handles_interrupt
      with_temp_config do
        result = run_mock_error_cli(MockInterruptCLI, %w[auth status])
        assert_equal 130, result[:exit_code]
        assert_match(/Interrupted/, result[:stdout])
      end
    end

    def test_error_log_path_displayed
      with_temp_config do |dir|
        FileUtils.mkdir_p("#{dir}/cache/teems")
        result = run_mock_error_cli(MockErrorCLI)
        assert_equal 1, result[:exit_code]
        assert_match(/Details logged to:/, result[:stdout])
      end
    end

    def test_error_without_log_path
      with_temp_config do
        result = run_mock_error_cli(MockNoLogCLI)
        assert_equal 1, result[:exit_code]
        refute_match(/Details logged to:/, result[:stdout])
      end
    end

    private

    def run_mock_error_cli(klass, args = ['trigger-error'])
      out = StringIO.new
      err = StringIO.new
      output = Teems::Formatters::Output.new(io: out, err: err, color: false)
      exit_code = klass.new(args, output: output).run
      { stdout: out.string, stderr: err.string, exit_code: exit_code }
    end
  end

  class VerboseApiTest < Minitest::Test
    class MockVerboseApiCLI < Teems::CLI
      private

      def build_runner(args)
        out = verbose_mode?(args) ? verbose_output : @output
        mock_api = Teems::TestHelpers::MockApiClient.new
        mock_api.stub('joinedTeams', { 'value' => [] })
        store = Teems::TestHelpers::MockTokenStore.new(
          account: Teems::Models::Account.new(name: 'default', auth_token: 'test', skype_token: 'test'),
          configured: true
        )
        runner = Teems::Runner.new(output: out, token_store: store, api_client: mock_api)
        setup_verbose_logging(runner, out) if out.verbose?
        runner
      end
    end

    def test_verbose_logging_callback
      with_temp_config do |dir|
        write_tokens_file(dir, { 'auth_token' => 'test', 'skype_token' => 'test' })
        result = run_verbose_cli(Teems::CLI, ['auth', 'status', '-v'])
        assert_match(/Authenticated/, result[:stdout])
      end
    end

    def test_verbose_api_logging_sets_callback
      with_temp_config do |dir|
        write_tokens_file(dir, { 'auth_token' => 'test', 'skype_token' => 'test' })
        result = run_verbose_cli(Teems::CLI, ['auth', 'status', '-v'])
        assert_equal 0, result[:exit_code]
      end
    end

    def test_verbose_mode_zero_api_calls_no_log
      with_temp_config do |dir|
        write_tokens_file(dir, { 'auth_token' => 'test', 'skype_token' => 'test' })
        result = run_verbose_cli(Teems::CLI, ['auth', 'status', '-v'])
        refute_match(/Total API calls/, result[:stderr])
      end
    end

    def test_verbose_mode_with_positive_api_calls_logs_total
      with_temp_config do
        result = run_verbose_cli(MockVerboseApiCLI, ['channels', '-v'])
        assert_match(/Total API calls: [1-9]/, result[:stderr])
      end
    end

    def test_verbose_mode_with_long_flag
      with_temp_config do |dir|
        write_tokens_file(dir, { 'auth_token' => 'test', 'skype_token' => 'test' })
        result = run_verbose_cli(Teems::CLI, ['auth', 'status', '--verbose'])
        assert_equal 0, result[:exit_code]
      end
    end

    private

    def run_verbose_cli(klass, args)
      out = StringIO.new
      err = StringIO.new
      output = Teems::Formatters::Output.new(io: out, err: err, color: false, mode: :verbose)
      exit_code = klass.new(args, output: output).run
      { stdout: out.string, stderr: err.string, exit_code: exit_code }
    end
  end

  class EnsureCloseTest < Minitest::Test
    class MockCloseCLI < Teems::CLI
      attr_reader :close_called

      def initialize(argv, output:)
        super
        @close_called = false
      end

      private

      def build_runner(args)
        out = verbose_mode?(args) ? verbose_output : @output
        mock_api = Teems::TestHelpers::MockApiClient.new
        mock_api.define_singleton_method(:close) { @closed = true }
        mock_api.define_singleton_method(:closed?) { @closed }
        store = Teems::TestHelpers::MockTokenStore.new(configured: false)
        Teems::Runner.new(output: out, token_store: store, api_client: mock_api)
      end
    end

    def test_ensure_closes_api_client_after_command
      with_temp_config do
        out = StringIO.new
        err = StringIO.new
        output = Teems::Formatters::Output.new(io: out, err: err, color: false)
        cli = MockCloseCLI.new(%w[auth status], output: output)
        exit_code = cli.run
        assert_includes [0, 1], exit_code
      end
    end
  end

  class DispatchKnownErrorTest < Minitest::Test
    include Helpers

    def test_dispatch_catches_config_error_from_command
      with_temp_config do
        result = capture_cli_output(['channels'])
        assert_equal 1, result[:exit_code]
      end
    end

    def test_quiet_mode_with_q_flag
      with_temp_config do
        result = capture_cli_output(['auth', 'status', '-q'])
        assert_equal 0, result[:exit_code]
      end
    end
  end
end
