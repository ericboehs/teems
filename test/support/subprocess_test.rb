# frozen_string_literal: true

require 'test_helper'
require 'open3'

# Tests for the Open3 wrapper that keeps signalled child processes quiet
class SubprocessTest < Minitest::Test
  def test_capture3_returns_stdout_stderr_and_status
    out, err, status = Teems::Support::Subprocess.capture3('sh', '-c', 'printf o; printf e >&2')

    assert_equal 'o', out
    assert_equal 'e', err
    assert_predicate status, :success?
  end

  def test_capture3_reports_failure_status
    _out, _err, status = Teems::Support::Subprocess.capture3('sh', '-c', 'exit 3')

    refute_predicate status, :success?
    assert_equal 3, status.exitstatus
  end

  # Open3's reader threads inherit this flag when they are created, so it has to be off
  # for the duration of the call - that is what keeps IOError backtraces off the terminal
  # when a poll is interrupted mid-read.
  def test_capture3_disables_thread_reporting_during_the_call
    observed = nil
    stub = ->(*_args) { [+'', +'', nil].tap { observed = Thread.report_on_exception } }

    Open3.stub(:capture3, stub) { Teems::Support::Subprocess.capture3('noop') }

    refute observed, 'reader threads must be created with reporting disabled'
  end

  def test_capture3_restores_previous_reporting_flag
    original = Thread.report_on_exception
    Teems::Support::Subprocess.capture3('sh', '-c', 'exit 0')

    assert_equal original, Thread.report_on_exception
  end

  def test_capture3_restores_flag_when_the_command_is_missing
    original = Thread.report_on_exception

    assert_raises(Errno::ENOENT) do
      Teems::Support::Subprocess.capture3('teems-no-such-binary-xyz')
    end
    assert_equal original, Thread.report_on_exception
  end
end
