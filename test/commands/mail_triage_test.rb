# frozen_string_literal: true

require 'test_helper'

# `teems mail` triage: what each action sends to Graph, how messages are chosen, and the
# confirmation, dry-run, and failure handling around it.
# rubocop:disable Metrics/MethodLength, Metrics/AbcSize, Metrics/ClassLength
class MailTriageCommandTest < Minitest::Test
  # Stands in for a terminal on stdin that answers the confirmation prompt
  FakeTerminal = Struct.new(:answer) do
    def tty? = true
    def gets = answer
  end

  def setup
    @saved_tz = ENV.fetch('TZ', nil)
    ENV['TZ'] = 'America/Chicago'
    @saved_stdin = $stdin
    $stdin = StringIO.new
  end

  def teardown
    ENV['TZ'] = @saved_tz
    $stdin = @saved_stdin
  end

  def run_mail(args, stubs: {}, errors: {})
    capture = capture_output do |output|
      runner = configured_runner(output: output)
      @api = runner.api_client
      stubs.each { |path, response| @api.stub(path, response) }
      errors.each { |path, error| @api.stub_error(path, error) }
      @code = Teems::Commands::Mail.new(args, runner: runner).execute
    end
    capture.merge(code: @code)
  end

  def writes = @api.calls.reject { |call| call[:method] == :get }
  def messages(*ids) = { 'value' => ids.map { |id| sample_mail_message('id' => id) } }
  def folders = { 'value' => [sample_mail_folder('Inbox'), sample_mail_folder('Projects')] }

  def test_mark_read_and_unread
    with_temp_config do
      result = run_mail(%w[mark-read AAMk-1 AAMk-2])

      assert_equal 0, result[:code]
      assert_equal(%w[/v1.0/me/messages/AAMk-1 /v1.0/me/messages/AAMk-2], writes.map { |call| call[:path] })
      assert_equal([:patch], writes.map { |call| call[:method] }.uniq)
      assert_equal({ isRead: true }, writes.first[:body])
      assert_equal 'IdType="ImmutableId"', writes.first[:headers]['Prefer']
      assert_includes result[:stdout], 'Marked 2 messages read'

      run_mail(%w[mark-unread AAMk-1])

      assert_equal({ isRead: false }, writes.first[:body])
    end
  end

  def test_flag_and_unflag
    with_temp_config do
      assert_includes run_mail(%w[flag AAMk-1])[:stdout], 'Flagged 1 message'
      assert_equal({ flag: { flagStatus: 'flagged' } }, writes.first[:body])

      assert_includes run_mail(%w[unflag AAMk-1])[:stdout], 'Unflagged 1 message'
      assert_equal({ flag: { flagStatus: 'notFlagged' } }, writes.first[:body])
    end
  end

  def test_flag_with_a_due_date_starts_today
    with_temp_config do
      due = Date.today + 3
      run_mail(['flag', 'AAMk-1', '--due', due.iso8601])
      flag = writes.first[:body][:flag]

      assert_equal 'flagged', flag[:flagStatus]
      assert_equal({ dateTime: "#{due.iso8601}T00:00:00", timeZone: 'America/Chicago' }, flag[:dueDateTime])
      assert_equal "#{Date.today.iso8601}T00:00:00", flag[:startDateTime][:dateTime]
    end
  end

  # Graph refuses a start after the due date, so a past due date starts on itself
  def test_flag_with_a_past_due_date_starts_on_it
    with_temp_config do
      run_mail(%w[flag AAMk-1 --due 2020-01-02])

      assert_equal '2020-01-02T00:00:00', writes.first[:body][:flag][:startDateTime][:dateTime]
    end
  end

  def test_bad_due_date_and_misplaced_options_change_nothing
    with_temp_config do
      { %w[flag AAMk-1 --due someday] => 'Unknown due date: someday',
        %w[archive AAMk-1 --due today] => '--due works with flag only',
        %w[archive AAMk-1 --to Projects] => '--to works with move only',
        %w[move AAMk-1] => 'Usage: teems mail move <id>... --to <folder>',
        %w[archive] => 'Usage: teems mail archive <id>...',
        %w[archive AAMk-1 --search report] => 'Give message IDs or --search/--folder, not both',
        %w[archive AAMk-1 --unread] => '--unread and --flagged select with --folder alone',
        %w[archive --search report --flagged] => '--unread and --flagged select with --folder alone',
        %w[archive --search report -n 0] => '-n must be between 1 and 1000' }.each do |args, message|
        result = run_mail(args)

        assert_equal 1, result[:code], args.join(' ')
        assert_includes result[:stderr], message
        assert_empty writes, args.join(' ')
      end
    end
  end

  def test_archive_and_delete_move_the_message
    with_temp_config do
      assert_includes run_mail(%w[archive AAMk-1])[:stdout], 'Archived 1 message'
      assert_equal '/v1.0/me/messages/AAMk-1/move', writes.first[:path]
      assert_equal({ destinationId: :archive }, writes.first[:body])

      assert_includes run_mail(%w[delete AAMk-1])[:stdout], 'Moved 1 message to Deleted Items'
      assert_equal :post, writes.first[:method]
      assert_equal({ destinationId: :deleteditems }, writes.first[:body])
    end
  end

  def test_move_resolves_the_folder_name
    with_temp_config do
      result = run_mail(%w[move AAMk-1 --to projects], stubs: { '/v1.0/me/mailFolders' => folders })

      assert_equal 0, result[:code]
      assert_equal({ destinationId: sample_mail_folder('Projects')['id'] }, writes.first[:body])
      assert_includes result[:stdout], 'Moved 1 message to projects'
    end
  end

  def test_short_ids_resolve_and_unknown_ones_change_nothing
    with_temp_config do
      message = Teems::Models::MailMessage.from_api(sample_mail_message('id' => 'AAMk-full'))
      Teems::Services::MailIdCache.new.remember([message])
      run_mail(['archive', message.short_id])

      assert_equal '/v1.0/me/messages/AAMk-full/move', writes.first[:path]

      result = run_mail(%w[archive AAMk-2 0000aaaa])

      assert_equal 1, result[:code]
      assert_includes result[:stderr], 'Unknown message ID: 0000aaaa'
      assert_empty writes
    end
  end

  def test_search_selection_with_yes
    with_temp_config do
      result = run_mail(['archive', '--search', 'from:jira', '--folder', 'Inbox', '--yes'],
                        stubs: { '/mailFolders/inbox/messages' => messages('m1', 'm2') })
      search = @api.calls.first

      assert_equal 0, result[:code]
      assert_equal '"from:jira"', search[:params]['$search']
      assert_equal 250, search[:params]['$top']
      assert_equal(%w[/v1.0/me/messages/m1/move /v1.0/me/messages/m2/move], writes.map { |call| call[:path] })
      assert_includes result[:stdout], 'Archived 2 messages'
    end
  end

  def test_folder_selection_with_filters
    with_temp_config do
      run_mail(%w[mark-read --folder Inbox --unread --flagged -y], stubs: { '/messages' => messages('m1') })
      filter = @api.calls.first[:params]['$filter']

      assert_equal '/v1.0/me/mailFolders/inbox/messages', @api.calls.first[:path]
      assert_equal "receivedDateTime ge 1900-01-01T00:00:00Z and isRead eq false and flag/flagStatus eq 'flagged'",
                   filter
      assert_equal 1, writes.length
    end
  end

  def test_selection_needs_yes_without_a_terminal
    with_temp_config do
      result = run_mail(%w[delete --search report], stubs: { '/v1.0/me/messages' => messages('m1', 'm2') })

      assert_equal 1, result[:code]
      assert_includes result[:stderr], '2 messages selected; pass --yes to go ahead'
      assert_empty writes
    end
  end

  def test_selection_asks_at_a_terminal
    with_temp_config do
      $stdin = FakeTerminal.new("y\n")
      result = run_mail(%w[archive --search report], stubs: { '/v1.0/me/messages' => messages('m1', 'm2') })

      assert_equal 0, result[:code]
      assert_includes result[:stderr], 'Archive 2 messages? [y/N] '
      assert_equal 2, writes.length

      $stdin = FakeTerminal.new("\n")
      result = run_mail(%w[archive --search report], stubs: { '/v1.0/me/messages' => messages('m1') })

      assert_equal 1, result[:code]
      assert_includes result[:stderr], 'Cancelled; nothing changed'
      assert_empty writes
    end
  end

  def test_the_prompt_shows_under_quiet
    with_temp_config do
      $stdin = FakeTerminal.new(nil)
      result = run_mail(%w[flag -q --search report], stubs: { '/v1.0/me/messages' => messages('m1') })

      assert_includes result[:stderr], 'Flag 1 message? [y/N] '
      assert_empty writes
    end
  end

  def test_dry_run_lists_without_changing
    with_temp_config do
      result = run_mail(%w[archive --search report --dry-run], stubs: { '/v1.0/me/messages' => messages('m1') })
      short = Teems::Models::MailMessage.short_id('m1')

      assert_equal 0, result[:code]
      assert_includes result[:stdout], "#{short}  2026-10-20"
      assert_includes result[:stdout], 'Would archive 1 message (dry run, nothing changed)'
      assert_empty writes

      named = run_mail(%w[move AAMk-1 --to Archive --dry-run])

      assert_includes named[:stdout], Teems::Models::MailMessage.short_id('AAMk-1')
      assert_includes named[:stdout], 'Would move 1 message to Archive'
      assert_empty writes
    end
  end

  def test_dry_run_json
    with_temp_config do
      result = run_mail(%w[unflag --folder Inbox --dry-run --json], stubs: { '/messages' => messages('m1') })
      json = JSON.parse(result[:stdout])

      assert_equal({ 'action' => 'unflag', 'dry_run' => true }, json.slice('action', 'dry_run'))
      assert_equal(['m1'], json['messages'].map { |message| message['id'] })
      assert_equal ['AAMk-1'], JSON.parse(run_mail(%w[delete AAMk-1 --dry-run --json])[:stdout])['ids']
    end
  end

  def test_no_matches_is_not_an_error
    with_temp_config do
      result = run_mail(%w[archive --search nothing])

      assert_equal 0, result[:code]
      assert_includes result[:stdout], 'No messages matched'
    end
  end

  def test_one_failure_does_not_stop_the_rest
    with_temp_config do
      gone = Teems::ApiError.new('HTTP 404: Not Found', status_code: 404)
      result = run_mail(%w[archive AAMk-1 AAMk-2], errors: { '/messages/AAMk-1/move' => gone })

      assert_equal 1, result[:code]
      assert_equal 2, writes.length
      assert_includes result[:stdout], 'Archived 1 message'
      assert_includes result[:stderr], "#{Teems::Models::MailMessage.short_id('AAMk-1')}: HTTP 404: Not Found"
      assert_includes result[:stderr], '1 message failed'
    end
  end

  def test_all_failing_reports_no_success
    with_temp_config do
      gone = Teems::ApiError.new('HTTP 404: Not Found', status_code: 404)
      result = run_mail(%w[unflag AAMk-1], errors: { '/messages/AAMk-1' => gone })

      assert_equal 1, result[:code]
      refute_includes result[:stdout], 'Unflagged'
      assert_includes result[:stderr], '1 message failed'
    end
  end

  def test_json_report
    with_temp_config do
      gone = Teems::ApiError.new('HTTP 404: Not Found', status_code: 404)
      result = run_mail(%w[mark-read AAMk-1 AAMk-2 --json], errors: { '/messages/AAMk-2' => gone })

      assert_equal 1, result[:code]
      assert_equal({ 'action' => 'mark-read', 'done' => ['AAMk-1'],
                     'failed' => [{ 'id' => 'AAMk-2', 'error' => 'HTTP 404: Not Found' }] },
                   JSON.parse(result[:stdout]))
      assert_equal 0, run_mail(%w[mark-read AAMk-1 --json])[:code]
    end
  end

  def test_an_expired_token_is_not_counted_as_a_failure
    with_temp_config do
      expired = Teems::ApiError.new('Invalid token or session expired', status_code: 401)
      result = run_mail(%w[archive AAMk-1], errors: { '/move' => expired })

      assert_equal 1, result[:code]
      assert_includes result[:stderr], 'Mail request failed'
      refute_includes result[:stdout], 'Archived'
    end
  end

  def test_a_full_selection_notes_the_cap
    with_temp_config do
      result = run_mail(%w[archive --search report -n 2 --yes], stubs: { '/v1.0/me/messages' => messages('m1', 'm2') })

      assert_equal 2, @api.calls.first[:params]['$top']
      assert_includes result[:stdout], 'Stopped at 2 messages; run again (or raise -n) for the rest'
    end
  end
end
# rubocop:enable Metrics/MethodLength, Metrics/AbcSize, Metrics/ClassLength
