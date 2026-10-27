# frozen_string_literal: true

module Teems
  module Models
    # A mail message from Microsoft Graph (/me/messages). Text a sender controls is kept free
    # of terminal control characters (see Support::ControlChars), whichever way it is shown.
    MailMessage = Data.define(
      :id, :subject, :from, :to, :cc, :received_at, :is_read, :has_attachments, :flagged,
      :categories, :body_type, :body, :internet_message_id, :web_link, :protection
    ) do
      extend Parsing

      def self.from_api(data)
        new(**header_attrs(data), **body_attrs(data))
      end

      def self.header_attrs(data)
        { id: data['id'], subject: clean(data['subject']), from: recipient(data['from']),
          to: recipients(data['toRecipients']), cc: recipients(data['ccRecipients']),
          received_at: parse_time(data['receivedDateTime']), is_read: data['isRead'] == true,
          has_attachments: data['hasAttachments'] == true, flagged: Hash(data['flag'])['flagStatus'] == 'flagged' }
      end

      def self.body_attrs(data)
        body = data['body'] || {}
        { categories: Array(data['categories']).map { |category| clean(category) },
          body_type: body['contentType'].to_s.downcase, body: clean(body['content']),
          internet_message_id: data['internetMessageId'], web_link: data['webLink'],
          protection: protection(data['internetMessageHeaders']) }
      end

      # 'purview' (rights-managed, Content-Class rpmsg.message), 'smime' (an S/MIME envelope),
      # or nil, from the internet headers. Drafts have none, so nil is not proof of plain mail.
      def self.protection(headers)
        fields = Array(headers).to_h { |header| [header['name'].to_s.downcase, header['value'].to_s.downcase] }
        return 'purview' if fields['content-class'].to_s.start_with?('rpmsg.message')

        type, params = Support::MimeHeader.field(fields['content-type'])
        'smime' if Support::MimePart::PKCS7_TYPES.include?(type) && params['smime-type'] != 'signed-data'
      end

      def self.recipient(data)
        email = Hash(data)['emailAddress'] || {}
        { name: clean(email['name']), address: clean(email['address']) }
      end

      def self.clean(text) = Support::ControlChars.strip(text)

      def self.recipients(list) = Array(list).map { |entry| recipient(entry) }

      # Names of the attachments a person attached (inline images left out)
      def self.attachment_names(attachments)
        attachments.reject { |item| item['isInline'] }.map { |item| clean(item['name']) }
      end

      # Short handle shown in lists; `teems mail read` accepts it after a list or search
      def short_id = self.class.short_id(id)

      def self.short_id(id) = Digest::SHA256.hexdigest(id.to_s)[0, 8]

      def read? = is_read
      def status = is_read ? 'Read' : 'Unread'
      def html? = body_type == 'html'

      # What to show instead of a protected message's body, or nil for plain mail
      def protection_note = self.class::PROTECTION_NOTES[protection]

      # True for S/MIME encrypted mail, which Graph returns with no body (the envelope is an attachment)
      def bodyless? = body.strip.empty?

      def from_label = self.class.label(from)
      def from_display = self.class.display(from)
      def to_display = to.map { |entry| self.class.display(entry) }.join(', ')
      def cc_display = cc.map { |entry| self.class.display(entry) }.join(', ')

      def self.label(entry)
        name = entry[:name]
        name.empty? ? entry[:address] : name
      end

      def self.display(entry)
        name, address = entry.values_at(:name, :address)
        return address if name.empty? || name == address
        return name if address.empty?

        "#{name} <#{address}>"
      end

      # Plain-text body with a links footer; plain-text messages come back unchanged
      def text_body
        return Formatters::HtmlText.convert(body) if html?

        Formatters::HtmlText::Result.new(text: body.gsub("\r\n", "\n").rstrip, footer: '')
      end

      # short id, received (local), sender, one-line subject
      def list_columns
        [short_id, Formatters::MailDates.short(received_at), from_label, subject.tr("\r\n", '  ')]
      end

      # Tab-separated: full id, received (ISO 8601 local), sender address, subject, Read/Unread
      def tsv_row
        [id, Formatters::MailDates.iso(received_at), from[:address], subject, status]
          .map { |field| field.to_s.tr("\t\r\n", '   ') }.join("\t")
      end

      # Header lines for `teems mail read`, in Outlook's order; Cc, Categories and Attachments
      # only when present. notes (e.g. Encryption) go just before the ID.
      def headers(attachments: [], notes: {})
        cc_line = cc_display
        names = attachments.join(', ')
        { 'Subject' => subject, 'From' => from_display, 'To' => to_display, 'Cc' => cc_line,
          'Date' => Formatters::MailDates.long(received_at), 'Categories' => categories.join(', '),
          'Status' => status, 'Attachments' => names, **notes, 'ID' => id }
          .reject { |name, value| value.empty? && %w[Cc Categories Attachments].include?(name) }
      end

      # `teems mail read` output: header block, blank line, plain-text body with links at the end
      def to_text(attachments: [], notes: {})
        lines = headers(attachments: attachments, notes: notes).map { |name, value| "#{name}: #{value}" }
        [*lines, '', text_body.to_s].join("\n")
      end

      # JSON for `teems mail read --json`: summary plus plain-text body and links
      def full_json_hash(attachments: [])
        text = text_body
        to_json_hash.merge(body: text.text, links: text.footer, attachments: attachments)
      end

      def to_json_hash
        { id: id, short_id: short_id, subject: subject, from: from, to: to, cc: cc,
          received_at: received_at&.iso8601, is_read: is_read, has_attachments: has_attachments, flagged: flagged,
          categories: categories, internet_message_id: internet_message_id, web_link: web_link }
      end
    end

    # Constants set inside Data.define's block would land on Models, so they go here
    MailMessage::PROTECTION_NOTES = {
      'purview' => 'Protected by Purview; open in Outlook',
      'smime' => 'S/MIME encrypted; read it with teems mail read --decrypt'
    }.freeze
  end
end
