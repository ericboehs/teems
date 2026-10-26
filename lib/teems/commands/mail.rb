# frozen_string_literal: true

module Teems
  module Commands
    # list, read, folders, and search for `teems mail`
    module MailReading
      DEFAULT_COUNT = 20

      private

      def list_messages
        folder, count = list_args
        return error('Count must be a positive number') unless count&.positive?

        show_messages(mail_api.messages(folder: mail_folders.resolve_id(folder), count: count, only: only_filters))
      end

      # --unread and --flagged limit a listing (both: unread and flagged)
      def only_filters = Api::Mail::FILTERS.keys.select { |key| @options[key] }

      # [folder] [count]; a lone number is the count
      def list_args
        folder, count = positional_args.drop(1)
        return ['Inbox', Integer(folder)] if !count && folder.to_s.match?(/\A\d+\z/)

        [folder || 'Inbox', Integer(count || @options[:limit] || DEFAULT_COUNT, exception: false)]
      end

      def search_messages
        query = positional_args[1]
        return error('Usage: teems mail search <query> [folder]') if query.to_s.strip.empty?

        count = (@options[:limit] || DEFAULT_COUNT).clamp(1, 1000)
        show_messages(mail_api.search(query: query, count: count, folder: search_folder))
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

        show_message(mail_api.message(resolve_message_id(token)))
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

    # Outlook mail via Microsoft Graph: list, read, folders, search, local sync, and triage
    # (read state, flags, and moves). Nothing sends mail.
    class Mail < Base
      include MailReading
      include MailSyncing
      include MailTriage
      include Support::Timezone

      HELP = MailHelp::TEXT

      SUBCOMMANDS = {
        'list' => :list_messages, 'recent' => :list_messages, 'read' => :read_message,
        'folders' => :list_folders, 'search' => :search_messages, 'sync' => :sync_mail,
        **MailTriage::ACTIONS.transform_values { :triage }
      }.freeze

      FLAGS = { '--unread' => :unread, '--flagged' => :flagged, '--html' => :html, '--tsv' => :tsv,
                '--attachments' => :attachments, '--no-login' => :no_login, '--dry-run' => :dry_run,
                '--yes' => :yes, '-y' => :yes }.freeze
      VALUES = { '--since' => :since, '--dir' => :dir, '--folder' => :folders, '--search' => :search,
                 '--to' => :to, '--due' => :due }.freeze

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

      # No default -n: list and search show 20, a triage selection up to 1,000
      def default_options = super.merge(limit: nil)

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

      private

      def run_authenticated(handler)
        auth = require_auth
        return auth if auth

        with_token_refresh { fresh_attempt(handler) }
      rescue ApiError => e
        api_error_result('Mail request failed', e)
      rescue Teems::Error => e
        error(e.message)
      end

      # The folder tree is cached for one attempt: a retry after a token refresh starts over
      # with the new token
      def fresh_attempt(handler)
        @mail_folders = nil
        send(handler)
      end

      def mail_api = runner.mail_api
      def mail_folders = @mail_folders ||= Services::MailFolders.new(mail_api)
      def mail_formatter = Formatters::MailFormatter.new(output: output)
      def id_cache = Services::MailIdCache.new
    end
  end
end
