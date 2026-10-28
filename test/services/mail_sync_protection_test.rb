# frozen_string_literal: true

require 'test_helper'
require_relative 'mail_sync_helpers'

# How mail sync labels S/MIME encrypted mail. Exchange wraps it as TNEF: the headers say
# application/ms-tnef and hasAttachments is false, so only an empty body and an smime.p7m
# in the attachment listing give it away.
class MailSyncProtectionTest < Minitest::Test
  include MailSyncTestHelpers

  INBOX = Teems::Models::MailFolder.from_api(
    { 'id' => 'inbox-id', 'displayName' => 'Inbox', 'unreadItemCount' => 0, 'totalItemCount' => 0 }
  )
  EMPTY_BODY = { 'contentType' => 'text', 'content' => '' }.freeze
  TNEF_HEADERS = [{ 'name' => 'Content-Type', 'value' => 'application/ms-tnef' }].freeze
  ENVELOPE = { 'id' => 'env1', 'name' => 'smime.p7m', 'contentType' => 'application/pkcs7-mime', 'size' => 9 }.freeze

  def setup
    @client = MockApiClient.new
    @api = Teems::Api::Mail.new(@client, mock_account)
  end

  # Syncs one message (overrides on the sample) with this attachment listing; returns its Markdown
  def sync_one(store, listing: [], **overrides)
    @client.stub('/attachments', { 'value' => listing })
    @client.stub('/messages/delta', { 'value' => [sample_mail_message('id' => 'm1', **overrides)],
                                      '@odata.deltaLink' => 'https://g/delta?$deltatoken=d1' })
    Teems::Services::MailSyncEngine.new(api: @api, store: store, options: { attachments: true }).sync(INBOX)
    File.read(File.join(store.folder_dir('Inbox'), store.load_index('Inbox').dig('m1', 'file')))
  end

  def attachment_calls = @client.calls.count { |call| call[:path].include?('/attachments') }

  def test_tnef_wrapped_smime_mail_is_labelled
    with_store do |store|
      content = sync_one(store, listing: [ENVELOPE], 'body' => EMPTY_BODY, 'hasAttachments' => false,
                                'internetMessageHeaders' => TNEF_HEADERS)

      assert_includes content, %(protection: "smime"\n---)
      assert_includes content, "> #{Teems::Models::MailMessage::PROTECTION_NOTES['smime']}\n"
      assert_includes content, 'attachments: ""', 'the envelope is not a file'
      refute Dir.exist?(File.join(store.folder_dir('Inbox'), 'attachments')), 'nor is it saved'
    end
  end

  # Meeting responses and the like often have no body and nothing attached
  def test_an_empty_body_without_an_envelope_is_plain
    with_store do |store|
      content = sync_one(store, 'body' => EMPTY_BODY, 'hasAttachments' => false)

      refute_includes content, 'protection:'
      assert_equal 1, attachment_calls
    end
  end

  # A .p7m next to a real body is something someone attached, not the message's envelope
  def test_a_p7m_beside_a_body_is_an_attachment
    with_store do |store|
      content = sync_one(store, listing: [ENVELOPE], 'hasAttachments' => true)

      refute_includes content, 'protection:'
      assert_includes content, 'attachments: "smime.p7m"'
    end
  end

  # Only messages that could hide an envelope cost an attachment listing
  def test_mail_with_a_body_and_purview_mail_are_not_probed
    with_store do |store|
      sync_one(store, 'hasAttachments' => false)

      assert_equal 0, attachment_calls
    end
    with_store do |store|
      content = sync_one(store, 'body' => EMPTY_BODY, 'hasAttachments' => false,
                                'internetMessageHeaders' => purview_headers)

      assert_equal 0, attachment_calls
      assert_includes content, %(protection: "purview")
    end
  end
end
