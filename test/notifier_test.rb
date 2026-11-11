# frozen_string_literal: true

require_relative "test_helper"

class NotifierTest < Minitest::Test
  class RecordingNotifier < Timebox::Notifier
    attr_reader :arguments, :options, :calls
    attr_accessor :result, :failure, :sound_result, :sound_failure

    def initialize
      @calls = []
      @sound_result = true
    end

    def system(*arguments, **options)
      @arguments = arguments
      @options = options
      @calls << [arguments, options]
      if arguments.first == "/usr/bin/afplay"
        raise @sound_failure if @sound_failure

        return @sound_result
      end
      raise @failure if @failure

      @result
    end
  end

  def test_invokes_osascript_with_a_persistent_single_button_dialog_and_sound
    notifier = RecordingNotifier.new
    notifier.result = true

    assert notifier.notify
    assert_equal ["/usr/bin/afplay", "/System/Library/Sounds/Glass.aiff"], notifier.calls.first.first
    assert_equal({ out: File::NULL, err: File::NULL }, notifier.calls.first.last)
    assert_equal 2, notifier.calls.size
    assert_equal ["/usr/bin/osascript", "-e", Timebox::Notifier::SCRIPT], notifier.arguments
    script = notifier.arguments.last
    assert_includes script, 'display dialog "Your focus session has ended. Return to Timebox to check in."'
    assert_includes script, 'with title "Timebox"'
    assert_includes script, 'buttons {"OK"} default button "OK"'
    assert_match(/^activate$/, script)
    refute_includes script, "giving up after"
    refute_includes script, "display notification"
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

  def test_failed_sound_playback_warns_and_still_shows_the_dialog
    notifier = RecordingNotifier.new
    notifier.result = true
    notifier.sound_result = false

    _, error = capture_io { assert notifier.notify }

    assert_includes error, "Could not play the alert sound"
    assert_equal "/usr/bin/osascript", notifier.arguments.first
  end

  def test_a_missing_sound_player_does_not_prevent_the_dialog
    notifier = RecordingNotifier.new
    notifier.result = true
    notifier.sound_failure = Errno::ENOENT.new("afplay")

    _, error = capture_io { assert notifier.notify }

    assert_includes error, "Could not play the alert sound"
    assert_equal "/usr/bin/osascript", notifier.arguments.first
  end
end
