# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'fileutils'
require 'optparse'
require 'time'
require 'io/console'
require 'digest'

# Microsoft Teams CLI - A command-line interface for Microsoft Teams
module Teems
  # Base error class for all Teems errors
  class Error < StandardError; end

  # Error raised when a Teams API request fails (4xx/5xx responses)
  class ApiError < Error
    # error_code is the service's own code (Graph's error.code, e.g. "syncStateNotFound")
    attr_reader :status_code, :error_code

    def initialize(message = nil, status_code: nil, error_code: nil)
      @status_code = status_code
      @error_code = error_code
      super(message)
    end

    def not_found? = status_code == 404
    def unauthorized? = status_code == 401
    def forbidden? = status_code == 403
    def rate_limited? = status_code == 429
  end

  # Error raised when required configuration is missing or invalid
  class ConfigError < Error; end

  # Error raised when authentication fails or tokens are missing
  class AuthError < Error; end

  # Error raised when token storage operations fail
  class TokenStoreError < Error; end

  autoload :VERSION, 'teems/version'
  autoload :CLI, 'teems/cli'
  autoload :Runner, 'teems/runner'

  # Data models for Teams entities
  module Models
    autoload :Account, 'teems/models/account'
    autoload :Channel, 'teems/models/channel'
    autoload :Chat, 'teems/models/chat'
    autoload :Event, 'teems/models/event'
    autoload :IcsEvent, 'teems/models/ics_event'
    autoload :EventDisplay, 'teems/models/event_display'
    autoload :Message, 'teems/models/message'
    autoload :InlineImage, 'teems/models/inline_image'
    autoload :InlineImageParsing, 'teems/models/inline_image'
    autoload :Parsing, 'teems/models/parsing'
    autoload :User, 'teems/models/user'
    autoload :UserProfile, 'teems/models/user_profile'
    autoload :Duration, 'teems/models/duration'
    autoload :MailFolder, 'teems/models/mail_folder'
    autoload :MailMessage, 'teems/models/mail_message'
  end

  # Application services for configuration, caching, and API communication
  module Services
    autoload :ApiClient, 'teems/services/api_client'
    autoload :Configuration, 'teems/services/configuration'
    autoload :TokenStore, 'teems/services/token_store'
    autoload :TokenExtractor, 'teems/services/token_extractor'
    autoload :TokenRefresher, 'teems/services/token_refresher'
    autoload :CacheStore, 'teems/services/cache_store'
    autoload :FileDownloader, 'teems/services/file_downloader'
    autoload :InlineImageDownloader, 'teems/services/inline_image_downloader'
    autoload :TeamsUrlParser, 'teems/services/teams_url_parser'
    autoload :SyncStore, 'teems/services/sync_store'
    autoload :SyncFileOps, 'teems/services/sync_store'
    autoload :SyncDirNaming, 'teems/services/sync_dir_naming'
    autoload :SyncDirOwnership, 'teems/services/sync_dir_ownership'
    autoload :SyncDirPlanning, 'teems/services/sync_dir_planning'
    autoload :SafariJsRunner, 'teems/services/safari_js_runner'
    autoload :SyncEngine, 'teems/services/sync_engine'
    autoload :SyncImages, 'teems/services/sync_images'
    autoload :MailFolders, 'teems/services/mail_folders'
    autoload :MailIdCache, 'teems/services/mail_id_cache'
    autoload :MailLegacyFiles, 'teems/services/mail_legacy_files'
    autoload :MailSyncAttachments, 'teems/services/mail_sync_attachments'
    autoload :MailSyncEngine, 'teems/services/mail_sync_engine'
    autoload :MailSyncFolder, 'teems/services/mail_sync_folder'
    autoload :MailSyncIndex, 'teems/services/mail_sync_folder'
    autoload :MailSyncStore, 'teems/services/mail_sync_store'
  end

  # Output formatters for messages and terminal output
  module Formatters
    autoload :Output, 'teems/formatters/output'
    autoload :FormatUtils, 'teems/formatters/format_utils'
    autoload :MessageFormatter, 'teems/formatters/message_formatter'
    autoload :MarkdownFormatter, 'teems/formatters/markdown_formatter'
    autoload :CalendarFormatter, 'teems/formatters/calendar_formatter'
    autoload :IcsFormat, 'teems/formatters/ics_format'
    autoload :TranscriptMarkdown, 'teems/formatters/transcript_markdown'
    autoload :HtmlEntities, 'teems/formatters/html_entities'
    autoload :HtmlTags, 'teems/formatters/html_text'
    autoload :HtmlText, 'teems/formatters/html_text'
    autoload :TextBuffer, 'teems/formatters/html_text'
    autoload :LinkCleaner, 'teems/formatters/link_cleaner'
    autoload :LinkCollector, 'teems/formatters/link_collector'
    autoload :MailDates, 'teems/formatters/mail_formatter'
    autoload :MailFormatter, 'teems/formatters/mail_formatter'
    autoload :MailMarkdown, 'teems/formatters/mail_markdown'
  end

  # CLI commands implementing user-facing functionality
  module Commands
    autoload :Base, 'teems/commands/base'
    autoload :Activity, 'teems/commands/activity'
    autoload :Auth, 'teems/commands/auth'
    autoload :Cal, 'teems/commands/cal'
    autoload :CalIcsExport, 'teems/commands/cal_ics'
    autoload :Channels, 'teems/commands/channels'
    autoload :Chats, 'teems/commands/chats'
    autoload :Messages, 'teems/commands/messages'
    autoload :Sync, 'teems/commands/sync'
    autoload :SyncFolders, 'teems/commands/sync_folders'
    autoload :Help, 'teems/commands/help'
    autoload :Who, 'teems/commands/who'
    autoload :Ooo, 'teems/commands/ooo'
    autoload :Org, 'teems/commands/org'
    autoload :Meeting, 'teems/commands/meeting'
    autoload :Transcripts, 'teems/commands/transcripts'
    autoload :Status, 'teems/commands/status'
    autoload :Mail, 'teems/commands/mail'
    autoload :MailReading, 'teems/commands/mail'
    autoload :MailSyncing, 'teems/commands/mail_sync'
  end

  # Thin wrappers around Teams API endpoints
  module Api
    autoload :Client, 'teems/api/client'
    autoload :Calendar, 'teems/api/calendar'
    autoload :Channels, 'teems/api/channels'
    autoload :Chats, 'teems/api/chats'
    autoload :Files, 'teems/api/files'
    autoload :Mail, 'teems/api/mail'
    autoload :Meetings, 'teems/api/meetings'
    autoload :Messages, 'teems/api/messages'
    autoload :Users, 'teems/api/users'
  end

  # Utility classes for paths and helpers
  module Support
    autoload :XdgPaths, 'teems/support/xdg_paths'
    autoload :HelpFormatter, 'teems/support/help_formatter'
    autoload :ErrorLogger, 'teems/support/error_logger'
    autoload :Timezone, 'teems/support/timezone'
    autoload :TimeParsing, 'teems/support/time_parsing'
    autoload :Subprocess, 'teems/support/subprocess'
    autoload :ControlChars, 'teems/support/control_chars'
  end
end
