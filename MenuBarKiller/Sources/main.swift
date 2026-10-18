import Foundation
import CoreGraphics

// MARK: - SkyLight Private API Declarations (loaded via dlsym)

nonisolated(unsafe) private let skylight: UnsafeMutableRawPointer = {
    guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else {
        fatalError("Failed to load SkyLight framework")
    }
    return handle
}()

private typealias SLSMainConnectionIDFunc = @convention(c) () -> Int32
private typealias SLSSetMenuBarVisibilityOverrideFunc = @convention(c) (Int32, UInt32, Bool) -> Int32
private typealias SLSSetMenuBarAutohideEnabledFunc = @convention(c) (Int32, Bool) -> Int32
private typealias SLSSetMenuBarSystemOverrideAlphaFunc = @convention(c) (Int32, Float) -> Int32
private typealias SLSGetMenuBarVisibilityOverrideFunc = @convention(c) (Int32, UInt32) -> Bool

private func loadSymbol<T>(_ name: String) -> T {
    guard let sym = dlsym(skylight, name) else {
        fatalError("Failed to find symbol: \(name)")
    }
    return unsafeBitCast(sym, to: T.self)
}

nonisolated(unsafe) private let SLSMainConnectionID: SLSMainConnectionIDFunc = loadSymbol("SLSMainConnectionID")
nonisolated(unsafe) private let SLSSetMenuBarVisibilityOverrideOnDisplay: SLSSetMenuBarVisibilityOverrideFunc = loadSymbol("SLSSetMenuBarVisibilityOverrideOnDisplay")
nonisolated(unsafe) private let SLSSetMenuBarAutohideEnabled: SLSSetMenuBarAutohideEnabledFunc = loadSymbol("SLSSetMenuBarAutohideEnabled")
nonisolated(unsafe) private let SLSSetMenuBarSystemOverrideAlpha: SLSSetMenuBarSystemOverrideAlphaFunc = loadSymbol("SLSSetMenuBarSystemOverrideAlpha")
nonisolated(unsafe) private let SLSGetMenuBarVisibilityOverrideOnDisplay: SLSGetMenuBarVisibilityOverrideFunc = loadSymbol("SLSGetMenuBarVisibilityOverrideOnDisplay")

// MARK: - Commands

enum Command: String {
    case hide
    case show
    case status
    case install
    case uninstall
    case daemon
}

func hideMenuBar() {
    let cid = SLSMainConnectionID()
    let display = CGMainDisplayID()

    // Layer 1: Visibility override — tells WindowServer to not render the bar
    let r1 = SLSSetMenuBarVisibilityOverrideOnDisplay(cid, display, false)

    // Layer 2: Autohide — ensures the bar is in autohide mode
    let r2 = SLSSetMenuBarAutohideEnabled(cid, true)

    // Layer 3: Alpha override — makes it fully transparent even if something shows it
    let r3 = SLSSetMenuBarSystemOverrideAlpha(cid, 0.0)

    let overridden = SLSGetMenuBarVisibilityOverrideOnDisplay(cid, display)
    print("Menu bar hidden (visibility=\(r1), autohide=\(r2), alpha=\(r3), override_active=\(overridden))")
}

func showMenuBar() {
    let cid = SLSMainConnectionID()
    let display = CGMainDisplayID()

    // Reverse all three layers
    let r1 = SLSSetMenuBarVisibilityOverrideOnDisplay(cid, display, true)
    let r2 = SLSSetMenuBarAutohideEnabled(cid, false)
    let r3 = SLSSetMenuBarSystemOverrideAlpha(cid, 1.0)

    print("Menu bar restored (visibility=\(r1), autohide=\(r2), alpha=\(r3))")
}

func printStatus() {
    let cid = SLSMainConnectionID()
    let display = CGMainDisplayID()
    let overridden = SLSGetMenuBarVisibilityOverrideOnDisplay(cid, display)
    print("Menu bar visibility override active: \(overridden)")
}

func runDaemon() {
    // Hide immediately
    hideMenuBar()

    // Re-apply every 5 seconds to counteract anything that tries to show it
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 5, repeating: 5.0)
    timer.setEventHandler {
        let cid = SLSMainConnectionID()
        let display = CGMainDisplayID()
        _ = SLSSetMenuBarVisibilityOverrideOnDisplay(cid, display, false)
        _ = SLSSetMenuBarSystemOverrideAlpha(cid, 0.0)
    }
    timer.resume()

    // Keep alive
    dispatchMain()
}

let launchAgentLabel = "com.saturno.menubarkiller"
let launchAgentPath = ("~/Library/LaunchAgents/\(launchAgentLabel).plist" as NSString).expandingTildeInPath

func installLaunchAgent() {
    let executablePath = CommandLine.arguments[0]
    let resolvedPath = URL(fileURLWithPath: executablePath).standardizedFileURL.path

    let plist: [String: Any] = [
        "Label": launchAgentLabel,
        "ProgramArguments": [resolvedPath, "daemon"],
        "RunAtLoad": true,
        "KeepAlive": true,
        "StandardOutPath": "/tmp/menubarkiller.log",
        "StandardErrorPath": "/tmp/menubarkiller.err"
    ]

    let dir = (launchAgentPath as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

    let data = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try! data.write(to: URL(fileURLWithPath: launchAgentPath))

    print("LaunchAgent installed at \(launchAgentPath)")
    print("Loading agent...")

    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    task.arguments = ["load", "-w", launchAgentPath]
    try? task.run()
    task.waitUntilExit()
    print("Agent loaded. Menu bar will be hidden on every login.")
}

func uninstallLaunchAgent() {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    task.arguments = ["unload", launchAgentPath]
    try? task.run()
    task.waitUntilExit()

    try? FileManager.default.removeItem(atPath: launchAgentPath)
    print("LaunchAgent uninstalled.")

    // Restore menu bar
    showMenuBar()
}

// MARK: - Main

let args = CommandLine.arguments
let command = args.count > 1 ? Command(rawValue: args[1]) : nil

switch command {
case .hide:
    hideMenuBar()
case .show:
    showMenuBar()
case .status:
    printStatus()
case .install:
    installLaunchAgent()
case .daemon:
    runDaemon()
case .uninstall:
    uninstallLaunchAgent()
case nil:
    print("""
    MenuBarKiller - Permanently hide the macOS menu bar via SkyLight private APIs

    Usage:
      menubarkiller hide       Hide the menu bar immediately
      menubarkiller show       Restore the menu bar
      menubarkiller status     Check current override status
      menubarkiller install    Install as LaunchAgent (persistent across reboots)
      menubarkiller uninstall  Remove LaunchAgent and restore menu bar
      menubarkiller daemon     Run in daemon mode (used by LaunchAgent)
    """)
}

