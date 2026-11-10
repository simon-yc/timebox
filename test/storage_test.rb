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
      "status" => "active"
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
end
