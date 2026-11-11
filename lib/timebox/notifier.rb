# frozen_string_literal: true

module Timebox
  class Notifier
    SCRIPT = <<~APPLESCRIPT
      activate
      display dialog "Your focus session has ended. Return to Timebox to check in." ¬
        with title "Timebox" buttons {"OK"} default button "OK"
    APPLESCRIPT

    def notify
      warn "Warning: Could not play the alert sound." unless play_sound
      system("/usr/bin/osascript", "-e", SCRIPT, out: File::NULL, err: File::NULL)
    rescue SystemCallError
      false
    end

    private

    def play_sound
      system("/usr/bin/afplay", "/System/Library/Sounds/Glass.aiff", out: File::NULL, err: File::NULL)
    rescue SystemCallError
      false
    end
  end
end
