# frozen_string_literal: true

module Teems
  # Command-line interface entry point that dispatches to commands
  class CLI
    ERROR_LABELS = { AuthError => 'Auth error', ApiError => 'API error' }.freeze

    COMMANDS = {
      'auth' => Commands::Auth,
      'cal' => Commands::Cal,
      'channels' => Commands::Channels,
      'chats' => Commands::Chats,
      'messages' => Commands::Messages,
      'sync' => Commands::Sync,
      'who' => Commands::Who,
      'org' => Commands::Org,
      'help' => Commands::Help
    }.freeze

    def initialize(argv, output: Formatters::Output.new)
      @argv = argv.dup
      @output = output
    end

    def run
      command_name, *args = @argv

      return show_help if help_requested?(command_name)
      return show_version if version_requested?(command_name)

      dispatch_command(command_name, args)
    rescue Interrupt
      handle_interrupt
    rescue StandardError => e
      handle_error(e)
    end

    private

    def help_requested?(name) = !name || ['-h', '--help'].include?(name)
    def version_requested?(name) = ['--version', '-V', 'version'].include?(name)

    def show_help = run_command('help', [])

    def show_version
      @output.puts "teems v#{VERSION}"
      0
    end

    def dispatch_command(command_name, args)
      COMMANDS[command_name] ? run_command(command_name, args) : show_unknown_command(command_name)
    rescue ConfigError, AuthError, ApiError => e
      handle_known_error(e)
    end

    def show_unknown_command(command_name)
      @output.error("Unknown command: #{command_name}")
      @output.puts
      @output.puts "Run 'teems help' for available commands."
      1
    end

    def handle_known_error(error)
      label = error_label(error)
      @output.error(label ? "#{label}: #{error.message}" : error.message)
      log_error(error)
      1
    end

    def error_label(error) = ERROR_LABELS[error.class]

    def handle_interrupt
      @output.puts
      @output.puts 'Interrupted.'
      130
    end

    def handle_error(error)
      @output.error("Unexpected error: #{error.message}")
      log_path = log_error(error)
      @output.puts "Details logged to: #{log_path}" if log_path
      1
    end

    def run_command(name, args)
      command_class = COMMANDS[name]
      return 1 unless command_class

      runner = build_runner(args)
      execute_command(command_class, args, runner)
    ensure
      runner&.api_client&.close
    end

    def build_runner(args)
      out = verbose_mode?(args) ? verbose_output : @output
      Runner.new(output: out).tap { |new_runner| setup_verbose_logging(new_runner, out) if out.verbose? }
    end

    def verbose_output
      @output.with_verbose
    end

    def setup_verbose_logging(runner, output)
      runner.api_client.on_request = lambda { |method, count|
        output.debug("[API ##{count}] #{method}")
      }
    end

    def execute_command(command_class, args, runner)
      command = command_class.new(args, runner: runner)
      result = command.execute
      log_api_call_count(runner) if runner.output.verbose?
      result
    end

    def verbose_mode?(args) = args.include?('-v') || args.include?('--verbose')

    def log_api_call_count(runner)
      count = runner.api_client.call_count
      runner.output.debug("Total API calls: #{count}") if count.positive?
    end

    def log_error(error) = Support::ErrorLogger.log(error)
  end
end
