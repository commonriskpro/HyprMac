import Cocoa

@MainActor
public func runWlogoutMenu(args: [String] = []) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    var customLayoutPath: String? = nil
    var i = 0
    while i < args.count {
        let arg = args[i]
        if (arg == "-l" || arg == "--layout") && i + 1 < args.count {
            customLayoutPath = args[i + 1]
            i += 2
        } else {
            i += 1
        }
    }

    let loader = WlogoutLayoutLoader()
    let items = loader.loadItems(fromPath: customLayoutPath)

    let window = WlogoutWindow(items: items)
    window.onDismiss = {
        window.close()
        exit(0)
    }
    window.onActionExecuted = { _ in
        window.close()
        exit(0)
    }

    window.present()
    app.activate(ignoringOtherApps: true)
    app.run()
}
