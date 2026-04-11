# frozen_string_literal: true

module Teems
  module Api
    # API wrapper for meeting-related endpoints (Graph shares API)
    class Meetings < Client
      def share_preview(sharing_url)
        encoded = encode_sharing_url(sharing_url)
        post("/v1.0/shares/u!#{encoded}/driveItem/preview")
      end

      def share_item(sharing_url, select: nil)
        encoded = encode_sharing_url(sharing_url)
        params = select ? { '$select' => select } : {}
        get("/v1.0/shares/u!#{encoded}/driveItem", params: params)
      end

      private

      def encode_sharing_url(url)
        [url].pack('m0').tr('+/', '-_').delete('=')
      end
    end
  end
end
