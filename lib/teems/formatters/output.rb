# frozen_string_literal: true

module Teems
  module Formatters
    # ANSI color wrapping helpers for Output
    module OutputColors
      def red(text) = wrap(:red, text)
      def green(text) = wrap(:green, text)
      def yellow(text) = wrap(:yellow, text)
      def blue(text) = wrap(:blue, text)
      def magenta(text) = wrap(:magenta, text)
      def cyan(text) = wrap(:cyan, text)
      def gray(text) = wrap(:gray, text)
      def bold(text) = wrap(:bold, text)

      def with_verbose(mode = :verbose)
        self.class.new(io: @io, err: @err, color: @color, mode: mode)
      end

      def with_quiet(mode = :quiet)
        self.class.new(io: @io, err: @err, color: @color, mode: mode)
      end
    end

    # Stands in for stdout or stderr once its reader has gone away (see Output#to_stdout)
    module NullIO
      def self.puts(*) = nil
      def self.print(*) = nil
      def self.flush = self
      def self.tty? = false
    end

    # Terminal output with ANSI color support
    class Output
      include OutputColors

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

      def verbose? = @mode == :verbose
      def quiet? = @mode == :quiet
      def tty? = @io.tty?

      def puts(message = '')
        write_unless_quiet { |io| io.puts(message) }
      end

      def print(message)
        write_unless_quiet { |io| io.print(message) }
      end

      def flush
        to_stdout(&:flush)
      end

      def error(message)
        to_stderr { |err| err.puts(colorize("#{red('Error:')} #{message}")) }
      end

      def warn(message)
        to_stderr { |err| err.puts(colorize("#{yellow('Warning:')} #{message}")) } unless quiet?
      end

      # A question for the person at the terminal: on stderr, so piped stdout stays data, and
      # shown under --quiet too, since an unseen question would just hang (stderr is unbuffered)
      def prompt(message)
        to_stderr { |err| err.print(message) }
      end

      def success(message)
        puts(colorize("#{green('✓')} #{message}"))
      end

      def info(message)
        puts(colorize(message))
      end

      def debug(message)
        return unless verbose?

        to_stderr { |err| err.puts(colorize("#{gray('[debug]')} #{message}")) }
      end

      private

      def write_unless_quiet(&)
        to_stdout(&) unless quiet?
      end

      # A reader that stops early (`teems ... | head`) is not an error: drop the
      # rest of stdout and let the command finish quietly. Raising instead would
      # surface as "Unexpected error: Broken pipe", or be caught by a per-item
      # rescue and reported as a failed chat or download.
      def to_stdout
        yield @io
      rescue Errno::EPIPE
        @io = NullIO
      end

      # The same for stderr, which `teems ... 2>&1 | head` closes along with stdout. A
      # warning that raised here would also escape the per-item rescues that report it.
      def to_stderr
        yield @err
      rescue Errno::EPIPE
        @err = NullIO
      end

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
