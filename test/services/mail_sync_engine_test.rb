# frozen_string_literal: true

require 'test_helper'
require_relative 'mail_sync_helpers'

# Delta scenarios keep the API pages, files on disk and saved state assertions together.
# rubocop:disable Metrics/MethodLength, Metrics/AbcSize, Metrics/ClassLength
class MailSyncEngineTest < Minitest::Test
  include MailSyncTestHelpers

  INBOX = Teems::Models::MailFolder.from_api(
    { 'id' => 'inbox-id', 'displayName' => 'Inbox', 'unreadItemCount' => 0, 'totalItemCount' => 0 }
  )

  def setup
    @client = MockApiClient.new
    @api = Teems::Api::Mail.new(@client, mock_account)
  end

  def engine(store, **options) = Teems::Services::MailSyncEngine.new(api: @api, store: store, options: options)

  def inbox_files(store) = Dir.children(store.folder_dir('Inbox')).sort

  def test_first_sync_pages_writes_adopts_and_checkpoints
    with_tz do
      with_store do |store|
        write_legacy(store, 'Inbox', 'legacy.md', id: 77, subject: 'Old one',
                                                  date: 'Monday, October 19, 2026 at 8:00:00 AM')
        @client.stub('skiptoken=2', { 'value' => [sample_mail_message('id' => 'old', 'subject' => 'Old one',
                                                                      'receivedDateTime' => '2026-10-19T13:00:00Z'),
                                                  { 'id' => 'gone', '@removed' => { 'reason' => 'deleted' } }],
                                      '@odata.deltaLink' => 'https://g/delta?$deltatoken=d1' })
        @client.stub('/messages/delta', { 'value' => [sample_mail_message('id' => 'new1')],
                                          '@odata.nextLink' => 'https://g/delta?$skiptoken=2' })

        stats = engine(store, since: Time.utc(2026, 10, 1)).sync(INBOX)

        assert_equal({ created: 1, updated: 0, unchanged: 0, adopted: 1, removed: 0 }, stats)
        assert_equal 'receivedDateTime ge 2026-10-01T00:00:00Z', @client.calls.first[:params]['$filter']
        new_file = Teems::Formatters::MailMarkdown.filename(mail('new1'))

        assert_equal ['index.json', 'legacy.md', new_file].sort, inbox_files(store)
        index = store.load_index('Inbox')

        assert_equal({ 'file' => 'legacy.md', 'legacy' => true }, index['old'].slice('file', 'legacy'))
        assert_equal new_file, index['new1']['file']
        assert_equal 'https://g/delta?$deltatoken=d1', store.load_state.dig('inbox-id', 'delta_link')
        assert_nil store.load_state.dig('inbox-id', 'next_link')
        assert_includes File.read(File.join(store.folder_dir('Inbox'), 'legacy.md')), 'id: 77'
      end
    end
  end

  def test_incremental_sync_updates_and_marks_removed
    with_store do |store|
      first = [sample_mail_message('id' => 'm1'), sample_mail_message('id' => 'm2')]
      @client.stub('/messages/delta', { 'value' => first, '@odata.deltaLink' => 'https://g/delta?$deltatoken=d1' })
      engine(store).sync(INBOX)
      removed = { 'id' => 'm2', '@removed' => {} }
      @client.stub('deltatoken=d1', { 'value' => [sample_mail_message('id' => 'm1', 'isRead' => true),
                                                  sample_mail_message('id' => 'm2'), removed, removed],
                                      '@odata.deltaLink' => 'https://g/delta?$deltatoken=d2' })

      stats = engine(store).sync(INBOX)

      assert_equal({ created: 0, updated: 1, unchanged: 1, adopted: 0, removed: 1 }, stats)
      assert_equal 'https://g/delta?$deltatoken=d1', @client.calls.last[:path]
      index = store.load_index('Inbox')

      assert index.dig('m1', 'read')
      assert index.dig('m2', 'removed_at')
      assert_nil Teems::Services::MailSyncIndex.entry_for(Teems::Models::MailMessage.from_api('id' => 'x'),
                                                          'f')['received']
      assert_equal 'https://g/delta?$deltatoken=d2', store.load_state.dig('inbox-id', 'delta_link')
    end
  end

  def test_unchanged_run_does_not_rewrite_index
    with_store do |store|
      @client.stub('/messages/delta', { 'value' => [sample_mail_message('id' => 'm1')],
                                        '@odata.deltaLink' => 'https://g/delta?$deltatoken=d1' })
      engine(store).sync(INBOX)
      index_path = File.join(store.folder_dir('Inbox'), 'index.json')
      File.utime(Time.at(0), Time.at(0), index_path)
      @client.stub('deltatoken=d1', { 'value' => [], '@odata.deltaLink' => 'https://g/delta?$deltatoken=d2' })

      engine(store).sync(INBOX)

      assert_equal Time.at(0), File.mtime(index_path)
    end
  end

  def test_empty_folder_still_writes_an_index
    with_store do |store|
      @client.stub('/messages/delta', { 'value' => [], '@odata.deltaLink' => 'https://g/delta?$deltatoken=d1' })

      engine(store).sync(INBOX)

      assert store.index_exists?('Inbox')
    end
  end

  def test_resumes_from_next_link_and_restarts_without_index
    with_store do |store|
      store.save_index('Inbox', {})
      store.save_state({ 'inbox-id' => { 'next_link' => 'https://g/delta?$skiptoken=5', 'delta_link' => 'old' } })
      @client.stub('skiptoken=5', { 'value' => [], '@odata.deltaLink' => 'https://g/delta?$deltatoken=d9' })
      engine(store).sync(INBOX)

      assert_equal 'https://g/delta?$skiptoken=5', @client.calls.first[:path]
      FileUtils.rm(File.join(store.folder_dir('Inbox'), 'index.json'))
      @client.stub('/messages/delta', { 'value' => [], '@odata.deltaLink' => 'https://g/delta?$deltatoken=d1' })
      engine(store).sync(INBOX)

      assert_equal '/v1.0/me/mailFolders/inbox-id/messages/delta', @client.calls.last[:path]
    end
  end

  def test_expired_delta_token_restarts_once
    with_store do |store|
      store.save_index('Inbox', {})
      store.save_state({ 'inbox-id' => { 'delta_link' => 'https://g/delta?$deltatoken=expired' } })
      @client.stub_error('deltatoken=expired', Teems::ApiError.new('gone', status_code: 410))
      @client.stub('/messages/delta', { 'value' => [], '@odata.deltaLink' => 'https://g/delta?$deltatoken=d1' })

      engine(store).sync(INBOX)

      assert_equal 'https://g/delta?$deltatoken=d1', store.load_state.dig('inbox-id', 'delta_link')
      @client.stub_error('/messages/delta', Teems::ApiError.new('gone', status_code: 410))
      store.save_state({})

      assert_raises(Teems::ApiError) { engine(store).sync(INBOX) }
    end
  end

  def test_other_api_errors_propagate
    with_store do |store|
      @client.stub_error('/messages/delta', Teems::ApiError.new('boom', status_code: 500))

      assert_raises(Teems::ApiError) { engine(store).sync(INBOX) }
    end
  end

  def test_adopted_legacy_file_seen_again_is_left_unchanged
    with_tz do
      with_store do |store|
        write_legacy(store, 'Inbox', 'legacy.md', id: 77, subject: 'Old one',
                                                  date: 'Monday, October 19, 2026 at 8:00:00 AM')
        old = sample_mail_message('id' => 'old', 'subject' => 'Old one', 'receivedDateTime' => '2026-10-19T13:00:00Z')
        @client.stub('/messages/delta', { 'value' => [old], '@odata.deltaLink' => 'https://g/delta?$deltatoken=d1' })
        engine(store).sync(INBOX)
        @client.stub('deltatoken=d1', { 'value' => [old.merge('isRead' => true)],
                                        '@odata.deltaLink' => 'https://g/delta?$deltatoken=d2' })

        stats = engine(store).sync(INBOX)

        assert_equal({ created: 0, updated: 0, unchanged: 1, adopted: 0, removed: 0 }, stats)
        assert store.load_index('Inbox').dig('old', 'read')
        assert_equal %w[index.json legacy.md], inbox_files(store)
        assert_includes File.read(File.join(store.folder_dir('Inbox'), 'legacy.md')), 'id: 77'
      end
    end
  end

  def test_attachment_names_without_downloads
    with_store do |store|
      @client.stub('/attachments', { 'value' => [{ 'id' => 'file1', 'name' => 'a.txt', 'size' => 5 }] })
      @client.stub('/messages/delta', { 'value' => [sample_mail_message('id' => 'm1', 'hasAttachments' => true)],
                                        '@odata.deltaLink' => 'https://g/delta?$deltatoken=d1' })

      engine(store).sync(INBOX)

      refute Dir.exist?(File.join(store.folder_dir('Inbox'), 'attachments'))
      content = File.read(File.join(store.folder_dir('Inbox'), store.load_index('Inbox').dig('m1', 'file')))

      assert_includes content, 'attachments: "a.txt"'
    end
  end

  def test_attachment_names_and_downloads
    with_store do |store|
      @client.stub('/attachments/file1', { 'contentBytes' => ['hello'].pack('m0') })
      @client.stub('/attachments/link1', { 'name' => 'reference' })
      @client.stub('/attachments', { 'value' => [{ 'id' => 'file1', 'name' => '../a.txt', 'size' => 5 },
                                                 { 'id' => 'link1', 'name' => 'b.url', 'size' => 1 },
                                                 { 'id' => 'ref1', 'name' => 'c.docx', 'size' => 1,
                                                   '@odata.type' => '#microsoft.graph.referenceAttachment' },
                                                 { 'id' => 'img', 'name' => 'logo.png', 'isInline' => true }] })
      @client.stub('/messages/delta', { 'value' => [sample_mail_message('id' => 'm1', 'hasAttachments' => true)],
                                        '@odata.deltaLink' => 'https://g/delta?$deltatoken=d1' })

      engine(store, attachments: true).sync(INBOX)

      dir = File.join(store.folder_dir('Inbox'), 'attachments', mail('m1').short_id)

      assert_equal ['a.txt'], Dir.children(dir)
      assert_equal 'hello', File.read(File.join(dir, 'a.txt'))
      content = File.read(File.join(store.folder_dir('Inbox'), store.load_index('Inbox').dig('m1', 'file')))

      assert_includes content, 'attachments: "../a.txt, b.url, c.docx"'
      calls = @client.calls.length
      @client.stub('deltatoken=d1', { 'value' => [sample_mail_message('id' => 'm1', 'hasAttachments' => true)],
                                      '@odata.deltaLink' => 'https://g/delta?$deltatoken=d2' })
      engine(store, attachments: true).sync(INBOX)

      assert_equal 3, @client.calls.length - calls, 'delta, list, and the attachment that saved nothing'
      refute(@client.calls.any? { |call| call[:path].include?('ref1') })
    end
  end
end
# rubocop:enable Metrics/MethodLength, Metrics/AbcSize, Metrics/ClassLength
