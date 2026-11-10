# Timebox

A local-first time-boxing CLI, built in plain Ruby as a learning project.

The eventual loop is **plan → focus → check in → choose what comes next → reflect**.
Tasks and history will stay on your machine, without accounts or a server.

## What works today

The Ruby core, SQLite persistence, and `start` / `status` commands are implemented:

- Command help works.
- `start` asks for a task, duration, and optional notes, saves a focus block to
  SQLite, and displays its task, notes (when provided), duration, start time, and
  deadline. Closing the terminal does not lose the saved block.
- Invalid input prints an error and exits with code 1; a successful start exits
  with code 0.
- `status` reads the saved block in a new process and displays its task, notes,
  duration, start time, deadline, state, and remaining minutes and seconds.
  When there is no active block, it says so and exits successfully.
- A second `start` is rejected without replacing the saved block, including when
  two processes try to start at once.
- `Timebox::Duration.parse` converts durations such as `"25m"` and `"1h"` to seconds.
- `Timebox::FocusBlock` stores a task, duration, start time, and calculated deadline.
  Notes can be read and edited. Its `expired?(now:)` method checks whether the
  deadline has been reached.
- `Timebox::Storage` can save a block to SQLite and read the current active block.
  A database constraint prevents saving a second active block.
- Minitest covers parsing, input validation, deadline boundaries, and commands
  through the executable. Storage and CLI tests use temporary databases to check
  persistence, concurrent starts, and the single-active-block constraint.

The `start` command saves its block, prints its summary, and exits. Background
deadline checks and notifications are future work. Once a deadline passes,
`status` displays `awaiting check-in` and zero remaining time; it does not count
elapsed time as confirmed focus or discard the block. Resolving an active block
with `stop` or `checkin` belongs to the next step, so even an overdue block prevents
another start for now.
The roadmap below summarizes the supplied project plan; it describes future work.

## Run it

Use Ruby 4.0 (tested with 4.0.9) and Bundler 4.0.23, the version recorded in
`Gemfile.lock`. The macOS system Ruby 2.6 cannot run this project's locked toolchain.
Check that `ruby --version` selects your intended Ruby installation.

From the repository root, install the locked SQLite and Minitest dependencies:

```sh
ruby --version
bundle --version
bundle install
bundle exec ruby bin/timebox --help
```

Create a focus block interactively:

```sh
bundle exec ruby bin/timebox start
```

Enter a task name, a duration such as `25m` or `1h`, and optional notes when
prompted. Press Enter to leave notes empty. The CLI trims outer whitespace from
the inputs. Invalid input ends the command with an error; it does not prompt
again yet.

Inspect the saved block, including after closing and reopening the terminal:

```sh
bundle exec ruby bin/timebox status
```

Status timestamps include the local date and timezone. Remaining time is computed
from the stored absolute deadline each time you run the command. Database errors
are reported with an error message and exit code 1.

The executable also supports `bundle exec ./bin/timebox --help`. The shorter
`timebox` command will need installation or a PATH change later.

Run all tests:

```sh
bundle exec ruby -Itest -e 'Dir["test/**/*_test.rb"].sort.each { |file| require File.expand_path(file) }'
```

The command finds and loads every test file. All tests should pass with no skips.
To run just the parser tests:

```sh
bundle exec ruby -Itest test/duration_test.rb
```

## Find your way around

```text
bin/timebox                 Executable: loads the library and returns an exit code
lib/timebox.rb              Loads the project files
lib/timebox/cli.rb          Help, persistent start, and saved-block status
lib/timebox/duration.rb     Converts duration strings to seconds
lib/timebox/focus_block.rb  Validates block attributes and calculates deadlines
lib/timebox/storage.rb      Saves and reads blocks in SQLite
test/test_helper.rb         Loads Minitest and the project
test/cli_test.rb            Commands, persistence, countdown, and concurrent starts
test/duration_test.rb       Parsing and invalid-input tests
test/focus_block_test.rb    Block attributes, validation, and expiration tests
test/storage_test.rb        Persistence, SQL parameters, and active-block constraint
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
bundle exec ruby -Ilib -rtimebox -e 'puts Timebox::Duration.parse("25m")'
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

## Storage

`Timebox::Storage.new` opens a database at
`~/.local/share/timebox/timebox.sqlite3` and creates its directory and table if
needed. Override the location with `TIMEBOX_DB` or an explicit `path:` argument.
Both `start` and `status` use this location and close their connections when done.
For example, to use a separate database, set the same path for each command:

```sh
TIMEBOX_DB="$PWD/demo.sqlite3" bundle exec ruby bin/timebox start
TIMEBOX_DB="$PWD/demo.sqlite3" bundle exec ruby bin/timebox status
```

`save(block)` returns the inserted row ID. `current_block` returns a hash with
string keys, or `nil` when no active block exists. Times are stored as Unix
timestamps in whole seconds. Close the connection with `close` when finished.

Saved blocks currently keep the database status `active` until a future check-in
or stop flow resolves them. The CLI derives the displayed state (`running` or
`awaiting check-in`) from the deadline without changing this database status.
Saving another active block raises `SQLite3::ConstraintException`; `start` handles
this with a message explaining that a block already exists. Tests always pass a
temporary path and clean up their databases.

## Build in small steps

1. **Check-ins (next):** Add `stop` and `checkin`. Record what actually happened and let
   the user continue, switch tasks, take a break, or finish.
2. **Background reminders:** Add a user-level macOS LaunchAgent and a deadline
   checker. Handle overdue blocks after sleep or restart and avoid duplicate
   notifications. Test the macOS integration separately.
3. **Reflection:** Add `review` and `stats`, using confirmed activity. Practice a
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
