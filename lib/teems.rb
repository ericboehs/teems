# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'fileutils'
require 'optparse'
require 'time'
require 'io/console'

# Microsoft Teams CLI - A command-line interface for Microsoft Teams
module Teems
  class Error < StandardError; end

  class ApiError < Error
    attr_reader :status_code

    def initialize(message = nil, status_code: nil)
      @status_code = status_code
      super(message)
    end

    def not_found? = status_code == 404
    def unauthorized? = status_code == 401
    def forbidden? = status_code == 403
    def rate_limited? = status_code == 429
  end
  class ConfigError < Error; end
  class AuthError < Error; end
  class TokenStoreError < Error; end

  autoload :VERSION, 'teems/version'
  autoload :CLI, 'teems/cli'
  autoload :Runner, 'teems/runner'

  # Data models for Teams entities
  module Models
    autoload :Account, 'teems/models/account'
    autoload :Channel, 'teems/models/channel'
    autoload :Chat, 'teems/models/chat'
    autoload :Message, 'teems/models/message'
    autoload :User, 'teems/models/user'
  end

  # Application services for configuration, caching, and API communication
  module Services
    autoload :ApiClient, 'teems/services/api_client'
    autoload :Configuration, 'teems/services/configuration'
    autoload :TokenStore, 'teems/services/token_store'
    autoload :TokenExtractor, 'teems/services/token_extractor'
    autoload :TokenRefresher, 'teems/services/token_refresher'
    autoload :CacheStore, 'teems/services/cache_store'
    autoload :TeamsUrlParser, 'teems/services/teams_url_parser'
    autoload :SyncStore, 'teems/services/sync_store'
  end

  # Output formatters for messages and terminal output
  module Formatters
    autoload :Output, 'teems/formatters/output'
    autoload :MessageFormatter, 'teems/formatters/message_formatter'
    autoload :MarkdownFormatter, 'teems/formatters/markdown_formatter'
  end

  # CLI commands implementing user-facing functionality
  module Commands
    autoload :Base, 'teems/commands/base'
    autoload :Auth, 'teems/commands/auth'
    autoload :Channels, 'teems/commands/channels'
    autoload :Chats, 'teems/commands/chats'
    autoload :Messages, 'teems/commands/messages'
    autoload :Sync, 'teems/commands/sync'
    autoload :Help, 'teems/commands/help'
  end

  # Thin wrappers around Teams API endpoints
  module Api
    autoload :Client, 'teems/api/client'
    autoload :Channels, 'teems/api/channels'
    autoload :Chats, 'teems/api/chats'
    autoload :Messages, 'teems/api/messages'
  end

  # Utility classes for paths and helpers
  module Support
    autoload :XdgPaths, 'teems/support/xdg_paths'
    autoload :HelpFormatter, 'teems/support/help_formatter'
    autoload :ErrorLogger, 'teems/support/error_logger'
  end
end
