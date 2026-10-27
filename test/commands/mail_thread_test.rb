# frozen_string_literal: true

require 'test_helper'

# `teems mail thread` and the --thread option on triage: a message's whole conversation,
# from every folder, oldest first.
# rubocop:disable Metrics/MethodLength, Metrics/AbcSize, Metrics/ClassLength
class MailThreadCommandTest < Minitest::Test
  # Stands in for a terminal on stdin that answers the confirmation prompt
  FakeTerminal = Struct.new(:answer) do
    def tty? = true
    def gets = answer
  end

  def setup
    @saved_stdin = $stdin
    $stdin = StringIO.new
  end

  def teardown
    $stdin = @saved_stdin
  end

  def run_mail(args, stubs: thread_stubs)
    capture = capture_output do |output|
      runner = configured_runner(output: output)
      @api = runner.api_client
      stubs.each { |path, response| @api.stub(path, response) }
      @code = Teems::Commands::Mail.new(args, runner: runner).execute
    end
    capture.merge(code: @code)
  end

  def folder(name) = sample_mail_folder(name)
  def folder_id(name) = folder(name)['id']

  def thread_message(id, received, folder_name, **overrides)
    sample_mail_message('id' => id, 'receivedDateTime' => received, 'parentFolderId' => folder_id(folder_name),
                        'subject' => 'Monthly report', **overrides)
  end

  # Graph returns them in no promised order; these are newest first
  def conversation
    [thread_message('AAMk-3', '2026-10-27T19:17:19Z', 'Inbox'),
     thread_message('AAMk-sent', '2026-10-05T14:00:00Z', 'Sent Items'),
     thread_message('AAMk-gone', '2026-10-05T13:32:18Z', 'Deleted Items'),
     thread_message('AAMk-1', '2026-10-01T18:44:53Z', 'Inbox')]
  end

  # Specific paths first: the mock matches by substring, in the order stubbed
  def thread_stubs(messages = conversation)
    { '/v1.0/me/messages/AAMk-1' => { 'conversationId' => "conv'1" },
      '/v1.0/me/messages/AAMk-3' => { 'conversationId' => "conv'1" },
      '/v1.0/me/messages' => { 'value' => messages },
      **%w[sentitems drafts deleteditems junkemail].to_h do |name|
        ["/v1.0/me/mailFolders/#{name}", folder({ 'sentitems' => 'Sent Items', 'deleteditems' => 'Deleted Items',
                                                  'junkemail' => 'Junk Email' }.fetch(name, name.capitalize))]
      end,
      '/v1.0/me/mailFolders' => { 'value' => ['Inbox', 'Sent Items', 'Deleted Items'].map { |name| folder(name) } } }
  end

  def conversation_call = @api.calls.find { |call| call[:path] == '/v1.0/me/messages' }
  def writes = @api.calls.reject { |call| call[:method] == :get }

  def test_lists_the_conversation_oldest_first_with_folders
    with_temp_config do
      result = run_mail(%w[thread AAMk-3])
      lines = result[:stdout].lines

      assert_equal 0, result[:code]
      assert_equal 4, lines.length
      assert_equal(%w[2026-10-01 2026-10-05 2026-10-05 2026-10-27], lines.map { |line| line[/\d{4}-\d\d-\d\d/] })
      assert_match(/unread  Inbox$/, lines.first.chomp)
      assert_includes lines[1], 'Deleted Items'
      assert_includes lines[2], 'Sent Items'
    end
  end

  def test_filters_on_the_conversation_and_sorts_locally
    with_temp_config do
      run_mail(%w[thread AAMk-3])
      params = conversation_call[:params]

      assert_equal "conversationId eq 'conv''1'", params['$filter']
      assert_includes params['$select'], 'parentFolderId'
      refute_includes params['$select'], 'body'
      refute params.key?('$orderby'), 'Graph refuses $orderby with a conversationId filter'
    end
  end

  def test_remembers_short_ids_for_read_and_triage
    with_temp_config do
      run_mail(%w[thread AAMk-3])
      short = Teems::Models::MailMessage.short_id('AAMk-sent')

      assert_equal 'AAMk-sent', Teems::Services::MailIdCache.new.resolve(short)
    end
  end

  def test_tsv_and_json_name_the_folder
    with_temp_config do
      rows = run_mail(%w[thread AAMk-3 --tsv])[:stdout].lines.map { |line| line.chomp.split("\t") }

      assert_equal ['Inbox', 'Deleted Items', 'Sent Items', 'Inbox'], rows.map(&:last)
      assert_equal 'AAMk-1', rows.first.first

      json = JSON.parse(run_mail(%w[thread AAMk-3 --json])[:stdout])

      assert_equal(%w[AAMk-1 AAMk-gone AAMk-sent AAMk-3], json.map { |message| message['id'] })
      assert_equal 'Sent Items', json[2]['folder']
    end
  end

  def test_full_prints_each_message_as_read_does
    with_temp_config do
      messages = [thread_message('AAMk-1', '2026-10-01T18:44:53Z', 'Inbox', 'hasAttachments' => true),
                  thread_message('AAMk-3', '2026-10-27T19:17:19Z', 'Inbox',
                                 'internetMessageHeaders' => purview_headers)]
      stubs = { '/v1.0/me/messages/AAMk-1/attachments' => { 'value' => [{ 'name' => 'report.pdf' }] },
                **thread_stubs(messages) }
      result = run_mail(%w[thread AAMk-3 --full], stubs: stubs)
      blocks = result[:stdout].split(/^-{72}$/)

      assert_equal 0, result[:code]
      assert_equal 2, blocks.length
      assert_includes blocks.first, 'report.pdf'
      assert_includes blocks.first, "Folder: Inbox\nID: AAMk-1"
      assert_includes blocks.last, 'Protected by Purview'
      assert_includes conversation_call[:params]['$select'], 'body'
      assert_equal(1, @api.calls.count { |call| call[:path].end_with?('/attachments') },
                   'only the message with attachments asks for them')
    end
  end

  def test_full_json_has_bodies_folders_and_encryption
    with_temp_config do
      messages = [thread_message('AAMk-1', '2026-10-01T18:44:53Z', 'Inbox'),
                  thread_message('AAMk-3', '2026-10-27T19:17:19Z', 'Inbox',
                                 'internetMessageHeaders' => purview_headers)]
      json = JSON.parse(run_mail(%w[thread AAMk-3 --full --json], stubs: thread_stubs(messages))[:stdout])

      assert_equal(['Inbox'], json.map { |message| message['folder'] }.uniq)
      assert(json.all? { |message| message.key?('body') })
      refute json.first.key?('encryption')
      assert_equal({ 'type' => 'purview', 'decrypted' => false }, json.last['encryption'])
    end
  end

  def test_needs_an_id_and_a_conversation
    with_temp_config do
      result = run_mail(%w[thread])

      assert_equal 1, result[:code]
      assert_includes result[:stderr], 'Usage: teems mail thread <id> [--full]'

      result = run_mail(%w[thread AAMk-1], stubs: { '/v1.0/me/messages/AAMk-1' => {} })

      assert_equal 1, result[:code]
      assert_includes result[:stderr], 'That message belongs to no conversation'
    end
  end

  # Sent Items and Deleted Items stay put unless named; each conversation is fetched once, and
  # its messages handled oldest first
  def test_archive_thread_moves_the_conversation_but_not_sent_or_deleted_mail
    with_temp_config do
      result = run_mail(%w[archive AAMk-3 AAMk-1 --thread --yes])

      assert_equal 0, result[:code]
      assert_equal(%w[/v1.0/me/messages/AAMk-1/move /v1.0/me/messages/AAMk-3/move], writes.map { |call| call[:path] })
      assert_includes result[:stdout], 'Archived 2 messages'
      assert_equal(1, @api.calls.count { |call| call[:path] == '/v1.0/me/messages' })
    end
  end

  def test_a_named_message_counts_wherever_it_sits
    with_temp_config do
      stubs = { '/v1.0/me/messages/AAMk-gone' => { 'conversationId' => "conv'1" }, **thread_stubs }
      run_mail(%w[mark-read AAMk-gone --thread --yes], stubs: stubs)

      assert_equal(%w[AAMk-1 AAMk-gone AAMk-3], writes.map { |call| call[:path].split('/').last })
    end
  end

  def test_thread_asks_first_and_dry_run_lists
    with_temp_config do
      result = run_mail(%w[archive AAMk-3 --thread])

      assert_equal 1, result[:code]
      assert_includes result[:stderr], '2 messages selected; pass --yes'
      assert_empty writes

      $stdin = FakeTerminal.new("y\n")

      assert_includes run_mail(%w[archive AAMk-3 --thread])[:stdout], 'Archived 2 messages'

      result = run_mail(%w[archive AAMk-3 --thread --dry-run])

      assert_empty writes
      assert_equal 3, result[:stdout].lines.length
      assert_includes result[:stdout], 'Would archive 2 messages'
    end
  end

  def test_thread_needs_message_ids
    with_temp_config do
      result = run_mail(%w[archive --search report --thread])

      assert_equal 1, result[:code]
      assert_includes result[:stderr], '--thread works with message IDs, not --search or --folder'
      assert_empty writes
    end
  end
end
# rubocop:enable Metrics/MethodLength, Metrics/AbcSize, Metrics/ClassLength
