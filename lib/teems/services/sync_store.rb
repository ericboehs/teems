# frozen_string_literal: true

module Teems
  module Services
    # Manages local sync state and file storage for the sync command.
    # Stores chat history as Markdown + JSON in XDG data directory.
    class SyncStore
      include SyncDirNaming

      SYNC_DIR = 'sync'
      STATE_FILE = 'sync_state.json'
      CHATS_DIR = 'chats'

      def initialize(xdg_paths: Support::XdgPaths.new)
        @xdg_paths = xdg_paths
      end

      def sync_dir = @sync_dir ||= File.join(@xdg_paths.data_dir, SYNC_DIR)

      def load_state
        path = File.join(sync_dir, STATE_FILE)
        return {} unless File.exist?(path)

        JSON.parse(File.read(path))
      rescue JSON::ParserError
        backup_corrupt_file(path)
        {}
      end

      def save_state(state)
        FileUtils.mkdir_p(sync_dir)
        atomic_write(File.join(sync_dir, STATE_FILE), JSON.pretty_generate(state))
      end

      def last_synced_time(state, chat_id)
        (ts = state.dig('chats', chat_id, 'last_synced_at')) ? Time.parse(ts) : nil
      rescue ArgumentError
        nil
      end

      def update_chat_state(state, chat_id, attrs:)
        ensure_chat_entry(state, chat_id).merge!(build_chat_fields(chat_id, attrs))
        state
      end

      def mark_unavailable(state, chat_id, display_name: nil, chat_type: nil)
        entry = ensure_chat_entry(state, chat_id)
        entry.merge!('unavailable' => true, 'unavailable_at' => Time.now.iso8601)
        entry['chat_type'] = chat_type if chat_type
        apply_display_name(entry, display_name, chat_id) if display_name
        state
      end

      def chat_unavailable?(state, chat_id) = state.dig('chats', chat_id, 'unavailable') == true

      def chat_dir(chat_id, state: nil)
        dir_name = state&.dig('chats', chat_id, 'dir_name') || sanitize_id(chat_id)
        File.join(sync_dir, CHATS_DIR, type_dir(state&.dig('chats', chat_id, 'chat_type')), dir_name)
      end

      def write_messages(chat_id, messages_md:, messages_json:, state: nil)
        dir = chat_dir(chat_id, state: state).tap { |path| FileUtils.mkdir_p(path) }
        atomic_write(File.join(dir, 'messages.md'), messages_md)
        atomic_write(File.join(dir, 'messages.json'), messages_json)
      end

      def write_chat_metadata(chat_id, metadata, state: nil)
        dir = chat_dir(chat_id, state: state).tap { |path| FileUtils.mkdir_p(path) }
        atomic_write(File.join(dir, 'chat_metadata.json'), JSON.pretty_generate(metadata))
      end

      def read_messages_json(chat_id, state: nil)
        path = File.join(chat_dir(chat_id, state: state), 'messages.json')
        return [] unless File.exist?(path)

        JSON.parse(File.read(path))
      rescue JSON::ParserError
        backup_corrupt_file(path)
        []
      end

      def ensure_dir_name(state, chat_id, display_name, chat_type: nil)
        new_dir_name = build_dir_name(chat_id, display_name)
        entry = ensure_chat_entry(state, chat_id)
        maybe_rename(entry, new_dir_name, chat_type)
        entry.merge!('dir_name' => new_dir_name, 'chat_type' => chat_type)
        new_dir_name
      end

      private

      def ensure_chat_entry(state, chat_id)
        (state['chats'] ||= {})[chat_id] ||= {}
      end

      def build_chat_fields(chat_id, attrs)
        display_name = attrs[:display_name]
        { 'last_synced_at' => attrs[:last_synced_at].iso8601, 'message_count' => attrs[:message_count],
          'display_name' => display_name, 'dir_name' => build_dir_name(chat_id, display_name),
          'chat_type' => attrs[:chat_type] }
      end

      def apply_display_name(entry, display_name, chat_id)
        entry.merge!('display_name' => display_name, 'dir_name' => build_dir_name(chat_id, display_name))
      end

      def maybe_rename(entry, new_dir_name, chat_type)
        current = entry['dir_name']
        current_type = entry['chat_type']
        return unless current && (current != new_dir_name || current_type != chat_type)

        perform_rename(current_type, current, chat_type, new_dir_name)
      end

      def perform_rename(old_type, old_name, new_type, new_name)
        old_path = chat_type_path(old_type, old_name)
        new_path = chat_type_path(new_type, new_name)
        return if old_path == new_path || !File.directory?(old_path) || File.exist?(new_path)

        FileUtils.mkdir_p(File.dirname(new_path)) && File.rename(old_path, new_path)
      end

      def chat_type_path(type, name) = File.join(sync_dir, CHATS_DIR, type_dir(type), name)

      def atomic_write(path, content)
        File.write("#{path}.tmp", content)
        File.rename("#{path}.tmp", path)
      end

      def backup_corrupt_file(path)
        File.rename(path, "#{path}.corrupt.#{Time.now.strftime('%Y%m%d%H%M%S')}")
      rescue StandardError
        nil
      end
    end
  end
end
