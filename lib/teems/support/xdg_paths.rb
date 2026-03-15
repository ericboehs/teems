# frozen_string_literal: true

module Teems
  module Support
    # XDG-compliant paths for config, cache, and data directories
    class XdgPaths
      def config_dir
        @config_dir ||= File.join(
          ENV.fetch('XDG_CONFIG_HOME', File.join(Dir.home, '.config')),
          'teems'
        )
      end

      def cache_dir
        @cache_dir ||= File.join(
          ENV.fetch('XDG_CACHE_HOME', File.join(Dir.home, '.cache')),
          'teems'
        )
      end

      def data_dir
        @data_dir ||= File.join(
          ENV.fetch('XDG_DATA_HOME', File.join(Dir.home, '.local', 'share')),
          'teems'
        )
      end

      def config_file(filename)
        File.join(config_dir, filename)
      end

      def cache_file(filename)
        File.join(cache_dir, filename)
      end

      def data_file(filename)
        File.join(data_dir, filename)
      end

      def ensure_config_dir
        FileUtils.mkdir_p(config_dir)
      rescue SystemCallError => e
        warn "teems: Could not create config directory #{config_dir}: #{e.message}"
        raise
      end

      def ensure_cache_dir
        FileUtils.mkdir_p(cache_dir)
      rescue SystemCallError => e
        warn "teems: Could not create cache directory #{cache_dir}: #{e.message}"
        raise
      end

      def ensure_data_dir
        FileUtils.mkdir_p(data_dir)
      rescue SystemCallError => e
        warn "teems: Could not create data directory #{data_dir}: #{e.message}"
        raise
      end
    end
  end
end
