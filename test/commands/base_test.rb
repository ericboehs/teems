# frozen_string_literal: true

require 'test_helper'

# Tests for the base command class shared behavior
module BaseCommandTests
  # Tests for option parsing, positional args, and base execute behavior
  class BasicTest < Minitest::Test
    # Minimal command subclass for testing base option parsing
    class TestCommand < Teems::Commands::Base
      def execute
        0
      end
    end

    def test_parses_limit_option_short
      with_temp_config do
        cmd = TestCommand.new(['-n', '50'], runner: test_runner)
        assert_equal 50, cmd.options[:limit]
      end
    end

    def test_parses_limit_option_long
      with_temp_config do
        cmd = TestCommand.new(['--limit', '100'], runner: test_runner)
        assert_equal 100, cmd.options[:limit]
      end
    end

    def test_parses_verbose_option
      with_temp_config { assert TestCommand.new(['-v'], runner: test_runner).options[:verbose] }
    end

    def test_parses_quiet_option
      with_temp_config { assert TestCommand.new(['-q'], runner: test_runner).options[:quiet] }
    end

    def test_parses_json_option
      with_temp_config { assert TestCommand.new(['--json'], runner: test_runner).options[:json] }
    end

    def test_parses_help_option
      with_temp_config { assert TestCommand.new(['--help'], runner: test_runner).options[:help] }
    end

    def test_separates_positional_args
      with_temp_config do
        cmd = TestCommand.new(['arg1', '-v', 'arg2'], runner: test_runner)
        assert_equal %w[arg1 arg2], cmd.positional_args
        assert cmd.options[:verbose]
      end
    end

    def test_default_limit_is_twenty
      with_temp_config { assert_equal 20, TestCommand.new([], runner: test_runner).options[:limit] }
    end

    def test_runner_accessor
      with_temp_config do
        runner = test_runner
        assert_equal runner, TestCommand.new([], runner: runner).runner
      end
    end

    def test_base_execute_raises_not_implemented
      with_temp_config do
        assert_raises(NotImplementedError) { Teems::Commands::Base.new([], runner: test_runner).execute }
      end
    end

    def test_unknown_option_is_tracked
      with_temp_config do
        assert TestCommand.new(['--unknown-flag'], runner: test_runner).send(:unknown_options?)
      end
    end

    def test_check_unknown_options_returns_nil_when_none
      with_temp_config do
        assert_nil TestCommand.new([], runner: test_runner).send(:check_unknown_options)
      end
    end

    def test_show_help_returns_true_with_help_flag
      with_temp_config do
        assert TestCommand.new(['--help'], runner: test_runner).send(:show_help?)
      end
    end

    def test_show_help_returns_false_without_help_flag
      with_temp_config do
        refute TestCommand.new([], runner: test_runner).send(:show_help?)
      end
    end
  end

  # Tests for output helper methods like success, info, warn, and error
  class OutputTest < Minitest::Test
    # Command subclass that exercises all output helper methods
    class OutputTestCommand < Teems::Commands::Base
      def execute
        success('Success message')
        info('Info message')
        warn('Warning message')
        error('Error message')
        debug('Debug message')
        puts('Plain message')
        print('Printed')
        0
      end

      def test_require_auth
        require_auth
      end
    end

    def test_success_outputs_message
      with_temp_config do
        result = capture_output do |output|
          OutputTestCommand.new([], runner: test_runner(output: output)).send(:success, 'It worked')
        end
        assert_match(/It worked/, result[:stdout])
      end
    end

    def test_info_outputs_message
      with_temp_config do
        result = capture_output do |output|
          OutputTestCommand.new([], runner: test_runner(output: output)).send(:info, 'Info here')
        end
        assert_match(/Info here/, result[:stdout])
      end
    end

    def test_warn_outputs_to_stderr
      with_temp_config do
        result = capture_output do |output|
          OutputTestCommand.new([], runner: test_runner(output: output)).send(:warn, 'Be warned')
        end
        assert_match(/Be warned/, result[:stderr])
      end
    end

    def test_error_outputs_to_stderr
      with_temp_config do
        result = capture_output do |output|
          OutputTestCommand.new([], runner: test_runner(output: output)).send(:error, 'Something broke')
        end
        assert_match(/Something broke/, result[:stderr])
      end
    end

    def test_debug_silent_without_verbose
      with_temp_config do
        result = capture_output do |output|
          OutputTestCommand.new([], runner: test_runner(output: output)).send(:debug, 'Debug info')
        end
        refute_match(/Debug info/, result[:stderr])
      end
    end
  end

  # Tests for verbose, quiet, require_auth, and JSON output helpers
  class OutputExtendedTest < Minitest::Test
    # Command subclass for testing extended output behaviors
    class OutputTestCommand < Teems::Commands::Base
      def execute
        0
      end

      def test_require_auth
        require_auth
      end
    end

    def test_debug_outputs_with_verbose
      with_temp_config do
        err = StringIO.new
        verbose_output = Teems::Formatters::Output.new(err: err, color: false, mode: :verbose)
        cmd = OutputTestCommand.new(['-v'], runner: test_runner(output: verbose_output))
        cmd.send(:debug, 'Debug info')
        assert_match(/Debug info/, err.string)
      end
    end

    def test_quiet_suppresses_success
      with_temp_config do
        result = capture_output do |output|
          OutputTestCommand.new(['-q'], runner: test_runner(output: output)).send(:success, 'It worked')
        end
        refute_match(/It worked/, result[:stdout])
      end
    end

    def test_require_auth_returns_error_when_not_configured
      with_temp_config do
        result = capture_output do |output|
          store = mock_unconfigured_store
          runner = Teems::Runner.new(output: output, token_store: store)
          OutputTestCommand.new([], runner: runner).test_require_auth
        end
        assert_match(/Not authenticated/, result[:stderr])
      end
    end

    def test_require_auth_returns_nil_when_configured
      with_temp_config do
        store = mock_token_store(account: mock_account, configured: true)
        runner = Teems::Runner.new(output: test_output, token_store: store)
        assert_nil OutputTestCommand.new([], runner: runner).test_require_auth
      end
    end

    def test_output_json_outputs_formatted_json
      with_temp_config do
        result = capture_output do |output|
          cmd = OutputTestCommand.new([], runner: test_runner(output: output))
          cmd.send(:output_json, { key: 'value' })
        end
        stdout = result[:stdout]
        assert_match(/"key"/, stdout)
        assert_match(/"value"/, stdout)
      end
    end
  end

  # Tests for automatic token refresh on 401 and expired token errors
  class TokenRefreshTest < Minitest::Test
    # Command subclass that exposes with_token_refresh for testing
    class RefreshTestCommand < Teems::Commands::Base
      attr_accessor :call_count, :should_fail_first

      def execute
        0
      end

      def test_with_token_refresh(&)
        with_token_refresh(&)
      end
    end

    def test_with_token_refresh_yields_block_on_success
      with_temp_config do
        cmd = RefreshTestCommand.new([], runner: test_runner)
        called = false
        cmd.test_with_token_refresh { called = true }
        assert called
      end
    end

    def test_with_token_refresh_returns_block_result
      with_temp_config do
        cmd = RefreshTestCommand.new([], runner: test_runner)
        assert_equal('success', cmd.test_with_token_refresh { 'success' })
      end
    end

    def test_with_token_refresh_raises_non_token_errors
      with_temp_config do
        cmd = RefreshTestCommand.new([], runner: test_runner)
        assert_raises(Teems::ApiError) do
          cmd.test_with_token_refresh { raise Teems::ApiError, 'Some other API error' }
        end
      end
    end

    def test_with_token_refresh_attempts_refresh_on_invalid_token
      call_count = assert_refresh_retry(refresh_succeeds: true) do |_count|
        raise Teems::ApiError.new('Invalid token or session expired', status_code: 401)
      end
      assert_equal 2, call_count
    end

    def test_with_token_refresh_attempts_refresh_on_expired_message
      call_count = assert_refresh_retry(refresh_succeeds: true) do |_count|
        raise Teems::ApiError, 'Token expired'
      end
      assert_equal 2, call_count
    end

    def test_with_token_refresh_reraises_if_refresh_fails
      call_count = assert_refresh_retry(refresh_succeeds: false, tokens: basic_tokens) do |_count|
        raise Teems::ApiError.new('Invalid token', status_code: 401)
      end
      assert_equal 1, call_count
    end

    def test_with_token_refresh_succeeds_after_refresh
      with_temp_config do |dir|
        cmd, call_count_ref = build_refresh_cmd(dir, refresh_succeeds: true)
        result = cmd.test_with_token_refresh do
          count = call_count_ref[:n] += 1
          raise Teems::ApiError.new('Invalid token', status_code: 401) if count == 1

          'success after refresh'
        end

        assert_equal 'success after refresh', result
        assert_equal 2, call_count_ref.fetch(:n)
      end
    end

    private

    def spaces_tokens
      { 'auth_token' => 'test-auth', 'skype_token' => 'test-skype', 'skype_spaces_token' => 'spaces-token' }
    end

    def basic_tokens
      { 'auth_token' => 'test-auth', 'skype_token' => 'test-skype' }
    end

    def build_refresh_cmd(dir, refresh_succeeds:, tokens: spaces_tokens)
      write_tokens_file(dir, tokens)
      runner = Teems::Runner.new(output: test_output)
      runner.define_singleton_method(:refresh_tokens) { refresh_succeeds }
      cmd = RefreshTestCommand.new([], runner: runner)
      call_count = { n: 0 }
      [cmd, call_count]
    end

    def assert_refresh_retry(refresh_succeeds:, tokens: spaces_tokens, &block)
      call_count = 0
      with_temp_config do |dir|
        cmd, = build_refresh_cmd(dir, refresh_succeeds: refresh_succeeds, tokens: tokens)
        assert_raises(Teems::ApiError) do
          cmd.test_with_token_refresh { call_count += 1; block.call(call_count) } # rubocop:disable Style/Semicolon
        end
      end
      call_count
    end
  end

  # Tests for default help text when a command does not override it
  class DefaultHelpTextTest < Minitest::Test
    # Command subclass without custom help text
    class NoHelpCommand < Teems::Commands::Base
      def execute
        0
      end
    end

    def test_default_help_text_shown_when_not_overridden
      with_temp_config do
        result = capture_output do |output|
          cmd = NoHelpCommand.new(['--help'], runner: test_runner(output: output))
          cmd.send(:validate_options)
        end

        assert_match(/No help available/, result[:stdout])
      end
    end
  end
end
