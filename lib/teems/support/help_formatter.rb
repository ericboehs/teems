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
        lines = []
        lines << @usage
        lines << ''
        lines << @description if @description
        lines << '' if @description

        @sections.each do |section|
          lines << section.render
          lines << ''
        end

        @notes.each do |note|
          lines << "Note: #{note}"
        end

        lines.join("\n")
      end

      # Section within help text
      class Section
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

          @items.each do |type, *args|
            case type
            when :option, :item
              label, desc = args
              lines << "  #{label.ljust(20)} #{desc}"
            when :text
              lines << "  #{args.first}"
            end
          end

          lines.join("\n")
        end
      end
    end
  end
end
