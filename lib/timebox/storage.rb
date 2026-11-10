# frozen_string_literal: true

require "sqlite3"
require "fileutils"

module Timebox
  class Storage
    DEFAULT_PATH = File.join(
      Dir.home, ".local", "share", "timebox", "timebox.sqlite3"
    )

    def initialize(path: ENV.fetch("TIMEBOX_DB", DEFAULT_PATH))
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
        );

        CREATE UNIQUE INDEX IF NOT EXISTS one_active_time_block
          ON time_blocks(status)
          WHERE status = 'active';
      SQL
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
               started_at, ends_at, status
        FROM time_blocks
        WHERE status = 'active'
        LIMIT 1
      SQL

      @db.get_first_row(sql)
    end

    # Close the database connection.
    def close
      @db.close unless @db.closed?
    end
  end
end
