# frozen_string_literal: true

require_relative "test_helper"

class FocusBlockTest < Minitest::Test
  def setup
    @start_time = Time.utc(2026, 11, 10, 14, 0, 0)

    @block = Timebox::FocusBlock.new(
      task: "Learn Ruby",
      duration_seconds: 1500,
      started_at: @start_time
    )
  end

  def test_stores_attributes
    assert_equal "Learn Ruby", @block.task
    assert_equal 1500, @block.duration_seconds
    assert_equal @start_time, @block.started_at
  end

  def test_calculates_deadline
    expected = Time.utc(2026, 11, 10, 14, 25, 0)

    assert_equal expected, @block.ends_at
  end

  def test_not_expired_before_deadline
    refute @block.expired?(now: @block.ends_at - 1)
  end

  def test_expired_at_deadline
    assert @block.expired?(now: @block.ends_at)
  end

  def test_expired_after_deadline
    assert @block.expired?(now: @block.ends_at + 1)
  end

  def test_rejects_invalid_tasks
    [nil, 25, "", " "].each do |task|
      assert_raises(ArgumentError, "Expected task #{task.inspect} to be rejected") do
        Timebox::FocusBlock.new(task: task, duration_seconds: 1500)
      end
    end
  end

  def test_rejects_invalid_durations
    [nil, "1500", 0, -1, 1.5].each do |duration|
      assert_raises(ArgumentError, "Expected duration #{duration.inspect} to be rejected") do
        Timebox::FocusBlock.new(task: "Learn Ruby", duration_seconds: duration)
      end
    end
  end

  def test_rejects_invalid_start_times
    [nil, "2026-11-10", 0].each do |started_at|
      assert_raises(ArgumentError, "Expected start time #{started_at.inspect} to be rejected") do
        Timebox::FocusBlock.new(
          task: "Learn Ruby",
          duration_seconds: 1500,
          started_at: started_at
        )
      end
    end
  end
end
