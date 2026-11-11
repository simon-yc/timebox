# frozen_string_literal: true

require_relative "../../lib/timebox"

# Existing command tests exercise one command at a time without waiting minutes.
class NoWaitTimer
  def wait(storage:, id:)
    false
  end
end

exit Timebox::CLI.run(ARGV, timer: NoWaitTimer.new)
