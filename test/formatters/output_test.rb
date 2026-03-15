# frozen_string_literal: true

require 'test_helper'

module OutputTests
  class BasicOutputTest < Minitest::Test
    def test_puts_writes_to_io
      io = StringIO.new
      output = Teems::Formatters::Output.new(io: io, color: false)
      output.puts('Hello world')
      assert_equal "Hello world\n", io.string
    end

    def test_puts_respects_quiet_mode
      io = StringIO.new
      output = Teems::Formatters::Output.new(io: io, color: false, mode: :quiet)
      output.puts('Hello world')
      assert_empty io.string
    end

    def test_print_writes_without_newline
      io = StringIO.new
      output = Teems::Formatters::Output.new(io: io, color: false)
      output.print('Hello')
      assert_equal 'Hello', io.string
    end

    def test_print_respects_quiet_mode
      io = StringIO.new
      output = Teems::Formatters::Output.new(io: io, color: false, mode: :quiet)
      output.print('Hello')
      assert_empty io.string
    end

    def test_error_writes_to_err
      io = StringIO.new
      err = StringIO.new
      output = Teems::Formatters::Output.new(io: io, err: err, color: false)
      output.error('Something failed')
      assert_match(/Error:.*Something failed/, err.string)
      assert_empty io.string
    end

    def test_warn_writes_to_err
      err = StringIO.new
      output = Teems::Formatters::Output.new(io: StringIO.new, err: err, color: false)
      output.warn('Be careful')
      assert_match(/Warning:.*Be careful/, err.string)
    end

    def test_warn_respects_quiet_mode
      err = StringIO.new
      output = Teems::Formatters::Output.new(err: err, color: false, mode: :quiet)
      output.warn('Be careful')
      assert_empty err.string
    end

    def test_success_writes_checkmark
      io = StringIO.new
      output = Teems::Formatters::Output.new(io: io, color: false)
      output.success('Done')
      assert_match(/\u{2713}.*Done/, io.string)
    end

    def test_info_writes_to_io
      io = StringIO.new
      output = Teems::Formatters::Output.new(io: io, color: false)
      output.info('Information')
      assert_equal "Information\n", io.string
    end

    def test_debug_writes_when_verbose
      err = StringIO.new
      output = Teems::Formatters::Output.new(err: err, color: false, mode: :verbose)
      output.debug('Debug info')
      assert_match(/\[debug\].*Debug info/, err.string)
    end

    def test_debug_silent_when_not_verbose
      err = StringIO.new
      output = Teems::Formatters::Output.new(err: err, color: false)
      output.debug('Debug info')
      assert_empty err.string
    end
  end

  class ColorAndModeTest < Minitest::Test
    def test_color_helpers_without_color_basic
      output = Teems::Formatters::Output.new(color: false)
      assert_equal 'text', output.red('text')
      assert_equal 'text', output.green('text')
      assert_equal 'text', output.yellow('text')
      assert_equal 'text', output.blue('text')
    end

    def test_color_helpers_without_color_extended
      output = Teems::Formatters::Output.new(color: false)
      assert_equal 'text', output.magenta('text')
      assert_equal 'text', output.cyan('text')
      assert_equal 'text', output.gray('text')
      assert_equal 'text', output.bold('text')
    end

    def test_color_helpers_with_color_basic
      output = Teems::Formatters::Output.new(color: true)
      assert_match(/\e\[0;31m.*text.*\e\[0m/, output.red('text'))
      assert_match(/\e\[0;32m.*text.*\e\[0m/, output.green('text'))
      assert_match(/\e\[0;33m.*text.*\e\[0m/, output.yellow('text'))
      assert_match(/\e\[0;34m.*text.*\e\[0m/, output.blue('text'))
    end

    def test_color_helpers_with_color_extended
      output = Teems::Formatters::Output.new(color: true)
      assert_match(/\e\[0;35m.*text.*\e\[0m/, output.magenta('text'))
      assert_match(/\e\[0;36m.*text.*\e\[0m/, output.cyan('text'))
      assert_match(/\e\[0;90m.*text.*\e\[0m/, output.gray('text'))
      assert_match(/\e\[1m.*text.*\e\[0m/, output.bold('text'))
    end

    def test_with_verbose_creates_new_instance
      output = Teems::Formatters::Output.new
      verbose_output = output.with_verbose(true)
      refute output.verbose?
      assert verbose_output.verbose?
    end

    def test_with_quiet_creates_new_instance
      output = Teems::Formatters::Output.new
      quiet_output = output.with_quiet(true)
      refute output.quiet?
      assert quiet_output.quiet?
    end

    def test_with_verbose_false_resets_to_normal
      output = Teems::Formatters::Output.new(mode: :verbose)
      normal_output = output.with_verbose(false)
      assert output.verbose?
      refute normal_output.verbose?
    end

    def test_with_quiet_false_resets_to_normal
      output = Teems::Formatters::Output.new(mode: :quiet)
      normal_output = output.with_quiet(false)
      assert output.quiet?
      refute normal_output.quiet?
    end
  end
end
