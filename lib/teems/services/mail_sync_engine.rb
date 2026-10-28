# frozen_string_literal: true

module Teems
  module Services
    # Incremental mail sync for one folder at a time using Graph delta queries. Each page is
    # written and checkpointed before the next is fetched, so an interrupted run resumes where
    # it stopped. Messages that leave a folder keep their file; the index records removed_at.
    class MailSyncEngine
      # Graph's answers to a delta link it can no longer use: 410 Gone, or 400 with one of
      # these codes (compared without case; the last is Exchange's, for an old or malformed
      # delta token)
      RESYNC_CODES = %w[syncstatenotfound syncstateinvalid resyncrequired errorinvalidsyncstatedata].freeze

      # Raised by fetch_page when Graph rejects the delta link itself (cause: the ApiError).
      # A 400 anywhere else, such as one message's attachments, must not restart the folder.
      class ResyncNeeded < StandardError; end

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
      # A delta link Graph rejects starts the folder over once; a second rejection raises
      # Graph's error.
      def sync(folder)
        attempts = 0
        begin
          @folder = MailSyncFolder.new(folder, @store)
          run_delta
        rescue ResyncNeeded => e
          raise e.cause unless (attempts += 1) == 1

          @folder.reset_state
          retry
        end
        @folder.stats
      end

      def self.resync?(error)
        case error.status_code
        when 410 then true
        when 400 then RESYNC_CODES.include?(error.error_code.to_s.downcase)
        else false
        end
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

      def fetch_page(link)
        link ? @api.delta_page(link) : @api.delta(folder: @folder.id, since: @options[:since])
      rescue ApiError => e
        raise ResyncNeeded if self.class.resync?(e)

        raise
      end

      def process(item)
        return @folder.mark_removed(item['id']) if item.key?('@removed')

        message = Models::MailMessage.from_api(item)
        legacy_file = @folder.legacy_file(message)
        return @folder.adopt(message, legacy_file) if legacy_file

        write(message)
      end

      def attachments = MailSyncAttachments.new(api: @api, store: @store, options: @options)

      def write(message)
        path = @folder.path
        file = @folder.file_for(message)
        listing = attachments.listing(message, path) if message.attachments_to_list?
        message = message.with(protection: 'smime') if listing&.encrypted
        content = Formatters::MailMarkdown.render(message, folder: path, attachments: listing ? listing.names : [])
        @folder.count(@store.write_message(path, file, content))
        @folder.record(message, file)
      end
    end
  end
end
