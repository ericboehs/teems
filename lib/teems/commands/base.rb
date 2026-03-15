# frozen_string_literal: true

module Teems
  module Commands
    # Base class for all CLI commands with option parsing and output helpers
    class Base
      attr_reader :runner, :options, :positional_args

      def initialize(args, runner:)
        @runner = runner
        @options = default_options
        @unknown_options = []
        @positional_args = []
        parse_options(args)
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
        pending = args.dup
        while pending.any?
          arg = pending.shift
          if arg.start_with?('-')
            parse_single_option(arg, pending)
          else
            @positional_args << arg
          end
        end
        @positional_args
      end

      private

      def parse_single_option(arg, pending)
        case arg
        when '-n', '--limit' then @options[:limit] = pending.shift.to_i
        when '-v', '--verbose' then @options[:verbose] = true
        when '-q', '--quiet' then @options[:quiet] = true
        when '--json' then @options[:json] = true
        when '-h', '--help' then @options[:help] = true
        else handle_option(arg, pending)
        end
      end

      protected

      # Override in subclass to handle command-specific options
      def handle_option(arg, _pending)
        @unknown_options << arg
      end

      def check_unknown_options
        return nil if @unknown_options.empty?

        error("Unknown option: #{@unknown_options.first}")
        error('Run with --help for available options.')
        1
      end

      def unknown_options?
        @unknown_options.any?
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
      def success(msg) = @options[:quiet] || output.success(msg)
      def info(msg) = @options[:quiet] || output.info(msg)
      def warn(message) = output.warn(message)

      def error(message)
        output.error(message)
        1
      end

      def debug(msg) = @options[:verbose] && output.debug(msg)
      def puts(message = '') = @options[:quiet] || output.puts(message)
      def print(msg) = @options[:quiet] || output.print(msg)
      def output_json(data) = output.puts(JSON.pretty_generate(data))

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
        raise unless e.unauthorized? || e.message.include?('expired')

        debug('Token expired, attempting refresh...')
        raise unless runner.refresh_tokens

        debug('Token refreshed, retrying request...')
        yield
      end
    end
  end
end
