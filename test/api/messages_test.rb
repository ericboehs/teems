# frozen_string_literal: true

require 'test_helper'

class MessagesApiTest < Minitest::Test
  def setup
    @api_client = Teems::TestHelpers::MockApiClient.new
    @account = mock_account
    @messages_api = Teems::Api::Messages.new(@api_client, @account)
  end

  def test_chat_messages_calls_correct_endpoint
    @api_client.stub('messages', { 'messages' => [] })

    @messages_api.chat_messages(chat_id: '19:abc@thread.v2')

    call = @api_client.calls.first
    assert_equal :get, call[:method]
    assert_includes call[:path], '19%3Aabc%40thread.v2'
    assert_includes call[:path], 'messages'
  end

  def test_chat_messages_passes_limit
    @api_client.stub('messages', { 'messages' => [] })

    @messages_api.chat_messages(chat_id: '19:abc@thread.v2', limit: 100)

    call = @api_client.calls.first
    assert_equal 100, call[:params][:pageSize]
  end

  def test_channel_messages_calls_correct_endpoint
    @api_client.stub('messages', { 'messages' => [] })

    @messages_api.channel_messages(team_id: 'team-1', channel_id: '19:chan@thread.tacv2')

    call = @api_client.calls.first
    assert_equal :get, call[:method]
    assert_includes call[:path], '19%3Achan%40thread.tacv2'
  end

  def test_chat_messages_page_without_backward_link
    @api_client.stub('messages', { 'messages' => [], '_metadata' => {} })

    @messages_api.chat_messages_page(chat_id: '19:abc@thread.v2', limit: 200)

    call = @api_client.calls.first
    assert_equal :get, call[:method]
    assert_includes call[:path], '19%3Aabc%40thread.v2'
    assert_equal 200, call[:params][:pageSize]
  end

  def test_chat_messages_page_with_start_time
    @api_client.stub('messages', { 'messages' => [], '_metadata' => {} })
    start = Time.new(2026, 1, 1, 0, 0, 0, '+00:00')

    @messages_api.chat_messages_page(chat_id: '19:abc@thread.v2', start_time: start)

    call = @api_client.calls.first
    assert call[:params][:startTime]
    assert_kind_of Integer, call[:params][:startTime]
  end

  def test_chat_messages_page_with_backward_link
    backward_link = '/v1/users/ME/conversations/19%3Aabc%40thread.v2/messages?syncState=abc123&pageSize=200'
    @api_client.stub(backward_link, { 'messages' => [], '_metadata' => {} })

    @messages_api.chat_messages_page(chat_id: '19:abc@thread.v2', backward_link: backward_link)

    call = @api_client.calls.first
    assert_equal backward_link, call[:path]
  end

  def test_replies_calls_correct_endpoint
    @api_client.stub('replies', { 'messages' => [] })

    @messages_api.replies(thread_id: '19:abc@thread.v2', message_id: '12345')

    call = @api_client.calls.first
    assert_equal :get, call[:method]
    assert_includes call[:path], '12345/replies'
  end
end
