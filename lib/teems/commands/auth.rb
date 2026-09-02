# frozen_string_literal: true

module Teems
  module Commands
    AUTH_HELP = <<~HELP
      teems auth - Manage Teams authentication

      USAGE:
        teems auth [action]

      ACTIONS:
        login       Authenticate via Safari (opens browser)
        logout      Remove stored tokens
        status      Show current authentication status
        manual      Show manual token extraction instructions
        set-tokens  Manually enter tokens from browser

      OPTIONS:
        --certauth  Use certificate authentication (requires VPN)

      EXAMPLES:
        teems auth login              # Authenticate (headless or Safari OAuth)
        teems auth login --certauth   # Use cert auth (on VPN)
        teems auth status             # Check if authenticated
        teems auth logout             # Clear stored tokens
    HELP

    # Token input methods for manual token entry and file import
    module AuthTokenInput
      def set_tokens
        file_path = positional_args[1]
        return import_tokens_from_file(file_path) if file_path

        prompt_and_save_tokens
      end

      private

      def prompt_and_save_tokens
        print_token_prompt
        auth_token = prompt_for_token('Auth token (from Authorization: Bearer header or authtoken cookie)')
        return error('Auth token is required') if auth_token.to_s.empty?

        save_extracted_tokens(auth_token, prompt_for_skype_token)
      end

      def print_token_prompt
        puts 'Enter your Teams tokens.'
        puts '(Tokens are long - you can also use: teems auth set-tokens <file>)'
        puts
      end

      def prompt_for_skype_token
        puts
        puts 'Skype token is optional (needed for some chat APIs).'
        puts 'Press Enter twice to skip, or paste the skypetoken_asm cookie value:'
        prompt_for_token('Skype token (optional)')
      end

      def prompt_for_token(label)
        puts "#{label}:\n(paste token, then press Enter twice or Ctrl-D)"
        lines = []
        while (input = $stdin.gets)
          break if input.strip.empty?

          lines << input.chomp
        end
        clean_token(lines.join)
      end

      def clean_token(raw)
        stripped = raw.sub(/^Bearer\s+/i, '').sub(/^skypetoken=/i, '').strip
        debug("Cleaned token (#{stripped.length} chars)")
        stripped
      end

      def import_tokens_from_file(file_path)
        return error("File not found: #{file_path}") unless File.exist?(file_path)

        read_and_save_token_file(file_path)
      rescue Errno::EACCES => e
        error("Cannot read file: #{e.message}")
      rescue Errno::EISDIR
        error("Path is a directory, not a file: #{file_path}")
      end

      def read_and_save_token_file(file_path)
        data = parse_token_file(file_path)
        return data if data.is_a?(Integer)

        validate_and_save_tokens(data)
      end

      def validate_and_save_tokens(data)
        auth_token, skype_token, chatsvc = data.values_at('auth_token', 'skype_token', 'chatsvc_token')
        auth_token ||= data['authtoken']
        return error('File must contain auth_token key') unless auth_token

        debug('Found auth token in file data')
        save_extracted_tokens(auth_token, skype_token || data['skypetoken'] || auth_token, chatsvc)
      end

      def parse_token_file(file_path)
        JSON.parse(File.read(file_path))
      rescue JSON::ParserError
        error('Invalid JSON file. Expected: {"auth_token": "..."}')
      end

      def save_extracted_tokens(auth_token, skype_token, chatsvc_token = nil)
        token_store.save(
          name: 'default', auth_token: clean_token(auth_token),
          skype_token: clean_token(skype_token), chatsvc_token: chatsvc_token
        )
        success('Tokens saved successfully!')
        0
      end
    end

    AUTH_ACTIONS = {
      'login' => :login, 'logout' => :logout, 'clear' => :logout,
      'status' => :status, 'manual' => :show_manual_instructions,
      'set-tokens' => :set_tokens, 'set' => :set_tokens
    }.freeze

    # Status display helpers for auth command
    module AuthStatus
      private

      def status
        return display_unauthenticated_status unless token_store.configured?

        display_authenticated_status
      end

      def display_authenticated_status
        account = token_store.account
        return display_incomplete_tokens unless account

        puts "#{output.green("\u2713")} Authenticated as: #{account.name}"
        display_token_age
        0
      end

      def display_incomplete_tokens
        puts "#{output.yellow("\u26A0")} Token file exists but is incomplete"
        puts 'Run: teems auth login'
        0
      end

      def display_token_age
        age = token_store.token_age
        return unless age

        hours = (age / 3600).to_i
        if hours >= 24
          puts "#{output.yellow("\u26A0")} Tokens are #{hours} hours old (may be expired)"
        else
          puts "  Token age: #{hours} hours"
        end
      end

      def display_unauthenticated_status
        puts "#{output.red("\u2717")} Not authenticated\n\nRun: teems auth login"
        0
      end
    end

    # Manages authentication with Microsoft Teams
    class Auth < Base
      include AuthTokenInput
      include AuthStatus

      AUTH_OPTIONS = {
        '--certauth' => ->(opts, _args) { opts[:certauth] = true }
      }.freeze

      def initialize(args, runner:)
        @options = {}
        super
      end

      def execute
        result = validate_options
        return result if result

        dispatch_action(positional_args.first)
      end

      protected

      def handle_option(arg, pending)
        handler = AUTH_OPTIONS[arg]
        return super unless handler

        handler.call(@options, pending)
      end

      def help_text = AUTH_HELP

      private

      def dispatch_action(action)
        method_name = AUTH_ACTIONS[action || 'status']
        return unknown_action(action) unless method_name

        send(method_name)
      end

      def unknown_action(action)
        error("Unknown auth action: #{action}")
        puts 'Available actions: login, logout, status, manual, set-tokens'
        1
      end

      def login
        print_login_banner
        mode = @options[:certauth] ? :certauth : :default
        tokens = runner.token_extractor(auth_mode: mode).extract
        handle_login_result(tokens)
      end

      def print_login_banner
        puts 'Starting Teams authentication...'
        puts 'Safari will open so you can sign in (PIV/CAC or MFA prompts appear there).'
        puts 'Leave this running - it captures the tokens as soon as sign-in completes.'
        puts
      end

      def handle_login_result(tokens)
        if tokens && tokens[:auth_token] && tokens[:skype_token]
          save_tokens(tokens)
          success('Authentication successful!')
          0
        else
          suggest_manual_auth
        end
      end

      def suggest_manual_auth
        error('Failed to extract tokens automatically')
        puts "\nRerun with -v to see where it stopped:\n  teems auth login -v"
        puts "\nOn VPN with a PIV card, try:\n  teems auth login --certauth"
        puts "\nOr extract the tokens by hand:\n  teems auth manual"
        1
      end

      def save_tokens(tokens)
        token_store.save(name: 'default', **tokens.slice(:auth_token, :skype_token,
                                                         :skype_spaces_token, :chatsvc_token,
                                                         :refresh_token, :client_id, :tenant_id))
      end

      def logout
        if token_store.configured?
          token_store.clear
          success('Tokens cleared')
        else
          puts 'No tokens to clear'
        end
        0
      end

      def show_manual_instructions
        puts runner.token_extractor.manual_instructions
        puts "\nOnce you have the tokens, you can set them manually:\n  teems auth set-tokens"
        0
      end
    end
  end
end
