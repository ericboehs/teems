# frozen_string_literal: true

require 'cgi'

module Teems
  module Models
    # Extracts inline images (screenshots pasted into a message) from Teams message HTML.
    # Teams stores them in its AMS object store and references them with
    # <img itemtype="http://schema.skype.com/AMSImage" src="https://<ams-host>/v1/objects/<id>/views/imgo">.
    module InlineImageParsing
      IMG_TAG = /<img\b[^>]*>/i
      ATTRIBUTE = /([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/
      AMS_ITEMTYPE = 'schema.skype.com/AMSImage'
      AMS_PATH = %r{\Ahttps://[^/\s]+/v1/objects/([^/?#\s]+)/views/}

      module_function

      def parse(html)
        return [] unless html.is_a?(String) && html.match?(/<img/i)

        html.scan(IMG_TAG).filter_map { |tag| image_from(tag_attributes(tag)) }.uniq(&:url)
      end

      def tag_attributes(tag)
        tag.scan(ATTRIBUTE).to_h { |name, double, single| [name.downcase, CGI.unescapeHTML(double || single)] }
      end

      def image_from(attrs)
        url = attrs['src'].to_s
        return unless ams_image?(attrs, url)

        InlineImage.new(id: attrs['itemid'] || url[AMS_PATH, 1], url: url, alt: attrs['alt'],
                        width: dimension(attrs['width']), height: dimension(attrs['height']),
                        format: attrs['itemscope'])
      end

      def ams_image?(attrs, url)
        url.start_with?('https://') && (attrs['itemtype'].to_s.include?(AMS_ITEMTYPE) || url.match?(AMS_PATH))
      end

      def dimension(value) = Integer(value.to_s, exception: false)&.then { |num| num.positive? ? num : nil }
    end

    # An image pasted inline into a Teams message body
    InlineImage = Data.define(:id, :url, :alt, :width, :height, :format) do
      def self.parse_html(html) = InlineImageParsing.parse(html)

      # Rebuilds an image from its stored (JSON) hash form
      def self.from_h(hash)
        return unless hash.is_a?(Hash)

        attrs = hash.transform_keys(&:to_sym).slice(*members)
        attrs[:url] ? new(**attrs) : nil
      end

      # Only the URL is required; the other attributes default to nil
      def initialize(url:, **optional)
        super(url: url, id: nil, alt: nil, width: nil, height: nil, format: nil, **optional)
      end

      # The original upload: `src` usually points at a recompressed JPEG preview,
      # while this view is what Teams opens for "view full image".
      def full_size_url
        url.sub(%r{(/v1/objects/[^/]+/views/)[^/?#]+}, '\1imgpsh_fullsize_anim')
      end

      # JSON form: the stored attributes plus the original-resolution URL
      def as_json = to_h.merge(full_size_url: full_size_url)

      def dimensions = width && height ? "#{width}x#{height}" : nil

      def label
        name = alt.to_s.strip
        name = 'image' if name.empty?
        size = dimensions
        size ? "#{name} (#{size})" : name
      end

      # Filesystem-safe name derived from the AMS object id
      def file_stem = (id || url[%r{/v1/objects/([^/]+)/}, 1] || 'image').to_s.gsub(/[^\w.-]/, '_')
    end
  end
end
