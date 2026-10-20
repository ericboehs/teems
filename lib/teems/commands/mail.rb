# frozen_string_literal: true

module Teems
  module Commands
    # list, read, folders, and search for `teems mail`
    module MailReading
      private

      def list_messages
        folder, count = list_args
        return error('Count must be a positive number') unless count&.positive?

        filter = Api::Mail::UNREAD if @options[:unread]
        show_messages(mail_api.messages(folder: mail_folders.resolve_id(folder), count: count, filter: filter))
      end

      # [folder] [count]; a lone number is the count
      def list_args
        folder, count = positional_args.drop(1)
        return ['Inbox', Integer(folder)] if !count && folder.to_s.match?(/\A\d+\z/)

        [folder || 'Inbox', Integer(count || @options[:limit], exception: false)]
      end

      def search_messages
        query = positional_args[1]
        return error('Usage: teems mail search <query> [folder]') if query.to_s.strip.empty?

        show_messages(mail_api.search(query: query, count: @options[:limit].clamp(1, 1000), folder: search_folder))
      end

      def search_folder
        name = @options[:folders]&.last || positional_args[2]
        name && mail_folders.resolve_id(name)
      end

      def show_messages(messages)
        id_cache.remember(messages)
        return json_result(messages.map(&:to_json_hash)) if @options[:json]
        return print_lines(messages.map(&:tsv_row)) if @options[:tsv]

        rows = mail_formatter.message_rows(messages)
        rows.empty? ? print_lines([output.gray('No messages found')]) : print_lines(rows)
      end

      def read_message
        token = positional_args[1]
        return error('Usage: teems mail read <id>') unless token

        message_id = id_cache.resolve(token)
        return error("Unknown message ID: #{token} (run teems mail list, or pass the full ID)") unless message_id

        show_message(mail_api.message(message_id))
      end

      def show_message(message)
        return print_lines([message.body]) if @options[:html]

        names = message.has_attachments ? attachment_names(message.id) : []
        return json_result(message.full_json_hash(attachments: names)) if @options[:json]

        print_lines([message.to_text(attachments: names)])
      end

      def attachment_names(message_id) = Models::MailMessage.attachment_names(mail_api.attachments(message_id))

      def list_folders
        all = mail_folders.all
        return json_result(all.map(&:to_json_hash)) if @options[:json]
        return print_lines(all.map(&:tsv_row)) if @options[:tsv]

        print_lines(mail_formatter.folder_rows(all))
      end

      def json_result(data)
        output_json(data)
        0
      end

      # Data output goes straight to stdout so --quiet only silences status messages
      def print_lines(lines)
        lines.each { |line| output.puts(line) }
        0
      end
    end

    # Read-only Outlook mail via Microsoft Graph: list, read, folders, search, and local sync
    class Mail < Base
      include MailReading
      include MailSyncing

      HELP = <<~HELP
        teems mail - Read Outlook mail via Microsoft Graph (read-only)

        USAGE:
          teems mail list [folder] [count] [--unread]   Newest messages (alias: recent)
          teems mail read <id> [--html]                 Headers, plain-text body, numbered links
          teems mail folders                            Folders with unread and total counts
          teems mail search <query> [folder]            Graph $search (KQL), e.g. from:alice subject:report
          teems mail sync [folder...] [options]         Incremental local copy (Graph delta)

        OPTIONS:
          --unread          list: only unread messages
          --html            read: print the raw HTML body
          --folder NAME     search: limit to a folder; sync: folder to sync (repeatable)
          --tsv             list/search/folders: tab-separated output with full IDs
          -n, --limit N     list: count (default 20); search: max results (default 20)
          --json            JSON output

        SYNC OPTIONS:
          --dir DIR         Store root (default ~/.local/share/teems/sync/mail)
          --since DAYS      First sync of a folder: only mail from the last DAYS days,
                            or "all" (default 90). Later runs fetch only changes.
          --attachments     Also download file attachments to <Folder>/attachments/
          --no-login        Never open Safari to log in (for launchd and cron)

        Folders are names ("Inbox", "Sent Items", "Projects/EERT"), well-known names
        (inbox, archive, sent, drafts, deleted, junk), or Graph folder IDs. IDs from
        list and search are short handles; read accepts them or full Graph IDs.

        Sync writes one Markdown file per message plus <Folder>/index.json, and keeps
        delta links in ~/.local/state/teems/mail-sync.json. Syncing into a directory an
        older outlook-cli sync filled (e.g. ~/Mail) adopts its files instead of
        duplicating them. Removed messages keep their file; the index marks them.
      HELP

      SUBCOMMANDS = {
        'list' => :list_messages, 'recent' => :list_messages, 'read' => :read_message,
        'folders' => :list_folders, 'search' => :search_messages, 'sync' => :sync_mail
      }.freeze

      FLAGS = { '--unread' => :unread, '--html' => :html, '--tsv' => :tsv,
                '--attachments' => :attachments, '--no-login' => :no_login }.freeze
      VALUES = { '--since' => :since, '--dir' => :dir, '--folder' => :folders }.freeze

      def initialize(args, runner:)
        @options = {}
        super
      end

      def execute
        validation = validate_options
        return validation if validation

        handler = SUBCOMMANDS[positional_args.first]
        return error("Usage: teems mail <#{SUBCOMMANDS.keys.join('|')}> (teems mail --help)") unless handler

        run_authenticated(handler)
      end

      protected

      def handle_option(arg, pending)
        return @options[FLAGS[arg]] = true if FLAGS.key?(arg)

        key = VALUES[arg]
        return super unless key

        store_value(key, pending.shift.to_s)
      end

      # --folder repeats (sync takes several); other values keep the last one given
      def store_value(key, value)
        key == :folders ? (@options[:folders] ||= []) << value : @options[key] = value
      end

      def help_text = HELP

      # Never opens Safari under --no-login; token refresh still works
      def auto_login = @options[:no_login] ? nil : super

      private

      def run_authenticated(handler)
        auth = require_auth
        return auth if auth

        with_token_refresh { send(handler) }
      rescue ApiError
        raise
      rescue Teems::Error => e
        error(e.message)
      end

      def mail_api = @mail_api ||= Api::Mail.new(api_client, runner.account)
      def mail_folders = @mail_folders ||= Services::MailFolders.new(mail_api)
      def mail_formatter = Formatters::MailFormatter.new(output: output)
      def id_cache = Services::MailIdCache.new
    end
  end
end
