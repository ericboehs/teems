# frozen_string_literal: true

module Teems
  module Services
    # Finds Markdown files an older outlook-cli sync wrote for the same message, so syncing
    # into an existing ~/Mail adopts them instead of writing duplicates. outlook-cli named
    # messages by AppleScript integer IDs, so files are matched on received time (to the
    # second, in local time, the exact second first), subject (ignoring case and
    # punctuation) and sender address. The sender matters for bursts such as a dozen
    # "Automatic reply" messages arriving in the same couple of seconds.
    class MailLegacyFiles
      DATE_FORMATS = ['%A, %B %d, %Y at %I:%M:%S %p', '%B %d, %Y at %I:%M:%S %p', '%m/%d/%Y %I:%M:%S %p'].freeze
      HEADER_BYTES = 4096
      # Long recipient lists push the closing --- past HEADER_BYTES; give up beyond this
      MAX_HEADER_BYTES = 65_536

      def initialize(dir, known_files: [])
        @dir = dir
        @known = known_files.to_set
        @entries = nil
      end

      # File name of an unclaimed legacy file for this message, or nil. Each file matches once.
      def match(message)
        received = message.received_at
        return unless received

        wanted = { subject: subject_key(message.subject), sender: message.from[:address].downcase }
        candidates = [0, -1, 1].flat_map { |offset| entries.fetch(received.to_i + offset, []) }
        found = candidates.find { |candidate| same_message?(candidate, wanted) }
        found&.store(:claimed, true)
        found&.fetch(:file)
      end

      def count = entries.sum { |_time, list| list.length }

      private

      # Unclaimed, same subject, and the same sender unless one side has no address
      def same_message?(candidate, wanted)
        return false if candidate[:claimed] || candidate[:subject] != wanted[:subject]

        senders = [candidate[:sender], wanted[:sender]]
        senders.include?('') || senders.uniq.one?
      end

      def entries
        @entries ||= Dir.glob(File.join(@dir, '*.md')).filter_map { |path| legacy_entry(path) }
                                                      .group_by { |entry| entry[:time] }
      end

      def legacy_entry(path)
        file = File.basename(path)
        return if @known.include?(file)

        fields = frontmatter(path)
        return unless fields['id'].to_s.match?(/\A\d+\z/)

        time = parse_date(fields['date'].to_s)
        time && { time: time.to_i, subject: subject_key(fields['subject'].to_s), sender: sender_key(fields['from']),
                  file: file }
      end

      def frontmatter(path)
        block = frontmatter_block(path, HEADER_BYTES) || frontmatter_block(path, MAX_HEADER_BYTES)
        block.to_s.scan(/^(\w+):[ \t]*(.*)$/).to_h.transform_values { |value| unquote(value) }
      end

      def frontmatter_block(path, bytes)
        head = File.read(path, bytes).to_s.force_encoding(Encoding::UTF_8).scrub('')
        head[/\A---\n(.*?)\n---/m, 1]
      end

      def unquote(value) = value.strip.delete_prefix('"').delete_suffix('"').gsub('\\"', '"')

      def parse_date(text)
        text = text.tr("\u202f\u00a0", '  ').squeeze(' ').strip
        DATE_FORMATS.each do |format|
          return Time.strptime(text, format)
        rescue ArgumentError
          next
        end
        nil
      end

      def subject_key(subject) = subject.downcase.gsub(/[^[:alnum:]]/, '')

      # Address from "Name <address>" (or a bare address), lower case; '' when there is none
      def sender_key(from)
        text = from.to_s
        address = text[/<([^<>@\s]+@[^<>\s]+)>/, 1] || text[/\A[^<>@\s]+@[^<>\s]+\z/]
        address.to_s.downcase
      end
    end
  end
end
