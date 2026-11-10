# frozen_string_literal: true

module Timebox
  class CLI
    HELP = <<~TEXT
      Timebox — a Ruby learning project

      Usage: ruby bin/timebox [command]

      Commands:
        help     Show this help
        start    Create a focus block
        status   Show the current block (not implemented)
    TEXT

    def self.run(arguments)
      command = arguments.first

      case command
      when nil, "help", "--help", "-h"
        puts HELP
        0
      when "start"
        start
      when "status"
        warn "Status is not implemented yet."
        1
      else
        warn "Unknown command: #{command}"
        1
      end
    end

    def self.start
      print "What are you working on? "
      task = $stdin.gets&.strip

      print "How long? (e.g. 25m, 1h) "
      duration = $stdin.gets&.strip

      seconds = Duration.parse(duration)

      block = FocusBlock.new(
        task: task,
        duration_seconds: seconds
      )

      puts "\nFocus block created!"
      puts "Task: #{block.task}"
      puts "Duration: #{block.duration_seconds / 60} minutes"
      puts "Started: #{block.started_at.strftime('%I:%M %p')}"
      puts "Ends: #{block.ends_at.strftime('%I:%M %p')}"

      0
    rescue ArgumentError => e
      warn "Error: #{e.message}"
      1
    end
  end
end
