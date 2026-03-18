# frozen_string_literal: true

module Teems
  module Api
    # API wrapper for SharePoint file operations via Microsoft Graph
    class Files < Client
      def drive_item(site_id:, list_id:, item_id:)
        get("/v1.0/sites/#{site_id}/lists/#{list_id}/items/#{item_id}/driveItem")
      end
    end
  end
end
