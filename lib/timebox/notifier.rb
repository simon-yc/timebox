# frozen_string_literal: true

module Timebox
  class Notifier
    SCRIPT = 'display notification "Your timebox is complete!" with title "Timebox" sound name "Glass"'

    def notify
      system("/usr/bin/osascript", "-e", SCRIPT, out: File::NULL, err: File::NULL)
    rescue SystemCallError
      false
    end
  end
end
