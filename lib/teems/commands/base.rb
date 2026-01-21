# frozen_string_literal: true

module Teems
  module Commands
    # Base class for all CLI commands with option parsing and output helpers
    class Base
      attr_reader :runner, :options, :positional_args

      def initialize(args, runner:)
        @runner = runner
        @options = default_options
        @positional_args = parse_options(args)
      end

      def execute
        raise NotImplementedError, 'Subclass must implement #execute'
      end

      protected

      # Convenience accessors
      def output = runner.output
      def config = runner.config
      def cache_store = runner.cache_store
      def token_store = runner.token_store
      def api_client = runner.api_client

      def default_options
        { verbose: false, quiet: false, json: false, limit: 20 }
      end

      def parse_options(args)
        remaining = []
        args = args.dup
        @unknown_options = []

        while args.any?
          arg = args.shift
          next remaining << arg unless arg.start_with?('-')

          parse_single_option(arg, args, remaining)
        end

        remaining
      end

      private

      def parse_single_option(arg, args, remaining)
        case arg
        when '-n', '--limit' then @options[:limit] = args.shift.to_i
        when '-v', '--verbose' then @options[:verbose] = true
        when '-q', '--quiet' then @options[:quiet] = true
        when '--json' then @options[:json] = true
        when '-h', '--help' then @options[:help] = true
        else handle_option(arg, args, remaining)
        end
      end

      protected

      # Override in subclass to handle command-specific options
      def handle_option(arg, _args, _remaining)
        @unknown_options ||= []
        @unknown_options << arg
        false
      end

      def check_unknown_options
        return nil if @unknown_options.nil? || @unknown_options.empty?

        error("Unknown option: #{@unknown_options.first}")
        error('Run with --help for available options.')
        1
      end

      def unknown_options?
        @unknown_options&.any?
      end

      def show_help?
        @options[:help]
      end

      def show_help
        output.puts help_text
        0
      end

      def validate_options
        return show_help if show_help?
        return check_unknown_options if unknown_options?

        nil
      end

      def help_text
        'No help available for this command.'
      end

      # Output helpers
      def success(message)
        output.success(message) unless @options[:quiet]
      end

      def info(message)
        output.info(message) unless @options[:quiet]
      end

      def warn(message)
        output.warn(message)
      end

      def error(message)
        output.error(message)
        1
      end

      def debug(message)
        output.debug(message) if @options[:verbose]
      end

      def puts(message = '')
        output.puts(message) unless @options[:quiet]
      end

      def print(message)
        output.print(message) unless @options[:quiet]
      end

      def output_json(data)
        output.puts(JSON.pretty_generate(data))
      end

      # Check if account is configured, show error if not
      def require_auth
        return nil if runner.configured?

        error('Not authenticated. Run: teems auth login')
        1
      end

      # Execute a block with automatic token refresh on 401
      # Usage: with_token_refresh { runner.messages_api.chat_messages(chat_id: id) }
      def with_token_refresh
        yield
      rescue ApiError => e
        raise unless e.message.include?('Invalid token') || e.message.include?('expired')

        debug('Token expired, attempting refresh...')
        if runner.refresh_tokens
          debug('Token refreshed, retrying request...')
          yield
        else
          warn('Token refresh failed. Try: teems auth login')
          raise
        end
      end
    end
  end
end
