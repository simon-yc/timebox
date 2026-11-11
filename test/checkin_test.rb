# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "open3"
require "rbconfig"
require "timeout"
require "tmpdir"

class CheckinTest < Minitest::Test
  EXECUTABLE = File.expand_path("../bin/timebox", __dir__)

  def setup
    @directory = Dir.mktmpdir("timebox-checkin-test-")
    @path = File.join(@directory, "timebox.sqlite3")
  end

  def teardown
    FileUtils.remove_entry(@directory) if @directory
  end

  def test_checkin_without_an_active_block
    output, error, status = run_cli("checkin")

    assert_equal 0, status.exitstatus
    assert_empty error
    assert_equal "No active focus block.\n", output
  end

  def test_checkin_rejects_a_running_block_without_changes
    save_block(started_at: Time.now)
    before = records

    output, error, status = run_cli("checkin", input: "completed\n\nfinish\n")

    assert_equal 1, status.exitstatus
    assert_includes error, "still running. Use stop to end it early"
    refute_includes output, "Outcome ("
    assert_equal before, records
  end

  def test_finish_accepts_all_three_outcomes_and_preserves_planned_fields
    ["completed", "partial", "incomplete"].each do |outcome|
      id = save_block
      before = records.last

      output, error, status = run_cli("checkin", input: "#{outcome}\n\nfinish\n")

      assert_equal 0, status.exitstatus
      assert_empty error
      assert_includes output, "Outcome: #{outcome}\n"
      assert_includes output, "Finished. No active block.\n"
      assert_equal before.merge("status" => "resolved", "outcome" => outcome), records.last
      assert_equal id, records.last["id"]
    end
    output, error, status = run_cli("status")
    assert_equal 0, status.exitstatus
    assert_empty error
    assert_equal "No active focus block.\n", output
  end

  def test_continue_creates_a_new_block_and_carries_updated_notes
    save_block
    before = records.first
    earliest = Time.now.to_i

    output, error, status = run_cli("checkin", input: "partial\nUpdated notes\ncontinue\n15m\n")

    assert_equal 0, status.exitstatus
    assert_empty error
    assert_includes output, "Next block started!"
    old, current = records
    assert_equal before.merge(
      "status" => "resolved", "outcome" => "partial", "notes" => "Updated notes"
    ), old
    refute_equal old["id"], current["id"]
    assert_equal "Original task", current["task"]
    assert_equal "Updated notes", current["notes"]
    assert_equal 900, current["duration_seconds"]
    assert_equal current["started_at"] + 900, current["ends_at"]
    assert_operator current["started_at"], :>=, earliest
    assert_operator current["started_at"], :<=, Time.now.to_i
    assert_equal "active", current["status"]
    assert_nil current["outcome"]
  end

  def test_continue_keeps_existing_notes_when_the_update_is_blank
    save_block

    _, error, status = run_cli("checkin", input: "partial\n\ncontinue\n25m\n")

    assert_equal 0, status.exitstatus, error
    assert_equal "Original notes", records.first["notes"]
    assert_equal "Original notes", records.last["notes"]
  end

  def test_switch_starts_another_task_with_its_own_notes
    save_block

    _, error, status = run_cli(
      "checkin", input: "completed\n\nswitch\n  Next task  \n1h\n  New task's notes  \n"
    )

    assert_equal 0, status.exitstatus, error
    old, current = records
    assert_equal "Original task", old["task"]
    assert_equal "Original notes", old["notes"]
    assert_equal "Next task", current["task"]
    assert_equal "New task's notes", current["notes"]
    assert_equal 3600, current["duration_seconds"]
  end

  def test_switch_allows_eof_at_optional_new_notes
    save_block

    _, error, status = run_cli("checkin", input: "completed\n\nswitch\nNext task\n15m\n")

    assert_equal 0, status.exitstatus, error
    assert_equal "", records.last["notes"]
  end

  def test_break_starts_a_timed_block_named_break
    save_block

    _, error, status = run_cli("checkin", input: "partial\n\nbreak\n5m\n")

    assert_equal 0, status.exitstatus, error
    old, current = records
    assert_equal "resolved", old["status"]
    assert_equal "partial", old["outcome"]
    assert_equal "Break", current["task"]
    assert_equal "", current["notes"]
    assert_equal 300, current["duration_seconds"]
    assert_equal "active", current["status"]
  end

  def test_numbered_choices_select_each_next_action
    choices = { "1" => "15m\n", "2" => "Next task\n15m\n\n", "3" => "5m\n", "4" => "" }
    choices.each do |choice, next_input|
      id = save_block

      _, error, status = run_cli("checkin", input: "2\n\n#{choice}\n#{next_input}")

      assert_equal 0, status.exitstatus, error
      resolved = records.find { |record| record["id"] == id }
      assert_equal "partial", resolved["outcome"]
      current = records.find { |record| record["status"] == "active" }
      if choice == "4"
        assert_nil current
      else
        expected_task = { "1" => "Original task", "2" => "Next task", "3" => "Break" }.fetch(choice)
        assert_equal expected_task, current["task"]
        _, stop_error, stop_status = run_cli("stop", input: "completed\n\n")
        assert_equal 0, stop_status.exitstatus, stop_error
      end
    end
  end

  def test_invalid_required_input_and_eof_leave_every_record_unchanged
    save_block
    before = records
    invalid_inputs = [
      "", "done\n", "completed\n\n", "completed\n\nlater\n",
      "completed\n\ncontinue\n", "completed\n\ncontinue\n0m\n",
      "completed\n\nswitch\n", "completed\n\nswitch\n \n25m\n\n"
    ]

    invalid_inputs.each do |input|
      output, error, status = run_cli("checkin", input: input)

      assert_equal 1, status.exitstatus, "Input: #{input.inspect}"
      assert_match(/\AError: [^\n]+\n\z/, error)
      refute_includes output, "Focus block resolved!"
      refute_includes output, "Next block started!"
      assert_equal before, records
    end
  end

  def test_repeating_checkin_does_not_resolve_the_running_successor
    save_block
    _, first_error, first_status = run_cli("checkin", input: "partial\n\ncontinue\n15m\n")
    assert_equal 0, first_status.exitstatus, first_error
    before = records

    _, error, status = run_cli("checkin", input: "completed\n\nfinish\n")

    assert_equal 1, status.exitstatus
    assert_includes error, "still running"
    assert_equal before, records
  end

  def test_repeating_finish_checkin_leaves_history_unchanged
    save_block
    _, first_error, first_status = run_cli("checkin", input: "completed\n\nfinish\n")
    assert_equal 0, first_status.exitstatus, first_error
    before = records

    output, error, status = run_cli("checkin")

    assert_equal 0, status.exitstatus
    assert_empty error
    assert_equal "No active focus block.\n", output
    assert_equal before, records
  end

  def test_failed_successor_insert_rolls_back_the_outcome_and_notes
    save_block
    before = records
    database = SQLite3::Database.new(@path)
    begin
      database.execute_batch(<<~SQL)
        CREATE TRIGGER reject_successor BEFORE INSERT ON time_blocks
        BEGIN
          SELECT RAISE(ABORT, 'forced successor failure');
        END;
      SQL
    ensure
      database.close
    end

    output, error, status = run_cli("checkin", input: "partial\nUpdated notes\ncontinue\n15m\n")

    assert_equal 1, status.exitstatus
    assert_includes error, "forced successor failure"
    refute_includes output, "Focus block resolved!"
    assert_equal before, records
  end

  def test_stale_checkin_cannot_replace_a_new_session
    save_block
    wrapper = "$stdout.sync = true; load ARGV.shift"
    Open3.popen3(
      { "TIMEBOX_DB" => @path }, RbConfig.ruby, "-e", wrapper, EXECUTABLE, "checkin"
    ) do |input, output, error, child|
      begin
        captured = String.new(encoding: Encoding::BINARY)
        Timeout.timeout(5) do
          captured << output.readpartial(1024) until captured.include?("Outcome (1-3 or name): ")
        end
        _, stop_error, stop_status = run_cli("stop", input: "completed\nFirst resolution\n")
        assert_equal 0, stop_status.exitstatus, stop_error
        _, start_error, start_status = run_cli("start", input: "New task\n1h\nNew notes\n")
        assert_equal 0, start_status.exitstatus, start_error
        before = records

        input.write("partial\nStale notes\ncontinue\n15m\n")
        input.close
        captured << output.read.b
        failure = error.read

        assert_equal 1, child.value.exitstatus
        assert_includes failure, "no longer active"
        refute_includes captured, "Focus block resolved!"
        assert_equal before, records
      ensure
        input.close unless input.closed?
      end
    end
  end

  private

  def run_cli(command, input: "")
    Open3.capture3({ "TIMEBOX_DB" => @path }, RbConfig.ruby, EXECUTABLE, command, stdin_data: input)
  end

  def save_block(started_at: Time.now - 3600)
    storage = Timebox::Storage.new(path: @path)
    storage.save(Timebox::FocusBlock.new(
      task: "Original task", duration_seconds: 1500, started_at: started_at, notes: "Original notes"
    ))
  ensure
    storage&.close
  end

  def records
    database = SQLite3::Database.new(@path)
    database.results_as_hash = true
    database.execute("SELECT * FROM time_blocks ORDER BY id")
  ensure
    database&.close
  end
end
