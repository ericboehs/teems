# frozen_string_literal: true

module Teems
  module Services
    # File I/O helpers for SyncStore: atomic writes, backup, and JSON persistence
    module SyncFileOps
      private

      def atomic_write(path, content)
        tmp_path = "#{path}.tmp"
        File.write(tmp_path, content)
        File.rename(tmp_path, path)
      end

      def backup_corrupt_file(path)
        backup_path = "#{path}.corrupt.#{Time.now.strftime('%Y%m%d%H%M%S')}"
        File.rename(path, backup_path)
      rescue SystemCallError, IOError => e
        warn "teems: Could not back up corrupt file #{path}: #{e.message}"
      end

      def load_json_or_default(path, default)
        return default unless File.exist?(path)

        JSON.parse(File.read(path))
      rescue JSON::ParserError
        backup_corrupt_file(path)
        default
      end
    end

    # Chat state query operations for SyncStore
    module SyncStateQuery
      private

      def parse_synced_at(timestamp)
        return nil unless timestamp

        Time.parse(timestamp)
      rescue ArgumentError
        nil
      end

      def chat_entry_unavailable?(entry)
        entry&.dig('unavailable') == true
      end
    end

    # Chat state mutation operations for SyncStore
    module SyncStateMutation
      # A nil display name or chat type (sync --chat) keeps the stored one
      def update_chat_state(state, chat_id, attrs:)
        entry = (state['chats'] ||= {})[chat_id] ||= {}
        dir_name = dir_name_for(entry, chat_id, attrs[:display_name])
        entry.merge!(synced_fields(attrs, dir_name)).delete('resync_from')
        state
      end

      def mark_unavailable(state, chat_id, **opts)
        entry = (state['chats'] ||= {})[chat_id] ||= {}
        apply_unavailable(entry)
        apply_chat_type(entry, opts[:chat_type])
        apply_display_info(entry, chat_id, opts[:display_name])
        state
      end

      private

      def synced_fields(attrs, dir_name)
        display_name, synced_at, count, chat_type =
          attrs.values_at(:display_name, :last_synced_at, :message_count, :chat_type)
        { 'last_synced_at' => synced_at.iso8601, 'message_count' => count, 'display_name' => display_name,
          'chat_type' => chat_type, 'dir_name' => dir_name }.compact
      end

      def apply_unavailable(entry)
        entry.merge!('unavailable' => true, 'unavailable_at' => Time.now.iso8601)
      end

      def apply_chat_type(entry, chat_type)
        entry['chat_type'] = chat_type if chat_type
      end

      def apply_display_info(entry, chat_id, display_name)
        return unless display_name

        entry.merge!('display_name' => display_name, 'dir_name' => dir_name_for(entry, chat_id, display_name))
      end

      # ensure_chat_dir owns the directory name; this only fills it in for callers that skipped it
      def dir_name_for(entry, chat_id, display_name) = entry['dir_name'] || build_dir_name(chat_id, display_name)
    end

    # Chat directory resolution for SyncStore
    module SyncChatDir
      def chat_dir(chat_id, state: nil)
        chat_entry = state&.dig('chats', chat_id)
        dir_name = chat_entry&.dig('dir_name') || sanitize_id(chat_id)
        File.join(sync_dir, SyncStore::CHATS_DIR, type_dir(chat_entry&.dig('chat_type')), dir_name)
      end

      def read_messages_json(chat_id, state: nil)
        load_json_or_default(File.join(chat_dir(chat_id, state: state), 'messages.json'), [])
      end
    end

    # Chat file write operations for SyncStore
    module SyncChatWrite
      def write_messages(chat_id, **opts)
        md, json, state = opts.values_at(:messages_md, :messages_json, :state)
        write_to_dir(chat_dir(chat_id, state: state),
                     'messages.md' => md, 'messages.json' => json)
      end

      def write_chat_metadata(chat_id, metadata, state: nil)
        dir = chat_dir(chat_id, state: state)
        write_to_dir(dir, 'chat_metadata.json' => JSON.pretty_generate(metadata))
      end

      private

      def write_to_dir(dir, files)
        FileUtils.mkdir_p(dir)
        files.each { |name, content| atomic_write(File.join(dir, name), content) }
      end
    end

    # Manages local sync state and file storage for the sync command.
    # Stores chat history as Markdown + JSON in XDG data directory.
    class SyncStore
      include SyncDirNaming
      include SyncDirOwnership
      include SyncDirPlanning
      include SyncFileOps
      include SyncStateQuery
      include SyncStateMutation
      include SyncChatDir
      include SyncChatWrite

      SYNC_DIR = 'sync'
      STATE_FILE = 'sync_state.json'
      CHATS_DIR = 'chats'

      def initialize(xdg_paths: Support::XdgPaths.new)
        @xdg_paths = xdg_paths
      end

      def sync_dir = @sync_dir ||= File.join(@xdg_paths.data_dir, SYNC_DIR)

      def last_synced_time(state, chat_id)
        parse_synced_at(state.dig('chats', chat_id, 'last_synced_at'))
      end

      def chat_unavailable?(state, chat_id)
        chat_entry = state.dig('chats', chat_id)
        chat_entry_unavailable?(chat_entry)
      end

      def load_state
        load_json_or_default(File.join(sync_dir, STATE_FILE), {})
      end

      def save_state(state)
        FileUtils.mkdir_p(sync_dir)
        atomic_write(File.join(sync_dir, STATE_FILE), JSON.pretty_generate(state))
      end
    end
  end
end
