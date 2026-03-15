# frozen_string_literal: true

module Teems
  module Services
    # Directory naming helpers for SyncStore
    module SyncDirNaming
      GENERIC_LABELS = ['Group Chat', '1:1 Chat', 'Meeting Chat', 'Channel', 'Space'].freeze
      MAX_DIR_NAME_LENGTH = 100
      TYPE_DIRS = {
        'oneOnOne' => 'dms', 'group' => 'groups', 'meeting' => 'meetings',
        'channel' => 'channels', 'space' => 'spaces'
      }.freeze

      module_function

      def type_dir(chat_type) = TYPE_DIRS[chat_type] || 'other'

      private

      def sanitize_id(id) = id.gsub(/[:@]/, '_')

      def sanitize_display_name(name)
        return nil if name.to_s.strip.empty?

        sanitized = name.strip.gsub(%r{[/\\:*?"<>|]}, '-').gsub(/\s+/, ' ')
        sanitized = sanitized[0, MAX_DIR_NAME_LENGTH].gsub(/[\s.]+\z/, '')
        sanitized.empty? ? nil : sanitized
      end

      def build_dir_name(chat_id, display_name)
        sanitized = sanitize_display_name(display_name)
        return sanitize_id(chat_id) unless sanitized
        return sanitized unless GENERIC_LABELS.include?(display_name&.strip)

        "#{sanitized} (#{sanitize_id(chat_id)[0, 20]})"
      end
    end
  end
end
