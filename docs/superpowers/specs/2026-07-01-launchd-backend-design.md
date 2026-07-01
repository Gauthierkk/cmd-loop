# launchd as a co-equal scheduling backend

**Date:** 2026-07-01
**Status:** Approved design, pending implementation plan

## Problem

cmdloop is a macOS menu bar app whose **single source of truth is the system
crontab**. It reads/writes cron entries and mirrors metadata (names, run history)
in `~/.config/cmd-loop/config.json`. macOS's native scheduler is launchd, not
cron, and many user jobs live in `~/Library/LaunchAgents`. We want launchd to be
a **co-equal backend**: the user picks cron or launchd per job, cmdloop fully
manages both (create / edit / enable / disable / delete), and the local scheduler
config (crontab **or** launchd plists) remains the source of truth so jobs run
even when the app is closed.

## Goals

- Full parity: user chooses the backend per job on the Add screen.
- Both crontab entries and launchd LaunchAgents remain the source of truth.
- Existing `config.json` continues to load with no user action (migration).
- Run history works identically for both backends, app open or closed.

## Non-goals

- Managing system-level agents/daemons (`/Library/LaunchAgents`,
  `/Library/LaunchDaemons`) — those need root; we stay in the user domain
  (`~/Library/LaunchAgents`, `gui/$UID`).
- A cron⇄launchd schedule translator. Launchd jobs use native launchd schedule
  fields; cron jobs use cron expressions. No cross-conversion.

## Design

### 1. Data model (`CronJob.swift`)

Add a backend dimension and generalize the schedule:

```swift
enum JobBackend: String, Codable { case cron, launchd }

enum JobSchedule: Codable {
  case cron(String)                    // 5-field cron expression
  case calendar([CalendarInterval])    // launchd StartCalendarInterval
  case interval(Int)                   // launchd StartInterval (seconds)
}

struct CalendarInterval: Codable {     // each nil = "every"
  var minute, hour, day, weekday, month: Int?
}
```

- `CronJob` gains `backend: JobBackend` and swaps `cronExpression: String` →
  `schedule: JobSchedule`.
- **Migration:** a custom `Codable` implementation reads a legacy `cronExpression`
  key into `.cron(...)` and defaults a missing `backend` to `.cron`, so existing
  `config.json` files decode unchanged. New writes use the `schedule` +
  `backend` shape.
- The type keeps the name `CronJob` to minimize diff churn across the UI and
  tests (it is now backend-agnostic; the name is retained deliberately).
- Following the existing cron pattern, `config.json` mirrors the schedule for
  **managed** jobs and the plist/crontab is written from it (config is
  authoritative for managed jobs; the scheduler entry is the execution mechanism
  that runs jobs while the app is closed). **External** launchd agents are read
  from their plist, exactly as external cron entries are read from the crontab.

### 2. Backends & facade

- **`CrontabManager`** — unchanged; owns the cron backend.
- **`LaunchdManager` (new)** — owns launchd:
  - Scan `~/Library/LaunchAgents`, parse each plist.
  - Write/remove managed plists named `com.cmdloop.<uuid>.plist` with Label
    `com.cmdloop.<uuid>`.
  - Load/unload via `launchctl bootstrap gui/$UID <plist>` and
    `launchctl bootout gui/$UID/<label>`.
  - Translate `JobSchedule` ⇄ plist keys (`StartCalendarInterval` /
    `StartInterval`).
  - Editing an **external** agent does a read-modify-write that **preserves
    unknown keys** so third-party agents' `EnvironmentVariables`, `WorkingDirectory`,
    etc. are not clobbered — only `ProgramArguments` and the schedule keys change.
- **`SchedulerManager` (new facade)** — the UI's single entry point:
  - `loadAllJobs()` merges cron + launchd jobs into one list.
  - Routes `sync` / `runNow` / `delete` / `updateExternal` / toggle by
    `job.backend`.
  - `runNow` lives here (backend-agnostic: direct `$SHELL -l -c` exec, unchanged
    from today's behavior; captures output to a manual run-log file).
  - The existing `CrontabManager.shared` call sites in the UI are updated to call
    `SchedulerManager.shared`.

### 3. External agent discovery

Show every plist in `~/Library/LaunchAgents` **except** those whose Label matches
a noise blocklist of prefixes:

```
com.apple.  homebrew.mxcl.  com.microsoft.  com.google.  org.mongodb.
com.docker.  com.adobe.  com.valvesoftware.  com.logi.
```

(The final blocklist is a maintainable constant; the list above is the starting
set.) Shown external agents:

- Get a stable deterministic UUID derived from their content (via the existing
  `deterministicUUID(from:)`), so identity survives reloads.
- Get a user-assignable display name via the existing `ExternalNameStore`
  (default `"launchd job"`), keyed by content.
- Derive their command from `ProgramArguments` (joined for display).
- Managed cmdloop agents (`com.cmdloop.*`) are excluded from the external scan;
  they come from `config.json` like managed cron jobs.

### 4. Schedule editor UI (Add / Edit screen)

- A **backend segmented control**: `Cron | Launchd`.
- **Cron** selected → the existing 5-field cron expression text input.
- **Launchd** selected → **native launchd fields**:
  - Calendar mode: Minute / Hour / Day-of-month / Weekday / Month, each a small
    input where blank = "every" (maps to one `StartCalendarInterval` dict).
  - Interval mode toggle: "Every N minutes/seconds" (maps to `StartInterval`).
- The command field is shared by both backends.
- Job rows display a small `cron` / `launchd` tag and a human-readable schedule
  summary (e.g. "every 30 min", "08:00 daily", "Mondays 09:00").
- **Guardrail:** an external agent whose schedule cannot round-trip through the
  editor (an array of more than one `StartCalendarInterval` dict, or exotic keys
  not modeled) shows its schedule **read-only**. Run / rename / enable / disable /
  delete still work; only schedule-editing is disabled, to avoid data loss.

### 5. Run history (`RunLogStore`)

Managed launchd jobs wrap the command so per-run logging matches cron exactly:

```
ProgramArguments = ["/bin/zsh", "-l", "-c",
  "<command> >> '<logdir>'/run-$(date +%Y-%m-%dT%H-%M-%S).log 2>&1"]
```

This is the same per-run redirection as `RunLogStore.cronRedirection`, but
**without** the `%`-escaping cron requires (launchd passes the string verbatim to
the shell). Result: per-run log files, run counts, and last-run detection work
identically whether a job fires via cron or launchd, and whether the app is open
or closed. A `RunLogStore.launchdRedirection(for:)` (un-escaped variant) backs
this. `runNow` continues to write a `-manual.log` run file via direct exec.

### 6. Enable / disable / delete (launchd)

- **Managed:**
  - Enable = write plist + `launchctl bootstrap`.
  - Disable = `launchctl bootout` + remove the plist file (job retained in
    `config.json`). Exact mirror of cron's "remove from crontab, keep in config."
  - Delete = disable + drop from `config.json` (+ remove run logs, as today).
- **External:**
  - Disable = `launchctl bootout` but **keep** the plist file on disk.
  - Delete = `launchctl bootout` + remove the plist file.
  - Edit = read-modify-write preserving unknown keys (see §2).
- **Launch-time reconcile:** on startup `SchedulerManager` ensures each enabled
  managed launchd job's plist exists and is loaded, and disabled managed launchd
  jobs are unloaded/removed — the launchd analog of today's
  `CrontabManager.sync(jobs)` in `AppDelegate.applicationDidFinishLaunching`.

## Testing

`cmdloopTests` extends `CronJobTests` (and/or adds `LaunchdTests`) to cover:

- `config.json` migration: legacy `cronExpression` decodes to `.cron`, missing
  `backend` defaults to `.cron`; round-trips through encode/decode.
- `JobSchedule` encode/decode for all three cases.
- `LaunchdManager` schedule translation: `JobSchedule.calendar/.interval` →
  plist dict and back.
- External plist parsing: `ProgramArguments` → command, schedule extraction, and
  the read-only guardrail for multi-dict `StartCalendarInterval`.
- The noise blocklist filter includes/excludes the right labels.

## Open questions

None outstanding. Two defaults were explicitly confirmed:
- Keep the `CronJob` type name (no rename).
- Managed launchd disable removes the plist file (retained in config).
