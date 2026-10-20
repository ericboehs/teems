# frozen_string_literal: true

module Teems
  module Services
    # Remembers full Graph message IDs for the short IDs `teems mail list` and `search` print,
    # so `teems mail read <short id>` works afterwards. Kept in the XDG cache dir.
    class MailIdCache
      MAX_ENTRIES = 2000

      def initialize(paths: Support::XdgPaths.new)
        @path = paths.cache_file('mail-ids.json')
      end

      def remember(messages)
        return if messages.empty?

        # Listed IDs move to the end, so the ones in use are the last evicted
        listed = messages.to_h { |message| [message.short_id, message.id] }
        ids = load.except(*listed.keys).merge(listed)
        FileUtils.mkdir_p(File.dirname(@path), mode: 0o700)
        File.write(@path, JSON.generate(ids.to_a.last(MAX_ENTRIES).to_h))
      end

      # Full ID for a short ID or unique prefix of one (4+ hex digits); full IDs pass through
      def resolve(token)
        prefix = self.class.short_prefix(token)
        return token.to_s.strip unless prefix

        matches = ids_starting_with(prefix)
        matches.one? ? matches.first : nil
      end

      # Lowercased short ID (or prefix) for a token that looks like one, else nil
      def self.short_prefix(token)
        stripped = token.to_s.strip
        stripped.match?(/\A\h{4,16}\z/) ? stripped.downcase : nil
      end

      private

      def ids_starting_with(prefix) = load.select { |short, _id| short.start_with?(prefix) }.values.uniq

      def load
        data = File.file?(@path) ? JSON.parse(File.read(@path)) : {}
        data.is_a?(Hash) ? data : {}
      rescue JSON::ParserError
        {}
      end
    end
  end
end
