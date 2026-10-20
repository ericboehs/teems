# frozen_string_literal: true

module Teems
  module Formatters
    # Shared stateless formatting utilities used across commands and formatters
    module FormatUtils
      # Longest file name most filesystems allow, in bytes
      NAME_MAX = 255
      # Names File.basename can return that are not a file in the directory
      UNSAFE_NAMES = ['', '.', '..', '/'].freeze
      # Longer "extensions" are just dots in a long name, and are cut with the rest of it
      MAX_EXTENSION = 16

      module_function

      def truncate(text, max = 120)
        text.length > max ? "#{text[0...max]}..." : text
      end

      def format_bytes(bytes)
        if bytes >= 1_048_576 then "#{(bytes / 1_048_576.0).round(1)} MB"
        elsif bytes >= 1024 then "#{(bytes / 1024.0).round(1)} KB"
        else "#{bytes} B"
        end
      end

      # A name safe to join onto a directory: no path or control characters, not "." or "..",
      # and short enough for the filesystem (keeping the extension when it has to be cut)
      def safe_filename(name)
        base = File.basename(name.to_s.scrub('').gsub(/[[:cntrl:]]/, ''))
        UNSAFE_NAMES.include?(base) ? 'file' : fit_filename(base)
      end

      def fit_filename(base)
        return base if base.bytesize <= NAME_MAX

        ext = kept_extension(base)
        "#{base.delete_suffix(ext).byteslice(0, NAME_MAX - ext.bytesize).scrub('')}#{ext}"
      end

      def kept_extension(base)
        ext = File.extname(base)
        ext.bytesize > MAX_EXTENSION ? '' : ext
      end

      def attachment_name(att)
        att.is_a?(Hash) ? (att['fileName'] || att['name'] || 'file') : att.to_s
      end

      # One-line description of a message's inline images, e.g. "image (881x179), chart"
      def image_summary(images) = images.map(&:label).join(', ')

      def format_single_reaction(reaction, emoji_map)
        type = reaction[:type]
        emoji = emoji_map[type] || type
        count = reaction[:count] || 1
        count > 1 ? "#{emoji}(#{count})" : emoji.to_s
      end

      def format_time(time_string)
        return '' unless time_string

        Time.parse(time_string).getlocal.strftime('[%Y-%m-%d %H:%M]')
      rescue ArgumentError
        ''
      end

      def format_end_time(start_time, end_time)
        fmt = (end_time - start_time) >= 86_400 ? '%b %-d, %-I:%M %p' : '%-I:%M %p'
        end_time.strftime(fmt)
      end

      def build_time_range(start_str, end_match)
        start_time = Time.parse(start_str).getlocal
        end_time = end_match ? Time.parse(end_match[1]).getlocal : nil
        [start_time, end_time]
      end
    end
  end
end
