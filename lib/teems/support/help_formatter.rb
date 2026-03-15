# frozen_string_literal: true

module Teems
  module Support
    # Formats help text for commands
    class HelpFormatter
      def initialize(usage)
        @usage = usage
        @description = nil
        @sections = []
        @notes = []
      end

      def description(text)
        @description = text
      end

      def note(text)
        @notes << text
      end

      def section(title)
        section = Section.new(title)
        yield section
        @sections << section
      end

      def render
        lines = [@usage, '']
        lines.push(@description, '') if @description
        @sections.each { |section| lines.push(section.render, '') }
        @notes.each { |note| lines << "Note: #{note}" }
        lines.join("\n")
      end

      # Section within help text
      class Section
        ITEM_RENDERERS = {
          option: ->(args) { "  #{args[0].ljust(20)} #{args[1]}" },
          item: ->(args) { "  #{args[0].ljust(20)} #{args[1]}" },
          text: ->(args) { "  #{args.first}" }
        }.freeze

        def initialize(title)
          @title = title
          @items = []
        end

        def option(flags, description)
          @items << [:option, flags, description]
        end

        def item(label, description)
          @items << [:item, label, description]
        end

        def text(content)
          @items << [:text, content]
        end

        def render
          lines = ["#{@title}:"]
          @items.each { |type, *args| lines << render_item(type, args) }
          lines.join("\n")
        end

        private

        def render_item(type, args)
          ITEM_RENDERERS[type]&.call(args)
        end
      end
    end
  end
end
