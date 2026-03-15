# frozen_string_literal: true

module Teems
  module Support
    # Logs errors to a file for debugging
    module ErrorLogger
      module_function

      def log(error, paths: XdgPaths.new)
        paths.ensure_cache_dir
        log_file = paths.cache_file('error.log')
        File.open(log_file, 'a') { |file| write_entry(file, error) }
        log_file
      rescue SystemCallError, IOError => io_error
        warn "teems: Could not write error log: #{io_error.message}"
        nil
      end

      def write_entry(file, error)
        file.puts "#{Time.now.iso8601} - #{error.class}: #{error.message}"
        file.puts error.backtrace.first(10).map { |line| "  #{line}" }.join("\n") if error.backtrace
        file.puts
      end
    end
  end
end
