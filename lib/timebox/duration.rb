# frozen_string_literal: true

module Timebox
  class Duration
    def self.parse(value)
      raise ArgumentError, "Duration must be a string" unless value.is_a?(String)

      unit = value[-1]

      unless ["m", "h"].include?(unit)
        raise ArgumentError, "Duration must end in m (minutes) or h (hours)"
      end

      number_text = value[0...-1]

      unless number_text.match?(/\A\d+\z/)
        raise ArgumentError, "Duration must contain a whole number"
      end

      amount = number_text.to_i

      raise ArgumentError, "Duration must be positive" unless amount.positive?

      if unit == "m"
        amount * 60
      else
        amount * 3600
      end
    end
  end
end
