# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "rbconfig"

class CLITest < Minitest::Test
  EXECUTABLE = File.expand_path("../bin/timebox", __dir__)

  def test_start_accepts_minutes_and_displays_summary
    output, error, status = run_start("Learn Ruby\n25m\n")

    assert_equal 0, status.exitstatus
    assert_empty error
    assert_includes output, "What are you working on?"
    assert_includes output, "How long?"
    assert_includes output, "Focus block created!"
    assert_includes output, "Task: Learn Ruby\n"
    assert_includes output, "Duration: 25 minutes\n"
    assert_match(/^Started: \d{2}:\d{2} [AP]M$/, output)
    assert_match(/^Ends: \d{2}:\d{2} [AP]M$/, output)
  end

  def test_start_accepts_hours
    output, error, status = run_start("Learn Ruby\n1h\n")

    assert_equal 0, status.exitstatus
    assert_empty error
    assert_includes output, "Duration: 60 minutes\n"
  end

  def test_start_trims_outer_whitespace
    output, error, status = run_start("  Learn Ruby  \n  25m  \n")

    assert_equal 0, status.exitstatus
    assert_empty error
    assert_includes output, "Task: Learn Ruby\n"
    assert_includes output, "Duration: 25 minutes\n"
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

  private

  # Run the executable so these tests also cover argument handling and exit codes.
  def run_start(input)
    Open3.capture3(RbConfig.ruby, EXECUTABLE, "start", stdin_data: input)
  end

  def assert_start_rejected(input, expected_error)
    output, error, status = run_start(input)

    assert_equal 1, status.exitstatus
    assert_includes error, expected_error
    assert_match(/\AError: [^\n]+\n\z/, error)
    refute_includes output, "Focus block created!"
  end
end
