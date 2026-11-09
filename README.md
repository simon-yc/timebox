# Timebox

A local-first time-boxing CLI, built in plain Ruby as a learning project.

The eventual loop is **plan → focus → check in → choose what comes next → reflect**.
Tasks and history will stay on your machine, without accounts or a server.

## What works today

This repository is deliberately a starter, not a working timer:

- Command help works.
- `start` and `status` print a clear “not implemented” message and exit with code 1.
- The duration parser is an exercise stub, with three skipped tests to guide you.

Nothing starts a timer, saves data, installs a background process, or sends notifications yet.
The roadmap below summarizes the supplied project plan; it describes future work.

## Run it

You need Ruby. The exercise tests also need Minitest, which is already available
with the Ruby installation on the machine used to create this scaffold.
There are no new gems to install for this starter.

From the repository root:

```sh
ruby --version
ruby bin/timebox --help
```

The executable also supports `./bin/timebox --help`. The shorter `timebox` command
will need installation or a PATH change later.

Run the exercise tests:

```sh
ruby -Itest test/duration_test.rb
```

At first, expect **three skips and zero assertions**. This means the exercises
have not been enabled; it does not mean the parser is implemented.

## Find your way around

```text
bin/timebox                 Executable: loads the library and returns an exit code
lib/timebox.rb              Loads the project files
lib/timebox/cli.rb          Help text and command routing
lib/timebox/duration.rb     Your first implementation exercise
test/test_helper.rb         Loads Minitest and the project
test/duration_test.rb       Skipped examples to enable as you learn
```

`Timebox` is a Ruby module that groups the project's classes. In
`def self.parse(value)`, `self.` lets you call the method on the class:
`Timebox::Duration.parse("25m")`. `require_relative` loads another file relative
to the current file, so the starter needs no package installation.

## First exercise: parse a duration

Open `lib/timebox/duration.rb` and replace the `NotImplementedError` with your code.

Keep the first version small:

- Accept a positive whole number followed by `m` or `h`.
- Return seconds: `"25m"` becomes `1500`, and `"1h"` becomes `3600`.
- Raise `ArgumentError` for invalid input, including zero or negative durations.
- Leave combined units, decimals, and extra whitespace for another iteration.

In `test/duration_test.rb`, remove the `skip` line from the minutes test first.
Run it, make it pass, then enable the next test. The parser intentionally has no
solution supplied.

To try your parser directly after implementing it:

```sh
ruby -Ilib -rtimebox -e 'puts Timebox::Duration.parse("25m")'
```

## Build in small steps

1. **Ruby core:** Finish the parser. Add a plain Ruby focus-block class with a task,
   start time, and deadline. Write `expired?(now:)` yourself and test the exact
   deadline boundary. Then connect a basic interactive `start` flow. Decide how
   `status` will work across separate CLI invocations when you add persistence.
2. **Persistence:** Add SQLite through the `sqlite3` gem. Create tasks and time
   blocks, store UTC timestamps, and practice parameterized SQL. Verify that data
   survives closing and reopening the CLI.
3. **Check-ins:** Add `stop` and `checkin`. Record what actually happened and let
   the user continue, switch tasks, take a break, or finish.
4. **Background reminders:** Add a user-level macOS LaunchAgent and a deadline
   checker. Handle overdue blocks after sleep or restart and avoid duplicate
   notifications. Test the macOS integration separately.
5. **Reflection:** Add `review` and `stats`, using confirmed activity. Practice a
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
