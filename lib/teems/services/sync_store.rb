# frozen_string_literal: true

module Teems
  module Services
    # Manages local sync state and file storage for the sync command.
    # Stores chat history as Markdown + JSON in XDG data directory.
    class SyncStore
      SYNC_DIR = 'sync'
      STATE_FILE = 'sync_state.json'
      CHATS_DIR = 'chats'
      GENERIC_LABELS = ['Group Chat', '1:1 Chat', 'Meeting Chat'].freeze
      MAX_DIR_NAME_LENGTH = 100

      def initialize(xdg_paths: nil)
        @xdg_paths = xdg_paths || Support::XdgPaths.new
      end

      def sync_dir
        @sync_dir ||= File.join(@xdg_paths.data_dir, SYNC_DIR)
      end

      # Load the global sync state from disk
      def load_state
        path = File.join(sync_dir, STATE_FILE)
        return {} unless File.exist?(path)

        JSON.parse(File.read(path))
      rescue JSON::ParserError
        {}
      end

      # Save the global sync state to disk (atomic write)
      def save_state(state)
        ensure_sync_dir
        path = File.join(sync_dir, STATE_FILE)
        atomic_write(path, JSON.pretty_generate(state))
      end

      # Return the last synced time for a chat, or nil
      def last_synced_time(state, chat_id)
        ts = state.dig('chats', chat_id, 'last_synced_at')
        return nil unless ts

        Time.parse(ts)
      rescue ArgumentError
        nil
      end

      # Update per-chat metadata in the state hash (in-memory, call save_state to persist)
      def update_chat_state(state, chat_id, last_synced_at:, message_count:, display_name: nil)
        state['chats'] ||= {}
        state['chats'][chat_id] ||= {}
        state['chats'][chat_id].merge!(
          'last_synced_at' => last_synced_at.iso8601,
          'message_count' => message_count,
          'display_name' => display_name,
          'dir_name' => build_dir_name(chat_id, display_name)
        )
        state
      end

      # Mark a chat as unavailable (e.g. 404) so it gets skipped on future syncs
      def mark_unavailable(state, chat_id, display_name: nil)
        state['chats'] ||= {}
        state['chats'][chat_id] ||= {}
        state['chats'][chat_id]['unavailable'] = true
        state['chats'][chat_id]['unavailable_at'] = Time.now.iso8601
        if display_name
          state['chats'][chat_id]['display_name'] = display_name
          state['chats'][chat_id]['dir_name'] = build_dir_name(chat_id, display_name)
        end
        state
      end

      # Check if a chat has been marked as unavailable
      def chat_unavailable?(state, chat_id)
        state.dig('chats', chat_id, 'unavailable') == true
      end

      # Return the directory path for a specific chat
      # When state is provided, uses the human-readable dir_name; falls back to sanitized ID
      def chat_dir(chat_id, state: nil)
        dir_name = state&.dig('chats', chat_id, 'dir_name') || sanitize_id(chat_id)
        File.join(sync_dir, CHATS_DIR, dir_name)
      end

      # Write messages.md and messages.json for a chat (atomic writes)
      def write_messages(chat_id, messages_md:, messages_json:, state: nil)
        dir = chat_dir(chat_id, state: state)
        FileUtils.mkdir_p(dir)

        atomic_write(File.join(dir, 'messages.md'), messages_md)
        atomic_write(File.join(dir, 'messages.json'), messages_json)
      end

      # Write chat_metadata.json with original ID and display info
      def write_chat_metadata(chat_id, metadata, state: nil)
        dir = chat_dir(chat_id, state: state)
        FileUtils.mkdir_p(dir)

        atomic_write(File.join(dir, 'chat_metadata.json'), JSON.pretty_generate(metadata))
      end

      # Read existing messages.json for a chat, returns array or empty array
      def read_messages_json(chat_id, state: nil)
        path = File.join(chat_dir(chat_id, state: state), 'messages.json')
        return [] unless File.exist?(path)

        JSON.parse(File.read(path))
      rescue JSON::ParserError
        []
      end

      # Ensure a chat has the correct human-readable directory name.
      # Handles three cases: legacy dir (no dir_name in state yet), topic changed, or no change.
      # Returns the dir_name that was set.
      def ensure_dir_name(state, chat_id, display_name)
        new_dir_name = build_dir_name(chat_id, display_name)
        state['chats'] ||= {}
        state['chats'][chat_id] ||= {}
        current_dir_name = state['chats'][chat_id]['dir_name']

        if current_dir_name.nil?
          # Legacy directory: check if old sanitized-ID dir exists and rename it
          rename_chat_dir(sanitize_id(chat_id), new_dir_name)
        elsif current_dir_name != new_dir_name
          # Topic changed: rename from old dir_name to new
          rename_chat_dir(current_dir_name, new_dir_name)
        end

        state['chats'][chat_id]['dir_name'] = new_dir_name
        new_dir_name
      end

      # Migrate all existing chat directories to human-readable names.
      # Idempotent — safe to run repeatedly.
      def migrate_directories!(state)
        return unless state['chats']

        state['chats'].each do |chat_id, chat_state|
          display_name = chat_state['display_name']
          ensure_dir_name(state, chat_id, display_name)
        end
      end

      private

      def ensure_sync_dir
        FileUtils.mkdir_p(sync_dir)
      end

      # Sanitize a chat ID for use as a directory name
      # Replace : @ and other unsafe chars with _
      def sanitize_id(id)
        id.gsub(/[:@]/, '_')
      end

      # Sanitize a display name for use as a directory name
      # Replace filesystem-unsafe chars, collapse whitespace, truncate
      def sanitize_display_name(name)
        return nil if name.nil? || name.strip.empty?

        sanitized = name.strip
        sanitized = sanitized.gsub(%r{[/\\:*?"<>|]}, '-')
        sanitized = sanitized.gsub(/\s+/, ' ')
        sanitized = sanitized[0, MAX_DIR_NAME_LENGTH]
        sanitized = sanitized.gsub(/[\s.]+\z/, '')
        sanitized.empty? ? nil : sanitized
      end

      # Build a human-readable directory name for a chat.
      # Named topics use sanitized display name; generic labels get a short ID suffix;
      # nil/empty falls back to sanitized chat ID.
      def build_dir_name(chat_id, display_name)
        sanitized = sanitize_display_name(display_name)
        return sanitize_id(chat_id) unless sanitized

        if GENERIC_LABELS.include?(display_name&.strip)
          short_id = sanitize_id(chat_id)[0, 20]
          "#{sanitized} (#{short_id})"
        else
          sanitized
        end
      end

      # Rename a chat directory from old_name to new_name (within the chats dir).
      # No-op if old doesn't exist, new already exists, or names are the same.
      def rename_chat_dir(old_name, new_name)
        return if old_name == new_name

        chats_path = File.join(sync_dir, CHATS_DIR)
        old_path = File.join(chats_path, old_name)
        new_path = File.join(chats_path, new_name)

        return unless File.directory?(old_path)
        return if File.exist?(new_path)

        FileUtils.mkdir_p(chats_path)
        File.rename(old_path, new_path)
      end

      # Write to a temp file then rename for atomicity
      def atomic_write(path, content)
        tmp_path = "#{path}.tmp"
        File.write(tmp_path, content)
        File.rename(tmp_path, path)
      end
    end
  end
end
