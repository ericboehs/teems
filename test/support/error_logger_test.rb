# frozen_string_literal: true

require 'test_helper'

# Tests error logging to file with timestamps, appending, and IO failure handling
class ErrorLoggerTest < Minitest::Test
  def test_log_writes_error_to_file
    with_temp_config do
      paths = Teems::Support::XdgPaths.new
      log_file = Teems::Support::ErrorLogger.log(error_with_backtrace, paths: paths)
      content = File.read(log_file)
      assert log_file
      assert_includes content, 'RuntimeError'
      assert_includes content, 'test error'
      assert_includes content, 'file.rb:1'
    end
  end

  def error_with_backtrace
    RuntimeError.new('test error').tap do |err|
      err.set_backtrace(['file.rb:1:in `method`', 'file.rb:2:in `other`'])
    end
  end
  private :error_with_backtrace

  def test_log_returns_log_file_path
    with_temp_config do
      paths = Teems::Support::XdgPaths.new
      error = RuntimeError.new('test')

      result = Teems::Support::ErrorLogger.log(error, paths: paths)

      assert result.end_with?('error.log')
    end
  end

  def test_log_handles_error_without_backtrace
    with_temp_config do
      paths = Teems::Support::XdgPaths.new
      error = RuntimeError.new('no backtrace')

      log_file = Teems::Support::ErrorLogger.log(error, paths: paths)

      content = File.read(log_file)
      assert_includes content, 'no backtrace'
    end
  end

  def test_log_appends_to_existing_file
    with_temp_config do
      paths = Teems::Support::XdgPaths.new

      Teems::Support::ErrorLogger.log(RuntimeError.new('first'), paths: paths)
      log_file = Teems::Support::ErrorLogger.log(RuntimeError.new('second'), paths: paths)

      content = File.read(log_file)
      assert_includes content, 'first'
      assert_includes content, 'second'
    end
  end

  def test_log_returns_nil_on_io_failure
    with_temp_config do
      paths = Teems::Support::XdgPaths.new
      log_path = setup_blocking_log_path(paths)
      result = Teems::Support::ErrorLogger.log(RuntimeError.new('test'), paths: paths)
      assert_nil result
    ensure
      FileUtils.rm_rf(log_path) if log_path
    end
  end

  def setup_blocking_log_path(paths)
    FileUtils.mkdir_p(paths.cache_dir)
    log_path = paths.cache_file('error.log')
    FileUtils.mkdir_p(log_path)
    log_path
  end
  private :setup_blocking_log_path

  def test_write_entry_includes_timestamp
    with_temp_config do
      paths = Teems::Support::XdgPaths.new
      error = RuntimeError.new('timestamped')

      log_file = Teems::Support::ErrorLogger.log(error, paths: paths)

      content = File.read(log_file)
      # ISO8601 format includes 'T'
      assert_match(/\d{4}-\d{2}-\d{2}T/, content)
    end
  end
end
