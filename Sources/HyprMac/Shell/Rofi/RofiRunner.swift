import Cocoa

/// Entry point for running the native Rofi application launcher
@MainActor
public func runRofiLauncher(args: [String] = []) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let query = args.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    let initialQuery = query.isEmpty ? nil : query

    let window = RofiWindow(initialQuery: initialQuery)

    // Setup graceful exit handler
    window.onClose = {
        app.stop(nil)
        let dummy = NSEvent.otherEvent(
            with: .applicationDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 0,
            data1: 0,
            data2: 0
        )
        if let dummy = dummy {
            app.postEvent(dummy, atStart: true)
        }
        exit(0)
    }

    // Signal handlers for clean interruption
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)

    let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigintSource.setEventHandler {
        window.dismiss()
        exit(0)
    }
    sigintSource.resume()

    let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    sigtermSource.setEventHandler {
        window.dismiss()
        exit(0)
    }
    sigtermSource.resume()

    window.showLauncher()
    app.run()
}
