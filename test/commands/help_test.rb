# frozen_string_literal: true

require 'test_helper'

# Tests for the help command
class HelpCommandTest < Minitest::Test
  def test_execute_returns_zero
    with_temp_config do
      assert_equal 0, Teems::Commands::Help.new([], runner: test_runner).execute
    end
  end

  def test_shows_version
    result = run_help

    stdout = result[:stdout]
    assert_match(/teems/, stdout)
    assert_match(/v#{Teems::VERSION}/, stdout)
  end

  def test_shows_commands_section
    stdout = run_help[:stdout]

    assert_match(/COMMANDS:/, stdout)
    assert_match(/auth/, stdout)
    assert_match(/channels/, stdout)
    assert_match(/chats/, stdout)
    assert_match(/messages/, stdout)
  end

  def test_shows_global_options
    stdout = run_help[:stdout]

    assert_match(/GLOBAL OPTIONS:/, stdout)
    assert_match(/--limit/, stdout)
    assert_match(/--verbose/, stdout)
    assert_match(/--quiet/, stdout)
    assert_match(/--json/, stdout)
    assert_match(/--help/, stdout)
  end

  def test_shows_examples
    stdout = run_help[:stdout]

    assert_match(/EXAMPLES:/, stdout)
    assert_match(/teems auth login/, stdout)
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
    stdout = run_help(['foobar'])[:stdout]

    assert_match(/auth/, stdout)
    assert_match(/channels/, stdout)
    assert_match(/chats/, stdout)
    assert_match(/messages/, stdout)
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
