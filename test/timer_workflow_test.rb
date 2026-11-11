# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/timer_fakes"
require "fileutils"
require "open3"
require "rbconfig"
require "stringio"
require "timeout"
require "tmpdir"

class TimerWorkflowTest < Minitest::Test
  LIBRARY = File.expand_path("../lib/timebox", __dir__)

  def setup
    @directory = Dir.mktmpdir("timebox-timer-workflow-")
    @path = File.join(@directory, "timebox.sqlite3")
    @clock = FakeClock.new(speed: 60)
    @notifier = FakeNotifier.new
  end

  def teardown
    FileUtils.remove_entry(@directory) if @directory
  end

  def test_start_counts_down_notifies_and_automatically_checks_in
    @notifier.on_notify = lambda do
      assert_equal "active", records.last["status"]
      assert_nil records.last["outcome"]
    end

    output, error, code = run_with_timer("start", "Learn Ruby\n1m\nNotes\ncompleted\n\nfinish\n")

    assert_equal 0, code
    assert_empty error
    assert_includes output, "Remaining: 01:00"
    assert_includes output, "Remaining: 00:00"
    assert_includes output, "Checking in: Learn Ruby"
    assert_equal 1, @notifier.calls
    assert_equal "resolved", records.last["status"]
    assert_equal "completed", records.last["outcome"]
    assert_equal 60, records.last["duration_seconds"]
  end

  def test_continue_switch_and_break_start_another_countdown
    choices = {
      "continue" => ["2m\n", "First task", 120],
      "switch" => ["Other task\n2m\nOther notes\n", "Other task", 120],
      "break" => ["1m\n", "Break", 60]
    }
    choices.each do |choice, (answers, expected_task, seconds)|
      previous_calls = @notifier.calls
      input = "First task\n1m\nOriginal notes\npartial\n\n#{choice}\n#{answers}completed\n\nfinish\n"

      output, error, code = run_with_timer("start", input)

      assert_equal 0, code, error
      assert_empty error
      assert_equal previous_calls + 2, @notifier.calls
      assert_equal 2, output.scan("Checking in:").length
      first, second = records.last(2)
      assert_equal "partial", first["outcome"]
      assert_equal "completed", second["outcome"]
      assert_equal "resolved", second["status"]
      assert_equal expected_task, second["task"]
      assert_equal seconds, second["duration_seconds"]
      assert_equal first["ends_at"], second["started_at"]
    end
  end

  def test_manual_checkin_also_runs_the_successor_timer
    save_block(started_at: @clock.call - 120)

    output, error, code = run_with_timer("checkin", "partial\n\ncontinue\n1m\ncompleted\n\nfinish\n")

    assert_equal 0, code
    assert_empty error
    assert_includes output, "Remaining: 01:00"
    assert_equal 1, @notifier.calls
    assert_equal ["resolved", "resolved"], records.map { |record| record["status"] }
  end

  def test_notification_failure_still_enters_checkin
    @notifier.result = false

    output, error, code = run_with_timer("start", "Task\n1m\n\ncompleted\n\nfinish\n")

    assert_equal 0, code
    assert_includes error, "macOS notification failed"
    assert_includes output, "Checking in: Task"
    assert_equal 1, @notifier.calls
    assert_equal "completed", records.last["outcome"]
  end

  def test_start_does_not_watch_a_session_replaced_before_the_first_countdown
    replace_session_after(:start)

    output, error, code = run_with_timer("start", "Original\n1m\n\n")

    assert_equal 0, code
    assert_empty error
    assert_equal 0, @notifier.calls
    refute_includes output, "Remaining:"
    assert_replacement_is_active
  end

  def test_empty_checkin_does_not_adopt_a_session_created_at_handoff
    replace_session_after(:checkin)

    output, error, code = run_with_timer("checkin", "")

    assert_equal 0, code
    assert_empty error
    assert_equal 0, @notifier.calls
    refute_includes output, "Remaining:"
    assert_replacement_is_active
  end

  def test_finish_exits_even_if_another_session_starts_at_handoff
    ["checkin", "start"].each do |command|
      @path = File.join(@directory, "finish-#{command}.sqlite3")
      save_block(started_at: @clock.call - 120) if command == "checkin"
      replace_session_after(:checkin)
      input = command == "start" ? "Original\n1m\n\n" : ""

      output, error, code = run_with_timer(command, "#{input}completed\n\nfinish\n")

      assert_equal 0, code
      assert_empty error
      assert_equal(command == "start" ? 1 : 0, @notifier.calls)
      refute_includes output, "Checking in: Replacement"
      assert_replacement_is_active
    end
  end

  def test_checkin_does_not_watch_a_successor_replaced_at_handoff
    ["checkin", "start"].each do |command|
      @path = File.join(@directory, "continue-#{command}.sqlite3")
      save_block(started_at: @clock.call - 120) if command == "checkin"
      replace_session_after(:checkin)
      input = command == "start" ? "Original\n1m\n\n" : ""

      output, error, code = run_with_timer(command, "#{input}partial\n\ncontinue\n1m\n")

      assert_equal 0, code
      assert_empty error
      assert_equal(command == "start" ? 1 : 0, @notifier.calls)
      refute_includes output, "Checking in: Replacement"
      assert_replacement_is_active
    end
  end

  def test_eof_at_automatic_checkin_leaves_the_session_active
    output, error, code = run_with_timer("start", "Task\n1m\n\n")

    assert_equal 1, code
    assert_includes error, "Select completed, partial, or incomplete"
    refute_includes output, "Focus block resolved!"
    assert_equal 1, @notifier.calls
    assert_equal "active", records.last["status"]
    assert_nil records.last["outcome"]
  end

  def test_interrupt_during_countdown_keeps_the_saved_block
    @clock.on_sleep = -> { raise Interrupt }

    output, error, code = run_with_timer("start", "Task\n1m\nKeep notes\n")

    assert_equal 130, code
    assert_empty error
    assert_includes output, "Any unresolved session is still saved"
    assert_equal 0, @notifier.calls
    assert_equal "active", records.last["status"]
    assert_nil records.last["outcome"]
    assert_equal "Keep notes", records.last["notes"]
  end

  def test_interrupt_at_automatic_checkin_does_not_resolve_the_block
    input = Class.new(StringIO) do
      def gets
        @reads = (@reads || 0) + 1
        raise Interrupt if @reads == 4

        super
      end
    end.new("Task\n1m\n\n")

    _, error, code = run_with_timer("start", input)

    assert_equal 130, code
    assert_empty error
    assert_equal 1, @notifier.calls
    assert_equal "active", records.last["status"]
    assert_nil records.last["outcome"]
  end

  def test_a_session_replaced_during_notification_is_not_checked_in
    @notifier.on_notify = lambda do
      storage = Timebox::Storage.new(path: @path)
      begin
        storage.resolve(id: storage.current_block["id"], outcome: "completed")
        storage.save(Timebox::FocusBlock.new(
          task: "Replacement", duration_seconds: 60, started_at: @clock.call
        ))
      ensure
        storage.close
      end
    end

    output, error, code = run_with_timer("start", "Task\n1m\n\n")

    assert_equal 1, code
    assert_includes error, "no longer active"
    refute_includes output, "Checking in: Replacement"
    assert_equal "Replacement", records.last["task"]
    assert_equal "active", records.last["status"]
    assert_nil records.last["outcome"]
  end

  def test_ctrl_c_and_terminal_hangup_preserve_the_session
    script = <<~RUBY
      require ARGV.shift
      $stdout.sync = true
      notifier = Object.new
      def notifier.notify
        true
      end
      exit Timebox::CLI.run(ARGV, timer: Timebox::Timer.new(notifier: notifier))
    RUBY

    ["INT", "HUP"].each do |signal|
      @path = File.join(@directory, "#{signal}.sqlite3")
      Open3.popen3(
        { "TIMEBOX_DB" => @path }, RbConfig.ruby, "-e", script, LIBRARY, "start"
      ) do |input, output, error, child|
        begin
          input.write("Signal test\n1m\nKeep notes\n")
          input.close
          captured = String.new(encoding: Encoding::BINARY)
          Timeout.timeout(5) do
            captured << output.readpartial(1024) until captured.include?("Remaining:")
          end
          before = records
          Process.kill(signal, child.pid)
          captured << output.read.b
          error.read
          status = child.value

          refute status.success?
          assert_equal 130, status.exitstatus if signal == "INT"
          assert_equal before, records
          assert_equal "active", records.last["status"]
          assert_nil records.last["outcome"]
        ensure
          input.close unless input.closed?
        end
      end
    end
  end

  private

  # Schedule another connection's write exactly between a command and its timer.
  def replace_session_after(command)
    replace = lambda do
      storage = Timebox::Storage.new(path: @path)
      begin
        current = storage.current_block
        storage.resolve(id: current["id"], outcome: "completed") if current
        storage.save(Timebox::FocusBlock.new(
          task: "Replacement", duration_seconds: 60, started_at: @clock.call
        ))
      ensure
        storage.close
      end
    end
    @cli = Class.new(Timebox::CLI)
    @cli.define_singleton_method(command) do |**options, &on_saved|
      result = super(**options, &on_saved)
      callback = replace
      replace = nil
      callback&.call
      result
    end
  end

  def assert_replacement_is_active
    assert_equal "Replacement", records.last["task"]
    assert_equal "active", records.last["status"]
    assert_nil records.last["outcome"]
  end

  def run_with_timer(command, input)
    previous_input = $stdin
    previous_path = ENV["TIMEBOX_DB"]
    $stdin = input.is_a?(String) ? StringIO.new(input) : input
    ENV["TIMEBOX_DB"] = @path
    code = nil
    output, error = capture_io do
      timer = Timebox::Timer.new(
        clock: @clock, sleeper: @clock.method(:sleep), notifier: @notifier
      )
      code = (@cli || Timebox::CLI).run([command], timer: timer, clock: @clock)
    end
    [output, error, code]
  ensure
    $stdin = previous_input
    ENV["TIMEBOX_DB"] = previous_path
  end

  def save_block(started_at:)
    storage = Timebox::Storage.new(path: @path)
    storage.save(Timebox::FocusBlock.new(
      task: "Saved task", duration_seconds: 60, started_at: started_at
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
