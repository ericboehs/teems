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
end
