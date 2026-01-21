# frozen_string_literal: true

module Teems
  module Services
    # Manages caching of user and channel data
    class CacheStore
      def initialize(paths: nil)
        @paths = paths || Support::XdgPaths.new
        @user_cache = {}
      end

      def get_user(user_id)
        @user_cache[user_id]
      end

      def set_user(user_id, display_name)
        @user_cache[user_id] = display_name
      end

      def clear
        @user_cache.clear
        FileUtils.rm_f(users_cache_file)
      end

      private

      def users_cache_file
        @paths.cache_file('users.json')
      end
    end
  end
end
