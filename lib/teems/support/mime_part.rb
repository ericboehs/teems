# frozen_string_literal: true

module Teems
  module Support
    # One MIME entity (RFC 2045/2046): headers, a decoded body, and parts when multipart.
    # Enough to read a decrypted S/MIME message: text and HTML bodies, attachment names,
    # nested multiparts.
    class MimePart
      SIGNED_MULTIPART = 'multipart/signed'
      PKCS7_TYPES = %w[application/pkcs7-mime application/x-pkcs7-mime].freeze

      attr_reader :headers, :body

      def self.parse(raw)
        raw = raw.b
        return new({}, raw.sub(/\A\r?\n/, '')) if raw.match?(/\A\r?\n/)

        head, body = raw.split(/\r?\n\r?\n/, 2)
        new(header_fields(head.to_s), body.to_s)
      end

      # Unfolded, names lowercased; the first of a repeated header wins
      def self.header_fields(head)
        head.gsub(/\r?\n[ \t]+/, ' ').split(/\r?\n/).each_with_object({}) do |line, fields|
          name, value = line.split(':', 2)
          fields[name.strip.downcase] ||= value.strip if value
        end
      end

      def initialize(headers, body)
        @headers = headers
        @body = body
      end

      def content_type = type_field.first.then { |type| type.empty? ? 'text/plain' : type }
      def multipart? = content_type.start_with?('multipart/')
      def text? = %w[text/plain text/html].include?(content_type)

      def parts
        boundary = type_field.last['boundary']
        return [] unless multipart? && boundary

        sections = body.split(/(?:\A|\r?\n)--#{Regexp.escape(boundary.b)}/).drop(1)
        sections.take_while { |section| !section.start_with?('--') }.map do |section|
          MimePart.parse(section.sub(/\A[ \t]*\r?\n/, ''))
        end
      end

      # The parts with no parts of their own, in order (this part when it is not multipart)
      def leaves = multipart? ? parts.flat_map(&:leaves) : [self]

      # [the content inside any signature layers, whether there were any]
      def unsigned
        inner = signed_content
        inner ? [inner.unsigned.first, true] : [self, false]
      end

      # The part a signature wraps (multipart/signed keeps its first part, opaque signed
      # PKCS #7 gives up the content inside it), or nil when this part is not signed
      def signed_content
        type = content_type
        return parts.first if type == SIGNED_MULTIPART

        MimePart.parse(SignedData.content(decoded)) if PKCS7_TYPES.include?(type)
      end

      # The body with its transfer encoding undone, as bytes
      def decoded
        case headers['content-transfer-encoding'].to_s.strip.downcase
        when 'base64' then body.unpack1('m')
        when 'quoted-printable' then body.gsub("\r\n", "\n").unpack1('M')
        else body
        end
      end

      # The decoded body as UTF-8 text, from its charset
      def text = MimeHeader.transcode(decoded, type_field.last['charset'])

      def filename
        params = MimeHeader.field(headers['content-disposition']).last
        MimeHeader.decoded(params, 'filename') || MimeHeader.decoded(type_field.last, 'name')
      end

      # Something a person attached, as opposed to the message body or an image shown inline
      def attachment?
        disposition = MimeHeader.field(headers['content-disposition']).first
        return true if disposition == 'attachment'

        disposition.empty? && !text? && !headers.key?('content-id') && !filename.to_s.empty?
      end

      private

      def type_field = @type_field ||= MimeHeader.field(headers['content-type'])
    end
  end
end
