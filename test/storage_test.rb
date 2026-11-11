# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "tmpdir"

class StorageTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("timebox-storage-test-")
    @path = File.join(@directory, "nested", "timebox.sqlite3")
    @storage = Timebox::Storage.new(path: @path)
    @block = Timebox::FocusBlock.new(
      task: "Learn Ruby",
      duration_seconds: 1500,
      started_at: Time.utc(2026, 11, 10, 14),
      notes: "Practice SQLite"
    )
  end

  def teardown
    @storage&.close
  ensure
    FileUtils.remove_entry(@directory) if @directory
  end

  def test_new_database_has_no_current_block
    assert_nil @storage.current_block
  end

  def test_rejects_an_empty_database_path
    error = assert_raises(SQLite3::CantOpenException) do
      Timebox::Storage.new(path: "")
    end

    assert_includes error.message, "Database path is empty"
  end

  def test_failed_initialization_closes_its_database_connection
    path = File.join(@directory, "corrupt.sqlite3")
    contents = "This is not a SQLite database"
    File.binwrite(path, contents)

    # Retain the failed instance so its connection can be checked before GC runs.
    broken_storage = Timebox::Storage.allocate
    assert_raises(SQLite3::NotADatabaseException) do
      broken_storage.send(:initialize, path: path)
    end

    assert broken_storage.instance_variable_get(:@db).closed?
    assert_equal contents, File.binread(path)
  ensure
    database = broken_storage&.instance_variable_get(:@db)
    database.close if database && !database.closed?
  end

  def test_saves_and_reads_all_block_fields
    id = @storage.save(@block)

    assert_kind_of Integer, id
    assert_equal({
      "id" => id,
      "task" => "Learn Ruby",
      "notes" => "Practice SQLite",
      "duration_seconds" => 1500,
      "started_at" => @block.started_at.to_i,
      "ends_at" => @block.ends_at.to_i,
      "status" => "active",
      "outcome" => nil
    }, @storage.current_block)
  end

  def test_saved_block_survives_reopening
    @storage.save(@block)
    saved = @storage.current_block
    @storage.close

    @storage = Timebox::Storage.new(path: @path)

    assert_equal saved, @storage.current_block
  end

  def test_preserves_quotes_and_sql_like_text
    block = Timebox::FocusBlock.new(
      task: "Ruby's SQL; DROP TABLE time_blocks; --",
      duration_seconds: 1500,
      notes: "Don't interpolate SQL; use ? parameters"
    )
    @storage.save(block)
    saved = @storage.current_block

    assert_equal block.task, saved["task"]
    assert_equal block.notes, saved["notes"]
  end

  def test_saves_default_empty_notes
    block = Timebox::FocusBlock.new(task: "Learn Ruby", duration_seconds: 1500)
    @storage.save(block)

    assert_equal "", @storage.current_block["notes"]
  end

  def test_preserves_integer_values_at_sqlite_boundaries
    [[0, (2**63) - 1], [-(2**63), 60]].each do |start, duration|
      block = Timebox::FocusBlock.new(
        task: "Boundary", started_at: Time.at(start), duration_seconds: duration
      )
      id = @storage.save(block)
      saved = @storage.current_block

      assert_equal start, saved["started_at"]
      assert_equal duration, saved["duration_seconds"]
      assert_equal start + duration, saved["ends_at"]
      %w[started_at duration_seconds ends_at].each do |field|
        assert_instance_of Integer, saved[field]
      end
      @storage.resolve(id: id, outcome: "completed")
    end
  end

  def test_rejects_values_outside_sqlite_integer_range_before_inserting
    [[0, 2**63], [(2**63) - 1, 1], [2**63, 1], [-(2**63) - 1, 60]].each do |start, duration|
      block = Timebox::FocusBlock.new(
        task: "Too large", started_at: Time.at(start), duration_seconds: duration
      )

      assert_raises(ArgumentError) { @storage.save(block) }
      assert_nil @storage.current_block
    end
  end

  def test_checkin_yields_its_successor_id_only_after_commit
    id = @storage.save(@block)
    successor = Timebox::FocusBlock.new(task: "Next", duration_seconds: 60)
    yielded = []

    resolved = @storage.checkin(
      id: id, outcome: "completed", next_block: successor, now: @block.ends_at
    ) do |next_id|
      yielded << next_id
      # A separate connection must already see the committed successor.
      assert_equal "Next", read_block(next_id)["task"]
    end
    assert resolved
    assert_equal [@storage.current_block["id"]], yielded
  end

  def test_checkin_does_not_yield_when_no_successor_is_committed
    id = @storage.save(@block)
    yielded = []
    on_saved = ->(next_id) { yielded << next_id }
    oversized = Timebox::FocusBlock.new(task: "Too large", duration_seconds: 2**63)

    assert_raises(ArgumentError) do
      @storage.checkin(
        id: id, outcome: "completed", next_block: oversized, now: @block.ends_at, &on_saved
      )
    end
    assert_equal id, @storage.current_block["id"]
    refute @storage.checkin(id: id, outcome: "completed", now: @block.ends_at - 1, &on_saved)
    assert @storage.checkin(id: id, outcome: "completed", now: @block.ends_at, &on_saved)
    assert_empty yielded
  end

  def test_rejects_second_active_block_from_another_connection
    id = @storage.save(@block)
    other = Timebox::Storage.new(path: @path)

    begin
      assert_raises(SQLite3::ConstraintException) { other.save(@block) }
      assert_equal id, @storage.current_block["id"]
    ensure
      other.close
    end
  end

  def test_allows_repeated_close
    @storage.close
    @storage.close

    @storage = Timebox::Storage.new(path: @path)

    assert_nil @storage.current_block
  end

  def test_resolves_all_three_outcomes_without_changing_planned_fields
    ["completed", "partial", "incomplete"].each do |outcome|
      id = @storage.save(@block)
      before = read_block(id)

      assert @storage.resolve(id: id, outcome: outcome)
      assert_nil @storage.current_block
      assert_equal before.merge("status" => "resolved", "outcome" => outcome), read_block(id)
    end
  end

  def test_rejects_invalid_outcomes_without_changing_the_block
    id = @storage.save(@block)
    before = read_block(id)

    [nil, "", "done", "Completed", "interrupted", 0].each do |outcome|
      assert_raises(ArgumentError) { @storage.resolve(id: id, outcome: outcome) }
      assert_equal before, read_block(id)
    end
  end

  def test_resolve_can_update_notes_with_quotes_and_sql_like_text
    id = @storage.save(@block)
    before = read_block(id)
    notes = "Done'; DROP TABLE time_blocks; --"

    assert @storage.resolve(id: id, outcome: "partial", notes: notes)
    assert_equal before.merge(
      "status" => "resolved", "outcome" => "partial", "notes" => notes
    ), read_block(id)
  end

  def test_resolve_can_explicitly_clear_notes
    id = @storage.save(@block)

    assert @storage.resolve(id: id, outcome: "completed", notes: "")
    assert_equal "", read_block(id)["notes"]
  end

  def test_resolve_rejects_invalid_notes_without_changing_the_block
    id = @storage.save(@block)
    before = read_block(id)

    [25, [], false].each do |notes|
      assert_raises(ArgumentError) do
        @storage.resolve(id: id, outcome: "partial", notes: notes)
      end
      assert_equal before, read_block(id)
    end
  end

  def test_resolving_allows_a_new_block_to_start
    first_id = @storage.save(@block)
    @storage.resolve(id: first_id, outcome: "completed")

    second_id = @storage.save(@block)

    refute_equal first_id, second_id
    assert_equal second_id, @storage.current_block["id"]
    assert_equal "resolved", read_block(first_id)["status"]
    assert_equal "completed", read_block(first_id)["outcome"]
  end

  def test_resolving_a_missing_block_returns_false
    refute @storage.resolve(id: 999, outcome: "incomplete")
    assert_nil @storage.current_block
  end

  def test_a_stale_resolve_cannot_change_a_resolved_or_new_block
    first_id = @storage.save(@block)
    other = Timebox::Storage.new(path: @path)

    begin
      assert @storage.resolve(id: first_id, outcome: "completed")
      resolved = read_block(first_id)
      second_id = @storage.save(@block)

      refute other.resolve(id: first_id, outcome: "incomplete", notes: "Stale update")
      assert_equal resolved, read_block(first_id)
      assert_equal second_id, @storage.current_block["id"]
      assert_equal "Practice SQLite", @storage.current_block["notes"]
    ensure
      other.close
    end
  end

  def test_database_enforces_status_and_outcome_constraints
    id = @storage.save(@block)

    with_database do |database|
      assert_raises(SQLite3::ConstraintException) do
        database.execute("UPDATE time_blocks SET status = 'unknown' WHERE id = ?", [id])
      end
      assert_raises(SQLite3::ConstraintException) do
        database.execute("UPDATE time_blocks SET status = 'resolved' WHERE id = ?", [id])
      end
      assert_raises(SQLite3::ConstraintException) do
        database.execute("UPDATE time_blocks SET outcome = 'completed' WHERE id = ?", [id])
      end
      assert_raises(SQLite3::ConstraintException) do
        database.execute(
          "UPDATE time_blocks SET status = 'resolved', outcome = 'done' WHERE id = ?", [id]
        )
      end
    end

    assert_equal "active", @storage.current_block["status"]
    assert_nil @storage.current_block["outcome"]
  end

  def test_schema_adds_only_the_nullable_text_outcome_column
    columns = with_database { |database| database.execute("PRAGMA table_info(time_blocks)") }

    assert_equal [
      "id", "task", "notes", "duration_seconds", "started_at", "ends_at", "status", "outcome"
    ], columns.map { |column| column["name"] }
    outcome = columns.find { |column| column["name"] == "outcome" }
    assert_equal "TEXT", outcome["type"]
    assert_equal 0, outcome["notnull"]
  end

  def test_existing_database_is_not_reset_or_migrated
    legacy_path = File.join(@directory, "legacy.sqlite3")
    with_database(path: legacy_path) do |database|
      database.execute_batch(<<~SQL)
        CREATE TABLE time_blocks (
          id INTEGER PRIMARY KEY, task TEXT, notes TEXT,
          duration_seconds INTEGER, started_at INTEGER, ends_at INTEGER, status TEXT
        );
        INSERT INTO time_blocks VALUES
          (1, 'Existing task', 'Keep me', 1500, 1000, 2500, 'active');
      SQL
    end
    before = with_database(path: legacy_path) do |database|
      database.get_first_row("SELECT * FROM time_blocks WHERE id = 1")
    end

    legacy = Timebox::Storage.new(path: legacy_path)
    begin
      assert_raises(SQLite3::SQLException) { legacy.current_block }
    ensure
      legacy.close
    end

    with_database(path: legacy_path) do |database|
      assert_equal before, database.get_first_row("SELECT * FROM time_blocks WHERE id = 1")
      columns = database.execute("PRAGMA table_info(time_blocks)")
      refute_includes columns.map { |column| column["name"] }, "outcome"
    end
  end

  def test_checkin_accepts_the_exact_deadline_but_not_an_early_call
    id = @storage.save(@block)
    before = read_block(id)

    refute @storage.checkin(id: id, outcome: "completed", now: @block.ends_at - 1)
    assert_equal before, read_block(id)
    assert @storage.checkin(id: id, outcome: "completed", now: @block.ends_at)
    assert_equal before.merge("status" => "resolved", "outcome" => "completed"), read_block(id)
    assert_nil @storage.current_block
  end

  def test_checkin_resolves_and_starts_a_separate_block
    id = @storage.save(@block)
    before = read_block(id)
    successor = Timebox::FocusBlock.new(task: "Next task", duration_seconds: 900)

    assert @storage.checkin(
      id: id, outcome: "partial", next_block: successor, now: @block.ends_at
    )

    assert_equal before.merge("status" => "resolved", "outcome" => "partial"), read_block(id)
    current = @storage.current_block
    refute_equal id, current["id"]
    assert_equal "Next task", current["task"]
    assert_equal 900, current["duration_seconds"]
    assert_nil current["outcome"]
  end

  def test_checkin_rolls_back_resolution_when_saving_the_next_block_fails
    id = @storage.save(@block)
    before = read_block(id)
    successor = Timebox::FocusBlock.new(task: "Next task", duration_seconds: 900)
    with_database do |database|
      database.execute_batch(<<~SQL)
        CREATE TRIGGER reject_successor BEFORE INSERT ON time_blocks
        BEGIN
          SELECT RAISE(ABORT, 'forced successor failure');
        END;
      SQL
    end

    assert_raises(SQLite3::ConstraintException) do
      @storage.checkin(
        id: id, outcome: "partial", notes: "Updated", next_block: successor, now: @block.ends_at
      )
    end
    assert_equal before, @storage.current_block
    count = with_database { |database| database.get_first_value("SELECT COUNT(*) FROM time_blocks") }
    assert_equal 1, count
  end

  def test_checkin_rolls_back_if_interrupted_after_inserting_the_next_block
    id = @storage.save(@block)
    before = read_block(id)
    successor = Timebox::FocusBlock.new(task: "Next task", duration_seconds: 900)
    interrupted_storage = Class.new(Timebox::Storage) do
      def save(block)
        super
        raise Interrupt, "Simulated interruption"
      end
    end.new(path: @path)

    assert_raises(Interrupt) do
      interrupted_storage.checkin(
        id: id, outcome: "completed", next_block: successor, now: @block.ends_at
      )
    end
    assert_equal before, @storage.current_block
    count = with_database { |database| database.get_first_value("SELECT COUNT(*) FROM time_blocks") }
    assert_equal 1, count
  ensure
    interrupted_storage&.close
  end

  def test_stale_checkin_does_not_resolve_or_replace_a_new_block
    id = @storage.save(@block)
    @storage.resolve(id: id, outcome: "completed")
    resolved = read_block(id)
    new_id = @storage.save(@block)
    current = @storage.current_block
    successor = Timebox::FocusBlock.new(task: "Stale successor", duration_seconds: 900)

    refute @storage.checkin(
      id: id, outcome: "incomplete", notes: "Stale", next_block: successor, now: @block.ends_at
    )
    assert_equal resolved, read_block(id)
    assert_equal current, @storage.current_block
    assert_equal new_id, @storage.current_block["id"]
  end

  def test_checkin_rejects_invalid_values_without_changing_the_block
    id = @storage.save(@block)
    before = read_block(id)

    assert_raises(ArgumentError) { @storage.checkin(id: id, outcome: "done", now: @block.ends_at) }
    assert_raises(ArgumentError) do
      @storage.checkin(id: id, outcome: "completed", notes: 25, now: @block.ends_at)
    end
    assert_raises(ArgumentError) do
      @storage.checkin(id: id, outcome: "completed", next_block: "invalid", now: @block.ends_at)
    end
    assert_equal before, @storage.current_block
  end

  private

  def read_block(id)
    with_database do |database|
      database.get_first_row("SELECT * FROM time_blocks WHERE id = ?", [id])
    end
  end

  def with_database(path: @path)
    database = SQLite3::Database.new(path)
    database.results_as_hash = true
    yield database
  ensure
    database&.close
  end
end
