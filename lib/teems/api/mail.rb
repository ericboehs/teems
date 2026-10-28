# frozen_string_literal: true

module Teems
  module Api
    # Paths and headers shared by the Graph mail wrappers. Message IDs are requested as immutable
    # IDs so they survive moves between folders.
    module MailPaths
      private

      def prefer_header = { 'Prefer' => 'IdType="ImmutableId"' }

      def folder_path(folder_id) = "/v1.0/me/mailFolders/#{encode(folder_id)}"

      def message_path(message_id) = "/v1.0/me/messages/#{encode(message_id)}"

      def encode(segment) = URI.encode_www_form_component(segment)
    end

    # API wrapper for reading Microsoft Graph mail (see MailActions for changing it)
    class Mail < Client
      include MailPaths

      LIST_FIELDS = %w[id receivedDateTime from subject isRead hasAttachments flag].freeze
      # internetMessageHeaders only to tell protected mail apart (MailEncryption.from_headers); delta
      # has no lighter way, since hasAttachments is unreliable for it and $expand is refused
      MESSAGE_FIELDS = (LIST_FIELDS + %w[toRecipients ccRecipients categories body internetMessageId webLink
                                         internetMessageHeaders]).freeze
      PAGE_MAX = 250
      # Delta pages carry full bodies, so keep them small
      DELTA_PAGE_SIZE = 50
      # $filter conditions messages can be limited to
      FILTERS = { unread: 'isRead eq false', flagged: "flag/flagStatus eq 'flagged'" }.freeze

      # Top-level folders, or the children of parent_id
      def folders(parent_id: nil)
        path = parent_id ? "#{folder_path(parent_id)}/childFolders" : '/v1.0/me/mailFolders'
        collect(path, { '$top' => PAGE_MAX, '$select' => folder_fields }, limit: nil)
      end

      def folder(folder_id)
        get(folder_path(folder_id), params: { '$select' => folder_fields })
      end

      # Newest first; only names FILTERS that every message must match, e.g. [:unread]
      def messages(folder:, count:, only: [])
        params = list_params(count).merge('$orderby' => 'receivedDateTime desc', '$filter' => filter(only)).compact
        parse_messages(collect("#{folder_path(folder)}/messages", params, limit: count))
      end

      def message(message_id)
        data = get(message_path(message_id), params: { '$select' => MESSAGE_FIELDS.join(',') },
                                             headers: prefer_header)
        Models::MailMessage.from_api(data)
      end

      # The message's Outlook on the web address
      def web_link(message_id)
        get(message_path(message_id), params: { '$select' => 'webLink' }, headers: prefer_header)['webLink']
      end

      # The conversation (thread) a message belongs to
      def conversation_id(message_id)
        get(message_path(message_id), params: { '$select' => 'conversationId' },
                                      headers: prefer_header)['conversationId']
      end

      # Every message in a conversation, in any folder, oldest first: Graph refuses $orderby
      # alongside this filter, so the sorting happens here. MESSAGE_FIELDS as fields adds bodies.
      def conversation(conversation_id, fields: LIST_FIELDS)
        params = { '$filter' => "conversationId eq '#{conversation_id.gsub("'", "''")}'", '$top' => PAGE_MAX,
                   '$select' => [*fields, 'parentFolderId'].join(',') }
        parse_messages(collect('/v1.0/me/messages', params, limit: nil)).sort_by { |message| message.received_at.to_i }
      end

      # Every message in the conversations these messages belong to, each once
      def conversations_of(message_ids)
        message_ids.filter_map { |id| conversation_id(id) }.uniq.flat_map { |id| conversation(id) }.uniq(&:id)
      end

      # KQL search (Graph $search) across the mailbox, or within one folder
      def search(query:, count:, folder: nil)
        path = folder ? "#{folder_path(folder)}/messages" : '/v1.0/me/messages'
        params = list_params(count).merge('$search' => "\"#{query.gsub(/["\\]/) { |char| "\\#{char}" }}\"")
        parse_messages(collect(path, params, limit: count))
      end

      # First page of a delta query for one folder; since limits it to messages received after that time
      def delta(folder:, since: nil)
        params = { '$select' => MESSAGE_FIELDS.join(',') }
        params['$filter'] = "receivedDateTime ge #{since.utc.strftime('%Y-%m-%dT%H:%M:%SZ')}" if since
        get("#{folder_path(folder)}/messages/delta", params: params, headers: delta_header)
      end

      # Follows an @odata.nextLink or @odata.deltaLink from a delta query
      def delta_page(link) = get(link, headers: delta_header)

      # Attachment metadata (no content) for one message
      def attachments(message_id)
        path = "#{message_path(message_id)}/attachments"
        collect(path, { '$select' => 'id,name,size,contentType,isInline' }, limit: nil)
      end

      # One attachment including its base64 contentBytes (file attachments only)
      def attachment(message_id, attachment_id)
        get("#{message_path(message_id)}/attachments/#{encode(attachment_id)}", headers: prefer_header)
      end

      private

      # Graph wants each $orderby property (receivedDateTime) to lead the $filter, or it may
      # refuse the query as InefficientFilter
      def filter(names)
        return if names.empty?

        ['receivedDateTime ge 1900-01-01T00:00:00Z', *FILTERS.values_at(*names)].join(' and ')
      end

      def list_params(count) = { '$top' => count.clamp(1, PAGE_MAX), '$select' => LIST_FIELDS.join(',') }

      def collect(path, params, limit:)
        headers = prefer_header
        collect_pages(get(path, params: params, headers: headers), headers: headers, limit: limit)
      end

      def folder_fields = 'id,displayName,parentFolderId,childFolderCount,unreadItemCount,totalItemCount'

      def parse_messages(items) = items.map { |data| Models::MailMessage.from_api(data) }

      def delta_header = { 'Prefer' => "IdType=\"ImmutableId\", odata.maxpagesize=#{DELTA_PAGE_SIZE}" }
    end
  end
end
