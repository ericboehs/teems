# frozen_string_literal: true

require 'test_helper'

class MailApiTest < Minitest::Test
  def setup
    @client = MockApiClient.new
    @api = Teems::Api::Mail.new(@client, mock_account)
  end

  def call(index = 0) = @client.calls[index]

  def test_folders
    @client.stub('/v1.0/me/mailFolders', { 'value' => [sample_mail_folder] })

    assert_equal(['Inbox'], @api.folders.map { |folder| folder['displayName'] })
    assert_includes call[:params]['$select'], 'unreadItemCount'
  end

  def test_child_folders
    @client.stub('childFolders', { 'value' => [sample_mail_folder('Child')] })

    assert_equal(['Child'], @api.folders(parent_id: 'abc/def').map { |folder| folder['displayName'] })
    assert_equal '/v1.0/me/mailFolders/abc%2Fdef/childFolders', call[:path]
  end

  def test_messages_flagged_and_unread
    @api.messages(folder: 'inbox', count: 5, only: %i[unread flagged])

    assert_equal "receivedDateTime ge 1900-01-01T00:00:00Z and isRead eq false and flag/flagStatus eq 'flagged'",
                 call[:params]['$filter']
    assert_includes call[:params]['$select'], 'flag'
  end

  def test_actions_update_and_move_by_immutable_id
    actions = Teems::Api::MailActions.new(@client, mock_account)
    actions.update('id/with+chars', { isRead: true })
    actions.move('id/with+chars', 'archive')

    assert_equal [:patch, '/v1.0/me/messages/id%2Fwith%2Bchars', { isRead: true }],
                 call.values_at(:method, :path, :body)
    assert_equal [:post, '/v1.0/me/messages/id%2Fwith%2Bchars/move', { destinationId: 'archive' }],
                 call(1).values_at(:method, :path, :body)
    assert_equal ['IdType="ImmutableId"'], @client.calls.map { |request| request[:headers]['Prefer'] }.uniq
  end

  def test_folder
    @client.stub('/mailFolders/inbox', sample_mail_folder)

    assert_equal 'Inbox', @api.folder('inbox')['displayName']
  end

  def test_messages_newest_first_with_unread_filter
    @client.stub('/messages', { 'value' => [sample_mail_message('id' => 'a')] })
    @api.messages(folder: 'inbox', count: 2, only: [:unread])
    params = call[:params]

    assert_equal 'receivedDateTime desc', params['$orderby']
    assert_equal 'receivedDateTime ge 1900-01-01T00:00:00Z and isRead eq false', params['$filter']
    assert_equal 2, params['$top']
    assert_equal 'IdType="ImmutableId"', call[:headers]['Prefer']
  end

  def test_messages_follow_next_link
    @client.stub('page2', { 'value' => [sample_mail_message('id' => 'b')] })
    @client.stub('/messages', { 'value' => [sample_mail_message('id' => 'a')], '@odata.nextLink' => 'https://g/page2' })

    assert_equal %w[a b], @api.messages(folder: 'inbox', count: 2).map(&:id)
    assert_equal 'https://g/page2', call(1)[:path]
  end

  def test_messages_stop_at_count
    @client.stub('/messages', { 'value' => [sample_mail_message('id' => 'a'), sample_mail_message('id' => 'b')],
                                '@odata.nextLink' => 'https://g/page2' })

    assert_equal ['a'], @api.messages(folder: 'inbox', count: 1).map(&:id)
    assert_equal 1, @client.calls.length
    refute call[:params].key?('$filter')
  end

  def test_message
    @client.stub('/v1.0/me/messages/', sample_mail_message)

    assert_equal 'Quarterly report: Q3', @api.message('id/with+chars').subject
    assert_equal '/v1.0/me/messages/id%2Fwith%2Bchars', call[:path]
    assert_includes call[:params]['$select'], 'body'
  end

  def test_search_quotes_query_and_scopes_to_folder
    @client.stub('/messages', { 'value' => [sample_mail_message] })

    @api.search(query: 'subject:"q3" \\x', count: 5)
    @api.search(query: 'q3', count: 5, folder: 'archive')

    assert_equal '/v1.0/me/messages', call[:path]
    assert_equal '"subject:\\"q3\\" \\\\x"', call[:params]['$search']
    assert_equal '/v1.0/me/mailFolders/archive/messages', call(1)[:path]
  end

  def test_delta_since
    @client.stub('delta', { 'value' => [] })
    @api.delta(folder: 'inbox', since: Time.utc(2026, 10, 1, 5))

    assert_equal '/v1.0/me/mailFolders/inbox/messages/delta', call[:path]
    assert_equal 'receivedDateTime ge 2026-10-01T05:00:00Z', call[:params]['$filter']
    assert_includes call[:headers]['Prefer'], 'odata.maxpagesize=50'
  end

  def test_delta_without_since_and_delta_page
    @client.stub('delta', { 'value' => [] })
    @api.delta(folder: 'inbox')
    @api.delta_page('https://g/delta?$deltatoken=x')

    refute call[:params].key?('$filter')
    assert_equal 'https://g/delta?$deltatoken=x', call(1)[:path]
  end

  def test_attachments
    @client.stub('/attachments/', { 'name' => 'a.pdf', 'contentBytes' => 'aGk=' })
    @client.stub('/attachments', { 'value' => [{ 'id' => 'att', 'name' => 'a.pdf' }] })

    assert_equal(['a.pdf'], @api.attachments('m1').map { |item| item['name'] })
    assert_equal 'aGk=', @api.attachment('m1', 'att')['contentBytes']
    assert_equal '/v1.0/me/messages/m1/attachments/att', call(1)[:path]
  end
end
