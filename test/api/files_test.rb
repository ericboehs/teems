# frozen_string_literal: true

require 'test_helper'

# Tests for the Files API wrapper (SharePoint driveItem lookup)
module FilesApiTests
  # Tests for resolving SharePoint driveItem via Graph API
  class DriveItemTest < Minitest::Test
    def setup
      @api_client = Teems::TestHelpers::MockApiClient.new
      @account = mock_account
      @files_api = Teems::Api::Files.new(@api_client, @account)
    end

    def test_drive_item_calls_correct_endpoint
      @api_client.stub('driveItem', drive_item_response)
      @files_api.drive_item(site_id: 'site-1', list_id: 'list-2', item_id: 'item-3')
      call = @api_client.calls.first
      assert_equal :get, call[:method]
      assert_includes call[:path], '/v1.0/sites/site-1/lists/list-2/items/item-3/driveItem'
    end

    def test_drive_item_returns_response_with_download_url
      @api_client.stub('driveItem', drive_item_response)
      result = @files_api.drive_item(site_id: 'site-1', list_id: 'list-2', item_id: 'item-3')
      assert_equal 'https://example.com/download/report.pdf', result['@microsoft.graph.downloadUrl']
    end

    def test_drive_item_passes_account
      @api_client.stub('driveItem', drive_item_response)
      @files_api.drive_item(site_id: 's', list_id: 'l', item_id: 'i')
      assert_equal @account, @api_client.calls.first[:account]
    end

    private

    def drive_item_response
      { '@microsoft.graph.downloadUrl' => 'https://example.com/download/report.pdf',
        'name' => 'report.pdf', 'size' => 12_345 }
    end
  end
end
