# frozen_string_literal: true

require 'test_helper'

class HelpCommandTest < Minitest::Test
  def test_execute_returns_zero
    with_temp_config do
      assert_equal 0, Teems::Commands::Help.new([], runner: test_runner).execute
    end
  end

  def test_shows_version
    result = run_help

    assert_match(/teems/, result[:stdout])
    assert_match(/v#{Teems::VERSION}/, result[:stdout])
  end

  def test_shows_commands_section
    result = run_help

    assert_match(/COMMANDS:/, result[:stdout])
    assert_match(/auth/, result[:stdout])
    assert_match(/channels/, result[:stdout])
    assert_match(/chats/, result[:stdout])
    assert_match(/messages/, result[:stdout])
  end

  def test_shows_global_options
    result = run_help

    assert_match(/GLOBAL OPTIONS:/, result[:stdout])
    assert_match(/--limit/, result[:stdout])
    assert_match(/--verbose/, result[:stdout])
    assert_match(/--quiet/, result[:stdout])
    assert_match(/--json/, result[:stdout])
    assert_match(/--help/, result[:stdout])
  end

  def test_shows_examples
    result = run_help

    assert_match(/EXAMPLES:/, result[:stdout])
    assert_match(/teems auth login/, result[:stdout])
  end

  def test_shows_usage_hint
    result = run_help
    assert_match(/teems <command> --help/, result[:stdout])
  end

  def test_command_specific_help_for_known_command
    result = run_help(['auth'])
    assert_match(/auth/, result[:stdout])
  end

  def test_command_specific_help_for_unknown_command
    result = run_help(['nonexistent'])

    assert_match(/Unknown command: nonexistent/, result[:stderr])
    assert_match(/Available commands:/, result[:stdout])
  end

  def test_shows_available_commands_for_unknown_command
    result = run_help(['foobar'])

    assert_match(/auth/, result[:stdout])
    assert_match(/channels/, result[:stdout])
    assert_match(/chats/, result[:stdout])
    assert_match(/messages/, result[:stdout])
  end

  def test_help_for_channels_command
    result = run_help(['channels'])
    assert_match(/channels/, result[:stdout])
  end

  def test_help_for_chats_command
    result = run_help(['chats'])
    assert_match(/chats/, result[:stdout])
  end

  def test_help_for_messages_command
    result = run_help(['messages'])
    assert_match(/messages/, result[:stdout])
  end

  private

  def run_help(args = [])
    with_temp_config do
      capture_output do |output|
        Teems::Commands::Help.new(args, runner: test_runner(output: output)).execute
      end
    end
  end
end
