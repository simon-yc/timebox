# Timebox

A local-first time-boxing CLI, built in plain Ruby as a learning project.

The eventual loop is **plan → focus → check in → choose what comes next → reflect**.
Tasks and history will stay on your machine, without accounts or a server.

## What works today

The Ruby core and interactive `start` command are implemented:

- Command help works.
- `start` asks for a task and duration, creates a focus block, and displays its
  task, duration, start time, and deadline.
- Invalid input prints an error and exits with code 1; a successful start exits
  with code 0.
- `status` prints a “not implemented” message and exits with code 1.
- `Timebox::Duration.parse` converts durations such as `"25m"` and `"1h"` to seconds.
- `Timebox::FocusBlock` stores a task, duration, start time, and calculated deadline.
  Its `expired?(now:)` method checks whether the deadline has been reached.
- Minitest covers parsing, input validation, the exact deadline boundary, and the
  interactive command through the executable.

The `start` command prints its summary and exits. Its block exists only in memory
while the command runs. Persistence, background deadline checks, and notifications
are future work.
The roadmap below summarizes the supplied project plan; it describes future work.

## Run it

You need Ruby and Minitest. Minitest is already available with the Ruby
installation used for this project; no new dependencies have been added.

From the repository root:

```sh
ruby --version
ruby bin/timebox --help
```

Create a focus block interactively:

```sh
ruby bin/timebox start
```

Enter a task name and a duration such as `25m` or `1h` when prompted. The CLI trims
outer whitespace from both inputs. Invalid input ends the command with an error;
it does not prompt again yet.

The executable also supports `./bin/timebox --help`. The shorter `timebox` command
will need installation or a PATH change later.

Run all tests:

```sh
ruby -Itest -e 'Dir["test/**/*_test.rb"].sort.each { |file| require File.expand_path(file) }'
```

The command finds and loads every test file. All tests should pass with no skips.
To run just the parser tests:

```sh
ruby -Itest test/duration_test.rb
```

## Find your way around

```text
bin/timebox                 Executable: loads the library and returns an exit code
lib/timebox.rb              Loads the project files
lib/timebox/cli.rb          Help, command routing, and interactive start prompts
lib/timebox/duration.rb     Converts duration strings to seconds
lib/timebox/focus_block.rb  Validates block attributes and calculates deadlines
test/test_helper.rb         Loads Minitest and the project
test/cli_test.rb            Start prompts, output, errors, and process exit codes
test/duration_test.rb       Parsing and invalid-input tests
test/focus_block_test.rb    Block attributes, validation, and expiration tests
```

`Timebox` is a Ruby module that groups the project's classes. In
`def self.parse(value)`, `self.` lets you call the method on the class:
`Timebox::Duration.parse("25m")`. `require_relative` loads another file relative
to the current file, so the starter needs no package installation.

## Try the Ruby core

The duration parser accepts a positive whole number followed by lowercase `m`
(minutes) or `h` (hours) and returns seconds. Invalid input raises `ArgumentError`,
including non-string values, zero, negative numbers, decimals, extra whitespace,
and combined units such as `"1h30m"`.

Try it from the terminal:

```sh
ruby -Ilib -rtimebox -e 'puts Timebox::Duration.parse("25m")'
```

This prints `1500`. The flags add `lib` to Ruby's library search path, load
`timebox`, and execute the expression after `-e`.

With the library loaded, a focus block can be used like this:

```ruby
started_at = Time.utc(2026, 11, 10, 14, 0, 0)
block = Timebox::FocusBlock.new(
  task: "Learn Ruby",
  duration_seconds: Timebox::Duration.parse("25m"),
  started_at: started_at
)

block.ends_at                              # 2026-11-10 14:25:00 UTC
block.expired?(now: started_at)             # false
block.expired?(now: block.ends_at)          # true
```

The task must be a nonblank string, the duration a positive integer number of
seconds, and the start time a Ruby `Time`. Invalid attributes raise `ArgumentError`.
If omitted, `started_at` defaults to the current time. Calling `expired?` without
`now:` also uses the current time. Supplying explicit times keeps tests predictable.
This method only compares times; it does not wait, change a block's state, or send
a notification.

## Build in small steps

1. **Persistence (next):** Each CLI invocation is a separate process, so saved
   blocks are needed for `status` to work across invocations. Add SQLite through
   the `sqlite3` gem. Create tasks and time blocks, store UTC timestamps, and
   practice parameterized SQL. Verify that data survives closing and reopening
   the CLI.
2. **Check-ins:** Add `stop` and `checkin`. Record what actually happened and let
   the user continue, switch tasks, take a break, or finish.
3. **Background reminders:** Add a user-level macOS LaunchAgent and a deadline
   checker. Handle overdue blocks after sleep or restart and avoid duplicate
   notifications. Test the macOS integration separately.
4. **Reflection:** Add `review` and `stats`, using confirmed activity. Practice a
   SQL query that totals confirmed focus minutes for a selected day.

Keep domain rules in Ruby classes, terminal interaction in the CLI, and future
SQLite/macOS integration in separate adapters. Add those files when they have
their first job; there are no empty database or background-agent layers yet.

## Rules to preserve as you build

- A deadline passing changes `running` to `awaiting_checkin`; it does not prove
  that the time was spent focusing.
- Count focus time from user-confirmed outcomes, not elapsed time alone.
- Continuing a task creates a new time block.
- Save absolute deadlines so closing the terminal cannot lose a block.
- Make repeated background checks safe, with transactional state changes and
  duplicate-notification prevention.
- Keep the data local and avoid logging task names unnecessarily.

The eventual commands are `start`, `status`, `stop`, `checkin`, `review`, and
`stats`. A GUI, cloud sync, AI features, and elaborate analytics are outside this
first project.
