# frozen_string_literal: true

module Teems
  module Commands
    # Due dates for `teems mail flag --due`: YYYY-MM-DD, today, tomorrow, or a weekday name
    # (the next one, today included; three letters are enough)
    module MailDueDate
      WEEKDAYS = %w[sunday monday tuesday wednesday thursday friday saturday].freeze

      def self.parse(text, today: Date.today)
        word = text.to_s.strip.downcase
        relative(word, today) || weekday(word, today) || Date.iso8601(word)
      rescue Date::Error
        nil
      end

      def self.relative(word, today) = { 'today' => today, 'tomorrow' => today + 1 }[word]

      def self.weekday(word, today)
        day = WEEKDAYS.index { |name| name.start_with?(word) } if word.length >= 3
        day && (today + ((day - today.wday) % 7))
      end
    end

    # Messages for `teems mail` triage: named by ID, or selected with --search or --folder
    module MailSelection
      # Graph's $search returns at most 1,000 messages; folder selections stop there too
      BULK_MAX = 1000
      # Where --thread leaves the rest of a conversation alone: your own messages, and ones already put away
      THREAD_SKIPS = %w[sentitems drafts deleteditems junkemail].freeze

      # Message IDs to act on; a selection (not IDs given by hand) also has the messages
      Targets = Data.define(:ids, :messages, :selected) do
        def self.named(ids) = new(ids: ids, messages: [], selected: false)
        def self.selected(messages) = new(ids: messages.map(&:id), messages: messages, selected: true)

        def count = ids.length
        def empty? = ids.empty?
        def short_ids = ids.map { |id| Models::MailMessage.short_id(id) }
        def to_json_hash = selected ? { messages: messages.map(&:to_json_hash) } : { ids: ids }
      end

      private

      def triage_targets
        ids = positional_args.drop(1)
        check_selection(ids)
        return selected_targets if selecting?
        raise Error, "Usage: teems mail #{triage_action} <id>... (or --search QUERY, --folder NAME)" if ids.empty?

        named = ids.map { |token| resolve_message_id(token) }
        @options[:thread] ? thread_targets(named) : Targets.named(named)
      end

      def selecting? = @options[:search] || @options[:folders]

      def check_selection(ids)
        check_thread
        raise Error, 'Give message IDs or --search/--folder, not both' if selecting? && ids.any?
        return if only_filters.empty? || (@options[:folders] && !@options[:search])

        raise Error, '--unread and --flagged select with --folder alone'
      end

      def selected_targets
        messages = @options[:search] ? search_selection : folder_selection
        id_cache.remember(messages)
        Targets.selected(messages)
      end

      def check_thread
        raise Error, '--thread works with message IDs, not --search or --folder' if @options[:thread] && selecting?
      end

      # The named messages and the rest of their conversations, except what sits in THREAD_SKIPS
      def thread_targets(named)
        skipped = thread_skipped_folders
        kept = mail_api.conversations_of(named).select do |message|
          named.include?(message.id) || !skipped.include?(message.folder_id)
        end
        id_cache.remember(kept)
        Targets.selected(kept)
      end

      def thread_skipped_folders
        folders = mail_folders
        THREAD_SKIPS.map { |name| folders.resolve(name).id }
      end

      def search_selection
        folder = @options[:folders]&.last
        mail_api.search(query: @options[:search], count: bulk_limit, folder: folder && mail_folders.resolve_id(folder))
      end

      def folder_selection
        folder = mail_folders.resolve_id(@options[:folders].last)
        mail_api.messages(folder: folder, count: bulk_limit, only: only_filters)
      end

      def bulk_limit
        limit = @options[:limit] || BULK_MAX
        raise Error, "-n must be between 1 and #{BULK_MAX}" unless limit.between?(1, BULK_MAX)

        limit
      end

      def resolve_message_id(token)
        id_cache.resolve(token) or
          raise Error, "Unknown message ID: #{token} (run teems mail list, or pass the full ID)"
      end
    end

    # mark-read, mark-unread, flag, unflag, archive, move, and delete for `teems mail`. A
    # selection is confirmed first (or --yes), and --dry-run lists what would change without
    # changing it.
    module MailTriage
      include MailSelection

      # What to do, as [phrase for --dry-run and the prompt, phrase once done]
      ACTIONS = {
        'mark-read' => ['mark %<count>s read', 'Marked %<count>s read'],
        'mark-unread' => ['mark %<count>s unread', 'Marked %<count>s unread'],
        'flag' => ['flag %<count>s', 'Flagged %<count>s'],
        'unflag' => ['unflag %<count>s', 'Unflagged %<count>s'],
        'archive' => ['archive %<count>s', 'Archived %<count>s'],
        'move' => ['move %<count>s to %<folder>s', 'Moved %<count>s to %<folder>s'],
        'delete' => ['move %<count>s to Deleted Items', 'Moved %<count>s to Deleted Items']
      }.freeze
      # The change each action makes, as [:update, properties] or [:move, destination]
      CHANGES = {
        'mark-read' => [:update, { isRead: true }], 'mark-unread' => [:update, { isRead: false }],
        'unflag' => [:update, { flag: { flagStatus: 'notFlagged' } }],
        'archive' => %i[move archive], 'delete' => %i[move deleteditems]
      }.freeze

      private

      def triage
        change = triage_change
        targets = triage_targets
        return triage_preview(targets) if @options[:dry_run]
        return 0.tap { info('No messages matched') } if targets.empty?
        return error('Cancelled; nothing changed') unless confirmed?(targets)

        triage_report(apply_change(change, targets.ids), targets)
      end

      def triage_action = positional_args.first

      # [:update, properties] or [:move, destination folder]
      def triage_change
        action = triage_action
        raise Error, '--due works with flag only' if @options[:due] && action != 'flag'
        raise Error, '--to works with move only' if @options[:to] && action != 'move'

        return [:update, flag_value] if action == 'flag'

        CHANGES.fetch(action) { [:move, move_destination] }
      end

      def move_destination
        name = @options[:to] or raise Error, 'Usage: teems mail move <id>... --to <folder>'
        mail_folders.resolve_id(name)
      end

      def flag_value
        due_text = @options[:due]
        return { flag: { flagStatus: 'flagged' } } unless due_text

        due = MailDueDate.parse(due_text) or
          raise Error, "Unknown due date: #{due_text} (use YYYY-MM-DD, today, tomorrow, or a weekday)"
        { flag: { flagStatus: 'flagged', startDateTime: graph_date([Date.today, due].min),
                  dueDateTime: graph_date(due) } }
      end

      def graph_date(date) = { dateTime: "#{date.iso8601}T00:00:00", timeZone: detect_timezone }

      # A selection needs --yes, or a "y" at the prompt; messages named by ID go ahead
      def confirmed?(targets)
        return true if @confirmed || !targets.selected || @options[:yes]

        @confirmed = answered_yes?(targets.count)
      end

      def answered_yes?(count)
        confirm?(triage_phrase(0, count).sub(/\A./, &:upcase),
                 refusal: "#{count_text(count)} selected; pass --yes to go ahead (or --dry-run to list them)")
      end

      # { done: [ids], failed: { id => message } }. An expired token stops the run, so the retry
      # after a refresh starts over (every action is safe to repeat)
      def apply_change(change, ids)
        kind, value = change
        actions = runner.mail_actions
        ids.each_with_object({ done: [], failed: {} }) do |id, result|
          actions.public_send(kind, id, value)
          result[:done] << id
        rescue ApiError => e
          raise if token_expired?(e)

          result[:failed][id] = e.message
        end
      end

      def triage_preview(targets)
        return json_result({ action: triage_action, dry_run: true, **targets.to_json_hash }) if @options[:json]

        rows = targets.selected ? mail_formatter.message_rows(targets.messages) : targets.short_ids
        print_lines(rows)
        info("Would #{triage_phrase(0, targets.count)} (dry run, nothing changed)")
        0
      end

      def triage_report(result, targets)
        done, failed = result.values_at(:done, :failed)
        return triage_json(done, failed) if @options[:json]

        success(triage_phrase(1, done.length)) if done.any?
        failed.each { |id, message| warn("#{Models::MailMessage.short_id(id)}: #{message}") }
        note_cap(targets)
        failed.empty? ? 0 : error("#{count_text(failed.length)} failed")
      end

      def triage_json(done, failed)
        output_json(action: triage_action, done: done, failed: failed.map { |id, message| { id: id, error: message } })
        failed.empty? ? 0 : 1
      end

      def note_cap(targets)
        limit = targets.selected && bulk_limit
        info("Stopped at #{limit} messages; run again (or raise -n) for the rest") if limit && targets.count >= limit
      end

      def triage_phrase(index, count)
        format(ACTIONS.fetch(triage_action)[index], count: count_text(count), folder: @options[:to])
      end

      def count_text(count) = count == 1 ? '1 message' : "#{count} messages"
    end
  end
end
