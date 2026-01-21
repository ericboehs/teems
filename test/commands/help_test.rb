# frozen_string_literal: true

require 'test_helper'

class HelpCommandTest < Minitest::Test
  def test_execute_returns_zero
    with_temp_config do
      runner = test_runner
      cmd = Teems::Commands::Help.new([], runner: runner)

      assert_equal 0, cmd.execute
    end
  end

  def test_shows_version
    with_temp_config do
      result = capture_output do |output|
        runner = test_runner(output: output)
        cmd = Teems::Commands::Help.new([], runner: runner)
        cmd.execute
      end

      assert_match(/teems/, result[:stdout])
      assert_match(/v#{Teems::VERSION}/, result[:stdout])
    end
  end

  def test_shows_commands_section
    with_temp_config do
      result = capture_output do |output|
        runner = test_runner(output: output)
        cmd = Teems::Commands::Help.new([], runner: runner)
        cmd.execute
      end

      assert_match(/COMMANDS:/, result[:stdout])
      assert_match(/auth/, result[:stdout])
      assert_match(/channels/, result[:stdout])
      assert_match(/chats/, result[:stdout])
      assert_match(/messages/, result[:stdout])
    end
  end

  def test_shows_global_options
    with_temp_config do
      result = capture_output do |output|
        runner = test_runner(output: output)
        cmd = Teems::Commands::Help.new([], runner: runner)
        cmd.execute
      end

      assert_match(/GLOBAL OPTIONS:/, result[:stdout])
      assert_match(/--limit/, result[:stdout])
      assert_match(/--verbose/, result[:stdout])
      assert_match(/--quiet/, result[:stdout])
      assert_match(/--json/, result[:stdout])
      assert_match(/--help/, result[:stdout])
    end
  end

  def test_shows_examples
    with_temp_config do
      result = capture_output do |output|
        runner = test_runner(output: output)
        cmd = Teems::Commands::Help.new([], runner: runner)
        cmd.execute
      end

      assert_match(/EXAMPLES:/, result[:stdout])
      assert_match(/teems auth login/, result[:stdout])
    end
  end

  def test_shows_usage_hint
    with_temp_config do
      result = capture_output do |output|
        runner = test_runner(output: output)
        cmd = Teems::Commands::Help.new([], runner: runner)
        cmd.execute
      end

      assert_match(/teems <command> --help/, result[:stdout])
    end
  end

  def test_command_specific_help_for_known_command
    with_temp_config do
      result = capture_output do |output|
        runner = test_runner(output: output)
        cmd = Teems::Commands::Help.new(['auth'], runner: runner)
        cmd.execute
      end

      # Should show auth command help
      assert_match(/auth/, result[:stdout])
    end
  end

  def test_command_specific_help_for_unknown_command
    with_temp_config do
      result = capture_output do |output|
        runner = test_runner(output: output)
        cmd = Teems::Commands::Help.new(['nonexistent'], runner: runner)
        cmd.execute
      end

      assert_match(/Unknown command: nonexistent/, result[:stderr])
      assert_match(/Available commands:/, result[:stdout])
    end
  end

  def test_shows_available_commands_for_unknown_command
    with_temp_config do
      result = capture_output do |output|
        runner = test_runner(output: output)
        cmd = Teems::Commands::Help.new(['foobar'], runner: runner)
        cmd.execute
      end

      # Should list available commands
      assert_match(/auth/, result[:stdout])
      assert_match(/channels/, result[:stdout])
      assert_match(/chats/, result[:stdout])
      assert_match(/messages/, result[:stdout])
    end
  end

  def test_help_for_channels_command
    with_temp_config do
      result = capture_output do |output|
        runner = test_runner(output: output)
        cmd = Teems::Commands::Help.new(['channels'], runner: runner)
        cmd.execute
      end

      assert_match(/channels/, result[:stdout])
    end
  end

  def test_help_for_chats_command
    with_temp_config do
      result = capture_output do |output|
        runner = test_runner(output: output)
        cmd = Teems::Commands::Help.new(['chats'], runner: runner)
        cmd.execute
      end

      assert_match(/chats/, result[:stdout])
    end
  end

  def test_help_for_messages_command
    with_temp_config do
      result = capture_output do |output|
        runner = test_runner(output: output)
        cmd = Teems::Commands::Help.new(['messages'], runner: runner)
        cmd.execute
      end

      assert_match(/messages/, result[:stdout])
    end
  end
end
