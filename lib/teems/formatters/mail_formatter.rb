# frozen_string_literal: true

module Teems
  module Formatters
    # Date styles shared by mail output
    module MailDates
      module_function

      # The style Outlook for Mac printed, kept for `read` headers and synced Markdown
      def long(time) = time ? time.getlocal.strftime('%A, %B %-d, %Y at %-I:%M:%S %p') : ''

      def short(time) = time ? time.getlocal.strftime('%Y-%m-%d %H:%M') : ''

      def iso(time) = time ? time.getlocal.iso8601 : ''
    end

    # Terminal output for `teems mail` (TSV rows come from the models)
    class MailFormatter
      FROM_WIDTH = 24
      SUBJECT_WIDTH = 70

      def initialize(output:)
        @output = output
      end

      # id, received (local), from, subject, read flag
      def message_rows(messages) = messages.map { |message| message_row(message) }

      def folder_rows(folders)
        width = folders.map { |folder| folder.path.length }.push(6).max
        header = @output.bold("#{'FOLDER'.ljust(width)}  #{'UNREAD'.rjust(6)}  #{'TOTAL'.rjust(7)}")
        [header, *folders.collect { |folder| folder_row(folder, width) }]
      end

      private

      def message_row(message)
        short_id, received, from, subject = message.list_columns
        from = FormatUtils.truncate(from, FROM_WIDTH - 3).ljust(FROM_WIDTH)
        row = "#{@output.cyan(short_id)}  #{received}  #{from}  #{FormatUtils.truncate(subject, SUBJECT_WIDTH)}"
        row = message.read? ? "#{row}  #{@output.gray('read')}" : @output.bold("#{row}  unread")
        message.flagged ? "#{row}  #{@output.yellow('flagged')}" : row
      end

      def folder_row(folder, width)
        "#{folder.path.ljust(width)}  #{folder.unread_count.to_s.rjust(6)}  #{folder.total_count.to_s.rjust(7)}"
      end
    end
  end
end
