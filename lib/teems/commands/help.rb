# frozen_string_literal: true

module Teems
  module Commands
    # Displays help information for commands
    class Help < Base
      def execute
        topic = positional_args.first

        if topic
          show_command_help(topic)
        else
          show_general_help
        end

        0
      end

      private

      def show_general_help
        puts build_header
        puts build_commands_section
        puts build_options_section
        puts build_examples_section
        puts "Run #{output.cyan('teems <command> --help')} for command-specific help."
      end

      def build_header
        <<~HEADER
          #{output.bold('teems')} - Microsoft Teams CLI v#{VERSION}

          #{output.bold('USAGE:')}
            teems <command> [options]
        HEADER
      end

      def build_commands_section
        <<~COMMANDS
          #{output.bold('COMMANDS:')}
            #{output.cyan('auth')}         Authenticate with Teams
            #{output.cyan('cal')}          List calendar events and view details
            #{output.cyan('channels')}     List joined teams and channels
            #{output.cyan('chats')}        List recent chats
            #{output.cyan('messages')}     Read messages from a channel or chat
            #{output.cyan('sync')}         Sync chat history locally
        COMMANDS
      end

      def build_options_section
        <<~OPTIONS
          #{output.bold('GLOBAL OPTIONS:')}
            -n, --limit N          Number of items to show (default: 20)
            -v, --verbose          Show debug output
            -q, --quiet            Suppress output
            --json                 Output as JSON (where supported)
            -h, --help             Show help
        OPTIONS
      end

      def build_examples_section
        <<~EXAMPLES
          #{output.bold('EXAMPLES:')}
            teems auth login               Authenticate via Safari
            teems auth status              Show authentication status
            teems cal                      List today's calendar events
            teems cal tomorrow             Show tomorrow's events
            teems cal --week               Show this week's events
            teems cal show 3               View details for event #3
            teems cal accept 3             Accept event #3
            teems channels                 List all channels
            teems chats                    List recent chats
            teems messages <channel-id>    Read messages from a channel
        EXAMPLES
      end

      def show_command_help(topic)
        command_class = CLI::COMMANDS[topic]

        if command_class
          runner_stub = Runner.new(output: output)
          cmd = command_class.new(['--help'], runner: runner_stub)
          cmd.execute
        else
          error("Unknown command: #{topic}")
          puts
          puts "Available commands: #{CLI::COMMANDS.keys.join(', ')}"
        end
      end
    end
  end
end
