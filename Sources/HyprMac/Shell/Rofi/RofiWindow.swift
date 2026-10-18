import Cocoa

/// Launcher mode enumeration
public enum RofiMode: String, CaseIterable, Sendable {
    case apps = "APPS"
    case run = "RUN"
}

/// Mode Switcher Pill Button (APPS / RUN)
@MainActor
public final class RofiModeButton: NSView {
    public let mode: RofiMode
    public var isActive: Bool {
        didSet { updateAppearance() }
    }
    public var onClick: ((RofiMode) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?

    public init(mode: RofiMode, isActive: Bool = false) {
        self.mode = mode
        self.isActive = isActive
        super.init(frame: NSRect(x: 0, y: 0, width: 120, height: 38))
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 19.0
        layer?.masksToBounds = true

        titleLabel.stringValue = mode.rawValue
        titleLabel.isBezeled = false
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        titleLabel.drawsBackground = false
        titleLabel.alignment = .center
        addSubview(titleLabel)

        updateAppearance()
    }

    public override func layout() {
        super.layout()
        let labelHeight: CGFloat = 18.0
        let labelY = (bounds.height - labelHeight) / 2.0
        titleLabel.frame = NSRect(x: 0, y: labelY, width: bounds.width, height: labelHeight)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    public override func mouseDown(with event: NSEvent) {
        onClick?(mode)
    }

    private func updateAppearance() {
        if isActive {
            // Active state: solid white background (#FFFFFF), bold dark text (#121212)
            layer?.backgroundColor = NSColor.white.cgColor
            titleLabel.textColor = NSColor(hexString: "#121212")
            titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        } else {
            // Inactive state: dark translucent background (rgba(25, 25, 25, 0.75)), white text (#E0E0E0)
            layer?.backgroundColor = NSColor(red: 25.0 / 255.0, green: 25.0 / 255.0, blue: 25.0 / 255.0, alpha: 0.75).cgColor
            titleLabel.textColor = NSColor(hexString: "#E0E0E0")
            titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        }
    }
}

/// Pill search input bar (inputbar): height 42px, corner radius 21px, background rgba(20, 20, 20, 0.75)
@MainActor
public final class RofiInputBarView: NSView {
    public let searchField = NSTextField()
    private let searchIconImageView = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 21.0
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(red: 20.0 / 255.0, green: 20.0 / 255.0, blue: 20.0 / 255.0, alpha: 0.75).cgColor
        layer?.borderWidth = 1.0
        layer?.borderColor = NSColor(white: 1.0, alpha: 0.1).cgColor

        if let sfImg = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search") {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            searchIconImageView.image = sfImg.withSymbolConfiguration(config)
            searchIconImageView.contentTintColor = NSColor.white.withAlphaComponent(0.6)
        }
        searchIconImageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(searchIconImageView)

        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        searchField.textColor = .white
        searchField.placeholderAttributedString = NSAttributedString(
            string: "Search",
            attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.5),
                .font: NSFont.systemFont(ofSize: 14, weight: .regular)
            ]
        )
        addSubview(searchField)
    }

    public override func layout() {
        super.layout()
        let iconSize: CGFloat = 16.0
        let iconY = (bounds.height - iconSize) / 2.0
        searchIconImageView.frame = NSRect(x: 16.0, y: iconY, width: iconSize, height: iconSize)

        let fieldX = searchIconImageView.frame.maxX + 10.0
        let fieldWidth = max(0, bounds.width - fieldX - 16.0)
        let fieldHeight: CGFloat = 22.0
        let fieldY = (bounds.height - fieldHeight) / 2.0
        searchField.frame = NSRect(x: fieldX, y: fieldY, width: fieldWidth, height: fieldHeight)
    }
}

/// Left Column: imagebox (card container with wallpaper background, search input bar, and mode switcher)
@MainActor
public final class RofiImageBoxView: NSView {
    public let wallpaperImageView = NSImageView()
    private let wallpaperTintView = NSView()
    public let inputBarView = RofiInputBarView()
    private let modeSwitcherView = NSView()
    private let appsButton = RofiModeButton(mode: .apps, isActive: true)
    private let runButton = RofiModeButton(mode: .run, isActive: false)

    public var onModeChanged: ((RofiMode) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 14.0
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(hexString: "#191614").withAlphaComponent(0.85).cgColor

        wallpaperImageView.wantsLayer = true
        wallpaperImageView.imageScaling = .scaleAxesIndependently
        addSubview(wallpaperImageView)

        wallpaperTintView.wantsLayer = true
        wallpaperTintView.layer?.backgroundColor = NSColor(white: 0.0, alpha: 0.3).cgColor
        addSubview(wallpaperTintView)

        addSubview(inputBarView)

        modeSwitcherView.wantsLayer = true
        modeSwitcherView.addSubview(appsButton)
        modeSwitcherView.addSubview(runButton)
        addSubview(modeSwitcherView)

        appsButton.onClick = { [weak self] mode in
            self?.setMode(mode)
            self?.onModeChanged?(mode)
        }
        runButton.onClick = { [weak self] mode in
            self?.setMode(mode)
            self?.onModeChanged?(mode)
        }
    }

    public func setMode(_ mode: RofiMode) {
        appsButton.isActive = (mode == .apps)
        runButton.isActive = (mode == .run)
    }

    public func updateWallpaper(image: NSImage?) {
        wallpaperImageView.image = image
        let hasImage = (image != nil)
        wallpaperImageView.isHidden = !hasImage
        wallpaperTintView.isHidden = !hasImage
    }

    public override func layout() {
        super.layout()
        wallpaperImageView.frame = bounds
        wallpaperTintView.frame = bounds

        let inputPadding: CGFloat = 12.0
        let inputHeight: CGFloat = 42.0
        let inputY = bounds.height - inputPadding - inputHeight
        inputBarView.frame = NSRect(
            x: inputPadding,
            y: inputY,
            width: max(0, bounds.width - (inputPadding * 2.0)),
            height: inputHeight
        )

        let switcherHeight: CGFloat = 38.0
        let switcherY: CGFloat = 12.0
        modeSwitcherView.frame = NSRect(
            x: 0,
            y: switcherY,
            width: bounds.width,
            height: switcherHeight
        )

        let btnWidth: CGFloat = 120.0
        let btnSpacing: CGFloat = 12.0
        let totalBtnWidth = (btnWidth * 2.0) + btnSpacing
        let startX = max(0, (bounds.width - totalBtnWidth) / 2.0)

        appsButton.frame = NSRect(x: startX, y: 0, width: btnWidth, height: switcherHeight)
        runButton.frame = NSRect(x: startX + btnWidth + btnSpacing, y: 0, width: btnWidth, height: switcherHeight)
    }
}

/// Item Row View for application launcher listbox
@MainActor
public final class RofiItemRowView: NSView {
    public let rowIndex: Int
    public let result: RofiSearchResult

    public var appItem: AppItem? {
        if case .app(let item) = result {
            return item
        }
        return nil
    }

    public var isSelected: Bool = false {
        didSet { updateAppearance() }
    }

    public var onHover: ((Int) -> Void)?
    public var onClick: ((Int) -> Void)?

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?

    public init(rowIndex: Int, result: RofiSearchResult) {
        self.rowIndex = rowIndex
        self.result = result
        super.init(frame: NSRect(x: 0, y: 0, width: 452, height: 44))
        setupViews()
    }

    public convenience init(rowIndex: Int, appItem: AppItem) {
        self.init(rowIndex: rowIndex, result: .app(appItem))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        wantsLayer = true
        layer?.cornerRadius = 12.0
        layer?.masksToBounds = true

        iconView.image = result.icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)

        nameLabel.stringValue = result.title
        nameLabel.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        nameLabel.isBezeled = false
        nameLabel.isEditable = false
        nameLabel.isSelectable = false
        nameLabel.drawsBackground = false
        nameLabel.lineBreakMode = .byTruncatingTail
        addSubview(nameLabel)

        if let sub = result.subtitle, !sub.isEmpty {
            subtitleLabel.stringValue = sub
            subtitleLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
            subtitleLabel.isBezeled = false
            subtitleLabel.isEditable = false
            subtitleLabel.isSelectable = false
            subtitleLabel.drawsBackground = false
            subtitleLabel.lineBreakMode = .byTruncatingTail
            subtitleLabel.isHidden = false
            addSubview(subtitleLabel)
        } else {
            subtitleLabel.isHidden = true
        }

        updateAppearance()
    }

    public override func layout() {
        super.layout()
        let iconSize: CGFloat = 30.0
        let iconY = (bounds.height - iconSize) / 2.0
        iconView.frame = NSRect(x: 12.0, y: iconY, width: iconSize, height: iconSize)

        let labelX = iconView.frame.maxX + 12.0
        let labelWidth = max(0, bounds.width - labelX - 12.0)
        if let sub = result.subtitle, !sub.isEmpty {
            let titleHeight: CGFloat = 18.0
            let subtitleHeight: CGFloat = 14.0
            nameLabel.frame = NSRect(x: labelX, y: bounds.height - 23.0, width: labelWidth, height: titleHeight)
            subtitleLabel.frame = NSRect(x: labelX, y: 5.0, width: labelWidth, height: subtitleHeight)
        } else {
            let labelHeight: CGFloat = 20.0
            let labelY = (bounds.height - labelHeight) / 2.0
            nameLabel.frame = NSRect(x: labelX, y: labelY, width: labelWidth, height: labelHeight)
        }
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    public override func mouseEntered(with event: NSEvent) {
        onHover?(rowIndex)
    }

    public override func mouseMoved(with event: NSEvent) {
        onHover?(rowIndex)
    }

    public override func mouseDown(with event: NSEvent) {
        onClick?(rowIndex)
    }

    private func updateAppearance() {
        if isSelected {
            // Selected state: Solid off-white / light cream pill (#E6EBF2), Dark charcoal text (#181825), Semibold
            layer?.backgroundColor = NSColor(hexString: "#E6EBF2").cgColor
            nameLabel.textColor = NSColor(hexString: "#181825")
            nameLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
            subtitleLabel.textColor = NSColor(hexString: "#484848")
            if result.isSystemOrUtility {
                iconView.contentTintColor = NSColor(hexString: "#181825")
            } else {
                iconView.contentTintColor = nil
            }
        } else {
            // Unselected state: Dark subtle translucent pill (rgba(255, 255, 255, 0.05)), Light gray text (#D9E0EE), Regular
            layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.05).cgColor
            nameLabel.textColor = NSColor(hexString: "#D9E0EE")
            nameLabel.font = NSFont.systemFont(ofSize: 14, weight: .regular)
            subtitleLabel.textColor = NSColor.white.withAlphaComponent(0.45)
            if result.isSystemOrUtility {
                iconView.contentTintColor = HyprTheme.shared.primary
            } else {
                iconView.contentTintColor = nil
            }
        }
    }
}

/// Right Column: listbox (vertical stack of 8 items)
@MainActor
public final class RofiListBoxView: NSView {
    public let emptyLabel = NSTextField(labelWithString: "No matching applications")
    public private(set) var rowViews: [RofiItemRowView] = []

    public var onSelectionChanged: ((Int) -> Void)?
    public var onItemChosen: ((Int) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true
        emptyLabel.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        emptyLabel.textColor = NSColor.white.withAlphaComponent(0.5)
        emptyLabel.alignment = .center
        emptyLabel.isBezeled = false
        emptyLabel.isEditable = false
        emptyLabel.isSelectable = false
        emptyLabel.drawsBackground = false
        emptyLabel.isHidden = true
        addSubview(emptyLabel)
    }

    public func updateRows(results: [RofiSearchResult], selectedIndex: Int) {
        for row in rowViews {
            row.removeFromSuperview()
        }
        rowViews.removeAll()

        let count = min(results.count, 8)
        let hasItems = count > 0
        emptyLabel.isHidden = hasItems

        if !hasItems {
            emptyLabel.frame = bounds
            return
        }

        let topPadding: CGFloat = 14.0
        let rowHeight: CGFloat = 44.0
        let rowSpacing: CGFloat = 5.0

        for i in 0..<count {
            let item = results[i]
            let row = RofiItemRowView(rowIndex: i, result: item)
            row.isSelected = (i == selectedIndex)
            row.onHover = { [weak self] idx in
                self?.onSelectionChanged?(idx)
            }
            row.onClick = { [weak self] idx in
                self?.onItemChosen?(idx)
            }

            let y = bounds.height - topPadding - CGFloat(i + 1) * rowHeight - CGFloat(i) * rowSpacing
            row.frame = NSRect(x: 0, y: y, width: bounds.width, height: rowHeight)
            addSubview(row)
            rowViews.append(row)
        }
    }

    public func updateRows(apps: [AppItem], selectedIndex: Int) {
        updateRows(results: apps.map { .app($0) }, selectedIndex: selectedIndex)
    }

    public func setSelectedRowIndex(_ index: Int) {
        for (i, row) in rowViews.enumerated() {
            row.isSelected = (i == index)
        }
    }
}

/// Native macOS Rofi Application Launcher Window with 2-Column Split Layout
@MainActor
public final class RofiWindow: NSPanel, NSTextFieldDelegate {
    public static weak var current: RofiWindow?

    public var onClose: (() -> Void)?

    public static let defaultWidth: CGFloat = 900.0
    public static let defaultHeight: CGFloat = 440.0
    public static let defaultOuterPadding: CGFloat = 12.0
    public static let defaultImageBoxWidth: CGFloat = 410.0
    public static let defaultColumnSpacing: CGFloat = 14.0
    public static let maxVisibleItems: Int = 8

    private var allApps: [AppItem] = []
    public private(set) var filteredResults: [RofiSearchResult] = []

    public var filteredApps: [AppItem] {
        filteredResults.compactMap {
            if case .app(let a) = $0 { return a }
            return nil
        }
    }
    public private(set) var selectedIndex: Int = 0
    public private(set) var currentMode: RofiMode = .apps

    public let effectView = NSVisualEffectView()
    public let darkOverlayView = NSView()
    public let imageBoxView = RofiImageBoxView()
    public let listBoxView = RofiListBoxView()

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { true }

    public var searchField: NSTextField {
        imageBoxView.inputBarView.searchField
    }

    public init(initialQuery: String? = nil) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.defaultWidth, height: Self.defaultHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        Self.current = self
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        setupHierarchy()

        allApps = AppScanner.shared.scan()
        let query = initialQuery ?? ""
        searchField.stringValue = query
        searchField.delegate = self

        refreshWallpaper()
        applyFilter(query: query)
        centerOnActiveScreen()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: self
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setupHierarchy() {
        guard let contentView = contentView else { return }
        contentView.wantsLayer = true

        // NSVisualEffectView: behindWindow + hudWindow + darkAqua
        effectView.blendingMode = .behindWindow
        effectView.material = .hudWindow
        effectView.state = .active
        effectView.appearance = NSAppearance(named: .darkAqua)
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 16.0
        effectView.layer?.masksToBounds = true
        effectView.layer?.borderWidth = 1.0
        effectView.layer?.borderColor = NSColor(white: 1.0, alpha: 0.12).cgColor
        effectView.frame = contentView.bounds
        contentView.addSubview(effectView)

        // Dark Tint Overlay
        darkOverlayView.wantsLayer = true
        darkOverlayView.layer?.cornerRadius = 16.0
        darkOverlayView.layer?.masksToBounds = true
        darkOverlayView.layer?.backgroundColor = NSColor(hexString: "#121212").withAlphaComponent(0.85).cgColor
        darkOverlayView.frame = effectView.bounds
        effectView.addSubview(darkOverlayView)

        // Two-column layout calculation
        let contentHeight = Self.defaultHeight - (Self.defaultOuterPadding * 2.0) // 416
        let listboxWidth = Self.defaultWidth - (Self.defaultOuterPadding * 2.0) - Self.defaultImageBoxWidth - Self.defaultColumnSpacing // 452

        imageBoxView.frame = NSRect(
            x: Self.defaultOuterPadding,
            y: Self.defaultOuterPadding,
            width: Self.defaultImageBoxWidth,
            height: contentHeight
        )
        darkOverlayView.addSubview(imageBoxView)

        listBoxView.frame = NSRect(
            x: Self.defaultOuterPadding + Self.defaultImageBoxWidth + Self.defaultColumnSpacing,
            y: Self.defaultOuterPadding,
            width: listboxWidth,
            height: contentHeight
        )
        darkOverlayView.addSubview(listBoxView)

        listBoxView.onSelectionChanged = { [weak self] idx in
            self?.setSelectedIndex(idx)
        }
        listBoxView.onItemChosen = { [weak self] idx in
            self?.launchItem(at: idx)
        }

        imageBoxView.onModeChanged = { [weak self] mode in
            self?.setMode(mode)
        }
    }

    public func refreshWallpaper() {
        let img = loadWallpaperImage()
        imageBoxView.updateWallpaper(image: img)
    }

    public func loadWallpaperImage() -> NSImage? {
        // 1. Read path string from ~/.cache/current_wallpaper
        let cachePath = NSString(string: "~/.cache/current_wallpaper").expandingTildeInPath
        if FileManager.default.fileExists(atPath: cachePath),
           let raw = try? String(contentsOfFile: cachePath, encoding: .utf8) {
            let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty && FileManager.default.fileExists(atPath: path),
               let img = NSImage(contentsOfFile: path) {
                return img
            }
        }

        // 2. Query the active screen's macOS wallpaper
        let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first
        if let scr = targetScreen,
           let url = NSWorkspace.shared.desktopImageURL(for: scr),
           FileManager.default.fileExists(atPath: url.path),
           let img = NSImage(contentsOf: url) {
            return img
        }

        // 3. Fallback: return nil (clean dark translucent gradient/surface with NO image)
        return nil
    }

    private func centerOnActiveScreen() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let targetScreen = screen else { return }

        let screenFrame = targetScreen.frame
        let winFrame = frame
        let x = screenFrame.origin.x + (screenFrame.width - winFrame.width) / 2.0
        let y = screenFrame.origin.y + (screenFrame.height - winFrame.height) / 2.0
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    public func showLauncher() {
        refreshWallpaper()
        centerOnActiveScreen()
        makeKeyAndOrderFront(nil)
        makeFirstResponder(searchField)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func dismiss() {
        orderOut(nil)
        onClose?()
    }

    @objc private func handleDidResignKey() {
        dismiss()
    }

    public func setMode(_ mode: RofiMode) {
        guard currentMode != mode else { return }
        currentMode = mode
        imageBoxView.setMode(mode)
        applyFilter(query: searchField.stringValue)
    }

    private func applyFilter(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        switch currentMode {
        case .apps:
            var results: [RofiSearchResult] = []

            // 1. Calculator Provider
            if let calcResult = MathEvaluator.evaluate(trimmed) {
                results.append(.calculator(result: calcResult, expression: trimmed))
            }

            if trimmed.isEmpty {
                results.append(contentsOf: allApps.map { .app($0) })
            } else {
                // 2. System Commands Provider
                let sysCmds = SystemCommandProvider.match(query: trimmed)

                // 3. Apps Provider
                let matchedApps = FuzzyMatcher.match(query: trimmed, candidates: allApps, extractTarget: { $0.name })

                var scoredItems: [(item: RofiSearchResult, score: Int)] = []
                for cmd in sysCmds {
                    var s = FuzzyMatcher.score(query: trimmed, target: cmd.title) ?? 30_000
                    let cmdId = cmd.id.hasPrefix("sys:") ? String(cmd.id.dropFirst(4)) : cmd.id
                    for sc in SystemCommandProvider.commands where sc.id == cmdId {
                        for kw in sc.keywords {
                            if kw.lowercased() == trimmed.lowercased() {
                                s = max(s, 95_000)
                            } else if kw.lowercased().hasPrefix(trimmed.lowercased()) {
                                s = max(s, 48_000)
                            }
                        }
                    }
                    scoredItems.append((cmd, s))
                }
                for app in matchedApps {
                    let s = FuzzyMatcher.score(query: trimmed, target: app.name) ?? 0
                    scoredItems.append((.app(app), s))
                }
                scoredItems.sort { $0.score > $1.score }

                results.append(contentsOf: scoredItems.map { $0.item })
            }

            filteredResults = results

        case .run:
            let binaries = PathBinaryScanner.shared.scan()
            if trimmed.isEmpty {
                filteredResults = binaries.map { .runBinary(name: $0.name, path: $0.path) }
            } else {
                let matched = FuzzyMatcher.match(query: trimmed, candidates: binaries, extractTarget: { $0.name })
                filteredResults = matched.map { .runBinary(name: $0.name, path: $0.path) }
            }
        }

        selectedIndex = 0
        rebuildList()
    }

    private func rebuildList() {
        listBoxView.updateRows(results: filteredResults, selectedIndex: selectedIndex)
    }

    public func setSelectedIndex(_ index: Int) {
        let count = min(filteredResults.count, Self.maxVisibleItems)
        guard count > 0 else { return }

        var next = index
        if next < 0 {
            next = count - 1
        } else if next >= count {
            next = 0
        }

        selectedIndex = next
        listBoxView.setSelectedRowIndex(selectedIndex)
    }

    public func launchItem(at index: Int) {
        guard index >= 0 && index < filteredResults.count else { return }
        let item = filteredResults[index]
        switch item {
        case .app(let appItem):
            launchApp(appItem)
        case .calculator(let result, _):
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(result, forType: .string)
            dismiss()
        case .systemCommand(_, _, _, _, let action):
            action()
            dismiss()
        case .runBinary(_, let path):
            launchBinary(path: path)
            dismiss()
        }
    }

    private func launchBinary(path: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        do {
            try task.run()
        } catch {
            let script = "tell application \"Terminal\" to do script \"\(path)\""
            _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/osascript"), arguments: ["-e", script])
        }
    }

    private func launchApp(_ item: AppItem) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: item.bundleURL, configuration: config) { _, error in
            if let error = error {
                print("[-] Failed to launch " + item.name + ": " + error.localizedDescription)
            }
        }
        dismiss()
    }

    // MARK: - NSTextFieldDelegate & Key Commands

    public func controlTextDidChange(_ obj: Notification) {
        applyFilter(query: searchField.stringValue)
    }

    public func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            setSelectedIndex(selectedIndex + 1)
            return true
        } else if commandSelector == #selector(NSResponder.moveUp(_:)) {
            setSelectedIndex(selectedIndex - 1)
            return true
        } else if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            launchItem(at: selectedIndex)
            return true
        } else if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            dismiss()
            return true
        }
        return false
    }

    public override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape
            dismiss()
        case 125: // Down arrow
            setSelectedIndex(selectedIndex + 1)
        case 126: // Up arrow
            setSelectedIndex(selectedIndex - 1)
        case 36: // Enter / Return
            launchItem(at: selectedIndex)
        case 48: // Tab -> cycle mode APPS <-> RUN
            let nextMode: RofiMode = (currentMode == .apps) ? .run : .apps
            setMode(nextMode)
        default:
            super.keyDown(with: event)
        }
    }
}
