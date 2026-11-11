# frozen_string_literal: true

module Timebox
  class CLI
    HELP = <<~TEXT
      Timebox — a Ruby learning project

      Usage: ruby bin/timebox [command]

      Commands:
        help     Show this help
        start    Create and save a focus block
        status   Show the saved block and time remaining
        stop     Resolve the active block with an outcome
    TEXT

    ACTIVE_BLOCK_ERROR = "A focus block is already active. Run the status command to view it."

    def self.run(arguments)
      command = arguments.first

      case command
      when nil, "help", "--help", "-h"
        puts HELP
        0
      when "start"
        start
      when "status"
        status
      when "stop"
        stop
      else
        warn "Unknown command: #{command}"
        1
      end
    rescue SQLite3::Exception, SystemCallError => error
      warn "Error: Could not access the database: #{error.message}"
      1
    end

    def self.start
      storage = Storage.new

      if storage.current_block
        warn "Error: #{ACTIVE_BLOCK_ERROR}"
        return 1
      end

      print "What are you working on? "
      task = $stdin.gets&.strip

      print "How long? (e.g. 25m, 1h) "
      duration = $stdin.gets&.strip

      seconds = Duration.parse(duration)

      print "Notes (optional): "
      notes = $stdin.gets&.strip || ""

      block = FocusBlock.new(
        task: task,
        duration_seconds: seconds,
        notes: notes
      )
      storage.save(block)

      puts "\nFocus block created!"
      puts "Task: #{block.task}"
      puts "Notes: #{block.notes}" unless block.notes.empty?
      puts "Duration: #{block.duration_seconds / 60} minutes"
      puts "Started: #{block.started_at.strftime('%I:%M %p')}"
      puts "Ends: #{block.ends_at.strftime('%I:%M %p')}"
      puts "Saved locally. Use the status command to view this block."

      0
    rescue SQLite3::ConstraintException
      # The unique index also protects against two processes starting at once.
      warn "Error: #{ACTIVE_BLOCK_ERROR}"
      1
    rescue ArgumentError => error
      warn "Error: #{error.message}"
      1
    ensure
      storage&.close
    end

    def self.status(now: Time.now)
      storage = Storage.new
      block = storage.current_block

      unless block
        puts "No active focus block."
        return 0
      end

      remaining = [block["ends_at"] - now.to_i, 0].max
      state = remaining.positive? ? "running" : "awaiting check-in"

      puts "Current focus block:"
      puts "Task: #{block['task']}"
      puts "Notes: #{block['notes']}" unless block["notes"].empty?
      puts "Duration: #{block['duration_seconds'] / 60} minutes"
      puts "Status: #{block['status']}"
      puts "Started: #{Time.at(block['started_at']).strftime('%Y-%m-%d %I:%M %p %Z')}"
      puts "Ends: #{Time.at(block['ends_at']).strftime('%Y-%m-%d %I:%M %p %Z')}"
      puts "State: #{state}"
      puts "Remaining: #{remaining / 60}m #{remaining % 60}s"

      0
    ensure
      storage&.close
    end

    def self.stop
      storage = Storage.new
      block = storage.current_block

      unless block
        puts "No active focus block."
        return 0
      end

      puts "Stopping: #{block['task']}"
      puts "1. completed — Accomplished the intended task."
      puts "2. partial — Made progress but didn't finish."
      puts "3. incomplete — Made little or no meaningful progress."
      print "Outcome (1-3 or name): "
      selection = $stdin.gets&.strip
      choices = { "1" => "completed", "2" => "partial", "3" => "incomplete" }
      outcome = choices.fetch(selection, selection)

      unless Storage::OUTCOMES.include?(outcome)
        raise ArgumentError, "Select completed, partial, or incomplete (1-3)"
      end

      print "Update notes (optional; Enter keeps existing): "
      notes = $stdin.gets&.strip
      notes = nil if notes&.empty?

      unless storage.resolve(id: block["id"], outcome: outcome, notes: notes)
        warn "Error: This focus block is no longer active. Run status to view the current block."
        return 1
      end

      puts "\nFocus block resolved!"
      puts "Status: resolved"
      puts "Outcome: #{outcome}"
      final_notes = notes || block["notes"]
      puts "Notes: #{final_notes}" unless final_notes.empty?
      0
    rescue ArgumentError => error
      warn "Error: #{error.message}"
      1
    ensure
      storage&.close
    end
  end
end
