# frozen_string_literal: true

require 'test_helper'

# Tests for the Meetings API wrapper (Graph shares API)
module MeetingsApiTests
  # Tests for share_preview and share_item via Graph shares endpoint
  class SharesTest < Minitest::Test
    def setup
      @api_client = Teems::TestHelpers::MockApiClient.new
      @account = mock_account
      @meetings_api = Teems::Api::Meetings.new(@api_client, @account)
    end

    def test_share_preview_calls_post_with_encoded_url
      @api_client.stub('shares', { 'getUrl' => 'https://embed.example.com' })
      @meetings_api.share_preview('https://example.sharepoint.com/file')
      call = @api_client.calls.first
      assert_equal :post, call[:method]
      assert_includes call[:path], '/v1.0/shares/u!'
      assert_includes call[:path], '/driveItem/preview'
    end

    def test_share_item_calls_get_with_encoded_url
      @api_client.stub('shares', { 'name' => 'recording.mp4' })
      @meetings_api.share_item('https://example.sharepoint.com/file')
      call = @api_client.calls.first
      assert_equal :get, call[:method]
      assert_includes call[:path], '/v1.0/shares/u!'
      assert_includes call[:path], '/driveItem'
    end

    def test_share_item_passes_select_param
      @api_client.stub('shares', { 'name' => 'recording.mp4' })
      @meetings_api.share_item('https://example.sharepoint.com/file', select: 'name,size')
      call = @api_client.calls.first
      assert_equal({ '$select' => 'name,size' }, call[:params])
    end

    def test_share_preview_passes_account
      @api_client.stub('shares', {})
      @meetings_api.share_preview('https://example.sharepoint.com/file')
      assert_equal @account, @api_client.calls.first[:account]
    end

    def test_share_item_returns_response
      expected = { 'name' => 'recording.mp4', 'size' => 5000 }
      @api_client.stub('shares', expected)
      result = @meetings_api.share_item('https://example.sharepoint.com/file')
      assert_equal 'recording.mp4', result['name']
    end
  end
end
