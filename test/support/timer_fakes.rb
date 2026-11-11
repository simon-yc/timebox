# frozen_string_literal: true

class FakeClock
  attr_accessor :time, :speed, :on_sleep
  attr_reader :sleeps

  def initialize(time: Time.utc(2026, 11, 11, 14), speed: 1)
    @time = time
    @speed = speed
    @sleeps = []
  end

  def call
    @time
  end

  def sleep(seconds)
    @sleeps << seconds
    @time += seconds * @speed
    @on_sleep&.call
  end
end

class FakeNotifier
  attr_accessor :result, :on_notify
  attr_reader :calls

  def initialize(result: true)
    @result = result
    @calls = 0
  end

  def notify
    @calls += 1
    @on_notify&.call
    @result
  end
end
