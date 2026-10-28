# frozen_string_literal: true

module Teems
  module Services
    # A message's attachments during mail sync: lists them for its Markdown file and, with
    # the attachments option, saves file attachments under <folder>/attachments/<short id>/.
    # The listing is also where S/MIME encrypted mail shows itself: Exchange wraps it as TNEF,
    # so only an empty body and an smime.p7m attachment give it away.
    # One that fails the same way every time is skipped with a warning. Raising would fail
    # the page before its checkpoint, so every later run would stop there too.
    class MailSyncAttachments
      FILE_ATTACHMENT = '#microsoft.graph.fileAttachment'
      # 4xx errors that can succeed on a later run, unlike a missing or forbidden attachment
      RETRYABLE_STATUSES = [401, 408, 429].freeze
      # Local failures that can clear up (disk full, I/O), unlike a name the disk refuses
      RETRYABLE_ERRNOS = [Errno::ENOSPC, Errno::EIO, Errno::EDQUOT].freeze

      # names: attachment names for the Markdown; encrypted: an S/MIME envelope stood in for the body
      Listing = Data.define(:names, :encrypted)

      # options as for MailSyncEngine: attachments and on_warning
      def initialize(api:, store:, options:)
        @api = api
        @store = store
        @options = options
      end

      # The message's attachments other than inline images and, for a message with no body, its
      # S/MIME envelope: ciphertext, so neither listed nor saved as a file
      def listing(message, folder_path)
        envelopes, files = list(message).partition { |item| message.bodyless? && Models::MailEncryption.envelope?(item) }
        download_all(message, files, File.join(@store.folder_dir(folder_path), 'attachments')) if @options[:attachments]
        Listing.new(names: Models::MailMessage.attachment_names(files), encrypted: envelopes.any?)
      end

      def self.permanent?(error)
        return RETRYABLE_ERRNOS.none? { |errno| error.is_a?(errno) } unless error.is_a?(ApiError)

        status = error.status_code.to_i
        status.between?(400, 499) && !RETRYABLE_STATUSES.include?(status)
      end

      # The attachment's safe file name, or "name (2).ext" and so on when an earlier one in
      # the message took it (compared without case, as on macOS). The first keeps the plain
      # name, so files saved before stay where they are.
      def self.unique_name(name, taken)
        base = Formatters::FormatUtils.safe_filename(name.to_s)
        ext = File.extname(base)
        candidates = (2..).lazy.map { |number| "#{base.delete_suffix(ext)} (#{number})#{ext}" }
        unique = [base].lazy.chain(candidates).find { |candidate| !taken.include?(candidate.downcase) }
        taken << unique.downcase
        unique
      end

      private

      # A listing Graph refuses for good leaves the message without attachment names
      def list(message)
        @api.attachments(message.id).reject { |attachment| attachment['isInline'] }
      rescue ApiError => e
        skip(e, "attachments of message #{message.short_id}")
        []
      end

      # Item and reference attachments (attached emails, cloud links) have no file to save
      def download_all(message, files, attachments_dir)
        dir = File.join(attachments_dir, message.short_id)
        taken = Set.new
        files.each do |attachment|
          next unless attachment.fetch('@odata.type', FILE_ATTACHMENT) == FILE_ATTACHMENT

          download_or_skip(message, attachment, File.join(dir, self.class.unique_name(attachment['name'], taken)))
        end
      end

      def download_or_skip(message, attachment, path)
        download(message, attachment, path)
      rescue SystemCallError, ApiError => e
        skip(e, "attachment #{attachment['name'].to_s.inspect} of message #{message.short_id}")
      end

      def skip(error, what)
        raise error unless self.class.permanent?(error)

        @options[:on_warning]&.call("Skipped #{what}: #{error.message}")
      end

      # Skipped when a file of the same size is already there
      def download(message, attachment, path)
        attachment_id, size = attachment.values_at('id', 'size')
        return if File.size?(path) == size

        bytes = @api.attachment(message.id, attachment_id)['contentBytes']
        save(path, bytes) if bytes
      end

      def save(path, encoded)
        FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
        File.binwrite(path, encoded.unpack1('m'))
      end
    end
  end
end
