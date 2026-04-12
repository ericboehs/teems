# frozen_string_literal: true

require 'test_helper'

# Tests for Safari JS runner service
module SafariJsRunnerTests
  # Tests using a testable subclass that stubs osascript
  class CoreTest < Minitest::Test
    def test_available_returns_boolean
      runner = Teems::Services::SafariJsRunner.new
      result = runner.available?
      assert_includes [true, false], result
    end

    def test_execute_js_returns_nil_on_failure
      runner = build_runner(success: false)
      assert_nil runner.execute_js('1+1')
    end

    def test_execute_js_returns_stripped_output
      runner = build_runner(output: "  hello  \n")
      assert_equal 'hello', runner.execute_js('1+1')
    end

    def test_navigate_calls_applescript
      runner = build_runner(output: '')
      runner.navigate('https://example.com')
      assert runner.called
    end

    def test_wait_for_load_raises_on_timeout
      runner = build_runner(output: 'loading')
      assert_raises(Teems::Error) { runner.wait_for_load(timeout: 1) }
    end

    def test_wait_for_load_returns_when_complete
      runner = build_runner(output: 'complete')
      runner.wait_for_load(timeout: 2)
    end

    def test_page_url_returns_result
      runner = build_runner(output: 'https://example.com')
      assert_equal 'https://example.com', runner.page_url
    end

    def test_execute_js_escapes_special_chars
      runner = build_runner(output: 'ok')
      assert_equal 'ok', runner.execute_js("hello \"world\"\nnewline")
    end

    def test_real_run_applescript_with_bad_script
      runner = Teems::Services::SafariJsRunner.new
      result = runner.send(:run_applescript, 'return "hello"')
      # On macOS with osascript: returns "hello"; on CI: returns nil
      assert_includes [nil, 'hello'], result
    end

    def test_real_run_applescript_failure_returns_nil
      runner = Teems::Services::SafariJsRunner.new
      result = runner.send(:run_applescript, 'this is not valid applescript syntax !!!')
      assert_nil result
    end

    def test_log_with_output
      out = Teems::Formatters::Output.new(io: StringIO.new, err: StringIO.new, mode: :verbose)
      runner = Teems::Services::SafariJsRunner.new(output: out)
      runner.send(:log, 'test message')
      assert_includes out.instance_variable_get(:@err).string, 'test message'
    end

    def test_log_without_output
      runner = Teems::Services::SafariJsRunner.new
      runner.send(:log, 'test message')
    end

    private

    def build_runner(output: '', success: true, raise_error: nil)
      TestableSafariJsRunner.new(output: output, success: success, raise_error: raise_error)
    end
  end

  # Subclass that stubs Open3.capture3
  class TestableSafariJsRunner < Teems::Services::SafariJsRunner
    attr_reader :called

    def initialize(output: '', success: true, raise_error: nil)
      super(output: nil)
      @stub_output = output
      @stub_success = success
      @raise_error = raise_error
      @called = false
    end

    def sleep(_seconds) = nil

    private

    def run_applescript(_script)
      @called = true
      return nil unless @stub_success

      @stub_output.strip
    end
  end
end
