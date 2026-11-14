import Cocoa
import QuartzCore

/// Interactive clickable pill container with hand cursor
@MainActor
public class ClickablePill: NSView {
    public var onClick: (() -> Void)?

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    public override func mouseDown(with event: NSEvent) {
        // Intercept mouseDown so the window does not forward it to other responders or ignore it
    }

    public override func mouseUp(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        if bounds.contains(loc) {
            onClick?()
        }
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.0 else { return nil }
        if let target = super.hitTest(point) {
            if target == self || target.isDescendant(of: self) {
                return self
            }
            return target
        }
        return nil
    }

    public override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// Individual interactive workspace pill styled with mxmrn Japanese Kanji workspaces
@MainActor
public final class WorkspacePill: NSView {
    public static let kanjiList = ["一", "二", "三", "四", "五", "六", "七", "八", "九", "十"]

    public let workspaceID: Int
    public var theme: HyprTheme {
        didSet { updateAppearance() }
    }
    public var isActive: Bool = false {
        didSet { updateAppearance() }
    }
    public var activeBgColor: NSColor? {
        didSet { updateAppearance() }
    }
    public var activeFgColor: NSColor? {
        didSet { updateAppearance() }
    }
    public var inactiveTextColor: NSColor? {
        didSet { updateAppearance() }
    }
    public var onSelect: ((Int) -> Void)?

    public let label = NSTextField(labelWithString: "")

    public init(workspaceID: Int, theme: HyprTheme = .shared) {
        self.workspaceID = workspaceID
        self.theme = theme
        super.init(frame: .zero)
        setupView()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupView() {
        wantsLayer = true
        layer?.cornerRadius = 5.0
        layer?.masksToBounds = true

        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.isEditable = false
        label.isSelectable = false
        addSubview(label)

        let kanjiIndex = workspaceID - 1
        let symbol = (kanjiIndex >= 0 && kanjiIndex < Self.kanjiList.count) ? Self.kanjiList[kanjiIndex] : "\(workspaceID)"
        label.stringValue = symbol

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 22.0),
            heightAnchor.constraint(equalToConstant: 20.0),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 1.0),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -1.0)
        ])

        updateAppearance()
    }

    public func updateAppearance() {
        layer?.cornerRadius = 5.0
        let kanjiIndex = workspaceID - 1
        let symbol = (kanjiIndex >= 0 && kanjiIndex < Self.kanjiList.count) ? Self.kanjiList[kanjiIndex] : "\(workspaceID)"
        label.stringValue = symbol

        if isActive {
            layer?.backgroundColor = (activeBgColor ?? theme.primary).cgColor
            label.textColor = activeFgColor ?? theme.onPrimary
            label.font = .barFont(ofSize: 11, weight: .bold)
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            label.textColor = inactiveTextColor ?? theme.onSurface
            label.font = .barFont(ofSize: 11, weight: .medium)
        }
        needsLayout = true
    }

    public override func mouseUp(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        if bounds.contains(loc) {
            onSelect?(workspaceID)
        }
    }

    public override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// Floating glass capsule container styled after Waybar 5px border-radius floating capsules
@MainActor
public final class FloatingCapsuleView: NSView {
    public var cornerRadius: CGFloat = 5.0 {
        didSet {
            updateCornerRadius()
        }
    }

    public var theme: HyprTheme = .shared {
        didSet {
            updateTheme()
        }
    }

    public var surfaceAlpha: CGFloat = 0.65 {
        didSet {
            updateTheme()
        }
    }

    public var isFrameless: Bool = false {
        didSet {
            updateAppearance()
        }
    }

    private let clipView = NSView()
    private let visualEffectView = NSVisualEffectView()
    private let darkOverlay = NSView()
    public let stackView = NSStackView()
    public var contentView: NSView { clipView }
    private var stackLeadingConstraint: NSLayoutConstraint?
    private var stackTrailingConstraint: NSLayoutConstraint?

    public init(cornerRadius: CGFloat = 5.0, theme: HyprTheme = .shared, surfaceAlpha: CGFloat = 0.65) {
        self.cornerRadius = cornerRadius
        self.theme = theme
        self.surfaceAlpha = surfaceAlpha
        super.init(frame: .zero)
        setupViews()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.25
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        layer?.shadowRadius = 5.0

        clipView.translatesAutoresizingMaskIntoConstraints = false
        clipView.wantsLayer = true
        clipView.layer?.masksToBounds = true
        addSubview(clipView)

        // Frosted glass background
        visualEffectView.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.material = .fullScreenUI
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.appearance = NSAppearance(named: .darkAqua)
        visualEffectView.wantsLayer = true
        clipView.addSubview(visualEffectView)

        // Dark surface layer matching Material You theme with subtle 1px border
        darkOverlay.translatesAutoresizingMaskIntoConstraints = false
        darkOverlay.wantsLayer = true
        darkOverlay.layer?.backgroundColor = theme.surface.withAlphaComponent(surfaceAlpha).cgColor
        darkOverlay.layer?.borderWidth = 1.0
        darkOverlay.layer?.borderColor = NSColor(white: 1.0, alpha: 0.10).cgColor
        clipView.addSubview(darkOverlay)

        // Content stack inside capsule
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .horizontal
        stackView.spacing = 8.0
        stackView.alignment = .centerY
        clipView.addSubview(stackView)

        let leading = stackView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor, constant: 8.0)
        let trailing = stackView.trailingAnchor.constraint(equalTo: clipView.trailingAnchor, constant: -8.0)
        self.stackLeadingConstraint = leading
        self.stackTrailingConstraint = trailing

        NSLayoutConstraint.activate([
            clipView.topAnchor.constraint(equalTo: topAnchor),
            clipView.bottomAnchor.constraint(equalTo: bottomAnchor),
            clipView.leadingAnchor.constraint(equalTo: leadingAnchor),
            clipView.trailingAnchor.constraint(equalTo: trailingAnchor),

            visualEffectView.topAnchor.constraint(equalTo: clipView.topAnchor),
            visualEffectView.bottomAnchor.constraint(equalTo: clipView.bottomAnchor),
            visualEffectView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            visualEffectView.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),

            darkOverlay.topAnchor.constraint(equalTo: clipView.topAnchor),
            darkOverlay.bottomAnchor.constraint(equalTo: clipView.bottomAnchor),
            darkOverlay.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            darkOverlay.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),

            stackView.topAnchor.constraint(equalTo: clipView.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: clipView.bottomAnchor),
            leading,
            trailing
        ])

        updateCornerRadius()
        updateTheme()
        updateAppearance()
    }

    private func updateCornerRadius() {
        clipView.layer?.cornerRadius = cornerRadius
        visualEffectView.layer?.cornerRadius = cornerRadius
        darkOverlay.layer?.cornerRadius = cornerRadius
        needsLayout = true
    }

    public func updateTheme() {
        if isFrameless {
            darkOverlay.layer?.backgroundColor = NSColor.clear.cgColor
            darkOverlay.layer?.borderWidth = 0.0
            darkOverlay.layer?.borderColor = NSColor.clear.cgColor
        } else {
            darkOverlay.layer?.backgroundColor = theme.surface.withAlphaComponent(surfaceAlpha).cgColor
            darkOverlay.layer?.borderWidth = 1.0
            darkOverlay.layer?.borderColor = NSColor(white: 1.0, alpha: 0.10).cgColor
        }
    }

    private func updateAppearance() {
        if isFrameless {
            layer?.shadowOpacity = 0.0
            layer?.shadowPath = nil
            visualEffectView.isHidden = true
            darkOverlay.layer?.backgroundColor = NSColor.clear.cgColor
            darkOverlay.layer?.borderWidth = 0.0
            darkOverlay.layer?.borderColor = NSColor.clear.cgColor
            stackLeadingConstraint?.constant = 0.0
            stackTrailingConstraint?.constant = 0.0
        } else {
            layer?.shadowOpacity = 0.25
            visualEffectView.isHidden = false
            darkOverlay.layer?.borderWidth = 1.0
            stackLeadingConstraint?.constant = 8.0
            stackTrailingConstraint?.constant = -8.0
            updateTheme()
        }
        needsLayout = true
    }

    private var previousRenderedFrame: NSRect = .zero

    public override func layout() {
        super.layout()
        let currentFrame = frame
        if isFrameless {
            layer?.shadowOpacity = 0.0
            layer?.shadowPath = nil
        } else if bounds.width > 0 && bounds.height > 0 {
            layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        }

        // Invalidate vacated dirty rects in the transparent window backing store when shrinking
        if previousRenderedFrame != .zero && previousRenderedFrame != currentFrame {
            if currentFrame.width < previousRenderedFrame.width || currentFrame.height < previousRenderedFrame.height || currentFrame.origin != previousRenderedFrame.origin {
                let shadowPadding: CGFloat = 16.0
                let dirtyRect = previousRenderedFrame.insetBy(dx: -shadowPadding, dy: -shadowPadding)
                superview?.setNeedsDisplay(dirtyRect)
                window?.viewsNeedDisplay = true
            }
        }
        previousRenderedFrame = currentFrame
    }
}
