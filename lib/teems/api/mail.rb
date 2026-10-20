# frozen_string_literal: true

module Teems
  module Api
    # API wrapper for Microsoft Graph mail endpoints. Read-only: nothing here sends, moves, or deletes.
    # Message IDs are requested as immutable IDs so they survive moves between folders.
    class Mail < Client
      LIST_FIELDS = %w[id receivedDateTime from subject isRead hasAttachments].freeze
      MESSAGE_FIELDS = (LIST_FIELDS + %w[toRecipients ccRecipients categories body internetMessageId webLink]).freeze
      PAGE_MAX = 250
      # Delta pages carry full bodies, so keep them small
      DELTA_PAGE_SIZE = 50
      UNREAD = 'isRead eq false'

      # Top-level folders, or the children of parent_id
      def folders(parent_id: nil)
        path = parent_id ? "#{folder_path(parent_id)}/childFolders" : '/v1.0/me/mailFolders'
        collect(path, { '$top' => PAGE_MAX, '$select' => folder_fields }, limit: nil)
      end

      def folder(folder_id)
        get(folder_path(folder_id), params: { '$select' => folder_fields })
      end

      # Newest first; filter is an OData $filter such as UNREAD
      def messages(folder:, count:, filter: nil)
        params = list_params(count).merge('$orderby' => 'receivedDateTime desc', '$filter' => filter).compact
        parse_messages(collect("#{folder_path(folder)}/messages", params, limit: count))
      end

      def message(message_id)
        data = get(message_path(message_id), params: { '$select' => MESSAGE_FIELDS.join(',') },
                                             headers: prefer_header)
        Models::MailMessage.from_api(data)
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

      def list_params(count) = { '$top' => count.clamp(1, PAGE_MAX), '$select' => LIST_FIELDS.join(',') }

      def collect(path, params, limit:)
        items = []
        response = get(path, params: params, headers: prefer_header)
        loop do
          items.concat(response['value'] || [])
          link = response['@odata.nextLink']
          break if !link || (limit && items.length >= limit)

          response = get(link, headers: prefer_header)
        end
        limit ? items.first(limit) : items
      end

      def folder_fields = 'id,displayName,parentFolderId,childFolderCount,unreadItemCount,totalItemCount'

      def parse_messages(items) = items.map { |data| Models::MailMessage.from_api(data) }

      def prefer_header = { 'Prefer' => 'IdType="ImmutableId"' }

      def delta_header = { 'Prefer' => "IdType=\"ImmutableId\", odata.maxpagesize=#{DELTA_PAGE_SIZE}" }

      def folder_path(folder_id) = "/v1.0/me/mailFolders/#{encode(folder_id)}"

      def message_path(message_id) = "/v1.0/me/messages/#{encode(message_id)}"

      def encode(segment) = URI.encode_www_form_component(segment)
    end
  end
end
