# frozen_string_literal: true

module Teems
  module Services
    # Directory naming helpers for SyncStore.
    #
    # Every chat directory name ends with the chat's full sanitized ID, so two chats can never
    # share a directory. Older teems versions keyed generic labels ("Group Chat") by a 20-character
    # ID prefix and named chats by their title alone, which merged unrelated chats; see
    # SyncDirOwnership for how directories left over from that are handled.
    module SyncDirNaming
      MAX_DIR_NAME_LENGTH = 100
      # Most filesystems limit one path component to 255 bytes
      MAX_DIR_NAME_BYTES = 255
      TYPE_DIRS = {
        'oneOnOne' => 'dms', 'group' => 'groups', 'meeting' => 'meetings',
        'channel' => 'channels', 'space' => 'spaces'
      }.freeze

      module_function

      def type_dir(chat_type) = TYPE_DIRS[chat_type] || 'other'

      private

      def sanitize_id(id)
        id.gsub(/[:@]/, '_')
      end

      def sanitize_display_name(name, max_bytes: MAX_DIR_NAME_BYTES)
        return nil if name.to_s.strip.empty?

        sanitized = name.strip.gsub(%r{[/\\:*?"<>|]}, '-').gsub(/\s+/, ' ')[0, MAX_DIR_NAME_LENGTH]
        sanitized = sanitized.byteslice(0, max_bytes).scrub('').gsub(/[\s.]+\z/, '')
        sanitized.empty? ? nil : sanitized
      end

      # "<display name> (<full sanitized chat ID>)", or just the sanitized ID when there is no name
      def build_dir_name(chat_id, display_name)
        safe_id = sanitize_id(chat_id)
        label_bytes = [MAX_DIR_NAME_BYTES - safe_id.bytesize - ' ()'.bytesize, 0].max
        label = sanitize_display_name(display_name, max_bytes: label_bytes)
        label ? "#{label} (#{safe_id})" : safe_id
      end
    end
  end
end
