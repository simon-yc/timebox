# frozen_string_literal: true

require_relative "test_helper"

class DurationTest < Minitest::Test
  def test_parses_minutes
    assert_equal 1500, Timebox::Duration.parse("25m")
  end

  def test_parses_hours
    assert_equal 3600, Timebox::Duration.parse("1h")
  end

  def test_rejects_invalid_durations
    invalid_values = [
      "", "abc", "m", "h", "0m", "0h", "-5m", "1.5h",
      "25", "10s", " 25m ", "25m\n", "1h30m"
    ]

    invalid_values.each do |value|
      assert_raises(ArgumentError, "Expected #{value.inspect} to be rejected") do
        Timebox::Duration.parse(value)
      end
    end
  end

  def test_rejects_non_string_input
    [nil, 25, 1.5, []].each do |value|
      assert_raises(ArgumentError, "Expected #{value.inspect} to be rejected") do
        Timebox::Duration.parse(value)
      end
    end
  end
end
