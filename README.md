# Timebox

A local-first Ruby CLI for planning focus blocks and recording their outcomes.
Tasks, notes, and history stay in a local SQLite database.

## Setup

Use Ruby 4.0 (tested with 4.0.9) and Bundler 4.0.23, as recorded in `Gemfile.lock`.
The macOS system Ruby 2.6 cannot run the locked dependencies. From the repo root:

```sh
ruby --version
bundle --version
bundle install
bundle exec ruby bin/timebox --help
```

`bundle install` installs the SQLite and Minitest dependencies from the lockfile.
Use `bundle exec` to run commands with those versions.

## Commands

```sh
bundle exec ruby bin/timebox start
bundle exec ruby bin/timebox status
bundle exec ruby bin/timebox stop
bundle exec ruby bin/timebox checkin
```

Commands take no additional arguments. Durations use positive whole minutes or
hours. Duration and timestamp values must fit SQLite's signed 64-bit integer
range; excessive values are rejected before being stored.

- **start:** Ask for a task, duration (`25m` or `1h`), and optional notes. Save the
  block and run a terminal countdown to its saved deadline. A second active block
  is rejected.
- **status:** Show the active block, notes, planned times, and remaining time.
  Closing the terminal does not lose the block. An overdue block shows
  `awaiting check-in`; passing a deadline does not resolve it.
- **stop:** Select an outcome by name or number, then optionally replace notes.
  Press Enter at the notes prompt to keep existing notes. Resolving the block
  allows a new one to start, including after an overdue block.
- **checkin:** After the deadline, select an outcome, optionally update notes, and
  choose what comes next. Before the deadline, use `stop` to resolve a block early.

Check-in actions accept a name or number:

| Choice | Action | What happens |
| --- | --- | --- |
| 1 | `continue` | Same task and updated/current notes, with a new duration. |
| 2 | `switch` | Ask for another task, duration, and its own optional notes. |
| 3 | `break` | Ask for a duration and start a block named `Break` with empty notes. |
| 4 | `finish` | Resolve the current block without starting another. |

Every continuation, switch, or break creates a separate block starting when you
answer the prompts. The previous block's planned times remain unchanged. Timed
breaks use the same block structure and are identified by the task name `Break`.

## Foreground timer and macOS notifications

After `start`, Timebox keeps running and displays `Remaining: MM:SS`. It reads the
stored `ends_at` each second. At the deadline, it sends a native macOS notification
with the Glass sound through `/usr/bin/osascript`, then opens the check-in prompts
in the same terminal. Continue, switch, and timed break automatically start the
next countdown. A manual `checkin` also runs the countdown for any next block.

**Keep the terminal open for notifications.** There is no background service.
After computer sleep, an overdue timer notifies when the running process resumes.
Closing the terminal stops notifications but preserves the session in SQLite.
Ctrl+C returns exit code 130 and leaves any unresolved session saved. Later, use
`status`, `stop`, or `checkin` (once due); reopening the terminal does not resume a
countdown automatically. `status` and `stop` can also run in another terminal.

Each running timer attempts one notification per session. A notification failure
prints a warning and still opens check-in; it does not resolve or discard data.
macOS notification permissions and Focus settings can suppress banners or sounds.
If another command resolves or replaces the watched block, its countdown stops.
The timer follows only blocks created by its own command. Choosing `finish`
exits, even if another terminal starts a new block at the same time.

All required check-in input is validated before saving. The outcome, optional
notes update, and any next block are committed together in one transaction. Bad
input, EOF before a required answer, a failed database write, or a stale check-in
cannot leave the previous block partly resolved or overwrite a newer session.

Outcomes are exactly:

| Choice | Outcome | Meaning |
| --- | --- | --- |
| 1 | `completed` | Accomplished the intended task. |
| 2 | `partial` | Made progress but didn't finish. |
| 3 | `incomplete` | Made little or no meaningful progress. |

Status and outcome are separate: a new block is `active` with a `NULL` outcome;
`stop` or `checkin` changes it to `resolved` with one of the three outcomes. The
planned `started_at`, `ends_at`, and `duration_seconds` values remain unchanged.
There is no actual-time tracking or prompt for focused duration.

Blank or invalid outcomes leave the block active and return an error. Skipping
optional notes, including EOF, keeps the previous notes. With no active block,
`status`, `stop`, and `checkin` report that and exit successfully. Invalid input or
database errors exit with code 1. Status also displays a deadline-based state (`running`
or `awaiting check-in`); this is separate from the stored `active`/`resolved` status.

## Database and manual development reset

The default database is `~/.local/share/timebox/timebox.sqlite3`. Override it with
`TIMEBOX_DB`, using the same path for every command:

```sh
TIMEBOX_DB="$PWD/demo.sqlite3" bundle exec ruby bin/timebox start
TIMEBOX_DB="$PWD/demo.sqlite3" bundle exec ruby bin/timebox stop
```

An empty `TIMEBOX_DB` is rejected; unset it to use the default path.

The schema now includes a nullable `outcome` column. There are no migrations:
an older database is not upgraded and may report `no such column: outcome`.
The application never deletes or resets your data.
Check-in adds no schema changes; a database that already supports `stop` needs
no reset.

To reset an existing development database manually, close all Timebox processes.
If you use `TIMEBOX_DB`, export the same value you normally pass to commands in
this terminal first. Select and check the exact path:

```sh
timebox_db_path="${TIMEBOX_DB-$HOME/.local/share/timebox/timebox.sqlite3}"
printf 'Database selected: %s\n' "$timebox_db_path"
```

After checking the path, these commands move the database and any SQLite sidecar
files into a new backup directory. The next `status` creates a fresh empty schema
at the selected path. The script stops on a backup failure before recreating the
database. This is a manual reset; the application never runs these commands.

```sh
(
  set -e
  timebox_backup_dir="$(mktemp -d "${timebox_db_path}.backup.XXXXXX")"
  for timebox_suffix in "" "-wal" "-shm" "-journal"; do
    if [ -f "${timebox_db_path}${timebox_suffix}" ]; then
      mv -i -- "${timebox_db_path}${timebox_suffix}" "$timebox_backup_dir/"
    fi
  done
  printf 'Backup directory: %s\n' "$timebox_backup_dir"
  TIMEBOX_DB="$timebox_db_path" bundle exec ruby bin/timebox status
)
```

For a database opened directly with `Storage.new(path: ...)`, reset that explicit
path instead; set `timebox_db_path` to it before running the backup commands.

## Tests

```sh
bundle exec ruby -Itest -e 'Dir["test/**/*_test.rb"].sort.each { |file| require File.expand_path(file) }'
```

Tests use temporary databases, clean them up afterward, and do not use your
personal database. They cover parsing, note validation, deadline boundaries,
persistence, outcomes, check-in actions, planned-time preservation, rollback,
and conflicting updates.

Timer tests use fake clocks and notifications, so the suite does not wait for real
focus durations or send desktop alerts. Signal tests verify that Ctrl+C and a
terminal hangup leave the saved session intact.

Background services, analytics, actual-time tracking, and database migrations are
not implemented.
