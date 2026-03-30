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
        lines = command_descriptions.map { |name, desc| "    #{output.cyan(name.ljust(12))} #{desc}" }
        "#{output.bold('COMMANDS:')}\n#{lines.join("\n")}\n\n"
      end

      def command_descriptions
        [['activity', 'Show activity feed (mentions, reactions, calendar)'],
         ['auth', 'Authenticate with Teams'],
         ['cal', 'List calendar events and view details'],
         ['channels', 'List joined teams and channels'],
         ['chats', 'List recent chats'],
         ['messages', 'Read messages from a channel or chat'],
         ['sync', 'Sync chat history locally'],
         ['who', "Look up a user's profile"],
         ['org', 'Show org chart for a user'],
         ['status', 'View and manage your presence status']]
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
            teems cal create "Standup" --start "tomorrow 09:00"
            teems cal delete 3             Delete event #3
            teems channels                 List all channels
            teems chats                    List recent chats
            teems messages <channel-id>    Read messages from a channel
            teems who                      Show your profile
            teems who john                 Search for a user
            teems org                      Show your org chart
            teems org john --depth 1       Org chart for "john"
        EXAMPLES
      end

      def show_command_help(topic)
        command_class = CLI::COMMANDS[topic]
        command_class ? execute_help_for(command_class) : unknown_command_help(topic)
      end

      def execute_help_for(command_class)
        command_class.new(['--help'], runner: Runner.new(output: output)).execute
      end

      def unknown_command_help(topic)
        error("Unknown command: #{topic}")
        puts "\nAvailable commands: #{CLI::COMMANDS.keys.join(', ')}"
      end
    end
  end
end
