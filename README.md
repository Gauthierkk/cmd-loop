# cmdloop

A minimal macOS menu bar app for managing scheduled commands via **cron or launchd**. No dock icon, no window — just a popover from the menu bar.

## How it works

**Your local schedulers are the single source of truth.** cmdloop is a GUI frontend over both your crontab (`crontab -l` / `crontab -`) and your launchd agents (`~/Library/LaunchAgents` + `launchctl`). When you add a command you pick the backend; both remain the source of truth and both keep running when cmdloop is closed.

- When adding a command, choose **Cron** (a 5-field cron expression) or **Launchd** (native calendar fields, or an "every N minutes/seconds" interval)
- Cron jobs created in cmdloop are tagged with a comment marker (`# cmdloop:<uuid>`); launchd jobs are written as `com.cmdloop.<uuid>.plist` LaunchAgents
- External cron entries (added via terminal) show up as "cronjob"; external launchd agents in `~/Library/LaunchAgents` show up as "launchd job" (common system/Homebrew agents are filtered out). Either can be renamed, edited, run, or deleted; editing rewrites the underlying crontab line or plist in place
- Turn on **Auto-adopt external entries** in Settings and cmdloop periodically (about twice a day, plus at launch) takes ownership of external entries — wrapping each so its scheduled runs are logged — without touching its schedule or command. Crontab lines that are not plain five-field jobs (`PATH=…`, `@reboot …`) and agents that cannot be re-run through a shell are left alone; an agent its owner re-creates after adoption is handed back. Any single entry can be handed back with **Release** in its detail panel
- Disabling a job removes it from the crontab / unloads and removes its plist; enabling adds it back
- Jobs run via cron or launchd even if cmdloop isn't open

Job metadata (names, last run times) is stored in `~/.config/cmd-loop/config.json`; display names for external entries live in `names.json` and app preferences in `settings.json` alongside it. Each run writes its own log file under `~/.config/cmd-loop/logs/<job-uuid>/`, so run history works even when the app is closed. By default only the most recent run is kept per job; in Settings you can raise this to keep up to 20 runs per job.

Commands run in a login shell (`$SHELL -l -c`) so your PATH and environment are available.

## Install

```bash
brew tap gauthierkk/tap
brew install cmdloop
```

Installs a prebuilt universal binary (Apple Silicon + Intel) — no Xcode or Swift toolchain needed.

Then run it:

```bash
cmdloop
```

It launches in the background and appears as a **⏲** icon in your menu bar.

### From source

```bash
git clone https://github.com/Gauthierkk/cmd-loop.git
cd cmd-loop
./install.sh
```

## Uninstall

```bash
brew uninstall cmdloop
brew untap gauthierkk/tap
```

## Development

```bash
swift build
swift run cmdloop
make help   # build/run/test/install targets, plus launchd testing helpers
```

## Usage

Click the **⏲** icon in your menu bar to open the popover.

Each job row shows a toggle, a status dot, the job name, and the last run time. The status dot pulses green while a run is in progress, turns solid green after a clean exit, red after a failure, and stays dark until the job's first run. The popover sizes itself to fit the longest job name.

Per-job actions:

- **Toggle** — enable/disable a job (adds/removes its crontab entry, or loads/unloads its LaunchAgent). External entries can't be toggled — enable/disable stays with their owner
- **▶ Run now** — execute immediately in the background; the result lands in run history
- **☰ Details & logs** — opens the detail panel: run count, schedule in plain English, last run time, and each run's output; expand to browse previous runs (10 per page). The ☰ stays highlighted while its panel is open
- **✎ Edit** (in the detail panel header) — change a job's name, schedule, command, or backend (backend switching is for cmdloop-managed jobs only). Editing an external entry rewrites its crontab line or plist in place and preserves its run history. (An external agent with multiple calendar intervals shows its schedule read-only; name and command remain editable)
- **⬆ Release** (in the detail panel header, managed jobs only) — hand the job back to a plain cron/launchd entry and stop managing it (the inverse of adoption). It keeps running on the same schedule, but new runs are no longer logged; existing run history is kept. A released entry is excluded from **Auto-adopt**, so it stays released
- **✕ Delete** — remove the job and its scheduler entry

Footer:

- **⚙ Settings** — start at login, auto-adopt external entries (off by default; adopts them for logging about twice a day), log retention (runs to keep per job, 1–20; default 1), and Clear Logs
- **+** — add a command: name, backend (Cron or Launchd), schedule (a cron expression like `0 8 * * *`, or launchd calendar/interval fields), and shell command (multi-line allowed)
- **⏻** — quit cmdloop (scheduled jobs keep running via cron/launchd)

## CLI

```bash
cmdloop            # launch the menu bar app in the background
cmdloop --version  # print the version
cmdloop --help     # usage
```

## Requirements

- macOS 13+
- Swift 5.9+ (only when building from source; the brew install ships a prebuilt binary)
