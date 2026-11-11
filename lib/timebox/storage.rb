# frozen_string_literal: true

require "sqlite3"
require "fileutils"

module Timebox
  class Storage
    OUTCOMES = ["completed", "partial", "incomplete"].freeze

    DEFAULT_PATH = File.join(
      Dir.home, ".local", "share", "timebox", "timebox.sqlite3"
    )

    def initialize(path: ENV.fetch("TIMEBOX_DB", DEFAULT_PATH))
      if path == ""
        raise SQLite3::CantOpenException, "Database path is empty. Set TIMEBOX_DB to a path or unset it."
      end

      # Create the database directory if necessary.
      FileUtils.mkdir_p(File.dirname(path))

      # Open the SQLite database.
      @db = SQLite3::Database.new(path)
      @db.results_as_hash = true
      @db.busy_timeout = 5_000

      # Create the table and enforce one active block.
      @db.execute_batch(<<~SQL)
        CREATE TABLE IF NOT EXISTS time_blocks (
          id INTEGER PRIMARY KEY,
          task TEXT NOT NULL,
          notes TEXT NOT NULL DEFAULT '',
          duration_seconds INTEGER NOT NULL,
          started_at INTEGER NOT NULL,
          ends_at INTEGER NOT NULL,
          status TEXT NOT NULL DEFAULT 'active'
            CHECK (status IN ('active', 'resolved')),
          outcome TEXT CHECK (outcome IN ('completed', 'partial', 'incomplete')),
          CHECK (
            (status = 'active' AND outcome IS NULL) OR
            (status = 'resolved' AND outcome IS NOT NULL)
          )
        );

        CREATE UNIQUE INDEX IF NOT EXISTS one_active_time_block
          ON time_blocks(status)
          WHERE status = 'active';
      SQL
    rescue SQLite3::Exception
      close if @db
      raise
    end

    # Save a FocusBlock and return its database ID.
    def save(block)
      sql = <<~SQL
        INSERT INTO time_blocks
          (task, notes, duration_seconds, started_at, ends_at, status)
        VALUES (?, ?, ?, ?, ?, 'active')
      SQL

      values = [
        block.task,
        block.notes,
        block.duration_seconds,
        block.started_at.to_i,
        block.ends_at.to_i
      ]

      @db.execute(sql, values)
      @db.last_insert_row_id
    end

    # Return the active block as a Hash, or nil.
    def current_block
      sql = <<~SQL
        SELECT id, task, notes, duration_seconds,
               started_at, ends_at, status, outcome
        FROM time_blocks
        WHERE status = 'active'
        LIMIT 1
      SQL

      @db.get_first_row(sql)
    end

    # Return true if this active block was resolved; nil notes keep existing notes.
    def resolve(id:, outcome:, notes: nil)
      validate_resolution(outcome: outcome, notes: notes)

      sql = <<~SQL
        UPDATE time_blocks
        SET status = 'resolved', outcome = ?, notes = COALESCE(?, notes)
        WHERE id = ? AND status = 'active'
      SQL

      @db.execute(sql, [outcome, notes, id])
      @db.changes == 1
    end

    # Resolve a due block and optionally save its successor as one transaction.
    def checkin(id:, outcome:, notes: nil, next_block: nil, now: Time.now)
      validate_resolution(outcome: outcome, notes: notes)
      unless next_block.nil? || next_block.is_a?(FocusBlock)
        raise ArgumentError, "Next block must be a FocusBlock"
      end

      @db.transaction(:immediate)
      begin
        due = @db.get_first_row(
          "SELECT id FROM time_blocks WHERE id = ? AND status = 'active' AND ends_at <= ?",
          [id, now.to_i]
        )
        resolved = false
        if due
          resolved = resolve(id: id, outcome: outcome, notes: notes)
          save(next_block) if resolved && next_block
        end
        @db.commit
        resolved
      ensure
        @db.rollback if @db.transaction_active?
      end
    end

    # Close the database connection.
    def close
      @db.close unless @db.closed?
    end

    private

    def validate_resolution(outcome:, notes:)
      unless OUTCOMES.include?(outcome)
        raise ArgumentError, "Outcome must be completed, partial, or incomplete"
      end
      unless notes.nil? || notes.is_a?(String)
        raise ArgumentError, "Notes must be a string"
      end
    end
  end
end
