# frozen_string_literal: true

module Teems
  module Formatters
    # Terminal output with ANSI color support
    class Output
      COLORS = {
        red: "\e[0;31m",
        green: "\e[0;32m",
        yellow: "\e[0;33m",
        blue: "\e[0;34m",
        magenta: "\e[0;35m",
        cyan: "\e[0;36m",
        gray: "\e[0;90m",
        bold: "\e[1m",
        reset: "\e[0m"
      }.freeze

      attr_reader :mode

      def initialize(io: $stdout, err: $stderr, color: nil, mode: :normal)
        @io = io
        @err = err
        @color = [true, false].include?(color) ? color : io.tty?
        @mode = mode
      end

      def verbose = @mode == :verbose
      def quiet = @mode == :quiet
      alias quiet? quiet

      def puts(message = '')
        @io.puts(message) unless quiet?
      end

      def print(message)
        @io.print(message) unless quiet?
      end

      def flush
        @io.flush
      end

      def error(message)
        @err.puts(colorize("#{red('Error:')} #{message}"))
      end

      def warn(message)
        @err.puts(colorize("#{yellow('Warning:')} #{message}")) unless quiet?
      end

      def success(message)
        puts(colorize("#{green('✓')} #{message}"))
      end

      def info(message)
        puts(colorize(message))
      end

      def debug(message)
        return unless verbose

        @err.puts(colorize("#{gray('[debug]')} #{message}"))
      end

      # Color helpers
      def red(text) = wrap(:red, text)
      def green(text) = wrap(:green, text)
      def yellow(text) = wrap(:yellow, text)
      def blue(text) = wrap(:blue, text)
      def magenta(text) = wrap(:magenta, text)
      def cyan(text) = wrap(:cyan, text)
      def gray(text) = wrap(:gray, text)
      def bold(text) = wrap(:bold, text)

      def with_verbose(value)
        self.class.new(io: @io, err: @err, color: @color, mode: value ? :verbose : :normal)
      end

      def with_quiet(value)
        self.class.new(io: @io, err: @err, color: @color, mode: value ? :quiet : :normal)
      end

      private

      def wrap(color, text)
        return text.to_s unless @color

        "#{COLORS[color]}#{text}#{COLORS[:reset]}"
      end

      def colorize(text)
        text
      end
    end
  end
end
