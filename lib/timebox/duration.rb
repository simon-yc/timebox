# frozen_string_literal: true

module Timebox
  class Duration
    # TODO: Convert a duration such as "25m" or "1h" to seconds.
    # Accept positive whole numbers; raise ArgumentError for invalid input.
    def self.parse(value)
      raise NotImplementedError, "Your first exercise: implement Timebox::Duration.parse"
    end
  end
end
