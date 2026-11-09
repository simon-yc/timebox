# frozen_string_literal: true

require_relative "test_helper"

class DurationTest < Minitest::Test
  def test_parses_minutes
    skip "Exercise 1: remove this line, then implement minutes."

    assert_equal 1500, Timebox::Duration.parse("25m")
  end

  def test_parses_hours
    skip "Exercise 2: remove this line when you are ready to support hours."

    assert_equal 3600, Timebox::Duration.parse("1h")
  end

  def test_rejects_invalid_durations
    skip "Exercise 3: remove this line when you are ready to validate input."

    ["", "abc", "0m", "-5m", "1.5h", "25", "10s", " 25m "].each do |value|
      assert_raises(ArgumentError) { Timebox::Duration.parse(value) }
    end
  end
end
