import Cocoa
import CoreGraphics
import CoreText

@MainActor
final class WlogoutButtonView: NSView {
    let item: WlogoutItem
    var isHovered: Bool = false {
        didSet {
            if oldValue != isHovered {
                needsDisplay = true
            }
        }
    }
    var isPressed: Bool = false {
        didSet {
            if oldValue != isPressed {
                needsDisplay = true
            }
        }
    }
    var onClick: (@MainActor () -> Void)?

    private var trackingAreaRef: NSTrackingArea?

    private static let candidateNerdFonts = [
        "JetBrainsMono Nerd Font",
        "JetBrainsMonoNF-Regular",
        "FiraCode Nerd Font",
        "FiraCodeNF-Reg",
        "Hack Nerd Font",
        "Iosevka Nerd Font",
        "Symbols Nerd Font Mono"
    ]

    init(item: WlogoutItem) {
        self.item = item
        super.init(frame: NSRect(x: 0, y: 0, width: 120, height: 120))
        wantsLayer = true
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
        }
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isPressed else { return }
        isPressed = false
        let loc = convert(event.locationInWindow, from: nil)
        if bounds.contains(loc) {
            onClick?()
        }
    }

    private func findNerdFont(size: CGFloat) -> NSFont? {
        for name in Self.candidateNerdFonts {
            if let font = NSFont(name: name, size: size) {
                return font
            }
        }
        return nil
    }

    private func canRenderGlyph(text: String, font: NSFont) -> Bool {
        guard !text.isEmpty else { return false }
        let utf16 = Array(text.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        let ctFont = font as CTFont
        return CTFontGetGlyphsForCharacters(ctFont, utf16, &glyphs, utf16.count)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }

        let theme = HyprTheme.shared
        let accentColor = theme.primary
        let onAccentColor = theme.onPrimary
        let normalSurface = NSColor(red: 30.0 / 255.0, green: 30.0 / 255.0, blue: 30.0 / 255.0, alpha: 0.85)
        let normalOnSurface = theme.onSurface

        let buttonRect = bounds.insetBy(dx: 3, dy: 3)
        let cornerRadius: CGFloat = 16.0
        let path = NSBezierPath(roundedRect: buttonRect, xRadius: cornerRadius, yRadius: cornerRadius)

        // Shadow & Background
        let shadow = NSShadow()
        if isHovered {
            shadow.shadowColor = accentColor.withAlphaComponent(0.4)
            shadow.shadowOffset = NSSize(width: 0, height: -4)
            shadow.shadowBlurRadius = 16.0
        } else {
            shadow.shadowColor = NSColor(white: 0.0, alpha: 0.35)
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            shadow.shadowBlurRadius = 8.0
        }
        shadow.set()

        let backgroundColor: NSColor
        if isPressed {
            backgroundColor = theme.secondary
        } else if isHovered {
            backgroundColor = accentColor.withAlphaComponent(0.95)
        } else {
            backgroundColor = normalSurface
        }
        backgroundColor.setFill()
        path.fill()

        // Clear shadow for interior text/icons
        let noShadow = NSShadow()
        noShadow.set()

        let iconColor: NSColor = isHovered ? onAccentColor : normalOnSurface
        let labelColor: NSColor = isHovered ? onAccentColor : normalOnSurface
        let badgeColor: NSColor = isHovered ? onAccentColor.withAlphaComponent(0.7) : NSColor(white: 0.65, alpha: 0.8)

        // 1. Icon (Top: y = 56..96, height = 40)
        let iconRect = NSRect(x: buttonRect.origin.x, y: buttonRect.origin.y + 54, width: buttonRect.width, height: 40)
        var renderedNerdFont = false
        if let nerdFont = findNerdFont(size: 32), canRenderGlyph(text: item.text, font: nerdFont) {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: nerdFont,
                .foregroundColor: iconColor,
                .paragraphStyle: style
            ]
            let astr = NSAttributedString(string: item.text, attributes: attrs)
            let textBounds = astr.boundingRect(with: iconRect.size, options: [.usesLineFragmentOrigin])
            let centeredY = iconRect.origin.y + (iconRect.height - textBounds.height) / 2
            let drawRect = NSRect(x: iconRect.origin.x, y: centeredY, width: iconRect.width, height: textBounds.height)
            astr.draw(in: drawRect)
            renderedNerdFont = true
        }

        if !renderedNerdFont {
            if let sfSymbol = NSImage(systemSymbolName: item.fallbackSFSymbolName, accessibilityDescription: nil) {
                let config = NSImage.SymbolConfiguration(pointSize: 28, weight: .regular)
                    .applying(.init(paletteColors: [iconColor]))
                let configured = sfSymbol.withSymbolConfiguration(config) ?? sfSymbol
                let imgSize = configured.size
                let targetRect = NSRect(
                    x: iconRect.origin.x + (iconRect.width - imgSize.width) / 2,
                    y: iconRect.origin.y + (iconRect.height - imgSize.height) / 2,
                    width: imgSize.width,
                    height: imgSize.height
                )
                configured.draw(in: targetRect)
            }
        }

        // 2. Label (Middle: y = 30..48, height = 18)
        let labelRect = NSRect(x: buttonRect.origin.x, y: buttonRect.origin.y + 30, width: buttonRect.width, height: 18)
        let labelStyle = NSMutableParagraphStyle()
        labelStyle.alignment = .center
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13.5, weight: .semibold),
            .foregroundColor: labelColor,
            .paragraphStyle: labelStyle
        ]
        let labelStr = NSAttributedString(string: item.displayTitle, attributes: labelAttrs)
        labelStr.draw(in: labelRect)

        // 3. Keybind Badge (Bottom: y = 12..24, height = 14)
        let badgeRect = NSRect(x: buttonRect.origin.x, y: buttonRect.origin.y + 12, width: buttonRect.width, height: 14)
        let badgeStyle = NSMutableParagraphStyle()
        badgeStyle.alignment = .center
        let badgeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: badgeColor,
            .paragraphStyle: badgeStyle
        ]
        let badgeStr = NSAttributedString(string: item.keybindHint, attributes: badgeAttrs)
        badgeStr.draw(in: badgeRect)
    }
}

@MainActor
final class WlogoutOverlayView: NSView {
    let items: [WlogoutItem]
    var buttonsPerRow: Int = 3
    var onDismiss: (@MainActor () -> Void)?
    var onItemClick: (@MainActor (WlogoutItem) -> Void)?

    private var buttonViews: [WlogoutButtonView] = []
    private let visualEffect: NSVisualEffectView

    init(frame: NSRect, items: [WlogoutItem], buttonsPerRow: Int = 3) {
        self.items = items
        self.buttonsPerRow = max(1, buttonsPerRow)
        self.visualEffect = NSVisualEffectView(frame: frame)
        super.init(frame: frame)

        wantsLayer = true
        autoresizingMask = [.width, .height]

        visualEffect.autoresizingMask = [.width, .height]
        visualEffect.blendingMode = .behindWindow
        visualEffect.material = .hudWindow
        visualEffect.state = .active
        addSubview(visualEffect)

        buildButtons()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildButtons() {
        for btn in buttonViews {
            btn.removeFromSuperview()
        }
        buttonViews.removeAll()

        for item in items {
            let btn = WlogoutButtonView(item: item)
            btn.onClick = { [weak self, weak btn] in
                guard let self = self, let b = btn else { return }
                self.onItemClick?(b.item)
            }
            addSubview(btn)
            buttonViews.append(btn)
        }
        layoutButtons()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutButtons()
    }

    private func layoutButtons() {
        guard !buttonViews.isEmpty else { return }

        let buttonWidth: CGFloat = 120.0
        let buttonHeight: CGFloat = 120.0
        let spacing: CGFloat = 24.0

        let cols = min(buttonsPerRow, buttonViews.count)
        let rows = (buttonViews.count + buttonsPerRow - 1) / buttonsPerRow

        let totalGridWidth = CGFloat(cols) * buttonWidth + CGFloat(cols - 1) * spacing
        let totalGridHeight = CGFloat(rows) * buttonHeight + CGFloat(rows - 1) * spacing

        let startX = floor((bounds.width - totalGridWidth) / 2.0)
        let startY = floor((bounds.height - totalGridHeight) / 2.0)

        for (index, btn) in buttonViews.enumerated() {
            let row = index / buttonsPerRow
            let col = index % buttonsPerRow

            // In AppKit (non-flipped), top row has higher Y
            let y = startY + CGFloat(rows - 1 - row) * (buttonHeight + spacing)
            let x = startX + CGFloat(col) * (buttonWidth + spacing)
            btn.frame = NSRect(x: x, y: y, width: buttonWidth, height: buttonHeight)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Dark semi-transparent overlay matching reference style.css: rgba(0, 0, 0, 0.65)
        NSColor(white: 0.0, alpha: 0.65).setFill()
        dirtyRect.fill(using: .sourceOver)
    }

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        for btn in buttonViews {
            if btn.frame.contains(loc) {
                return
            }
        }
        onDismiss?()
    }
}

@MainActor
public final class WlogoutWindow: NSWindow {
    public let items: [WlogoutItem]
    public let actionDispatcher: WlogoutActionDispatcherProtocol
    public var onDismiss: (@MainActor () -> Void)?
    public var onActionExecuted: (@MainActor (WlogoutItem) -> Void)?

    private var overlayView: WlogoutOverlayView?

    public init(
        items: [WlogoutItem] = WlogoutItem.defaultItems,
        actionDispatcher: WlogoutActionDispatcherProtocol = WlogoutActionDispatcher.shared,
        screen: NSScreen? = NSScreen.main ?? NSScreen.screens.first
    ) {
        self.items = items
        self.actionDispatcher = actionDispatcher

        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        super.init(
            contentRect: screenFrame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        self.level = .screenSaver
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = false
        self.acceptsMouseMovedEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false

        let overlay = WlogoutOverlayView(frame: NSRect(origin: .zero, size: screenFrame.size), items: items)
        overlay.onDismiss = { [weak self] in
            self?.dismiss()
        }
        overlay.onItemClick = { [weak self] item in
            self?.execute(item: item)
        }
        self.overlayView = overlay
        self.contentView = overlay
    }

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { true }

    public func present() {
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func dismiss() {
        close()
        onDismiss?()
    }

    public func execute(item: WlogoutItem) {
        actionDispatcher.dispatch(item: item)
        close()
        onActionExecuted?(item)
    }

    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            dismiss()
            return
        }

        guard let chars = event.charactersIgnoringModifiers?.lowercased(),
              let keyChar = chars.first else {
            super.keyDown(with: event)
            return
        }

        if let match = items.first(where: { $0.keybind.lowercased().first == keyChar }) {
            execute(item: match)
            return
        }

        super.keyDown(with: event)
    }
}
