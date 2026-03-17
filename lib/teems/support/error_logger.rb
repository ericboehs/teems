# frozen_string_literal: true

module Teems
  module Support
    # Logs errors to a file for debugging
    module ErrorLogger
      module_function

      def log(error, paths: XdgPaths.new)
        log_file = prepare_log_file(paths)
        append_error_entry(log_file, error)
      rescue SystemCallError, IOError => e
        warn "teems: Could not write error log: #{e.message}"
        nil
      end

      def append_error_entry(log_file, error)
        File.open(log_file, 'a') { |file| write_entry(file, error) }
        log_file
      end

      def prepare_log_file(paths)
        paths.ensure_cache_dir
        paths.cache_file('error.log')
      end

      def write_entry(file, error)
        file.puts "#{Time.now.iso8601} - #{error.class}: #{error.message}"
        backtrace = error.backtrace
        file.puts backtrace.first(10).map { |line| "  #{line}" }.join("\n") if backtrace
        file.puts
      end
    end
  end
end
