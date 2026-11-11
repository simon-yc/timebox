# frozen_string_literal: true

module Timebox
  class CLI
    HELP = <<~TEXT
      Timebox — a Ruby learning project

      Usage: bundle exec ruby bin/timebox [command]

      Commands:
        help     Show this help
        start    Save a focus block and run its countdown
        status   Show the saved block and time remaining
        stop     Resolve the active block with an outcome
        checkin  Resolve a due block and choose what comes next
    TEXT

    ACTIVE_BLOCK_ERROR = "A focus block is already active. Run the status command to view it."

    def self.run(arguments, timer: nil, clock: -> { Time.now })
      if arguments.length > 1
        warn "Error: Unexpected arguments. Usage: bundle exec ruby bin/timebox [command]"
        return 1
      end

      timer ||= Timer.new(clock: clock)
      command = arguments.first
      next_id = nil

      result =
        case command
        when nil, "help", "--help", "-h"
          puts HELP
          0
        when "start"
          start(clock: clock) { |id| next_id = id }
        when "status"
          status(now: clock.call)
        when "stop"
          stop
        when "checkin"
          checkin(now: clock.call, clock: clock) { |id| next_id = id }
        else
          warn "Unknown command: #{command}"
          1
        end
      if result.zero? && next_id
        run_timer(timer, id: next_id, clock: clock)
      else
        result
      end
    rescue Interrupt
      puts "\nInterrupted. Any unresolved session is still saved; use status, stop, or checkin later."
      130
    rescue SQLite3::Exception, SystemCallError => error
      warn "Error: Could not access the database: #{error.message}"
      1
    end

    # Yield the saved ID to the timer while keeping the return value an exit code.
    def self.start(clock: -> { Time.now })
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
        started_at: clock.call,
        notes: notes
      )
      id = storage.save(block)

      puts "\nFocus block created!"
      print_block(block)
      puts "Saved locally. Keep this terminal open for the reminder dialog; Ctrl+C leaves the block saved."

      yield id if block_given?
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
      outcome, notes = prompt_resolution

      unless storage.resolve(id: block["id"], outcome: outcome, notes: notes)
        warn "Error: This focus block is no longer active. Run status to view the current block."
        return 1
      end

      print_resolution(outcome: outcome, notes: notes || block["notes"])
      0
    rescue ArgumentError => error
      warn "Error: #{error.message}"
      1
    ensure
      storage&.close
    end

    def self.checkin(now: Time.now, clock: -> { Time.now }, expected_id: nil)
      storage = Storage.new
      block = storage.current_block

      unless block
        puts "No active focus block."
        return 0
      end
      if expected_id && block["id"] != expected_id
        warn "Error: This focus block is no longer active. Run status to view the current block."
        return 1
      end
      if block["ends_at"] > now.to_i
        warn "Error: This block is still running. Use stop to end it early."
        return 1
      end

      puts "Checking in: #{block['task']}"
      outcome, notes = prompt_resolution
      next_block = prompt_next_block(block, notes: notes, clock: clock)

      next_id = nil
      resolved = storage.checkin(
        id: block["id"], outcome: outcome, notes: notes, next_block: next_block, now: now
      ) { |id| next_id = id }
      unless resolved
        warn "Error: This focus block is no longer active. Run status to view the current block."
        return 1
      end

      print_resolution(outcome: outcome, notes: notes || block["notes"])
      if next_block
        puts "\nNext block started!"
        print_block(next_block)
      else
        puts "Finished. No active block."
      end
      yield next_id if next_id && block_given?
      0
    rescue ArgumentError => error
      warn "Error: #{error.message}"
      1
    ensure
      storage&.close
    end

    def self.prompt_resolution
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

      [outcome, notes]
    end

    def self.print_resolution(outcome:, notes:)
      puts "\nFocus block resolved!"
      puts "Status: resolved"
      puts "Outcome: #{outcome}"
      puts "Notes: #{notes}" unless notes.empty?
    end

    def self.prompt_next_block(block, notes:, clock:)
      puts "1. continue — Same task, new block."
      puts "2. switch — Another task."
      puts "3. break — A timed break."
      puts "4. finish — No new block."
      print "Next action (1-4 or name): "
      selection = $stdin.gets&.strip
      choices = { "1" => "continue", "2" => "switch", "3" => "break", "4" => "finish" }
      action = choices.fetch(selection, selection)
      unless choices.values.include?(action)
        raise ArgumentError, "Select continue, switch, break, or finish (1-4)"
      end
      return nil if action == "finish"

      task = action == "break" ? "Break" : block["task"]
      next_notes = action == "continue" ? (notes || block["notes"]) : ""
      if action == "switch"
        print "Next task: "
        task = $stdin.gets&.strip
      end
      print "Next duration (e.g. 25m, 1h): "
      seconds = Duration.parse($stdin.gets&.strip)
      if action == "switch"
        print "Notes for next task (optional): "
        next_notes = $stdin.gets&.strip || ""
      end

      FocusBlock.new(task: task, duration_seconds: seconds, started_at: clock.call, notes: next_notes)
    end

    def self.run_timer(timer, id:, clock:)
      storage = Storage.new
      while id
        return 0 unless timer.wait(storage: storage, id: id)

        next_id = nil
        result = checkin(now: clock.call, clock: clock, expected_id: id) do |saved_id|
          next_id = saved_id
        end
        return result unless result.zero?

        id = next_id
      end
      0
    ensure
      storage&.close
    end

    def self.print_block(block)
      puts "Task: #{block.task}"
      puts "Notes: #{block.notes}" unless block.notes.empty?
      puts "Duration: #{block.duration_seconds / 60} minutes"
      puts "Started: #{block.started_at.strftime('%I:%M %p')}"
      puts "Ends: #{block.ends_at.strftime('%I:%M %p')}"
    end

    private_class_method :prompt_resolution, :print_resolution, :prompt_next_block, :print_block, :run_timer
  end
end
