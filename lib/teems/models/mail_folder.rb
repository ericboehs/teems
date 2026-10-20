# frozen_string_literal: true

module Teems
  module Models
    # A mail folder from Microsoft Graph (/me/mailFolders); path joins parent names with "/"
    MailFolder = Data.define(:id, :name, :path, :unread_count, :total_count, :child_count) do
      def self.from_api(data, parent_path: nil)
        name = data['displayName'].to_s
        new(id: data['id'], name: name, path: [parent_path, name].compact.join('/'),
            unread_count: data['unreadItemCount'].to_i, total_count: data['totalItemCount'].to_i,
            child_count: data['childFolderCount'].to_i)
      end

      # A full path match wins over a display name match; both ignore case
      def self.find_named(folders, name)
        wanted = name.strip
        candidates = folders.select { |folder| folder.named?(wanted) }
        candidates.find { |folder| folder.path.casecmp?(wanted) } || candidates.first
      end

      def to_json_hash = to_h

      def tsv_row = [path, unread_count, total_count].join("\t")

      # Matches a display name or full path, ignoring case
      def named?(wanted) = [path, name].any? { |candidate| candidate.casecmp?(wanted) }

      # [id, path] to list this folder's children with, or nil when it has none
      def child_lookup = child_count.positive? ? [id, path] : nil
    end
  end
end
