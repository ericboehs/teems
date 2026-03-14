# frozen_string_literal: true

module Teems
  module Services
    # Manages local sync state and file storage for the sync command.
    # Stores chat history as Markdown + JSON in XDG data directory.
    class SyncStore
      SYNC_DIR = 'sync'
      STATE_FILE = 'sync_state.json'
      CHATS_DIR = 'chats'
      GENERIC_LABELS = ['Group Chat', '1:1 Chat', 'Meeting Chat', 'Channel', 'Space'].freeze
      MAX_DIR_NAME_LENGTH = 100
      TYPE_DIRS = {
        'oneOnOne' => 'dms', 'group' => 'groups', 'meeting' => 'meetings',
        'channel' => 'channels', 'space' => 'spaces'
      }.freeze

      def initialize(xdg_paths: nil)
        @xdg_paths = xdg_paths || Support::XdgPaths.new
      end

      def sync_dir
        @sync_dir ||= File.join(@xdg_paths.data_dir, SYNC_DIR)
      end

      # Map chat_type to subdirectory name
      def type_dir(chat_type)
        TYPE_DIRS[chat_type] || 'other'
      end

      # Load the global sync state from disk
      def load_state
        path = File.join(sync_dir, STATE_FILE)
        return {} unless File.exist?(path)

        JSON.parse(File.read(path))
      rescue JSON::ParserError
        backup_corrupt_file(path)
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
      def update_chat_state(state, chat_id, last_synced_at:, message_count:, display_name: nil, chat_type: nil)
        ensure_chat_entry(state, chat_id).merge!(
          'last_synced_at' => last_synced_at.iso8601,
          'message_count' => message_count,
          'display_name' => display_name,
          'dir_name' => build_dir_name(chat_id, display_name),
          'chat_type' => chat_type
        )
        state
      end

      # Mark a chat as unavailable (e.g. 404) so it gets skipped on future syncs
      def mark_unavailable(state, chat_id, display_name: nil, chat_type: nil)
        entry = ensure_chat_entry(state, chat_id)
        entry['unavailable'] = true
        entry['unavailable_at'] = Time.now.iso8601
        entry['chat_type'] = chat_type if chat_type
        if display_name
          entry['display_name'] = display_name
          entry['dir_name'] = build_dir_name(chat_id, display_name)
        end
        state
      end

      # Check if a chat has been marked as unavailable
      def chat_unavailable?(state, chat_id)
        state.dig('chats', chat_id, 'unavailable') == true
      end

      # Return the directory path for a specific chat
      # When state is provided, uses the human-readable dir_name and type subdirectory;
      # falls back to sanitized ID in 'other/' when state is not available
      def chat_dir(chat_id, state: nil)
        dir_name = state&.dig('chats', chat_id, 'dir_name') || sanitize_id(chat_id)
        chat_type = state&.dig('chats', chat_id, 'chat_type')
        type_subdir = type_dir(chat_type)
        File.join(sync_dir, CHATS_DIR, type_subdir, dir_name)
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

      # Read existing messages.json for a chat, returns array or empty array.
      # Backs up corrupt files to prevent data loss on re-sync.
      def read_messages_json(chat_id, state: nil)
        path = File.join(chat_dir(chat_id, state: state), 'messages.json')
        return [] unless File.exist?(path)

        JSON.parse(File.read(path))
      rescue JSON::ParserError
        backup_corrupt_file(path)
        []
      end

      # Ensure a chat has the correct human-readable directory name within its type subdirectory.
      # Handles topic rename, type change, or no change needed.
      # Returns the dir_name that was set.
      def ensure_dir_name(state, chat_id, display_name, chat_type: nil)
        new_dir_name = build_dir_name(chat_id, display_name)
        entry = ensure_chat_entry(state, chat_id)
        current_dir_name = entry['dir_name']
        old_chat_type = entry['chat_type']

        if current_dir_name && (current_dir_name != new_dir_name || old_chat_type != chat_type)
          rename_chat_dir(
            current_dir_name, new_dir_name,
            old_type: type_dir(old_chat_type), new_type: type_dir(chat_type)
          )
        end

        entry['dir_name'] = new_dir_name
        entry['chat_type'] = chat_type
        new_dir_name
      end

      private

      def ensure_sync_dir
        FileUtils.mkdir_p(sync_dir)
      end

      # Ensure state has a chats hash and an entry for this chat_id, return the entry
      def ensure_chat_entry(state, chat_id)
        state['chats'] ||= {}
        state['chats'][chat_id] ||= {}
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

      # Rename/move a chat directory across type subdirectories.
      # No-op if old doesn't exist, new already exists, or paths are the same.
      def rename_chat_dir(old_name, new_name, old_type:, new_type:)
        chats_path = File.join(sync_dir, CHATS_DIR)
        old_path = File.join(chats_path, old_type, old_name)
        new_path = File.join(chats_path, new_type, new_name)
        return if old_path == new_path
        return unless File.directory?(old_path)
        return if File.exist?(new_path)

        FileUtils.mkdir_p(File.join(chats_path, new_type))
        File.rename(old_path, new_path)
      end

      # Write to a temp file then rename for atomicity
      def atomic_write(path, content)
        tmp_path = "#{path}.tmp"
        File.write(tmp_path, content)
        File.rename(tmp_path, path)
      end

      # Back up a corrupt file so data isn't lost, and warn the user
      def backup_corrupt_file(path)
        backup_path = "#{path}.corrupt.#{Time.now.strftime('%Y%m%d%H%M%S')}"
        File.rename(path, backup_path)
      rescue StandardError
        # If backup fails, still continue with empty state
        nil
      end
    end
  end
end
