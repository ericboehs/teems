# frozen_string_literal: true

require 'test_helper'

class TeamsUrlParserTest < Minitest::Test
  def test_parse_chat_url
    url = 'https://teams.microsoft.com/l/message/19:cc1bfd83bde443f0a9caa23026308bc9@thread.v2/1769003118480?context=%7B%22contextType%22%3A%22chat%22%7D'

    result = Teems::Services::TeamsUrlParser.parse(url)

    assert_equal '19:cc1bfd83bde443f0a9caa23026308bc9@thread.v2', result.conversation_id
    assert_equal '1769003118480', result.message_id
    assert_equal 'chat', result.context_type
    assert_nil result.team_id
  end

  def test_parse_channel_url
    url = 'https://teams.microsoft.com/l/message/19:abc123@thread.tacv2/1769003118480?context=%7B%22contextType%22%3A%22channel%22%2C%22channelId%22%3A%2219%3Aabc123%40thread.tacv2%22%2C%22teamId%22%3A%22team-uuid-here%22%7D'

    result = Teems::Services::TeamsUrlParser.parse(url)

    assert_equal '19:abc123@thread.tacv2', result.conversation_id
    assert_equal '1769003118480', result.message_id
    assert_equal 'channel', result.context_type
    assert_equal 'team-uuid-here', result.team_id
  end

  def test_parse_url_with_encoded_conversation_id
    url = 'https://teams.microsoft.com/l/message/19%3Atest%40thread.v2/123456789?context=%7B%22contextType%22%3A%22chat%22%7D'

    result = Teems::Services::TeamsUrlParser.parse(url)

    assert_equal '19:test@thread.v2', result.conversation_id
  end

  def test_parse_url_without_context
    url = 'https://teams.microsoft.com/l/message/19:abc@thread.v2/123456789'

    result = Teems::Services::TeamsUrlParser.parse(url)

    assert_equal '19:abc@thread.v2', result.conversation_id
    assert_equal '123456789', result.message_id
    assert_nil result.context_type
    assert_nil result.team_id
  end

  def test_parse_returns_nil_for_invalid_path
    url = 'https://teams.microsoft.com/l/chat/19:abc@thread.v2'

    result = Teems::Services::TeamsUrlParser.parse(url)

    assert_nil result
  end

  def test_parse_returns_nil_for_non_teams_url
    url = 'https://example.com/l/message/19:abc@thread.v2/123'

    result = Teems::Services::TeamsUrlParser.parse(url)

    assert_nil result
  end

  def test_parse_returns_nil_for_invalid_uri
    url = 'not a valid url at all'

    result = Teems::Services::TeamsUrlParser.parse(url)

    assert_nil result
  end

  def test_parse_returns_nil_for_malformed_context_json
    url = 'https://teams.microsoft.com/l/message/19:abc@thread.v2/123?context=not-valid-json'

    result = Teems::Services::TeamsUrlParser.parse(url)

    assert_equal '19:abc@thread.v2', result.conversation_id
    assert_nil result.context_type
  end

  def test_teams_url_returns_true_for_teams_url
    assert Teems::Services::TeamsUrlParser.teams_url?('https://teams.microsoft.com/l/message/...')
  end

  def test_teams_url_returns_false_for_non_teams_url
    refute Teems::Services::TeamsUrlParser.teams_url?('https://example.com/...')
  end

  def test_teams_url_returns_false_for_invalid_uri
    refute Teems::Services::TeamsUrlParser.teams_url?('not a url')
  end

  def test_teams_url_accepts_uri_object
    uri = URI.parse('https://teams.microsoft.com/l/message/test')

    assert Teems::Services::TeamsUrlParser.teams_url?(uri)
  end
end
