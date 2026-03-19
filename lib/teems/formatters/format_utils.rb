# frozen_string_literal: true

module Teems
  module Formatters
    # Shared stateless formatting utilities used across commands and formatters
    module FormatUtils
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

      def safe_filename(name)
        base = File.basename(name)
        base.empty? ? 'file' : base
      end

      def attachment_name(att)
        att.is_a?(Hash) ? (att['fileName'] || att['name'] || 'file') : att.to_s
      end

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
