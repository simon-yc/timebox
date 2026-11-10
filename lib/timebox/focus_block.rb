# frozen_string_literal: true

module Timebox
  class FocusBlock
    attr_reader :task, :duration_seconds, :started_at, :ends_at
    attr_accessor :notes

    def initialize(task:, duration_seconds:, started_at: Time.now, notes: "")
      raise ArgumentError, "Task cannot be empty" unless task.is_a?(String) && !task.strip.empty?

      unless duration_seconds.is_a?(Integer) && duration_seconds.positive?
        raise ArgumentError, "Duration must be a positive integer"
      end

      raise ArgumentError, "Start time must be a Time" unless started_at.is_a?(Time)
      raise ArgumentError, "Notes must be a string" unless notes.is_a?(String)

      @task = task
      @duration_seconds = duration_seconds
      @started_at = started_at
      @ends_at = started_at + duration_seconds
      @notes = notes
    end

    def expired?(now: Time.now)
      now >= ends_at
    end
  end
end
