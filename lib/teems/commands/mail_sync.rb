# frozen_string_literal: true

module Teems
  module Commands
    # `teems mail sync`: incremental local copy of mail folders via Graph delta queries
    module MailSyncing
      DEFAULT_SINCE_DAYS = 90

      private

      def sync_mail
        since = sync_since
        return error('--since must be a number of days or "all"') if since == :invalid

        store = Services::MailSyncStore.new(**sync_store_args)
        result = with_private_umask { store.with_lock { sync_folders(store, since) } }
        return result unless result == :locked

        info('Another teems mail sync is running; skipping')
        0
      end

      def sync_store_args
        dir = @options[:dir]
        dir ? { root: dir } : {}
      end

      # Time limiting a folder's first sync, nil for everything, or :invalid
      def sync_since
        value = @options.fetch(:since, DEFAULT_SINCE_DAYS.to_s).to_s.strip.downcase
        return nil if value == 'all'

        days = Integer(value, exception: false)
        days&.positive? ? Time.now - (days * 86_400) : :invalid
      end

      def sync_folder_names
        names = [*positional_args.drop(1), *@options[:folders]]
        names.empty? ? ['Inbox'] : names.uniq
      end

      # A folder that fails is reported and skipped so the others still sync; the exit
      # status is 1 when any failed
      def sync_folders(store, since)
        engine = sync_engine(store, since)
        names = sync_folder_names
        results = names.filter_map { |name| sync_one(engine, store, name) }.to_h
        output_json(results) if @options[:json]
        results.size == names.size ? 0 : 1
      end

      def sync_engine(store, since)
        options = { since: since, attachments: @options[:attachments], on_warning: ->(message) { warn(message) } }
        Services::MailSyncEngine.new(api: mail_api, store: store, options: options)
      end

      # [path, stats], or nil when the folder failed. Expired tokens are raised for
      # with_token_refresh; a folder interrupted by anything else resumes on the next run.
      def sync_one(engine, store, name)
        folder = mail_folders.resolve(name)
        path = folder.path
        sync_info("Syncing #{path} -> #{store.folder_dir(path)}")
        stats = engine.sync(folder)
        sync_info("  #{sync_summary(stats)}")
        [path, stats]
      rescue Teems::Error => e
        raise if e.is_a?(ApiError) && token_expired?(e)

        warn("#{name}: #{e.message}")
        nil
      end

      # Progress lines go to stdout, so --json leaves them out to keep its output parseable
      def sync_info(message) = @options[:json] || info(message)

      def sync_summary(stats)
        created, updated, unchanged, adopted, removed = stats.values_at(*Services::MailSyncFolder::STAT_KEYS)
        "#{created} new, #{updated} updated, #{unchanged} unchanged, " \
          "#{adopted} existing files adopted, #{removed} removed from folder"
      end

      # Synced mail is private: new files and directories are owner-only
      def with_private_umask
        previous = File.umask(0o077)
        yield
      ensure
        File.umask(previous)
      end
    end
  end
end
