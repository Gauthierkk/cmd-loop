import AppKit
import Foundation

let cmdloopVersion = "1.4.0"

// Handle informational CLI flags before any GUI/daemon work.
let cliArgs = CommandLine.arguments
if cliArgs.contains("--version") || cliArgs.contains("-v") {
    print("cmdloop \(cmdloopVersion)")
    exit(0)
}
if cliArgs.contains("--help") || cliArgs.contains("-h") {
    print("""
    cmdloop \(cmdloopVersion) — a minimal macOS menu bar cron manager

    Usage: cmdloop [options]

    Options:
      -v, --version   Print the version and exit
      -h, --help      Show this help and exit
          --daemon    Run in the foreground as the menu bar app (used internally;
                      cmdloop relaunches itself with this flag)

    Run with no options to launch the menu bar app in the background.
    """)
    exit(0)
}

// If launched without --daemon, re-launch as a detached background process and exit
if !CommandLine.arguments.contains("--daemon") {
    let execPath = ProcessInfo.processInfo.arguments[0]
    let process = Process()
    process.executableURL = URL(fileURLWithPath: execPath)
    process.arguments = ["--daemon"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
    print("cmdloop is running in the menu bar.")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)

// Minimal main menu so Cmd+C/V/X/A work in text fields
let mainMenu = NSMenu()
let editMenuItem = NSMenuItem()
editMenuItem.submenu = {
    let menu = NSMenu(title: "Edit")
    menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    return menu
}()
mainMenu.addItem(editMenuItem)
app.mainMenu = mainMenu

app.run()
