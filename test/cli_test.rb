# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "rbconfig"
require "fileutils"
require "tmpdir"
require "timeout"

class CLITest < Minitest::Test
  EXECUTABLE = File.expand_path("support/command_runner.rb", __dir__)

  def setup
    @directory = Dir.mktmpdir("timebox-cli-test-")
    @path = File.join(@directory, "nested", "timebox.sqlite3")
  end

  def teardown
    FileUtils.remove_entry(@directory) if @directory
  end

  def test_start_accepts_minutes_and_displays_summary
    output, error, status = run_start("Learn Ruby\n25m\n\n")

    assert_equal 0, status.exitstatus
    assert_empty error
    assert_includes output, "What are you working on?"
    assert_includes output, "How long?"
    assert_includes output, "Notes (optional):"
    assert_includes output, "Focus block created!"
    assert_includes output, "Task: Learn Ruby\n"
    assert_includes output, "Duration: 25 minutes\n"
    assert_match(/^Started: \d{2}:\d{2} [AP]M$/, output)
    assert_match(/^Ends: \d{2}:\d{2} [AP]M$/, output)
    refute_match(/^Notes:/, output)
  end

  def test_start_accepts_notes
    output, error, status = run_start("Learn Ruby\n25m\nReview keyword arguments\n")

    assert_equal 0, status.exitstatus
    assert_empty error
    assert_includes output, "Notes: Review keyword arguments\n"
  end

  def test_start_allows_eof_before_optional_notes
    output, error, status = run_start("Learn Ruby\n25m\n")

    assert_equal 0, status.exitstatus
    assert_empty error
    assert_includes output, "Focus block created!"
    refute_match(/^Notes:/, output)
  end

  def test_start_accepts_hours
    output, error, status = run_start("Learn Ruby\n1h\n")

    assert_equal 0, status.exitstatus
    assert_empty error
    assert_includes output, "Duration: 60 minutes\n"
  end

  def test_start_trims_outer_whitespace
    output, error, status = run_start("  Learn Ruby  \n  25m  \n  Practice accessors  \n")

    assert_equal 0, status.exitstatus
    assert_empty error
    assert_includes output, "Task: Learn Ruby\n"
    assert_includes output, "Duration: 25 minutes\n"
    assert_includes output, "Notes: Practice accessors\n"
  end

  def test_start_rejects_invalid_duration
    assert_start_rejected("Learn Ruby\nabc\n", "Duration must end in m (minutes) or h (hours)")
  end

  def test_start_rejects_blank_task
    assert_start_rejected("  \n25m\n", "Task cannot be empty")
  end

  def test_start_handles_eof_before_task
    assert_start_rejected("", "Error:")
  end

  def test_start_handles_eof_before_duration
    assert_start_rejected("Learn Ruby\n", "Error:")
  end

  def test_status_without_a_saved_block
    output, error, status = run_cli("status")

    assert_equal 0, status.exitstatus
    assert_empty error
    assert_equal "No active focus block.\n", output
  end

  def test_status_reads_a_block_saved_by_another_cli_process
    _, start_error, start_status = run_start("Learn Ruby\n25m\nPractice SQLite\n")
    assert_equal 0, start_status.exitstatus, start_error

    output, error, status = run_cli("status")

    assert_equal 0, status.exitstatus
    assert_empty error
    assert_includes output, "Task: Learn Ruby\n"
    assert_includes output, "Notes: Practice SQLite\n"
    assert_includes output, "Duration: 25 minutes\n"
    assert_includes output, "State: running\n"
    assert_match(/^Remaining: \d+m \d+s$/, output)
    assert_match(/^Started: \d{4}-\d{2}-\d{2} /, output)
    assert_match(/^Ends: \d{4}-\d{2}-\d{2} /, output)
  end

  def test_status_omits_empty_notes
    save_block

    output, error, status = run_cli("status")

    assert_equal 0, status.exitstatus
    assert_empty error
    refute_match(/^Notes:/, output)
  end

  def test_status_keeps_overdue_blocks_awaiting_checkin
    save_block(started_at: Time.now - 3600)

    output, error, status = run_cli("status")

    assert_equal 0, status.exitstatus
    assert_empty error
    assert_includes output, "State: awaiting check-in\n"
    assert_includes output, "Remaining: 0m 0s\n"

    # Passing the deadline must not clear or confirm the saved block.
    assert_start_rejected("Another task\n25m\n", "A focus block is already active")
    later_output, _, later_status = run_cli("status")
    assert_equal 0, later_status.exitstatus
    assert_includes later_output, "Task: Saved task\n"
  end

  def test_status_at_the_exact_deadline_boundary
    started_at = Time.utc(2026, 11, 10, 14)
    save_block(started_at: started_at)
    deadline = started_at + 1500

    output, error = capture_status_at(deadline - 1)
    assert_empty error
    assert_includes output, "State: running\n"
    assert_includes output, "Remaining: 0m 1s\n"

    output, error = capture_status_at(deadline)
    assert_empty error
    assert_includes output, "State: awaiting check-in\n"
    assert_includes output, "Remaining: 0m 0s\n"
  end

  def test_start_rejects_an_existing_block_without_overwriting_it
    _, first_error, first_status = run_start("First task\n25m\nOriginal notes\n")
    assert_equal 0, first_status.exitstatus, first_error

    assert_start_rejected("Second task\n1h\nOther notes\n", "A focus block is already active")

    output, error, status = run_cli("status")
    assert_equal 0, status.exitstatus
    assert_empty error
    assert_includes output, "Task: First task\n"
    assert_includes output, "Notes: Original notes\n"
    refute_includes output, "Second task"
  end

  def test_concurrent_starts_save_only_one_block
    tasks = ["First task", "Second task"]
    results = tasks.map do |task|
      Thread.new { run_start("#{task}\n25m\n") }
    end.map(&:value)

    assert_equal [0, 1], results.map { |_, _, status| status.exitstatus }.sort
    winner = results.index { |_, _, status| status.success? }
    _, loser_error, = results.find { |_, _, status| !status.success? }
    assert_includes loser_error, "Error: A focus block is already active"

    output, error, status = run_cli("status")
    assert_equal 0, status.exitstatus
    assert_empty error
    assert_includes output, "Task: #{tasks[winner]}\n"
  end

  def test_invalid_start_does_not_save_a_block
    assert_start_rejected("Learn Ruby\nabc\n", "Error:")

    output, error, status = run_cli("status")

    assert_equal 0, status.exitstatus
    assert_empty error
    assert_equal "No active focus block.\n", output
  end

  def test_database_errors_are_reported_without_a_backtrace
    # SQLite cannot use a directory as its database file.
    @path = @directory

    ["start", "status", "stop", "checkin"].each do |command|
      output, error, status = run_cli(command)

      assert_equal 1, status.exitstatus
      assert_match(/\AError: Could not access the database: [^\n]+\n\z/, error)
      refute_includes output, "Focus block created!"
    end
  end

  def test_help_does_not_open_a_database
    @path = @directory

    output, error, status = run_cli("--help")

    assert_equal 0, status.exitstatus
    assert_empty error
    assert_includes output, "status   Show the saved block and time remaining"
    assert_includes output, "Usage: bundle exec ruby bin/timebox [command]"
  end

  def test_extra_arguments_are_rejected_before_opening_the_database
    ["start", "status", "stop", "checkin", "help"].each do |command|
      output, error, status = Open3.capture3(
        { "TIMEBOX_DB" => @path }, RbConfig.ruby, EXECUTABLE, command, "--help",
        stdin_data: "Task\n25m\n\ncompleted\n\nfinish\n"
      )

      assert_equal 1, status.exitstatus
      assert_includes error, "Unexpected arguments"
      assert_includes error, "Usage: bundle exec ruby bin/timebox [command]"
      assert_empty output
      refute File.exist?(@path)
    end
  end

  def test_start_rejects_a_duration_too_large_to_store
    assert_start_rejected("Task\n999999999999999999999999999999m\n\n", "outside the supported range")
    assert_equal "No active focus block.\n", run_cli("status").first
  end

  def test_database_directory_errors_are_reported_without_a_backtrace
    parent = File.join(@directory, "not-a-directory")
    File.write(parent, "")
    @path = File.join(parent, "timebox.sqlite3")

    output, error, status = run_cli("start")

    assert_equal 1, status.exitstatus
    assert_match(/\AError: Could not access the database: [^\n]+\n\z/, error)
    refute_includes output, "Focus block created!"
  end

  def test_stop_without_an_active_block
    output, error, status = run_cli("stop")

    assert_equal 0, status.exitstatus
    assert_empty error
    assert_equal "No active focus block.\n", output
  end

  def test_stop_accepts_all_three_outcomes
    ["completed", "partial", "incomplete"].each do |outcome|
      id = save_block
      before = read_block(id)

      output, error, status = run_cli("stop", input: "#{outcome}\n\n")

      assert_equal 0, status.exitstatus
      assert_empty error
      assert_includes output, "Status: resolved\n"
      assert_includes output, "Outcome: #{outcome}\n"
      assert_equal before.merge("status" => "resolved", "outcome" => outcome), read_block(id)
    end
  end

  def test_stop_accepts_numbered_outcome_choices
    { "1" => "completed", "2" => "partial", "3" => "incomplete" }.each do |choice, outcome|
      id = save_block

      _, error, status = run_cli("stop", input: "#{choice}\n\n")

      assert_equal 0, status.exitstatus, error
      assert_equal outcome, read_block(id)["outcome"]
    end
  end

  def test_stop_rejects_invalid_outcomes_without_changing_the_block
    id = save_block
    before = read_block(id)

    ["", "4", "done", "Completed"].each do |outcome|
      output, error, status = run_cli("stop", input: "#{outcome}\n")

      assert_equal 1, status.exitstatus
      assert_includes error, "Error: Select completed, partial, or incomplete"
      refute_includes output, "Focus block resolved!"
      assert_equal before, read_block(id)
    end
  end

  def test_stop_handles_eof_before_outcome_without_changing_the_block
    id = save_block
    before = read_block(id)

    _, error, status = run_cli("stop")

    assert_equal 1, status.exitstatus
    assert_includes error, "Error: Select completed, partial, or incomplete"
    assert_equal before, read_block(id)
  end

  def test_stop_keeps_notes_when_the_response_is_blank
    id = save_block(notes: "Keep these notes")

    output, error, status = run_cli("stop", input: "completed\n\n")

    assert_equal 0, status.exitstatus
    assert_empty error
    assert_equal "Keep these notes", read_block(id)["notes"]
    assert_includes output, "Notes: Keep these notes\n"
  end

  def test_stop_keeps_notes_when_optional_input_reaches_eof
    id = save_block(notes: "Keep these notes")

    _, error, status = run_cli("stop", input: "partial\n")

    assert_equal 0, status.exitstatus
    assert_empty error
    assert_equal "Keep these notes", read_block(id)["notes"]
    assert_equal "partial", read_block(id)["outcome"]
  end

  def test_stop_updates_notes_without_changing_planned_fields
    id = save_block(notes: "Original notes")
    before = read_block(id)

    output, error, status = run_cli("stop", input: "partial\n  Need another pass  \n")

    assert_equal 0, status.exitstatus
    assert_empty error
    assert_includes output, "Notes: Need another pass\n"
    assert_equal before.merge(
      "status" => "resolved", "outcome" => "partial", "notes" => "Need another pass"
    ), read_block(id)
  end

  def test_stop_allows_a_new_cli_session_to_start
    id = save_block
    _, stop_error, stop_status = run_cli("stop", input: "completed\n\n")
    assert_equal 0, stop_status.exitstatus, stop_error

    empty_output, _, empty_status = run_cli("status")
    assert_equal 0, empty_status.exitstatus
    assert_equal "No active focus block.\n", empty_output

    _, start_error, start_status = run_start("Next task\n1h\nNext notes\n")
    assert_equal 0, start_status.exitstatus, start_error

    output, error, status = run_cli("status")
    assert_equal 0, status.exitstatus
    assert_empty error
    assert_includes output, "Task: Next task\n"
    assert_includes output, "Status: active\n"
    assert_equal "resolved", read_block(id)["status"]
    assert_equal "completed", read_block(id)["outcome"]
  end

  def test_stop_resolves_an_overdue_block
    id = save_block(started_at: Time.now - 3600)

    _, error, status = run_cli("stop", input: "incomplete\n\n")

    assert_equal 0, status.exitstatus
    assert_empty error
    assert_equal "resolved", read_block(id)["status"]
    assert_equal "incomplete", read_block(id)["outcome"]
  end

  def test_repeated_stop_preserves_the_resolved_session
    id = save_block(notes: "Original notes")
    _, first_error, first_status = run_cli("stop", input: "completed\nFinal notes\n")
    assert_equal 0, first_status.exitstatus, first_error
    resolved = read_block(id)

    output, error, status = run_cli("stop", input: "incomplete\nReplacement notes\n")

    assert_equal 0, status.exitstatus
    assert_empty error
    assert_equal "No active focus block.\n", output
    assert_equal resolved, read_block(id)
  end

  def test_failed_resolution_rolls_back_every_field
    id = save_block(notes: "Original notes")
    before = read_block(id)
    database = SQLite3::Database.new(@path)
    begin
      database.execute_batch(<<~SQL)
        CREATE TRIGGER reject_resolution AFTER UPDATE ON time_blocks
        BEGIN
          SELECT RAISE(ABORT, 'forced resolution failure');
        END;
      SQL
    ensure
      database.close
    end

    output, error, status = run_cli("stop", input: "partial\nUpdated notes\n")

    assert_equal 1, status.exitstatus
    assert_match(/\AError: Could not access the database: forced resolution failure\n\z/, error)
    refute_includes output, "Focus block resolved!"
    assert_equal before, read_block(id)
  end

  def test_stale_stop_cannot_overwrite_a_resolved_or_new_session
    id = save_block(notes: "Original notes")
    # Unbuffer output in this child so the test can synchronize at the real prompt.
    wrapper = "$stdout.sync = true; load ARGV.shift"
    Open3.popen3(
      { "TIMEBOX_DB" => @path }, RbConfig.ruby, "-e", wrapper, EXECUTABLE, "stop"
    ) do |input, output, error, child|
      begin
        captured = String.new
        Timeout.timeout(5) do
          captured << output.readpartial(1024) until captured.include?("Outcome (1-3 or name): ")
        end

        _, stop_error, stop_status = run_cli("stop", input: "completed\nFirst resolution\n")
        assert_equal 0, stop_status.exitstatus, stop_error
        resolved = read_block(id)
        _, start_error, start_status = run_start("New task\n1h\nNew notes\n")
        assert_equal 0, start_status.exitstatus, start_error

        input.write("incomplete\nStale notes\n")
        input.close
        captured << output.read
        failure = error.read

        assert_equal 1, child.value.exitstatus
        assert_match(/\AError: This focus block is no longer active\./, failure)
        refute_includes captured, "Focus block resolved!"
        assert_equal resolved, read_block(id)
        current_output, current_error, current_status = run_cli("status")
        assert_equal 0, current_status.exitstatus
        assert_empty current_error
        assert_includes current_output, "Task: New task\n"
        assert_includes current_output, "Notes: New notes\n"
      ensure
        input.close unless input.closed?
      end
    end
  end

  def test_empty_database_configuration_is_rejected_by_every_command
    @path = ""

    ["start", "status", "stop", "checkin"].each do |command|
      output, error, status = run_cli(command, input: "Task\n25m\n\n")

      assert_equal 1, status.exitstatus
      assert_match(/\AError: Could not access the database: Database path is empty\./, error)
      refute_includes output, "Focus block created!"
    end
  end

  def test_commands_reject_the_previous_schema_without_changing_existing_data
    FileUtils.mkdir_p(File.dirname(@path))
    database = SQLite3::Database.new(@path)
    begin
      database.execute_batch(<<~SQL)
        CREATE TABLE time_blocks (
          id INTEGER PRIMARY KEY, task TEXT, notes TEXT, duration_seconds INTEGER,
          started_at INTEGER, ends_at INTEGER, status TEXT
        );
        CREATE UNIQUE INDEX one_active_time_block ON time_blocks(status)
          WHERE status = 'active';
        INSERT INTO time_blocks VALUES
          (1, 'Existing task', 'Keep me', 1500, 1000, 2500, 'active');
      SQL
    ensure
      database.close
    end
    before = File.binread(@path)

    ["start", "status", "stop", "checkin"].each do |command|
      output, error, status = run_cli(command)

      assert_equal 1, status.exitstatus
      assert_includes error, "no such column: outcome"
      refute_includes output, "Focus block resolved!"
      assert_equal before, File.binread(@path)
    end
  end

  private

  # Isolate each command in a process while the dedicated timer tests cover waiting.
  def run_start(input)
    run_cli("start", input: input)
  end

  def run_cli(command, input: "")
    Open3.capture3(
      { "TIMEBOX_DB" => @path },
      RbConfig.ruby, EXECUTABLE, command, stdin_data: input
    )
  end

  def save_block(started_at: Time.now, notes: "")
    storage = Timebox::Storage.new(path: @path)
    block = Timebox::FocusBlock.new(
      task: "Saved task", duration_seconds: 1500, started_at: started_at, notes: notes
    )
    storage.save(block)
  ensure
    storage&.close
  end

  def read_block(id)
    database = SQLite3::Database.new(@path)
    database.results_as_hash = true
    database.get_first_row("SELECT * FROM time_blocks WHERE id = ?", [id])
  ensure
    database&.close
  end

  def capture_status_at(now)
    previous_path = ENV["TIMEBOX_DB"]
    ENV["TIMEBOX_DB"] = @path

    capture_io { assert_equal 0, Timebox::CLI.status(now: now) }
  ensure
    ENV["TIMEBOX_DB"] = previous_path
  end

  def assert_start_rejected(input, expected_error)
    output, error, status = run_start(input)

    assert_equal 1, status.exitstatus
    assert_includes error, expected_error
    assert_match(/\AError: [^\n]+\n\z/, error)
    refute_includes output, "Focus block created!"
  end
end
