# frozen_string_literal: true

require 'test_helper'

class BaseCommandTest < Minitest::Test
  # Create a concrete subclass for testing since Base is abstract
  class TestCommand < Teems::Commands::Base
    def execute
      0
    end
  end

  def test_parses_limit_option_short
    with_temp_config do
      runner = test_runner
      cmd = TestCommand.new(['-n', '50'], runner: runner)

      assert_equal 50, cmd.options[:limit]
    end
  end

  def test_parses_limit_option_long
    with_temp_config do
      runner = test_runner
      cmd = TestCommand.new(['--limit', '100'], runner: runner)

      assert_equal 100, cmd.options[:limit]
    end
  end

  def test_parses_verbose_option
    with_temp_config do
      runner = test_runner
      cmd = TestCommand.new(['-v'], runner: runner)

      assert cmd.options[:verbose]
    end
  end

  def test_parses_quiet_option
    with_temp_config do
      runner = test_runner
      cmd = TestCommand.new(['-q'], runner: runner)

      assert cmd.options[:quiet]
    end
  end

  def test_parses_json_option
    with_temp_config do
      runner = test_runner
      cmd = TestCommand.new(['--json'], runner: runner)

      assert cmd.options[:json]
    end
  end

  def test_parses_help_option
    with_temp_config do
      runner = test_runner
      cmd = TestCommand.new(['--help'], runner: runner)

      assert cmd.options[:help]
    end
  end

  def test_separates_positional_args
    with_temp_config do
      runner = test_runner
      cmd = TestCommand.new(['arg1', '-v', 'arg2'], runner: runner)

      assert_equal %w[arg1 arg2], cmd.positional_args
      assert cmd.options[:verbose]
    end
  end

  def test_default_limit_is_20
    with_temp_config do
      runner = test_runner
      cmd = TestCommand.new([], runner: runner)

      assert_equal 20, cmd.options[:limit]
    end
  end

  def test_runner_accessor
    with_temp_config do
      runner = test_runner
      cmd = TestCommand.new([], runner: runner)

      assert_equal runner, cmd.runner
    end
  end

  def test_base_execute_raises_not_implemented
    with_temp_config do
      runner = test_runner
      cmd = Teems::Commands::Base.new([], runner: runner)

      assert_raises(NotImplementedError) { cmd.execute }
    end
  end

  def test_unknown_option_is_tracked
    with_temp_config do
      runner = test_runner
      cmd = TestCommand.new(['--unknown-flag'], runner: runner)

      # The unknown option should be in positional_args since Base doesn't handle it
      # and the subclass doesn't override handle_option
      assert cmd.send(:unknown_options?)
    end
  end

  def test_show_help_returns_true_with_help_flag
    with_temp_config do
      runner = test_runner
      cmd = TestCommand.new(['--help'], runner: runner)

      assert cmd.send(:show_help?)
    end
  end

  def test_show_help_returns_false_without_help_flag
    with_temp_config do
      runner = test_runner
      cmd = TestCommand.new([], runner: runner)

      refute cmd.send(:show_help?)
    end
  end
end

class BaseCommandOutputTest < Minitest::Test
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
        runner = test_runner(output: output)
        cmd = OutputTestCommand.new([], runner: runner)
        cmd.send(:success, 'It worked')
      end

      assert_match(/It worked/, result[:stdout])
    end
  end

  def test_info_outputs_message
    with_temp_config do
      result = capture_output do |output|
        runner = test_runner(output: output)
        cmd = OutputTestCommand.new([], runner: runner)
        cmd.send(:info, 'Info here')
      end

      assert_match(/Info here/, result[:stdout])
    end
  end

  def test_warn_outputs_to_stderr
    with_temp_config do
      result = capture_output do |output|
        runner = test_runner(output: output)
        cmd = OutputTestCommand.new([], runner: runner)
        cmd.send(:warn, 'Be warned')
      end

      assert_match(/Be warned/, result[:stderr])
    end
  end

  def test_error_outputs_to_stderr
    with_temp_config do
      result = capture_output do |output|
        runner = test_runner(output: output)
        cmd = OutputTestCommand.new([], runner: runner)
        cmd.send(:error, 'Something broke')
      end

      assert_match(/Something broke/, result[:stderr])
    end
  end

  def test_debug_silent_without_verbose
    with_temp_config do
      result = capture_output do |output|
        runner = test_runner(output: output)
        cmd = OutputTestCommand.new([], runner: runner)
        cmd.send(:debug, 'Debug info')
      end

      refute_match(/Debug info/, result[:stderr])
    end
  end

  def test_debug_outputs_with_verbose
    with_temp_config do
      err = StringIO.new
      verbose_output = Teems::Formatters::Output.new(err: err, color: false, verbose: true)
      runner = test_runner(output: verbose_output)
      cmd = OutputTestCommand.new(['-v'], runner: runner)
      cmd.send(:debug, 'Debug info')

      assert_match(/Debug info/, err.string)
    end
  end

  def test_quiet_suppresses_success
    with_temp_config do
      result = capture_output do |output|
        runner = test_runner(output: output)
        cmd = OutputTestCommand.new(['-q'], runner: runner)
        cmd.send(:success, 'It worked')
      end

      refute_match(/It worked/, result[:stdout])
    end
  end

  def test_require_auth_returns_error_when_not_configured
    with_temp_config do
      result = capture_output do |output|
        store = mock_token_store(configured: false)
        runner = Teems::Runner.new(output: output, token_store: store)
        cmd = OutputTestCommand.new([], runner: runner)
        cmd.test_require_auth
      end

      assert_match(/Not authenticated/, result[:stderr])
    end
  end

  def test_require_auth_returns_nil_when_configured
    with_temp_config do
      store = mock_token_store(account: mock_account, configured: true)
      runner = Teems::Runner.new(output: test_output, token_store: store)
      cmd = OutputTestCommand.new([], runner: runner)

      assert_nil cmd.test_require_auth
    end
  end

  def test_output_json_outputs_formatted_json
    with_temp_config do
      result = capture_output do |output|
        runner = test_runner(output: output)
        cmd = OutputTestCommand.new([], runner: runner)
        cmd.send(:output_json, { key: 'value' })
      end

      assert_match(/"key"/, result[:stdout])
      assert_match(/"value"/, result[:stdout])
    end
  end
end

class WithTokenRefreshTest < Minitest::Test
  class RefreshTestCommand < Teems::Commands::Base
    attr_accessor :call_count, :should_fail_first

    def execute
      0
    end

    def test_with_token_refresh(&block)
      with_token_refresh(&block)
    end
  end

  def test_with_token_refresh_yields_block_on_success
    with_temp_config do
      runner = test_runner
      cmd = RefreshTestCommand.new([], runner: runner)
      called = false

      cmd.test_with_token_refresh { called = true }

      assert called
    end
  end

  def test_with_token_refresh_returns_block_result
    with_temp_config do
      runner = test_runner
      cmd = RefreshTestCommand.new([], runner: runner)

      result = cmd.test_with_token_refresh { 'success' }

      assert_equal 'success', result
    end
  end

  def test_with_token_refresh_raises_non_token_errors
    with_temp_config do
      runner = test_runner
      cmd = RefreshTestCommand.new([], runner: runner)

      assert_raises(Teems::ApiError) do
        cmd.test_with_token_refresh { raise Teems::ApiError, 'Some other API error' }
      end
    end
  end

  def test_with_token_refresh_attempts_refresh_on_invalid_token
    with_temp_config do |dir|
      write_tokens_file(dir, {
                          'auth_token' => 'test-auth',
                          'skype_token' => 'test-skype',
                          'skype_spaces_token' => 'spaces-token'
                        })
      runner = Teems::Runner.new(output: test_output)
      cmd = RefreshTestCommand.new([], runner: runner)
      call_count = 0

      # Mock the refresh to succeed but block still fails
      runner.define_singleton_method(:refresh_tokens) { true }

      assert_raises(Teems::ApiError) do
        cmd.test_with_token_refresh do
          call_count += 1
          raise Teems::ApiError, 'Invalid token or session expired'
        end
      end

      # Should have been called twice (initial + retry)
      assert_equal 2, call_count
    end
  end

  def test_with_token_refresh_attempts_refresh_on_expired_message
    with_temp_config do |dir|
      write_tokens_file(dir, {
                          'auth_token' => 'test-auth',
                          'skype_token' => 'test-skype',
                          'skype_spaces_token' => 'spaces-token'
                        })
      runner = Teems::Runner.new(output: test_output)
      cmd = RefreshTestCommand.new([], runner: runner)
      call_count = 0

      runner.define_singleton_method(:refresh_tokens) { true }

      assert_raises(Teems::ApiError) do
        cmd.test_with_token_refresh do
          call_count += 1
          raise Teems::ApiError, 'Token expired'
        end
      end

      assert_equal 2, call_count
    end
  end

  def test_with_token_refresh_reraises_if_refresh_fails
    with_temp_config do |dir|
      write_tokens_file(dir, {
                          'auth_token' => 'test-auth',
                          'skype_token' => 'test-skype'
                        })
      output = test_output
      runner = Teems::Runner.new(output: output)
      cmd = RefreshTestCommand.new([], runner: runner)
      call_count = 0

      runner.define_singleton_method(:refresh_tokens) { false }

      assert_raises(Teems::ApiError) do
        cmd.test_with_token_refresh do
          call_count += 1
          raise Teems::ApiError, 'Invalid token'
        end
      end

      # Should only be called once since refresh failed
      assert_equal 1, call_count
    end
  end

  def test_with_token_refresh_succeeds_after_refresh
    with_temp_config do |dir|
      write_tokens_file(dir, {
                          'auth_token' => 'test-auth',
                          'skype_token' => 'test-skype',
                          'skype_spaces_token' => 'spaces-token'
                        })
      runner = Teems::Runner.new(output: test_output)
      cmd = RefreshTestCommand.new([], runner: runner)
      call_count = 0

      runner.define_singleton_method(:refresh_tokens) { true }

      result = cmd.test_with_token_refresh do
        call_count += 1
        raise Teems::ApiError, 'Invalid token' if call_count == 1

        'success after refresh'
      end

      assert_equal 'success after refresh', result
      assert_equal 2, call_count
    end
  end
end
