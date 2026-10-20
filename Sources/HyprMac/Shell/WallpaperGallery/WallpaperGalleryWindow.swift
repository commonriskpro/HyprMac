import Cocoa

/// Category Pill Chip for filtering wallpapers by folder or color palette
@MainActor
public final class CategoryChipButton: NSView {
    public let category: String
    public let count: Int
    public var isSelected: Bool {
        didSet { updateAppearance() }
    }
    public var onClick: ((String) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?

    public init(category: String, count: Int, isSelected: Bool = false) {
        self.category = category
        self.count = count
        self.isSelected = isSelected
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 14.0
        layer?.masksToBounds = true

        let labelText = category == "all" ? "Todos (\(count))" : "\(category.capitalized) (\(count))"
        titleLabel.stringValue = labelText
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
        titleLabel.frame = bounds
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
        onClick?(category)
    }

    public func cleanup() {
        if let existing = trackingArea {
            removeTrackingArea(existing)
            trackingArea = nil
        }
        onClick = nil
    }

    private func updateAppearance() {
        if isSelected {
            layer?.backgroundColor = NSColor.white.cgColor
            titleLabel.textColor = NSColor(hexString: "#121212")
            titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .bold)
            layer?.borderWidth = 0
        } else {
            layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.08).cgColor
            titleLabel.textColor = NSColor(hexString: "#E0E0E0")
            titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            layer?.borderWidth = 1.0
            layer?.borderColor = NSColor(white: 1.0, alpha: 0.1).cgColor
        }
    }
}

/// Individual Wallpaper Visual Thumbnail Card in the Gallery Grid
@MainActor
public final class WallpaperCardView: NSView {
    public let item: WallpaperItem
    public let index: Int
    public var isSelected: Bool = false {
        didSet { updateAppearance() }
    }

    public var onHover: ((Int) -> Void)?
    public var onClick: ((Int) -> Void)?
    public var onDoubleClick: ((Int) -> Void)?

    private let imageContainer = NSView()
    private let thumbnailImageView = NSImageView()
    private let placeholderLabel = NSTextField(labelWithString: "Loading...")
    private let captionRow = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let categoryBadge = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?
    private var thumbnailToken: ThumbnailCancellationToken?
    private var isThumbnailLoaded: Bool = false

    public init(item: WallpaperItem, index: Int) {
        self.item = item
        self.index = index
        super.init(frame: NSRect(x: 0, y: 0, width: 250, height: 172))
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        wantsLayer = true
        layer?.cornerRadius = 14.0

        // 1. Image Container (16:10 aspect thumbnail)
        imageContainer.wantsLayer = true
        imageContainer.layer?.cornerRadius = 10.0
        imageContainer.layer?.masksToBounds = true
        imageContainer.layer?.backgroundColor = NSColor(white: 0.15, alpha: 0.8).cgColor
        addSubview(imageContainer)

        placeholderLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        placeholderLabel.textColor = NSColor.white.withAlphaComponent(0.4)
        placeholderLabel.alignment = .center
        placeholderLabel.isBezeled = false
        placeholderLabel.drawsBackground = false
        placeholderLabel.isEditable = false
        placeholderLabel.isSelectable = false
        imageContainer.addSubview(placeholderLabel)

        thumbnailImageView.imageScaling = .scaleAxesIndependently
        imageContainer.addSubview(thumbnailImageView)

        // 2. Caption Row (Title & Badge)
        addSubview(captionRow)

        nameLabel.stringValue = item.name
        nameLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        nameLabel.textColor = NSColor(hexString: "#E6EBF2")
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.isBezeled = false
        nameLabel.drawsBackground = false
        nameLabel.isEditable = false
        nameLabel.isSelectable = false
        captionRow.addSubview(nameLabel)

        categoryBadge.stringValue = item.category.uppercased()
        categoryBadge.font = NSFont.systemFont(ofSize: 9, weight: .bold)
        categoryBadge.textColor = NSColor.white.withAlphaComponent(0.6)
        categoryBadge.alignment = .right
        categoryBadge.isBezeled = false
        categoryBadge.drawsBackground = false
        categoryBadge.isEditable = false
        categoryBadge.isSelectable = false
        captionRow.addSubview(categoryBadge)

        updateAppearance()
    }

    public func loadThumbnailIfNeeded() {
        guard !isThumbnailLoaded, thumbnailToken == nil else { return }
        thumbnailToken = WallpaperThumbnailLoader.shared.loadThumbnail(for: item.path, targetSize: NSSize(width: 250, height: 140)) { [weak self] img in
            guard let self = self else { return }
            self.thumbnailToken = nil
            self.isThumbnailLoaded = true
            if let img = img {
                self.thumbnailImageView.image = img
                self.placeholderLabel.isHidden = true
            } else {
                self.placeholderLabel.stringValue = "Sin vista previa"
            }
        }
    }

    public func cancelPendingThumbnail() {
        thumbnailToken?.cancel()
        thumbnailToken = nil
    }

    public func unloadThumbnail() {
        cancelPendingThumbnail()
        thumbnailImageView.image = nil
        placeholderLabel.stringValue = "Loading..."
        placeholderLabel.isHidden = false
        isThumbnailLoaded = false
    }

    public override func layout() {
        super.layout()
        let pad: CGFloat = 6.0
        let imgHeight: CGFloat = 136.0
        imageContainer.frame = NSRect(x: pad, y: bounds.height - pad - imgHeight, width: bounds.width - (pad * 2.0), height: imgHeight)
        thumbnailImageView.frame = imageContainer.bounds
        placeholderLabel.frame = imageContainer.bounds

        let captionHeight: CGFloat = 20.0
        let captionY: CGFloat = 4.0
        captionRow.frame = NSRect(x: pad + 2.0, y: captionY, width: bounds.width - (pad * 2.0) - 4.0, height: captionHeight)

        let badgeWidth: CGFloat = 65.0
        let nameWidth = max(0, captionRow.bounds.width - badgeWidth - 4.0)
        nameLabel.frame = NSRect(x: 0, y: 0, width: nameWidth, height: captionHeight)
        categoryBadge.frame = NSRect(x: captionRow.bounds.width - badgeWidth, y: 0, width: badgeWidth, height: captionHeight)
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

    public override func mouseEntered(with event: NSEvent) {
        onHover?(index)
    }

    public override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?(index)
        } else {
            onClick?(index)
        }
    }

    public func cleanup() {
        cancelPendingThumbnail()
        if let existing = trackingArea {
            removeTrackingArea(existing)
            trackingArea = nil
        }
        onHover = nil
        onClick = nil
        onDoubleClick = nil
    }

    deinit {
        thumbnailToken?.cancel()
    }

    private func updateAppearance() {
        if isSelected {
            layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.16).cgColor
            layer?.borderWidth = 2.5
            layer?.borderColor = NSColor.white.cgColor
            nameLabel.textColor = .white
            nameLabel.font = NSFont.systemFont(ofSize: 12, weight: .bold)
            categoryBadge.textColor = .white
        } else {
            layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.04).cgColor
            layer?.borderWidth = 1.0
            layer?.borderColor = NSColor(white: 1.0, alpha: 0.08).cgColor
            nameLabel.textColor = NSColor(hexString: "#D0D5DD")
            nameLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            categoryBadge.textColor = NSColor.white.withAlphaComponent(0.5)
        }
    }
}

/// Interactive Document View arranging cards in a 4-column responsive grid
@MainActor
public final class WallpaperGridView: NSView {
    public static let columns: Int = 4
    public static let cardWidth: CGFloat = 254.0
    public static let cardHeight: CGFloat = 172.0
    public static let horizontalSpacing: CGFloat = 14.0
    public static let verticalSpacing: CGFloat = 14.0
    public static let padding: CGFloat = 18.0

    public private(set) var cardViews: [WallpaperCardView] = []
    public var onSelectionChanged: ((Int) -> Void)?
    public var onApplyItem: ((Int) -> Void)?

    private weak var observedClipView: NSClipView?

    public override var isFlipped: Bool { true }

    public override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        setupScrollObservation()
    }

    public func setupScrollObservation() {
        guard let clipView = enclosingScrollView?.contentView else { return }
        clipView.postsBoundsChangedNotifications = true
        if observedClipView !== clipView {
            if let old = observedClipView {
                NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: old)
            }
            observedClipView = clipView
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleClipViewBoundsDidChange),
                name: NSView.boundsDidChangeNotification,
                object: clipView
            )
        }
    }

    @objc private func handleClipViewBoundsDidChange(_ notification: Notification) {
        updateVisibleThumbnails()
    }

    public func updateVisibleThumbnails() {
        let visibleRect = enclosingScrollView?.documentVisibleRect ?? bounds
        let bufferRect = visibleRect.insetBy(dx: 0, dy: -250)

        for card in cardViews {
            if card.frame.intersects(bufferRect) {
                card.loadThumbnailIfNeeded()
            } else {
                card.cancelPendingThumbnail()
            }
        }
    }

    public func cancelAllPendingThumbnails() {
        for card in cardViews {
            card.cancelPendingThumbnail()
        }
    }

    public func reloadGrid(items: [WallpaperItem], selectedIndex: Int) {
        setupScrollObservation()

        for card in cardViews {
            card.cleanup()
            card.removeFromSuperview()
        }
        cardViews.removeAll(keepingCapacity: true)

        let count = items.count
        let cols = Self.columns
        let rows = Int(ceil(Double(count) / Double(cols)))

        let totalWidth = (CGFloat(cols) * Self.cardWidth) + (CGFloat(cols - 1) * Self.horizontalSpacing) + (Self.padding * 2.0)
        let totalHeight = (CGFloat(rows) * Self.cardHeight) + (CGFloat(max(0, rows - 1)) * Self.verticalSpacing) + (Self.padding * 2.0)

        setFrameSize(NSSize(width: max(bounds.width, totalWidth), height: max(bounds.height, totalHeight)))

        for (i, item) in items.enumerated() {
            let col = i % cols
            let row = i / cols
            let x = Self.padding + (CGFloat(col) * (Self.cardWidth + Self.horizontalSpacing))
            let y = Self.padding + (CGFloat(row) * (Self.cardHeight + Self.verticalSpacing))

            let card = WallpaperCardView(item: item, index: i)
            card.frame = NSRect(x: x, y: y, width: Self.cardWidth, height: Self.cardHeight)
            card.isSelected = (i == selectedIndex)
            card.onHover = { [weak self] idx in
                self?.onSelectionChanged?(idx)
            }
            card.onClick = { [weak self] idx in
                self?.onSelectionChanged?(idx)
            }
            card.onDoubleClick = { [weak self] idx in
                self?.onApplyItem?(idx)
            }
            addSubview(card)
            cardViews.append(card)
        }

        updateVisibleThumbnails()
    }

    public func setSelectedCardIndex(_ index: Int) {
        for (i, card) in cardViews.enumerated() {
            card.isSelected = (i == index)
        }
        if index >= 0 && index < cardViews.count {
            scrollToCard(cardViews[index])
            updateVisibleThumbnails()
        }
    }

    private func scrollToCard(_ card: WallpaperCardView) {
        let targetRect = card.frame.insetBy(dx: -10, dy: -10)
        _ = scrollToVisible(targetRect)
    }

    public func cleanup() {
        if let clipView = observedClipView {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: clipView)
            observedClipView = nil
        }
        for card in cardViews {
            card.cleanup()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

/// Fullscreen / Large Visual Wallpaper Selector & Gallery Window
@MainActor
public final class WallpaperGalleryWindow: NSPanel, NSTextFieldDelegate {
    public static weak var current: WallpaperGalleryWindow?

    public var onClose: (() -> Void)?

    public static let defaultWidth: CGFloat = 1120.0
    public static let defaultHeight: CGFloat = 700.0

    private var allWallpapers: [WallpaperItem] = []
    private var filteredWallpapers: [WallpaperItem] = []
    private var categories: [(name: String, count: Int)] = []
    private var selectedCategory: String = "all"
    public private(set) var selectedIndex: Int = 0
    private var searchDebounceWorkItem: DispatchWorkItem?

    public let effectView = NSVisualEffectView()
    public let darkOverlayView = NSView()
    public let headerView = NSView()
    public let searchField = NSTextField()
    private let searchIconView = NSImageView()
    private let categoriesScrollView = NSScrollView()
    private let categoriesStackView = NSView()
    private var categoryButtons: [CategoryChipButton] = []

    private let gridScrollView = NSScrollView()
    public let gridView = WallpaperGridView()

    private let statusBar = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { true }

    public init(initialQuery: String? = nil, synchronousLoad: Bool? = nil) {
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
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        setupHierarchy()

        let isTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTest") != nil
        let sync = synchronousLoad ?? isTest
        if sync {
            loadDataSync()
        } else {
            loadDataAsync()
        }

        let query = initialQuery ?? ""
        searchField.stringValue = query
        searchField.delegate = self

        if sync {
            applyFilter(query: query)
        }
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

        // Background blur
        effectView.blendingMode = .behindWindow
        effectView.material = .hudWindow
        effectView.state = .active
        effectView.appearance = NSAppearance(named: .darkAqua)
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 18.0
        effectView.layer?.masksToBounds = true
        effectView.layer?.borderWidth = 1.0
        effectView.layer?.borderColor = NSColor(white: 1.0, alpha: 0.14).cgColor
        effectView.frame = contentView.bounds
        contentView.addSubview(effectView)

        // Dark overlay
        darkOverlayView.wantsLayer = true
        darkOverlayView.layer?.cornerRadius = 18.0
        darkOverlayView.layer?.masksToBounds = true
        darkOverlayView.layer?.backgroundColor = NSColor(hexString: "#111111").withAlphaComponent(0.92).cgColor
        darkOverlayView.frame = effectView.bounds
        effectView.addSubview(darkOverlayView)

        // Layout dimensions
        let winWidth = Self.defaultWidth
        let winHeight = Self.defaultHeight
        let headerHeight: CGFloat = 108.0
        let statusHeight: CGFloat = 34.0
        let gridHeight = winHeight - headerHeight - statusHeight

        // Header View
        headerView.frame = NSRect(x: 0, y: winHeight - headerHeight, width: winWidth, height: headerHeight)
        darkOverlayView.addSubview(headerView)

        // Search Field inside Header
        let searchBarHeight: CGFloat = 38.0
        let searchBarWidth: CGFloat = 460.0
        let searchBarX: CGFloat = (winWidth - searchBarWidth) / 2.0
        let searchBarY = headerHeight - searchBarHeight - 10.0

        let searchContainer = NSView(frame: NSRect(x: searchBarX, y: searchBarY, width: searchBarWidth, height: searchBarHeight))
        searchContainer.wantsLayer = true
        searchContainer.layer?.cornerRadius = 19.0
        searchContainer.layer?.masksToBounds = true
        searchContainer.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.08).cgColor
        searchContainer.layer?.borderWidth = 1.0
        searchContainer.layer?.borderColor = NSColor(white: 1.0, alpha: 0.12).cgColor
        headerView.addSubview(searchContainer)

        if let sfImg = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search") {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            searchIconView.image = sfImg.withSymbolConfiguration(config)
            searchIconView.contentTintColor = NSColor.white.withAlphaComponent(0.6)
        }
        searchIconView.frame = NSRect(x: 14.0, y: (searchBarHeight - 16.0) / 2.0, width: 16.0, height: 16.0)
        searchContainer.addSubview(searchIconView)

        searchField.frame = NSRect(x: 36.0, y: (searchBarHeight - 22.0) / 2.0, width: searchBarWidth - 50.0, height: 22.0)
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        searchField.textColor = .white
        searchField.placeholderAttributedString = NSAttributedString(
            string: "Buscar fondo o color (ej. blue, anime, makima)...",
            attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.4),
                .font: NSFont.systemFont(ofSize: 13, weight: .regular)
            ]
        )
        searchContainer.addSubview(searchField)

        // Categories Horizontal ScrollView
        let catScrollHeight: CGFloat = 32.0
        let catScrollY = searchBarY - catScrollHeight - 10.0
        categoriesScrollView.frame = NSRect(x: 20.0, y: catScrollY, width: winWidth - 40.0, height: catScrollHeight)
        categoriesScrollView.hasVerticalScroller = false
        categoriesScrollView.hasHorizontalScroller = false
        categoriesScrollView.horizontalScrollElasticity = .allowed
        categoriesScrollView.drawsBackground = false
        categoriesScrollView.documentView = categoriesStackView
        headerView.addSubview(categoriesScrollView)

        // Grid ScrollView in Middle
        gridScrollView.frame = NSRect(x: 0, y: statusHeight, width: winWidth, height: gridHeight)
        gridScrollView.hasVerticalScroller = true
        gridScrollView.hasHorizontalScroller = false
        gridScrollView.autohidesScrollers = true
        gridScrollView.drawsBackground = false
        gridScrollView.documentView = gridView
        darkOverlayView.addSubview(gridScrollView)

        gridScrollView.contentView.postsBoundsChangedNotifications = true
        gridView.setupScrollObservation()

        gridView.onSelectionChanged = { [weak self] idx in
            self?.setSelectedIndex(idx)
        }
        gridView.onApplyItem = { [weak self] idx in
            self?.applySelectedItem(at: idx)
        }

        // Status Bar at Bottom
        statusBar.frame = NSRect(x: 0, y: 0, width: winWidth, height: statusHeight)
        statusBar.wantsLayer = true
        statusBar.layer?.backgroundColor = NSColor(white: 0.0, alpha: 0.4).cgColor
        darkOverlayView.addSubview(statusBar)

        statusLabel.frame = NSRect(x: 24.0, y: (statusHeight - 16.0) / 2.0, width: 400.0, height: 16.0)
        statusLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.6)
        statusLabel.isBezeled = false
        statusLabel.drawsBackground = false
        statusBar.addSubview(statusLabel)

        hintLabel.frame = NSRect(x: winWidth - 460.0, y: (statusHeight - 16.0) / 2.0, width: 436.0, height: 16.0)
        hintLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        hintLabel.textColor = NSColor.white.withAlphaComponent(0.4)
        hintLabel.alignment = .right
        hintLabel.stringValue = "↑↓←→ Navegar • Enter Aplicar • Tab Color • Esc Salir"
        hintLabel.isBezeled = false
        hintLabel.drawsBackground = false
        statusBar.addSubview(hintLabel)
    }

    private func loadDataSync() {
        allWallpapers = WallpaperScanner.shared.scan(forceRefresh: false)
        categories = Self.computeCategories(from: allWallpapers)
        buildCategoryChips()
    }

    public func loadDataAsync(forceRefresh: Bool = false, completion: (@MainActor () -> Void)? = nil) {
        statusLabel.stringValue = "Cargando galería de fondos..."

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let items = WallpaperScanner.shared.scan(forceRefresh: forceRefresh)
            let cats = Self.computeCategories(from: items)

            DispatchQueue.main.async {
                guard let self = self else { return }
                self.allWallpapers = items
                self.categories = cats
                self.buildCategoryChips()
                self.applyFilter(query: self.searchField.stringValue)
                completion?()
            }
        }
    }

    nonisolated public static func computeCategories(from items: [WallpaperItem]) -> [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for w in items {
            let cat = w.category.lowercased()
            let key = (cat.contains("/") ? (cat as NSString).lastPathComponent : cat)
            counts[key, default: 0] += 1
        }

        var cats: [(name: String, count: Int)] = [("all", items.count)]
        let sortedKeys = counts.keys.sorted {
            (counts[$0] ?? 0) > (counts[$1] ?? 0)
        }
        for k in sortedKeys {
            if k != "all" && !k.isEmpty {
                cats.append((name: k, count: counts[k] ?? 0))
            }
        }
        return cats
    }

    private func buildCategoryChips() {
        for btn in categoryButtons {
            btn.cleanup()
            btn.removeFromSuperview()
        }
        categoryButtons.removeAll()

        var curX: CGFloat = 0.0
        let chipHeight: CGFloat = 30.0
        let chipSpacing: CGFloat = 8.0

        for cat in categories {
            let btn = CategoryChipButton(category: cat.name, count: cat.count, isSelected: (cat.name == selectedCategory))
            let text = cat.name == "all" ? "Todos (\(cat.count))" : "\(cat.name.capitalized) (\(cat.count))"
            let estimatedWidth = CGFloat(text.count * 8 + 24)
            let chipWidth = max(76.0, estimatedWidth)

            btn.frame = NSRect(x: curX, y: 0, width: chipWidth, height: chipHeight)
            btn.onClick = { [weak self] selected in
                self?.selectCategory(selected)
            }
            categoriesStackView.addSubview(btn)
            categoryButtons.append(btn)

            curX += chipWidth + chipSpacing
        }

        categoriesStackView.frame = NSRect(x: 0, y: 0, width: curX, height: chipHeight)
    }

    public func selectCategory(_ catName: String) {
        selectedCategory = catName
        for btn in categoryButtons {
            btn.isSelected = (btn.category == catName)
        }
        applyFilter(query: searchField.stringValue)
    }

    public func cycleCategory(forward: Bool = true) {
        guard !categories.isEmpty else { return }
        let curIdx = categories.firstIndex(where: { $0.name == selectedCategory }) ?? 0
        let nextIdx: Int
        if forward {
            nextIdx = (curIdx + 1) % categories.count
        } else {
            nextIdx = (curIdx - 1 + categories.count) % categories.count
        }
        selectCategory(categories[nextIdx].name)
    }

    private func applyFilter(query: String) {
        searchDebounceWorkItem?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        var base = allWallpapers
        if selectedCategory != "all" {
            base = base.filter {
                let c = $0.category.lowercased()
                return c == selectedCategory || c.hasSuffix("/" + selectedCategory) || c.contains(selectedCategory)
            }
        }

        if q.isEmpty {
            filteredWallpapers = base
        } else {
            var scored: [(item: WallpaperItem, score: Int)] = []
            for item in base {
                var s: Int? = nil
                if let nameScore = FuzzyMatcher.score(query: q, target: item.name) {
                    s = nameScore
                }
                if let catScore = FuzzyMatcher.score(query: q, target: item.category) {
                    s = max(s ?? 0, catScore)
                }
                if let score = s {
                    scored.append((item, score))
                }
            }
            scored.sort { $0.score > $1.score }
            filteredWallpapers = scored.map { $0.item }
        }

        selectedIndex = 0
        gridView.reloadGrid(items: filteredWallpapers, selectedIndex: selectedIndex)

        let catName = selectedCategory == "all" ? "Todos" : selectedCategory.capitalized
        statusLabel.stringValue = "\(filteredWallpapers.count) fondos • Categoría: \(catName)"
    }

    public func setSelectedIndex(_ index: Int) {
        guard !filteredWallpapers.isEmpty else { return }
        var next = index
        if next < 0 {
            next = 0
        } else if next >= filteredWallpapers.count {
            next = filteredWallpapers.count - 1
        }
        selectedIndex = next
        gridView.setSelectedCardIndex(selectedIndex)
    }

    public func applySelectedItem(at index: Int) {
        guard index >= 0 && index < filteredWallpapers.count else { return }
        let item = filteredWallpapers[index]
        applyWallpaper(path: item.path)
        dismiss()
    }

    private func applyWallpaper(path: String) {
        let cachePath = NSString(string: "~/.cache/current_wallpaper").expandingTildeInPath
        try? path.write(toFile: cachePath, atomically: true, encoding: .utf8)

        let url = URL(fileURLWithPath: path)
        for screen in NSScreen.screens {
            try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
        }
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

    public func showGallery() {
        centerOnActiveScreen()
        makeKeyAndOrderFront(nil)
        makeFirstResponder(searchField)
        NSApp.activate(ignoringOtherApps: true)
        gridView.updateVisibleThumbnails()
    }

    public func dismiss() {
        gridView.cancelAllPendingThumbnails()
        orderOut(nil)
        onClose?()
    }

    @objc private func handleDidResignKey() {
        dismiss()
    }

    // MARK: - NSTextFieldDelegate & Key Commands

    private func flushSearchDebounce() {
        if let pending = searchDebounceWorkItem, !pending.isCancelled {
            pending.cancel()
            applyFilter(query: searchField.stringValue)
        }
    }

    public func controlTextDidChange(_ obj: Notification) {
        searchDebounceWorkItem?.cancel()
        let query = searchField.stringValue
        let workItem = DispatchWorkItem { [weak self] in
            self?.applyFilter(query: query)
        }
        searchDebounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150), execute: workItem)
    }

    public func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        flushSearchDebounce()
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            setSelectedIndex(selectedIndex + WallpaperGridView.columns)
            return true
        } else if commandSelector == #selector(NSResponder.moveUp(_:)) {
            setSelectedIndex(selectedIndex - WallpaperGridView.columns)
            return true
        } else if commandSelector == #selector(NSResponder.moveLeft(_:)) {
            setSelectedIndex(selectedIndex - 1)
            return true
        } else if commandSelector == #selector(NSResponder.moveRight(_:)) {
            setSelectedIndex(selectedIndex + 1)
            return true
        } else if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            applySelectedItem(at: selectedIndex)
            return true
        } else if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            dismiss()
            return true
        }
        return false
    }

    public override func keyDown(with event: NSEvent) {
        flushSearchDebounce()
        switch event.keyCode {
        case 53: // Escape
            dismiss()
        case 123: // Left
            setSelectedIndex(selectedIndex - 1)
        case 124: // Right
            setSelectedIndex(selectedIndex + 1)
        case 125: // Down
            setSelectedIndex(selectedIndex + WallpaperGridView.columns)
        case 126: // Up
            setSelectedIndex(selectedIndex - WallpaperGridView.columns)
        case 36: // Enter
            applySelectedItem(at: selectedIndex)
        case 48: // Tab -> Cycle color categories
            let shift = event.modifierFlags.contains(.shift)
            cycleCategory(forward: !shift)
        default:
            super.keyDown(with: event)
        }
    }
}
