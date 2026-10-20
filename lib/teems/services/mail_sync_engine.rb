# frozen_string_literal: true

module Teems
  module Services
    # Incremental mail sync for one folder at a time using Graph delta queries. Each page is
    # written and checkpointed before the next is fetched, so an interrupted run resumes where
    # it stopped. Messages that leave a folder keep their file; the index records removed_at.
    class MailSyncEngine
      FILE_ATTACHMENT = '#microsoft.graph.fileAttachment'
      # Graph's answers to a delta link it can no longer use: 410 Gone, or 400 with
      # syncStateNotFound / resyncRequired
      RESYNC_STATUSES = [400, 410].freeze
      # 4xx errors that can succeed on a later run, unlike a missing or forbidden attachment
      RETRYABLE_STATUSES = [401, 408, 429].freeze

      # options: since (Time limiting the first sync of a folder; nil syncs everything),
      # attachments (also download file attachments) and on_warning (called with problems
      # that are skipped rather than raised)
      def initialize(api:, store:, options: {})
        @api = api
        @store = store
        @options = options
        @folder = nil
      end

      # Syncs one Models::MailFolder; returns counts keyed by MailSyncFolder::STAT_KEYS.
      # A delta link Graph rejects (RESYNC_STATUSES) starts the folder over once.
      def sync(folder)
        attempts = 0
        begin
          @folder = MailSyncFolder.new(folder, @store)
          run_delta
        rescue ApiError => e
          raise unless RESYNC_STATUSES.include?(e.status_code) && (attempts += 1) == 1

          @folder.reset_state
          retry
        end
        @folder.stats
      end

      private

      # Each page is checkpointed, so an interrupted run resumes from its last page
      def run_delta
        link = @folder.resume_link
        loop do
          page = fetch_page(link)
          page['value'].to_a.each { |item| process(item) }
          @folder.checkpoint(page)
          link = page['@odata.nextLink']
          break unless link
        end
      end

      def fetch_page(link) = link ? @api.delta_page(link) : @api.delta(folder: @folder.id, since: @options[:since])

      def process(item)
        return @folder.mark_removed(item['id']) if item.key?('@removed')

        message = Models::MailMessage.from_api(item)
        legacy_file = @folder.legacy_file(message)
        return @folder.adopt(message, legacy_file) if legacy_file

        write(message)
      end

      def write(message)
        path = @folder.path
        file = @folder.file_for(message)
        names = message.has_attachments ? attachment_names(message) : []
        content = Formatters::MailMarkdown.render(message, folder: path, attachments: names)
        @folder.count(@store.write_message(path, file, content))
        @folder.record(message, file)
      end

      def attachment_names(message)
        files = @api.attachments(message.id).reject { |attachment| attachment['isInline'] }
        download_attachments(message, files) if @options[:attachments]
        Models::MailMessage.attachment_names(files)
      end

      # Item and reference attachments (attached emails, cloud links) have no file to save
      def download_attachments(message, files)
        dir = File.join(@store.folder_dir(@folder.path), 'attachments', message.short_id)
        files.each do |attachment|
          type = attachment.fetch('@odata.type', FILE_ATTACHMENT)
          download_or_skip(message, attachment, dir) if type == FILE_ATTACHMENT
        end
      end

      # An attachment that fails the same way every time is skipped with a warning. Raising
      # would fail the page before its checkpoint, so every later run would stop there too.
      def download_or_skip(message, attachment, dir)
        download(message, attachment, dir)
      rescue SystemCallError, ApiError => e
        raise unless permanent?(e)

        name = attachment['name'].to_s.inspect
        @options[:on_warning]&.call("Skipped attachment #{name} of message #{message.short_id}: #{e.message}")
      end

      def permanent?(error)
        return true unless error.is_a?(ApiError)

        status = error.status_code.to_i
        status.between?(400, 499) && !RETRYABLE_STATUSES.include?(status)
      end

      # Skipped when a file of the same size is already there
      def download(message, attachment, dir)
        attachment_id, name, size = attachment.values_at('id', 'name', 'size')
        path = File.join(dir, Formatters::FormatUtils.safe_filename(name.to_s))
        return if File.size?(path) == size

        bytes = @api.attachment(message.id, attachment_id)['contentBytes']
        save_attachment(path, bytes) if bytes
      end

      def save_attachment(path, encoded)
        FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
        File.binwrite(path, encoded.unpack1('m'))
      end
    end
  end
end
