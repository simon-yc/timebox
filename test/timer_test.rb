# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/timer_fakes"
require "tmpdir"
require "fileutils"
require "stringio"

class TimerTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("timebox-timer-test-")
    @storage = Timebox::Storage.new(path: File.join(@directory, "timebox.sqlite3"))
    @clock = FakeClock.new
    @notifier = FakeNotifier.new
    @output = StringIO.new
    @error = StringIO.new
    @id = @storage.save(Timebox::FocusBlock.new(
      task: "Timer test", duration_seconds: 3, started_at: @clock.call, notes: "Keep notes"
    ))
  end

  def teardown
    @storage&.close
    FileUtils.remove_entry(@directory) if @directory
  end

  def test_counts_down_to_the_saved_deadline_without_resolving_the_block
    before = @storage.current_block

    assert timer.wait(storage: @storage, id: @id)

    ["00:03", "00:02", "00:01", "00:00"].each do |remaining|
      assert_includes @output.string, "Remaining: #{remaining}"
    end
    assert_equal [1, 1, 1], @clock.sleeps
    assert_equal 1, @notifier.calls
    assert_equal before, @storage.current_block
    assert_empty @error.string
  end

  def test_a_clock_jump_expires_the_stored_deadline_after_one_sleep
    @clock.speed = 1000

    assert timer.wait(storage: @storage, id: @id)

    assert_equal [1], @clock.sleeps
    assert_equal 1, @notifier.calls
    assert_includes @output.string, "Remaining: 00:00"
  end

  def test_notifies_only_once_for_each_session_in_the_running_timer
    countdown = timer
    assert countdown.wait(storage: @storage, id: @id)
    assert countdown.wait(storage: @storage, id: @id)
    assert_equal 1, @notifier.calls

    @storage.resolve(id: @id, outcome: "completed")
    next_id = @storage.save(Timebox::FocusBlock.new(
      task: "Next", duration_seconds: 2, started_at: @clock.call
    ))
    assert countdown.wait(storage: @storage, id: next_id)
    assert_equal 2, @notifier.calls
  end

  def test_notification_failure_warns_once_and_still_allows_checkin
    @notifier.result = false
    countdown = timer

    assert countdown.wait(storage: @storage, id: @id)
    assert countdown.wait(storage: @storage, id: @id)
    assert_equal 1, @notifier.calls
    assert_equal 1, @error.string.scan("Warning:").length
    assert_includes @error.string, "Continuing with check-in"
    assert_equal "active", @storage.current_block["status"]
    assert_nil @storage.current_block["outcome"]
  end

  def test_stops_without_notifying_if_another_command_resolves_the_session
    @clock.on_sleep = -> { @storage.resolve(id: @id, outcome: "partial") }

    refute timer.wait(storage: @storage, id: @id)
    assert_equal 0, @notifier.calls
    assert_nil @storage.current_block
  end

  def test_does_not_watch_a_replacement_session
    @clock.on_sleep = lambda do
      @storage.resolve(id: @id, outcome: "completed")
      @storage.save(Timebox::FocusBlock.new(task: "Replacement", duration_seconds: 30))
    end

    refute timer.wait(storage: @storage, id: @id)
    assert_equal 0, @notifier.calls
    assert_equal "Replacement", @storage.current_block["task"]
    assert_equal "active", @storage.current_block["status"]
  end

  def test_interrupt_does_not_resolve_or_notify_the_session
    before = @storage.current_block
    @clock.on_sleep = -> { raise Interrupt }

    assert_raises(Interrupt) { timer.wait(storage: @storage, id: @id) }
    assert_equal before, @storage.current_block
    assert_equal 0, @notifier.calls
    assert @output.string.end_with?("\n")
  end

  private

  def timer
    Timebox::Timer.new(
      clock: @clock, sleeper: @clock.method(:sleep), notifier: @notifier,
      output: @output, error: @error
    )
  end
end
