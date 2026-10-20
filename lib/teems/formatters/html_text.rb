# frozen_string_literal: true

module Teems
  module Formatters
    # Tag groups used by HtmlText
    module HtmlTags
      # Removed with their contents before conversion
      DROPPED = %r{<(head|style|script|title|xml)\b[^>]*>.*?</\1\s*>}im
      COMMENTS = /<!--.*?-->/m
      TOKENS = /<[^>]*>|<|[^<]+/m
      BLOCKS = %w[address article blockquote center dd div dl dt footer form h1 h2 h3 h4 h5 h6 header
                  li ol section table tbody thead tfoot tr ul].freeze

      module_function

      # [name, closing?] for a tag token, or nil for anything that is not a tag
      def parse(token)
        match = token.match(%r{\A<\s*(/?)\s*([a-zA-Z][a-zA-Z0-9:-]*)})
        match && [match[2].downcase, !match[1].empty?]
      end

      def attribute(token, name)
        match = token.match(/\s#{name}\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/i)
        match && HtmlEntities.decode(match.captures.compact.first)
      end
    end

    # Accumulates converted text, tracking line starts so block boundaries never stack up
    # more newlines than asked for and indentation from source HTML never leaks in
    class TextBuffer
      ZERO_WIDTH = /[\u200b\u200c\u200d\u2060\ufeff\u034f\u00ad]/

      def initialize
        @out = +''
      end

      def <<(text)
        @out << text
        self
      end

      # Inline text with source whitespace collapsed; << keeps it as-is
      def add_text(text)
        collapsed = text.gsub(/[ \t\r\n\f]+/, ' ')
        self << (line_start? ? collapsed.lstrip : collapsed)
      end

      def line_break
        trim_line_end
        self << "\n"
      end

      # At least count newlines at the end, without adding to ones already there
      def ensure_newlines(count)
        return self if @out.empty?

        trim_line_end
        missing = count - trailing_newlines(count)
        missing.positive? ? self << ("\n" * missing) : self
      end

      def space
        @out.end_with?(' ', "\n") || @out.empty? ? self : self << ' '
      end

      def line_start? = @out.empty? || @out.end_with?("\n")

      def to_s
        text = @out.tr("\u00a0", ' ').gsub(ZERO_WIDTH, '').gsub(/[ \t]+$/, '')
        text.gsub(/\n{3,}/, "\n\n").sub(/\A\n+/, '').rstrip
      end

      private

      # Both helpers look only at the end of the buffer. An end-anchored regex such as
      # /[ \t]+\z/ is scanned from the start, which made long messages quadratic.
      def trim_line_end
        @out.chop! while @out.end_with?(' ', "\t")
      end

      # Newlines already at the end, counting no further than limit
      def trailing_newlines(limit) = (1..limit).count { |run| @out.end_with?("\n" * run) }
    end

    # Converts an HTML mail body to plain text. Each anchor's text stays inline followed by
    # a [N] marker, and the URLs are listed once each in a numbered "Links:" footer
    # (SafeLinks unwrapped, click tracking dropped, mailto:/tel:/cid: skipped).
    class HtmlText
      # Converted text and its "Links:" footer ('' when there are no links)
      Result = Data.define(:text, :footer) do
        # Text with the footer appended after a blank line, or the text alone when there are no links
        def to_s = footer.empty? ? text : "#{text}\n\n#{footer}"
      end

      OPEN_TAGS = {
        'a' => :open_anchor, 'br' => :line_break, 'p' => :open_paragraph, 'li' => :open_list_item,
        'img' => :image, 'hr' => :rule, 'pre' => :open_pre, 'td' => :cell, 'th' => :cell
      }.freeze
      CLOSE_TAGS = { 'a' => :close_anchor, 'br' => :line_break, 'p' => :close_paragraph, 'pre' => :close_pre }.freeze

      def self.convert(html) = new.convert(html.to_s)

      def initialize
        @buffer = TextBuffer.new
        @links = LinkCollector.new
        # Preformatted text, and whether the open <p> is one of Outlook's one-line paragraphs
        @state = { pre: false, outlook_paragraph: false }
      end

      def convert(html)
        tokens(html).each { |token| token.start_with?('<') ? tag(token) : text(token) }
        close_anchor
        Result.new(text: @buffer.to_s, footer: @links.footer)
      end

      private

      def tokens(html)
        Support::ControlChars.strip(html.scrub('')).gsub(HtmlTags::COMMENTS, '').gsub(HtmlTags::DROPPED, '').scan(HtmlTags::TOKENS)
      end

      def tag(token)
        name, closing = HtmlTags.parse(token)
        return text(token) unless name

        handler = (closing ? CLOSE_TAGS : OPEN_TAGS)[name]
        return send(handler, token) if handler

        @buffer.ensure_newlines(1) if HtmlTags::BLOCKS.include?(name)
      end

      def text(token)
        chunk = HtmlEntities.decode(token)
        @state[:pre] ? @buffer << chunk : @buffer.add_text(chunk)
        @links.add_text(chunk)
      end

      def open_anchor(token)
        href = HtmlTags.attribute(token, 'href')
        href ? @links.start(href) : close_anchor
      end

      def close_anchor(_token = nil)
        number = @links.finish
        @buffer.space << "[#{number}]" if number
      end

      def line_break(_token) = @buffer.line_break

      # Outlook writes every line as its own <p class=MsoNormal>, with &nbsp; paragraphs for
      # blank lines, so those end with one newline; other paragraphs get a blank line.
      def open_paragraph(token)
        @state[:outlook_paragraph] = HtmlTags.attribute(token, 'class').to_s.match?(/\bMso/i)
        @buffer.ensure_newlines(1)
      end

      def close_paragraph(_token) = @buffer.ensure_newlines(@state[:outlook_paragraph] ? 1 : 2)

      def open_list_item(_token) = @buffer.ensure_newlines(1) << '- '

      def image(token)
        @links.add_alt(HtmlTags.attribute(token, 'alt').to_s) if @links.capturing?
      end

      def rule(_token) = @buffer.ensure_newlines(1) << "#{'_' * 32}\n"

      def open_pre(_token) = pre(true)

      def close_pre(_token) = pre(false)

      def pre(enabled)
        @buffer.ensure_newlines(1)
        @state[:pre] = enabled
      end

      def cell(_token)
        @buffer.space unless @buffer.line_start?
      end
    end
  end
end
