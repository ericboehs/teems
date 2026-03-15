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

      EXAMPLES:
        teems auth login      # Open Safari and extract tokens
        teems auth status     # Check if authenticated
        teems auth logout     # Clear stored tokens
    HELP

    # Token input methods for manual token entry and file import
    module AuthTokenInput
      def set_tokens
        return import_tokens_from_file(positional_args[1]) if positional_args[1]

        prompt_and_save_tokens
      end

      private

      def prompt_and_save_tokens
        puts 'Enter your Teams tokens.'
        puts '(Tokens are long - you can also use: teems auth set-tokens <file>)'
        puts
        auth_token = prompt_for_token('Auth token (from Authorization: Bearer header or authtoken cookie)')
        return error('Auth token is required') if auth_token.to_s.empty?

        save_extracted_tokens(auth_token, prompt_for_skype_token)
      end

      def prompt_for_skype_token
        puts
        puts 'Skype token is optional (needed for some chat APIs).'
        puts 'Press Enter twice to skip, or paste the skypetoken_asm cookie value:'
        prompt_for_token('Skype token (optional)')
      end

      def prompt_for_token(label)
        puts "#{label}:"
        puts '(paste token, then press Enter twice or Ctrl-D)'
        read_multiline_token
      end

      def read_multiline_token
        clean_token(collect_input_lines.join)
      end

      def collect_input_lines
        result = []
        while (line = $stdin.gets)
          break if line.strip.empty?

          result << line.chomp
        end
        result
      end

      def clean_token(token) = token.sub(/^Bearer\s+/i, '').sub(/^skypetoken=/i, '').strip

      def import_tokens_from_file(file_path)
        return error("File not found: #{file_path}") unless File.exist?(file_path)

        data = parse_token_file(file_path)
        return data if data.is_a?(Integer)

        build_and_save_file_tokens(data)
      rescue Errno::EACCES => e
        error("Cannot read file: #{e.message}")
      rescue Errno::EISDIR
        error("Path is a directory, not a file: #{file_path}")
      end

      def parse_token_file(file_path)
        JSON.parse(File.read(file_path))
      rescue JSON::ParserError
        error('Invalid JSON file. Expected: {"auth_token": "..."}')
      end

      def build_and_save_file_tokens(data)
        auth_token = extract_auth_token(data)
        return error('File must contain auth_token key') unless auth_token

        save_extracted_tokens(auth_token, extract_skype_token(data, auth_token), data['chatsvc_token'])
      end

      def extract_auth_token(data) = data['auth_token'] || data['authtoken']
      def extract_skype_token(data, fallback) = data['skype_token'] || data['skypetoken'] || fallback

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

    # Manages authentication with Microsoft Teams
    class Auth < Base
      include AuthTokenInput

      def execute
        result = validate_options
        return result if result

        dispatch_action(positional_args.first)
      end

      protected

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
        tokens = runner.token_extractor.extract
        handle_login_result(tokens)
      end

      def print_login_banner
        puts 'Starting Teams authentication...'
        puts 'Safari will open to teams.microsoft.com'
        puts 'Please complete the login process (PIV/Entra ID)'
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
        puts "\nTry manual extraction instead:\n  teems auth manual"
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

      def status
        return display_unauthenticated_status unless token_store.configured?

        display_authenticated_status
      end

      def display_authenticated_status
        account = token_store.account
        unless account
          puts "#{output.yellow('⚠')} Token file exists but is incomplete"
          puts 'Run: teems auth login'
          return 0
        end
        puts "#{output.green('✓')} Authenticated as: #{account.name}"
        display_token_age
        0
      end

      def display_token_age
        age = token_store.token_age
        return unless age

        hours = (age / 3600).to_i
        if hours >= 24
          puts "#{output.yellow('⚠')} Tokens are #{hours} hours old (may be expired)"
        else
          puts "  Token age: #{hours} hours"
        end
      end

      def display_unauthenticated_status
        puts "#{output.red('✗')} Not authenticated\n\nRun: teems auth login"
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
