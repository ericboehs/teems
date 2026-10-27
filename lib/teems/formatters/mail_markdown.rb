# frozen_string_literal: true

module Teems
  module Formatters
    # Renders a synced mail message as Markdown with YAML frontmatter. The fields and layout
    # follow the files outlook-cli wrote to ~/Mail, so md2maildir and search indexes keep working.
    class MailMarkdown
      SLUG_MAX = 80

      def self.filename(message)
        date = message.received_at&.getlocal&.strftime('%Y-%m-%d') || 'unknown-date'
        slug = message.subject.unicode_normalize(:nfkc).gsub(/[^[:alnum:]]+/, '-')[0, SLUG_MAX].gsub(/\A-+|-+\z/, '')
        "#{date}-#{slug.empty? ? 'no-subject' : slug}-#{message.short_id}.md"
      end

      def self.render(message, folder:, attachments: []) = new(message, folder, attachments).render

      def initialize(message, folder, attachments)
        @message = message
        @folder = folder
        @attachments = attachments
      end

      def render
        [frontmatter, '', "# #{@message.subject}", '', "**From:** #{@message.from_display}",
         "**To:** #{addresses(@message.to)}", "**Date:** #{MailDates.long(@message.received_at)}",
         '', '---', '', *protection_lines, "#{@message.text_body}\n"].join("\n")
      end

      private

      def frontmatter
        fields = { 'id' => @message.id, **quoted_fields, 'status' => @message.status.downcase,
                   'attachments' => quote(@attachments.join(', ')),
                   'internet_message_id' => quote(@message.internet_message_id), **protection_field }
        ['---', *fields.map { |key, value| "#{key}: #{value}" }, '---'].join("\n")
      end

      def quoted_fields
        received = @message.received_at
        fields = { 'subject' => @message.subject, 'from' => @message.from_display, 'to' => addresses(@message.to),
                   'cc' => addresses(@message.cc), 'date' => MailDates.long(received),
                   'received' => MailDates.iso(received), 'folder' => @folder,
                   'categories' => @message.categories.join(', ') }
        fields.transform_values { |value| quote(value) }
      end

      # Protected mail only, so files of plain mail stay as outlook-cli wrote them
      def protection_field
        kind = @message.protection
        kind ? { 'protection' => quote(kind) } : {}
      end

      # A note above the body of protected mail, whose body is empty or Microsoft's placeholder;
      # Purview mail's links to Outlook on the web, which opens it
      def protection_lines
        note = @message.protection_note
        return [] unless note

        link = @message.protection == 'purview' && @message.web_link
        [link ? "> #{note}: <#{link}>" : "> #{note}", '']
      end

      def addresses(list) = list.map { |entry| entry[:address] }.reject(&:empty?).join(', ')

      # JSON strings are valid YAML double-quoted scalars
      def quote(value) = JSON.generate(value.to_s)
    end
  end
end
