# frozen_string_literal: true

module Timebox
  class CLI
    HELP = <<~TEXT
      Timebox — a Ruby learning project

      Usage: ruby bin/timebox [command]

      Commands:
        help     Show this help
        start    Start a focus block (not implemented yet)
        status   Show the current block (not implemented yet)

      Next exercise: connect start to Duration and FocusBlock.
      See README.md for the roadmap and test instructions.
    TEXT

    # Return a process exit code: 0 for success, 1 for an error or unfinished command.
    def self.run(arguments)
      command = arguments.first

      case command
      when nil, "help", "--help", "-h"
        puts HELP
        0
      when "start", "status"
        warn "#{command} is not implemented yet. See README.md for the next steps."
        1
      else
        warn "Unknown command: #{command}. Run ruby bin/timebox --help for usage."
        1
      end
    end
  end
end
