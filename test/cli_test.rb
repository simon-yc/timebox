# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "rbconfig"
require "fileutils"
require "tmpdir"

class CLITest < Minitest::Test
  EXECUTABLE = File.expand_path("../bin/timebox", __dir__)

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

    ["start", "status"].each do |command|
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

  private

  # Run the executable so these tests also cover argument handling and exit codes.
  def run_start(input)
    run_cli("start", input: input)
  end

  def run_cli(command, input: "")
    Open3.capture3(
      { "TIMEBOX_DB" => @path },
      RbConfig.ruby, EXECUTABLE, command, stdin_data: input
    )
  end

  def save_block(started_at: Time.now)
    storage = Timebox::Storage.new(path: @path)
    block = Timebox::FocusBlock.new(
      task: "Saved task", duration_seconds: 1500, started_at: started_at
    )
    storage.save(block)
  ensure
    storage&.close
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
