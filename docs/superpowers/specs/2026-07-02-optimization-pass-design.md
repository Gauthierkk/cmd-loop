# Optimization Pass — Design

**Date:** 2026-07-02
**Goal:** Behavior-preserving performance and code-quality pass, plus one small UI fix.

## Performance fixes

1. **Launchd sync diffing** — `LaunchDManager.writeAndLoad` skips the
   `bootout` + `bootstrap` round-trip (two synchronous process spawns) when the
   on-disk plist already matches the generated content. `unloadAndRemove` skips
   launchctl when no plist exists. Today every save/toggle of *any* job
   re-bootstraps every enabled launchd job.
2. **Startup off the main thread** — `applicationDidFinishLaunching` moves
   config load + scheduler reconcile + log prune to a utility queue. None of it
   touches UI or main-thread-only state.
3. **Popover view preload** — the popover's view is built at launch instead of
   lazily on first click, so the first open doesn't pay for UI construction
   plus the `crontab -l` read.
4. **One-time legacy log migration** — the legacy-log scan moves out of
   `RunLogStore.ensureDirectory` (today it re-scans the logs root once per job
   per sync) into a single `migrateLegacyLogs(for:)` pass at startup.
5. **Single enrichment pass** — the `latestRunDate` enrichment loop runs only
   in `SchedulerManager.loadAllJobs`; the duplicate in
   `CrontabManager.loadAllJobs` is removed.
6. **Cached formatters** — one shared `RelativeDateTimeFormatter` instead of a
   new instance per row / per call.

## UI fix

The ☰ (detail) button stays highlighted when the user jumps from the detail
panel straight to Settings or the add/edit form. Fix: a `hideLogsPanel()`
helper that hides the panel, clears `logsJob`, and rebuilds the job list; used
by `showSettings`, `showAddForm`, `showEditForm`, and the detail-close path.
The ☰ is highlighted only while that job's detail panel is visible.

## Code-quality restructuring (pure moves, no logic changes)

- Split `CronJob.swift` (710 lines, 7 types) into: `CronJob.swift` (model +
  display text), `CronParser.swift`, `ConfigManager.swift` (+
  `ExternalNameStore`), `CrontabManager.swift`.
- Split `PopoverViewController.swift` (961 lines) into the core controller
  plus `+Form`, `+Settings`, `+Logs` extension files, each owning its panel's
  construction and actions. Members lose `private` where cross-file access
  requires it.
- Dedupe: one `singleLineCommand` helper replaces the two copies of multi-line
  command flattening; one line-walking helper replaces the near-identical
  bodies of `removeExternalEntry` / `updateExternalEntry`.

## Homebrew: prebuilt binary distribution

`brew install cmdloop` used to download the source tarball and run
`swift build -c release` on the user's machine (slow; requires a Swift
toolchain). The release workflow now:

1. Checks out the release tag and builds a universal binary — each arch via
   `swift build --triple`, merged with `lipo` (works with command-line tools
   alone; the combined `--arch arm64 --arch x86_64` form needs Xcode).
2. Packages `cmdloop` + `com.cmdloop.plist` + `LICENSE` into
   `cmdloop-<version>-macos-universal.tar.gz` and uploads it to the GitHub
   release (needs `permissions: contents: write`).
3. Regenerates `Formula/cmdloop.rb` in the tap wholesale — `def install` is
   now just `bin.install` + `prefix.install`, no compile — so the workflow is
   the single source of truth for the formula.

Takes effect on the next release publish (or a manual `workflow_dispatch`
run, which rebuilds the latest release's asset and formula).

## Verification

`swift build` after each step (no Xcode locally, so no `swift test`). Manual
behavior check via the running app where practical.
