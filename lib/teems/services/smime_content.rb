# frozen_string_literal: true

module Teems
  module Services
    # What a decrypted S/MIME message says: its body (HTML when there is one, as Outlook
    # shows it), the names of its attachments, and whether it was also signed. A signature
    # is unwrapped to reach the content but not checked.
    class SmimeContent
      # body: text in body_type ('html' or 'text'); attachments: file names; signed: true/false
      Result = Data.define(:body, :body_type, :attachments, :signed)
      BODY_TYPES = %w[text/html text/plain].freeze

      def self.parse(mime) = new.parse(Support::MimePart.parse(mime))

      def parse(entity)
        content, signed = entity.unsigned
        leaves = content.leaves
        body = body_part(leaves)
        Result.new(body: body ? body.text : '', body_type: body&.content_type == 'text/html' ? 'html' : 'text',
                   attachments: leaves.select(&:attachment?).map { |part| part.filename.to_s }, signed: signed)
      end

      private

      def body_part(leaves)
        leaves.select { |part| part.text? && !part.attachment? }
              .min_by { |part| BODY_TYPES.index(part.content_type) }
      end
    end
  end
end
