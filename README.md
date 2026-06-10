# cmdloop

A minimal macOS menu bar app for managing cron jobs. No dock icon, no window — just a popover from the menu bar.

## How it works

**Your system crontab is the single source of truth.** cmdloop is a GUI frontend for `crontab -l` / `crontab -`. It reads, writes, and displays entries directly from your crontab.

- Jobs created in cmdloop are tagged with a comment marker (`# cmdloop:<uuid>`) so the app can track them
- External cron entries (added via terminal) show up in the UI as "cronjob" — you can give them a friendly name, edit their schedule/command, run them, or delete them. Names are stored separately; editing the schedule or command rewrites that crontab line in place
- Disabling a job removes it from the crontab; enabling adds it back
- Jobs run via cron even if cmdloop isn't open

Job metadata (names, last run times) is stored in `~/.config/cmd-loop/config.json`. Each run writes its own log file under `~/.config/cmd-loop/logs/<job-uuid>/`, so run history works even when the app is closed. By default runs older than 10 days are deleted; in Settings you can instead keep a fixed number of runs per job.

Commands run in a login shell (`$SHELL -l -c`) so your PATH and environment are available.

## Install

```bash
brew tap gauthierkk/tap
brew install cmdloop
```

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
```

## Usage

Click the **⏲** icon in your menu bar to open the popover.

Each job row shows a toggle, a status dot, the job name, its cron schedule, and the last run time. The status dot pulses green while a run is in progress, turns solid green after a clean exit, red after a failure, and stays dark until the job's first run.

Per-job actions:

- **Toggle** — enable/disable a job (adds/removes it from crontab)
- **▶ Run now** — execute immediately in the background; the result lands in run history
- **☰ Logs** — run count, last run time, and each run's output; expand to browse previous runs (10 per page)
- **✎ Edit / ✕ Delete** — modify or remove a job (editing an external entry rewrites its crontab line directly and preserves its history)

Footer:

- **⚙ Settings** — start at login, log retention (number of runs per job; default keeps 10 days), and Clear Logs
- **+** — add a command: name, cron expression (e.g. `0 8 * * *`), and shell command (multi-line allowed)
- **⏻** — quit cmdloop (scheduled jobs keep running via cron)

## CLI

```bash
cmdloop            # launch the menu bar app in the background
cmdloop --version  # print the version
cmdloop --help     # usage
```

## Requirements

- macOS 13+
- Swift 5.9+
