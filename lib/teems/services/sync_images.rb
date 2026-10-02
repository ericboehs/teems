# frozen_string_literal: true

module Teems
  module Services
    # Inline images saved beside a synced chat (`teems sync --images`) and linked from messages.md.
    # Files are named by AMS object id, so images already on disk are never fetched again.
    class SyncImages
      DIR = 'images'

      # { file stem => file name } for the images already saved for a chat
      def self.saved(chat_dir)
        dir = File.join(chat_dir, DIR)
        return {} unless File.directory?(dir)

        Dir.children(dir).reject { |name| name.end_with?('.tmp') }.to_h { |name| [File.basename(name, '.*'), name] }
      end

      # Callable for MarkdownFormatter: relative path of a saved image, or nil
      def self.link_resolver(chat_dir)
        saved = saved(chat_dir)
        lambda do |image|
          name = saved[image.file_stem]
          "#{DIR}/#{name}" if name
        end
      end

      def initialize(downloader:, output: nil)
        @downloader = downloader
        @output = output
      end

      # Downloads images not yet on disk; returns how many were saved
      def save(chat_dir, messages)
        existing = self.class.saved(chat_dir)
        pending = messages.flat_map(&:images).uniq(&:file_stem).reject { |image| existing.key?(image.file_stem) }
        pending.sum { |image| save_image(File.join(chat_dir, DIR), image) }
      end

      private

      def save_image(dir, image)
        stem = image.file_stem
        result = @downloader.fetch(image)
        FileUtils.mkdir_p(dir)
        path = File.join(dir, "#{stem}.#{result.extension}")
        File.binwrite("#{path}.tmp", result.body)
        File.rename("#{path}.tmp", path)
        1
      rescue StandardError => e
        @output&.warn("  Could not download image #{stem}: #{e.message}")
        0
      end
    end
  end
end
