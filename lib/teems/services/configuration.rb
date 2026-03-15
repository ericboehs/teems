# frozen_string_literal: true

module Teems
  module Services
    # Manages CLI configuration stored in XDG config directory
    class Configuration
      attr_writer :on_warning

      def initialize(paths: Support::XdgPaths.new)
        @paths = paths
        @on_warning = nil
        @data = nil
      end

      def [](key)
        data[key]
      end

      def []=(key, value)
        data[key] = value
        save_config
      end

      def to_h
        data.dup
      end

      private

      def data
        @data ||= load_config
      end

      def config_file
        @paths.config_file('config.json')
      end

      def load_config
        return {} unless File.exist?(config_file)

        JSON.parse(File.read(config_file))
      rescue JSON::ParserError => e
        @on_warning&.call("Config file #{config_file} is corrupted (#{e.message}). Using defaults.")
        {}
      end

      def save_config
        @paths.ensure_config_dir
        File.write(config_file, JSON.pretty_generate(data))
        File.chmod(0o600, config_file)
      end
    end
  end
end
