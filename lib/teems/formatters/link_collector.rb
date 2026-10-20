# frozen_string_literal: true

module Teems
  module Formatters
    # Collects the anchors of an HTML body, one entry per cleaned URL, numbered by first
    # appearance. A later anchor for the same URL supplies the label when the first had none.
    class LinkCollector
      LABEL_MAX = 80

      def initialize
        @links = {}
        @current = nil
      end

      def links = @links.to_a

      def empty? = @links.empty?

      def capturing? = @current.is_a?(Hash)

      def start(href)
        finish
        @current = { href: href, text: +'', alt: [] }
      end

      def add_text(text)
        @current[:text] << text if @current
      end

      def add_alt(alt)
        @current[:alt] << alt if @current && !alt.empty?
      end

      # Ends the current anchor; returns its footer number, or nil when it is not listed
      def finish
        current = @current
        return unless current

        @current = nil
        register(current[:href].strip, anchor_text(current))
      end

      def footer
        return '' if empty?

        lines = links.each.with_index(1).map do |(url, label), number|
          label.empty? ? "[#{number}] #{url}" : "[#{number}] #{label} <#{url}>"
        end
        ['Links:', *lines].join("\n")
      end

      private

      def anchor_text(current)
        text = current[:text]
        text.strip.empty? ? current[:alt].join(' ') : text
      end

      def register(href, text)
        return if LinkCleaner.skip?(href)

        url = LinkCleaner.clean(href)
        @links[url] = LinkCleaner.label(text, url, max: LABEL_MAX) if @links.fetch(url, '').empty?
        @links.keys.index(url) + 1
      end
    end
  end
end
