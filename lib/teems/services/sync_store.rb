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
      rescue StandardError
        nil
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
      def last_synced_time(state, chat_id)
        ts = state.dig('chats', chat_id, 'last_synced_at')
        return nil unless ts && sync_dir

        Time.parse(ts)
      rescue ArgumentError
        nil
      end

      def chat_unavailable?(state, chat_id)
        return false unless sync_dir

        state.dig('chats', chat_id, 'unavailable') == true
      end
    end

    # Chat state mutation operations for SyncStore
    module SyncStateMutation
      def update_chat_state(state, chat_id, attrs:)
        display_name, synced_at, count, chat_type =
          attrs.values_at(:display_name, :last_synced_at, :message_count, :chat_type)
        entry = (state['chats'] ||= {})[chat_id] ||= {}
        entry.merge!('last_synced_at' => synced_at.iso8601, 'message_count' => count,
                     'display_name' => display_name, 'chat_type' => chat_type,
                     'dir_name' => build_dir_name(chat_id, display_name))
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

      def apply_unavailable(entry)
        entry.merge!('unavailable' => true, 'unavailable_at' => Time.now.iso8601)
      end

      def apply_chat_type(entry, chat_type)
        entry['chat_type'] = chat_type if chat_type
      end

      def apply_display_info(entry, chat_id, display_name)
        return unless display_name

        entry.merge!('display_name' => display_name,
                     'dir_name' => build_dir_name(chat_id, display_name))
      end
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

    # Directory rename helpers for SyncStore
    module SyncRenameOps
      private

      def rename_entry_dir(entry, new_dir_name, chat_type)
        old_name = entry['dir_name']
        old_type = entry['chat_type']
        if old_name && (old_name != new_dir_name || old_type != chat_type)
          move_chat_dir(chat_type_path(old_type, old_name),
                        chat_type_path(chat_type, new_dir_name))
        end
        entry.merge!('dir_name' => new_dir_name, 'chat_type' => chat_type)
      end

      def move_chat_dir(old_path, new_path)
        return if old_path == new_path || !File.directory?(old_path) || File.exist?(new_path)

        FileUtils.mkdir_p(File.dirname(new_path))
        File.rename(old_path, new_path)
      end

      def chat_type_path(type, name) = File.join(sync_dir, SyncStore::CHATS_DIR, type_dir(type), name)
    end

    # Manages local sync state and file storage for the sync command.
    # Stores chat history as Markdown + JSON in XDG data directory.
    class SyncStore
      include SyncDirNaming
      include SyncFileOps
      include SyncStateQuery
      include SyncStateMutation
      include SyncChatDir
      include SyncChatWrite
      include SyncRenameOps

      SYNC_DIR = 'sync'
      STATE_FILE = 'sync_state.json'
      CHATS_DIR = 'chats'

      def initialize(xdg_paths: Support::XdgPaths.new)
        @xdg_paths = xdg_paths
      end

      def sync_dir = @sync_dir ||= File.join(@xdg_paths.data_dir, SYNC_DIR)

      def load_state
        load_json_or_default(File.join(sync_dir, STATE_FILE), {})
      end

      def save_state(state)
        FileUtils.mkdir_p(sync_dir)
        atomic_write(File.join(sync_dir, STATE_FILE), JSON.pretty_generate(state))
      end

      def ensure_dir_name(state, chat_info:)
        chat_id, display_name, chat_type = chat_info.values_at(:chat_id, :display_name, :chat_type)
        new_dir_name = build_dir_name(chat_id, display_name)
        entry = (state['chats'] ||= {})[chat_id] ||= {}
        rename_entry_dir(entry, new_dir_name, chat_type)
        new_dir_name
      end
    end
  end
end
