# frozen_string_literal: true

module Teems
  module Commands
    # Manages authentication with Microsoft Teams
    class Auth < Base
      def execute
        result = validate_options
        return result if result

        action = positional_args.first

        case action
        when 'login' then login
        when 'logout', 'clear' then logout
        when 'status', nil then status
        when 'manual' then show_manual_instructions
        when 'set-tokens', 'set' then set_tokens
        else
          error("Unknown auth action: #{action}")
          puts 'Available actions: login, logout, status, manual, set-tokens'
          1
        end
      end

      protected

      def help_text
        <<~HELP
          #{output.bold('teems auth')} - Manage Teams authentication

          #{output.bold('USAGE:')}
            teems auth [action]

          #{output.bold('ACTIONS:')}
            login       Authenticate via Safari (opens browser)
            logout      Remove stored tokens
            status      Show current authentication status
            manual      Show manual token extraction instructions
            set-tokens  Manually enter tokens from browser

          #{output.bold('EXAMPLES:')}
            teems auth login      # Open Safari and extract tokens
            teems auth status     # Check if authenticated
            teems auth logout     # Clear stored tokens
        HELP
      end

      private

      def login
        puts 'Starting Teams authentication...'
        puts 'Safari will open to teams.microsoft.com'
        puts 'Please complete the login process (PIV/Entra ID)'
        puts

        extractor = runner.token_extractor
        tokens = extractor.extract

        if tokens && tokens[:auth_token] && tokens[:skype_token]
          save_tokens(tokens)
          success('Authentication successful!')
          0
        else
          error('Failed to extract tokens automatically')
          puts
          puts 'Try manual extraction instead:'
          puts '  teems auth manual'
          1
        end
      end

      def save_tokens(tokens)
        token_store.save(
          name: 'default',
          auth_token: tokens[:auth_token],
          skype_token: tokens[:skype_token],
          chatsvc_token: tokens[:chatsvc_token]
        )
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
        if token_store.configured?
          account = token_store.account
          puts "#{output.green('✓')} Authenticated as: #{account.name}"

          age = token_store.token_age
          if age
            hours = (age / 3600).to_i
            if hours >= 24
              puts "#{output.yellow('⚠')} Tokens are #{hours} hours old (may be expired)"
            else
              puts "  Token age: #{hours} hours"
            end
          end
        else
          puts "#{output.red('✗')} Not authenticated"
          puts
          puts 'Run: teems auth login'
        end
        0
      end

      def show_manual_instructions
        puts runner.token_extractor.manual_instructions
        puts
        puts 'Once you have the tokens, you can set them manually:'
        puts '  teems auth set-tokens'
        0
      end

      def set_tokens
        # Check for file-based input first
        if positional_args[1]
          return set_tokens_from_file(positional_args[1])
        end

        puts 'Enter your Teams tokens.'
        puts '(Tokens are long - you can also use: teems auth set-tokens <file>)'
        puts

        auth_token = prompt_for_token('Auth token (from Authorization: Bearer header or authtoken cookie)')
        return error('Auth token is required') if auth_token.nil? || auth_token.empty?

        puts
        puts 'Skype token is optional (needed for some chat APIs).'
        puts 'Press Enter twice to skip, or paste the skypetoken_asm cookie value:'
        skype_token = prompt_for_token('Skype token (optional)')

        # Use auth_token as skype_token fallback if not provided
        skype_token = auth_token if skype_token.nil? || skype_token.empty?

        save_extracted_tokens(auth_token, skype_token)
      end

      def prompt_for_token(label)
        puts "#{label}:"
        puts '(paste token, then press Enter twice or Ctrl-D)'

        lines = []
        while (line = $stdin.gets)
          break if line.strip.empty?

          lines << line.chomp
        end

        token = lines.join
        # Clean up tokens if user pasted with prefix
        token = token.sub(/^Bearer\s+/i, '')
        token = token.sub(/^skypetoken=/i, '')
        token.strip
      end

      def set_tokens_from_file(file_path)
        unless File.exist?(file_path)
          return error("File not found: #{file_path}")
        end

        content = File.read(file_path)
        data = JSON.parse(content)

        auth_token = data['auth_token'] || data['authtoken']
        skype_token = data['skype_token'] || data['skypetoken']

        unless auth_token
          return error('File must contain auth_token key')
        end

        # Use auth_token as fallback if skype_token not provided
        skype_token ||= auth_token

        save_extracted_tokens(auth_token, skype_token, data['chatsvc_token'])
      rescue JSON::ParserError
        error('Invalid JSON file. Expected: {"auth_token": "..."}')
      end

      def save_extracted_tokens(auth_token, skype_token, chatsvc_token = nil)
        # Clean up tokens if pasted with prefix
        auth_token = auth_token.sub(/^Bearer\s+/i, '').strip
        skype_token = skype_token.sub(/^skypetoken=/i, '').strip

        token_store.save(
          name: 'default',
          auth_token: auth_token,
          skype_token: skype_token,
          chatsvc_token: chatsvc_token
        )

        success('Tokens saved successfully!')
        0
      end
    end
  end
end
