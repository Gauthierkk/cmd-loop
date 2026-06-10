# cmdloop

A minimal macOS menu bar app for managing cron jobs. No dock icon, no window — just a popover from the menu bar.

## How it works

**Your system crontab is the single source of truth.** cmdloop is a GUI frontend for `crontab -l` / `crontab -`. It reads, writes, and displays entries directly from your crontab.

- Jobs created in cmdloop are tagged with a comment marker (`# cmdloop:<uuid>`) so the app can track them
- External cron entries (added via terminal) show up in the UI as "cronjob" — you can give them a friendly name, run them, or delete them. The name is stored without modifying your crontab line
- Disabling a job removes it from the crontab; enabling adds it back
- Jobs run via cron even if cmdloop isn't open

Job metadata (names, last run times) is stored in `~/.config/cmd-loop/config.json`. Logs go to `~/.config/cmd-loop/logs/`.

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

- **+ Add Command** — enter a name, cron expression (e.g. `0 8 * * *`), and shell command
- **Toggle** — enable/disable a job (adds/removes it from crontab)
- **Run now** — execute immediately and stream output in the app
- **Edit / Delete** — modify or remove a job (for external entries, only the name is editable)
- **Clear Logs** — delete all log files
- **⚙ Settings** — toggle **Start at login** to launch cmdloop automatically on boot

## Requirements

- macOS 13+
- Swift 5.9+
