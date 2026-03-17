# frozen_string_literal: true

require 'test_helper'

# Tests for the Chats API wrapper (conversations and members)
class ApiChatsTest < Minitest::Test
  def test_list_calls_correct_endpoint
    api_client = Teems::TestHelpers::MockApiClient.new
    api_client.stub('conversations', { 'conversations' => [] })
    account = mock_account
    chats = Teems::Api::Chats.new(api_client, account)

    chats.list

    call = api_client.calls.last
    assert_equal :get, call[:method]
    assert_includes call[:path], '/v1/users/ME/conversations'
  end

  def test_list_passes_limit_as_page_size
    api_client = Teems::TestHelpers::MockApiClient.new
    api_client.stub('conversations', { 'conversations' => [] })
    account = mock_account
    chats = Teems::Api::Chats.new(api_client, account)

    chats.list(limit: 25)

    call = api_client.calls.last
    assert_equal 25, call[:params][:pageSize]
  end

  def test_list_default_limit
    api_client = Teems::TestHelpers::MockApiClient.new
    api_client.stub('conversations', { 'conversations' => [] })
    account = mock_account
    chats = Teems::Api::Chats.new(api_client, account)

    chats.list

    call = api_client.calls.last
    assert_equal 50, call[:params][:pageSize]
  end

  def test_get_chat_calls_correct_endpoint
    api_client = Teems::TestHelpers::MockApiClient.new
    api_client.stub('conversations', {})
    account = mock_account
    chats = Teems::Api::Chats.new(api_client, account)

    chats.get_chat(chat_id: '19:abc@thread.v2')

    call = api_client.calls.last
    assert_equal :get, call[:method]
    assert_includes call[:path], '/v1/users/ME/conversations/'
  end

  def test_get_chat_url_encodes_id
    api_client = Teems::TestHelpers::MockApiClient.new
    api_client.stub('conversations', {})
    account = mock_account
    chats = Teems::Api::Chats.new(api_client, account)

    chats.get_chat(chat_id: '19:abc@thread.v2')

    call = api_client.calls.last
    assert_includes call[:path], '19%3Aabc%40thread.v2'
  end

  def test_members_calls_correct_endpoint
    api_client = Teems::TestHelpers::MockApiClient.new
    api_client.stub('members', { 'members' => [] })
    account = mock_account
    chats = Teems::Api::Chats.new(api_client, account)

    chats.members(chat_id: '19:abc@thread.v2')

    call = api_client.calls.last
    call_path = call[:path]
    assert_equal :get, call[:method]
    assert_includes call_path, '/v1/threads/'
    assert_includes call_path, '/members'
  end

  def test_members_url_encodes_id
    api_client = Teems::TestHelpers::MockApiClient.new
    api_client.stub('members', { 'members' => [] })
    account = mock_account
    chats = Teems::Api::Chats.new(api_client, account)

    chats.members(chat_id: '19:abc@thread.v2')

    call = api_client.calls.last
    assert_includes call[:path], '19%3Aabc%40thread.v2'
  end
end
