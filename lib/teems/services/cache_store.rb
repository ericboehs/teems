# frozen_string_literal: true

module Teems
  module Services
    # Manages caching of user and channel data
    class CacheStore
      def initialize(paths: Support::XdgPaths.new)
        @paths = paths
        @user_cache = {}
      end

      def get_user(user_id)
        @user_cache[user_id]
      end

      def set_user(user_id, display_name)
        @user_cache[user_id] = display_name
      end

      # Store calendar event ID mappings for `cal show <N>` lookup
      def save_calendar_ids(ids_hash)
        @paths.ensure_cache_dir
        File.write(calendar_ids_file, JSON.generate(ids_hash))
      end

      # Retrieve a real event ID by its display number
      def get_calendar_id(number)
        return nil unless File.exist?(calendar_ids_file)

        data = JSON.parse(File.read(calendar_ids_file))
        data[number.to_s]
      rescue JSON::ParserError
        nil
      end

      def clear
        @user_cache.clear
        FileUtils.rm_f(users_cache_file)
        FileUtils.rm_f(calendar_ids_file)
      end

      private

      def users_cache_file
        @paths.cache_file('users.json')
      end

      def calendar_ids_file
        @paths.cache_file('calendar_ids.json')
      end
    end
  end
end
