# frozen_string_literal: true

module Teems
  module Services
    # A message's attachments during mail sync: lists them for its Markdown file and, with
    # the attachments option, saves file attachments under <folder>/attachments/<short id>/.
    # One that fails the same way every time is skipped with a warning. Raising would fail
    # the page before its checkpoint, so every later run would stop there too.
    class MailSyncAttachments
      FILE_ATTACHMENT = '#microsoft.graph.fileAttachment'
      # 4xx errors that can succeed on a later run, unlike a missing or forbidden attachment
      RETRYABLE_STATUSES = [401, 408, 429].freeze
      # Local failures that can clear up (disk full, I/O), unlike a name the disk refuses
      RETRYABLE_ERRNOS = [Errno::ENOSPC, Errno::EIO, Errno::EDQUOT].freeze

      # options as for MailSyncEngine: attachments and on_warning
      def initialize(api:, store:, options:)
        @api = api
        @store = store
        @options = options
      end

      # Names of the message's attachments, other than inline images
      def names(message, folder_path)
        files = list(message)
        download_all(message, files, File.join(@store.folder_dir(folder_path), 'attachments')) if @options[:attachments]
        Models::MailMessage.attachment_names(files)
      end

      def self.permanent?(error)
        return RETRYABLE_ERRNOS.none? { |errno| error.is_a?(errno) } unless error.is_a?(ApiError)

        status = error.status_code.to_i
        status.between?(400, 499) && !RETRYABLE_STATUSES.include?(status)
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
        files.each do |attachment|
          type = attachment.fetch('@odata.type', FILE_ATTACHMENT)
          download_or_skip(message, attachment, dir) if type == FILE_ATTACHMENT
        end
      end

      def download_or_skip(message, attachment, dir)
        download(message, attachment, dir)
      rescue SystemCallError, ApiError => e
        skip(e, "attachment #{attachment['name'].to_s.inspect} of message #{message.short_id}")
      end

      def skip(error, what)
        raise error unless self.class.permanent?(error)

        @options[:on_warning]&.call("Skipped #{what}: #{error.message}")
      end

      # Skipped when a file of the same size is already there
      def download(message, attachment, dir)
        attachment_id, name, size = attachment.values_at('id', 'name', 'size')
        path = File.join(dir, Formatters::FormatUtils.safe_filename(name.to_s))
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
