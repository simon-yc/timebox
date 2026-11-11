# frozen_string_literal: true

module Timebox
  class Timer
    def initialize(clock: -> { Time.now }, sleeper: ->(seconds) { sleep(seconds) },
                   notifier: Notifier.new, output: $stdout, error: $stderr)
      @clock = clock
      @sleeper = sleeper
      @notifier = notifier
      @output = output
      @error = error
      @notified_ids = {}
    end

    # Return true at the deadline, or false if another command changes the session.
    def wait(storage:, id:)
      displayed = false
      loop do
        block = storage.current_block
        unless block && block["id"] == id
          @output.puts "\nSession changed; countdown stopped."
          displayed = false
          return false
        end

        remaining = [block["ends_at"] - @clock.call.to_i, 0].max
        @output.print format("\rRemaining: %02d:%02d   ", remaining / 60, remaining % 60)
        @output.flush
        displayed = true

        if remaining.zero?
          @output.puts
          displayed = false
          notify_once(id)
          return true
        end
        @sleeper.call(1)
      end
    ensure
      @output.puts if displayed
    end

    private

    def notify_once(id)
      return if @notified_ids[id]

      @notified_ids[id] = true
      unless @notifier.notify
        @error.puts "Warning: macOS notification failed. Continuing with check-in."
      end
    end
  end
end
