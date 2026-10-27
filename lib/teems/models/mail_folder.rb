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

      # The folder whose full path is name, else the one whose display name is (both ignore
      # case), or nil. A display name several folders share raises rather than guessing.
      def self.find_named(folders, name)
        matches = matching(folders, name)
        return matches.first unless matches.length > 1

        raise Error, "Mail folder name is ambiguous: #{name} matches #{matches.map(&:path).join(', ')} " \
                     '(use the full path)'
      end

      def self.matching(folders, name)
        wanted = name.strip
        candidates = folders.select { |folder| folder.named?(wanted) }
        by_path = candidates.select { |folder| folder.path.casecmp?(wanted) }
        by_path.empty? ? candidates : by_path
      end

      def to_json_hash = to_h

      def tsv_row = [path, unread_count, total_count].join("\t")

      # Matches a display name or full path, ignoring case
      def named?(wanted) = [path, name].any? { |candidate| candidate.casecmp?(wanted) }

      def id_and_path = [id, path]

      # [id, path] to list this folder's children with, or nil when it has none
      def child_lookup = child_count.positive? ? [id, path] : nil
    end
  end
end
