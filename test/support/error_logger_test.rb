# frozen_string_literal: true

require 'test_helper'

class ErrorLoggerTest < Minitest::Test
  def test_log_writes_error_to_file
    with_temp_config do
      paths = Teems::Support::XdgPaths.new
      error = RuntimeError.new('test error')
      error.set_backtrace(['file.rb:1:in `method`', 'file.rb:2:in `other`'])

      log_file = Teems::Support::ErrorLogger.log(error, paths: paths)

      assert log_file
      content = File.read(log_file)
      assert_includes content, 'RuntimeError'
      assert_includes content, 'test error'
      assert_includes content, 'file.rb:1'
    end
  end

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
      # Make cache dir read-only to trigger IOError on file open
      cache_dir = paths.cache_dir
      FileUtils.mkdir_p(cache_dir)
      log_path = paths.cache_file('error.log')
      # Create a directory where the file should be to trigger error
      FileUtils.mkdir_p(log_path)

      result = Teems::Support::ErrorLogger.log(RuntimeError.new('test'), paths: paths)

      assert_nil result
    ensure
      FileUtils.rm_rf(log_path) if log_path
    end
  end

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
