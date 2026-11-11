# frozen_string_literal: true

require_relative "test_helper"

class NotifierTest < Minitest::Test
  class RecordingNotifier < Timebox::Notifier
    attr_reader :arguments, :options
    attr_accessor :result, :failure

    def system(*arguments, **options)
      @arguments = arguments
      @options = options
      raise @failure if @failure

      @result
    end
  end

  def test_invokes_osascript_with_separate_arguments_and_a_sound
    notifier = RecordingNotifier.new
    notifier.result = true

    assert notifier.notify
    assert_equal ["/usr/bin/osascript", "-e", Timebox::Notifier::SCRIPT], notifier.arguments
    assert_includes notifier.arguments.last, 'sound name "Glass"'
    assert_includes notifier.arguments.last, 'with title "Timebox"'
    assert_equal({ out: File::NULL, err: File::NULL }, notifier.options)
  end

  def test_unsuccessful_osascript_exit_is_reported_as_failure
    notifier = RecordingNotifier.new
    notifier.result = false

    refute notifier.notify
  end

  def test_a_missing_executable_is_reported_as_failure
    notifier = RecordingNotifier.new
    notifier.failure = Errno::ENOENT.new("osascript")

    refute notifier.notify
  end
end
