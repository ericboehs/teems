# frozen_string_literal: true

require 'open3'

module Teems
  module Support
    # Wrapper around Open3.capture3 for long-running child processes.
    #
    # Open3 reads stdout and stderr on background threads. When the process is signalled
    # while those reads are in flight, the pipes close underneath them and each thread
    # raises IOError, which Ruby prints as a backtrace before the main thread can exit
    # cleanly. Waiting on Safari sign-in or the headless helper keeps us inside capture3
    # for minutes at a time, so Ctrl-C there is routine rather than exceptional.
    #
    # Reader threads inherit Thread.report_on_exception when they are created, so muting
    # it for the duration of the call silences exactly those threads and nothing else.
    module Subprocess
      module_function

      def capture3(*command)
        previous = Thread.report_on_exception
        Thread.report_on_exception = false
        Open3.capture3(*command)
      ensure
        Thread.report_on_exception = previous
      end
    end
  end
end
