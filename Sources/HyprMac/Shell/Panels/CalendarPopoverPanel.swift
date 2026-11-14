import Cocoa
import QuartzCore

/// Dark floating popover panel anchored below the top bar's clock pill for viewing the month calendar and navigating dates.
@MainActor
public final class CalendarPopoverPanel: NSPanel {
    public static let panelWidth: CGFloat = 280.0
    public static let panelHeight: CGFloat = 296.0

    public private(set) var isOpen: Bool = false
    public var onClose: (() -> Void)?

    private let capsuleView = FloatingCapsuleView(cornerRadius: 10.0, surfaceAlpha: 0.65)

    // Current displayed month anchor
    public private(set) var displayedMonth: Date = Date()
    private var currentBarColors: HyprBarColors = HyprBarColors()

    // Header section
    public let headerContainer = ClickablePill()
    public let calendarIconLabel = NSTextField(labelWithString: "󰃭")
    public let monthYearTitleLabel = NSTextField(labelWithString: "")

    public let prevMonthButton = ClickablePill()
    public let prevMonthLabel = NSTextField(labelWithString: "‹")
    public let todayButton = ClickablePill()
    public let todayLabel = NSTextField(labelWithString: "•")
    public let nextMonthButton = ClickablePill()
    public let nextMonthLabel = NSTextField(labelWithString: "›")

    private let topDivider = NSView()

    // Weekdays section
    private let weekdayHeaderStack = NSStackView()

    // Days grid section (6 rows × 7 columns)
    private let daysGridStack = NSStackView()
    private struct DayCellViews: @unchecked Sendable {
        let pill: ClickablePill
        let label: NSTextField
    }
    private var cellViews: [DayCellViews] = []

    // Footer section
    private let bottomDivider = NSView()
    public let todayFooterContainer = ClickablePill()
    public let todayFooterLabel = NSTextField(labelWithString: "")

    private var outsideClickMonitor: Any?
    private var globalClickMonitor: Any?

    public struct ResolvedColors: Sendable {
        public let background: NSColor
        public let border: NSColor
        public let surface: NSColor
        public let accent: NSColor
        public let textPrimary: NSColor
        public let textSecondary: NSColor

        public init(theme: HyprTheme = .shared, barColors: HyprBarColors = HyprBarColors(), backgroundAlpha: CGFloat = 0.65) {
            let baseBg = theme.resolveColor(barColors.surface, fallback: theme.surface)
            self.background = baseBg.withAlphaComponent(backgroundAlpha)
            self.border = theme.resolveColor(nil, fallback: theme.outline)
            self.surface = theme.resolveColor(barColors.surface, fallback: theme.surface)
            self.accent = theme.resolveColor(barColors.clock, fallback: theme.primary)
            self.textPrimary = theme.resolveColor(barColors.windowTitle, fallback: theme.onSurface)
            self.textSecondary = theme.resolveColor(barColors.clock, fallback: theme.secondary)
        }
    }

    public init(anchorFrame: NSRect, screen: NSScreen?) {
        let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first
        let screenFrame = targetScreen?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)

        let popoverX = min(
            max(screenFrame.origin.x + 10.0, anchorFrame.midX - (Self.panelWidth / 2.0)),
            screenFrame.origin.x + screenFrame.width - Self.panelWidth - 10.0
        )
        let popoverY = anchorFrame.minY - Self.panelHeight - 6.0

        let initialFrame = NSRect(x: popoverX, y: popoverY, width: Self.panelWidth, height: Self.panelHeight)

        super.init(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        setupUI()
    }

    public override var canBecomeKey: Bool { true }

    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            dismissPopover()
            return
        }
        super.keyDown(with: event)
    }

    private func setupUI() {
        guard let content = contentView else { return }

        capsuleView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(capsuleView)

        NSLayoutConstraint.activate([
            capsuleView.topAnchor.constraint(equalTo: content.topAnchor),
            capsuleView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            capsuleView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            capsuleView.trailingAnchor.constraint(equalTo: content.trailingAnchor)
        ])

        let container = capsuleView.contentView
        let theme = HyprTheme.shared

        let mainStack = NSStackView()
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 8.0
        container.addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14.0),
            mainStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14.0),
            mainStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14.0),
            mainStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14.0)
        ])

        // Top Row: Header (Icon + Title) & Nav Buttons
        let topRow = NSStackView()
        topRow.translatesAutoresizingMaskIntoConstraints = false
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 6.0

        headerContainer.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.wantsLayer = true

        calendarIconLabel.translatesAutoresizingMaskIntoConstraints = false
        calendarIconLabel.isEditable = false
        calendarIconLabel.isSelectable = false
        calendarIconLabel.font = .barFont(ofSize: 13, weight: .bold)
        calendarIconLabel.textColor = theme.primary
        calendarIconLabel.stringValue = "󰃭"
        headerContainer.addSubview(calendarIconLabel)

        monthYearTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        monthYearTitleLabel.isEditable = false
        monthYearTitleLabel.isSelectable = false
        monthYearTitleLabel.font = .barFont(ofSize: 12, weight: .bold)
        monthYearTitleLabel.textColor = theme.onSurface
        headerContainer.addSubview(monthYearTitleLabel)

        NSLayoutConstraint.activate([
            calendarIconLabel.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor),
            calendarIconLabel.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),
            calendarIconLabel.widthAnchor.constraint(equalToConstant: 18.0),

            monthYearTitleLabel.leadingAnchor.constraint(equalTo: calendarIconLabel.trailingAnchor, constant: 6.0),
            monthYearTitleLabel.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor),
            monthYearTitleLabel.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),
            headerContainer.heightAnchor.constraint(equalToConstant: 22.0)
        ])

        headerContainer.onClick = { [weak self] in
            guard let self = self else { return }
            self.displayedMonth = Date()
            self.refreshCalendar()
        }
        topRow.addArrangedSubview(headerContainer)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        topRow.addArrangedSubview(spacer)

        // Navigation Buttons Stack
        let navStack = NSStackView()
        navStack.translatesAutoresizingMaskIntoConstraints = false
        navStack.orientation = .horizontal
        navStack.alignment = .centerY
        navStack.spacing = 4.0

        for (btn, lbl, symbol) in [
            (prevMonthButton, prevMonthLabel, "‹"),
            (todayButton, todayLabel, "•"),
            (nextMonthButton, nextMonthLabel, "›")
        ] {
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.wantsLayer = true
            btn.layer?.cornerRadius = 5.0
            btn.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.06).cgColor
            btn.layer?.borderWidth = 1.0
            btn.layer?.borderColor = NSColor(white: 1.0, alpha: 0.12).cgColor

            lbl.translatesAutoresizingMaskIntoConstraints = false
            lbl.isEditable = false
            lbl.isSelectable = false
            lbl.alignment = .center
            lbl.font = .barFont(ofSize: 12, weight: .bold)
            lbl.stringValue = symbol
            lbl.textColor = theme.onSurface
            btn.addSubview(lbl)

            NSLayoutConstraint.activate([
                btn.widthAnchor.constraint(equalToConstant: 24.0),
                btn.heightAnchor.constraint(equalToConstant: 22.0),
                lbl.centerXAnchor.constraint(equalTo: btn.centerXAnchor),
                lbl.centerYAnchor.constraint(equalTo: btn.centerYAnchor)
            ])
            navStack.addArrangedSubview(btn)
        }

        prevMonthButton.onClick = { [weak self] in
            guard let self = self else { return }
            if let prev = Calendar.current.date(byAdding: .month, value: -1, to: self.displayedMonth) {
                self.displayedMonth = prev
                self.refreshCalendar()
            }
        }

        todayButton.onClick = { [weak self] in
            guard let self = self else { return }
            self.displayedMonth = Date()
            self.refreshCalendar()
        }

        nextMonthButton.onClick = { [weak self] in
            guard let self = self else { return }
            if let next = Calendar.current.date(byAdding: .month, value: 1, to: self.displayedMonth) {
                self.displayedMonth = next
                self.refreshCalendar()
            }
        }

        topRow.addArrangedSubview(navStack)
        mainStack.addArrangedSubview(topRow)
        topRow.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true

        // Top Divider
        topDivider.translatesAutoresizingMaskIntoConstraints = false
        topDivider.wantsLayer = true
        topDivider.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.10).cgColor
        topDivider.heightAnchor.constraint(equalToConstant: 1.0).isActive = true
        mainStack.addArrangedSubview(topDivider)
        topDivider.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true

        // Weekday Header Row
        weekdayHeaderStack.translatesAutoresizingMaskIntoConstraints = false
        weekdayHeaderStack.orientation = .horizontal
        weekdayHeaderStack.alignment = .centerY
        weekdayHeaderStack.distribution = .fillEqually
        weekdayHeaderStack.spacing = 0.0
        weekdayHeaderStack.heightAnchor.constraint(equalToConstant: 16.0).isActive = true

        let calendar = Calendar.current
        let firstWeekday = calendar.firstWeekday
        let rawSymbols = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]
        let shift = (firstWeekday - 1) % 7
        let weekdaySymbols = Array(rawSymbols[shift..<7] + rawSymbols[0..<shift])

        for sym in weekdaySymbols {
            let lbl = NSTextField(labelWithString: sym)
            lbl.translatesAutoresizingMaskIntoConstraints = false
            lbl.isEditable = false
            lbl.isSelectable = false
            lbl.alignment = .center
            lbl.font = .barFont(ofSize: 9.5, weight: .bold)
            lbl.textColor = theme.onSurface.withAlphaComponent(0.60)
            weekdayHeaderStack.addArrangedSubview(lbl)
        }
        mainStack.addArrangedSubview(weekdayHeaderStack)
        weekdayHeaderStack.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true

        // Days Grid (6 rows × 7 columns)
        daysGridStack.translatesAutoresizingMaskIntoConstraints = false
        daysGridStack.orientation = .vertical
        daysGridStack.alignment = .leading
        daysGridStack.distribution = .fillEqually
        daysGridStack.spacing = 3.0

        for _ in 0..<6 {
            let rowStack = NSStackView()
            rowStack.translatesAutoresizingMaskIntoConstraints = false
            rowStack.orientation = .horizontal
            rowStack.alignment = .centerY
            rowStack.distribution = .fillEqually
            rowStack.spacing = 0.0
            rowStack.heightAnchor.constraint(equalToConstant: 26.0).isActive = true

            for _ in 0..<7 {
                let cellContainer = NSView()
                cellContainer.translatesAutoresizingMaskIntoConstraints = false

                let pill = ClickablePill()
                pill.translatesAutoresizingMaskIntoConstraints = false
                pill.wantsLayer = true
                pill.layer?.cornerRadius = 6.0
                cellContainer.addSubview(pill)

                let label = NSTextField(labelWithString: "")
                label.translatesAutoresizingMaskIntoConstraints = false
                label.isEditable = false
                label.isSelectable = false
                label.alignment = .center
                pill.addSubview(label)

                NSLayoutConstraint.activate([
                    pill.centerXAnchor.constraint(equalTo: cellContainer.centerXAnchor),
                    pill.centerYAnchor.constraint(equalTo: cellContainer.centerYAnchor),
                    pill.widthAnchor.constraint(equalToConstant: 32.0),
                    pill.heightAnchor.constraint(equalToConstant: 24.0),

                    label.centerXAnchor.constraint(equalTo: pill.centerXAnchor),
                    label.centerYAnchor.constraint(equalTo: pill.centerYAnchor)
                ])

                cellViews.append(DayCellViews(pill: pill, label: label))
                rowStack.addArrangedSubview(cellContainer)
            }
            daysGridStack.addArrangedSubview(rowStack)
        }
        mainStack.addArrangedSubview(daysGridStack)
        daysGridStack.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true

        // Bottom Divider
        bottomDivider.translatesAutoresizingMaskIntoConstraints = false
        bottomDivider.wantsLayer = true
        bottomDivider.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.10).cgColor
        bottomDivider.heightAnchor.constraint(equalToConstant: 1.0).isActive = true
        mainStack.addArrangedSubview(bottomDivider)
        bottomDivider.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true

        // Today Footer Row
        todayFooterContainer.translatesAutoresizingMaskIntoConstraints = false
        todayFooterContainer.wantsLayer = true

        todayFooterLabel.translatesAutoresizingMaskIntoConstraints = false
        todayFooterLabel.isEditable = false
        todayFooterLabel.isSelectable = false
        todayFooterLabel.alignment = .center
        todayFooterLabel.font = .barFont(ofSize: 10, weight: .medium)
        todayFooterLabel.textColor = theme.onSurface.withAlphaComponent(0.80)
        todayFooterContainer.addSubview(todayFooterLabel)

        NSLayoutConstraint.activate([
            todayFooterLabel.centerXAnchor.constraint(equalTo: todayFooterContainer.centerXAnchor),
            todayFooterLabel.centerYAnchor.constraint(equalTo: todayFooterContainer.centerYAnchor),
            todayFooterLabel.leadingAnchor.constraint(greaterThanOrEqualTo: todayFooterContainer.leadingAnchor),
            todayFooterLabel.trailingAnchor.constraint(lessThanOrEqualTo: todayFooterContainer.trailingAnchor),
            todayFooterContainer.heightAnchor.constraint(equalToConstant: 18.0)
        ])

        todayFooterContainer.onClick = { [weak self] in
            guard let self = self else { return }
            self.displayedMonth = Date()
            self.refreshCalendar()
        }
        mainStack.addArrangedSubview(todayFooterContainer)
        todayFooterContainer.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true

        applyTheme()
    }

    public func applyTheme(barColors: HyprBarColors = HyprBarColors()) {
        self.currentBarColors = barColors
        let theme = HyprTheme.shared
        let capsuleAlpha = HyprBarWindow.shared?.barView.capsuleAlpha ?? 0.65
        capsuleView.theme = theme
        capsuleView.surfaceAlpha = capsuleAlpha
        capsuleView.updateTheme()

        let resolved = ResolvedColors(theme: theme, barColors: barColors, backgroundAlpha: capsuleAlpha)
        calendarIconLabel.textColor = resolved.accent
        monthYearTitleLabel.textColor = resolved.textPrimary
        prevMonthLabel.textColor = resolved.textPrimary
        todayLabel.textColor = resolved.accent
        nextMonthLabel.textColor = resolved.textPrimary
        topDivider.layer?.backgroundColor = resolved.border.withAlphaComponent(0.20).cgColor
        bottomDivider.layer?.backgroundColor = resolved.border.withAlphaComponent(0.20).cgColor
        todayFooterLabel.textColor = resolved.textSecondary.withAlphaComponent(0.80)

        for subview in weekdayHeaderStack.arrangedSubviews {
            if let tf = subview as? NSTextField {
                tf.textColor = resolved.textSecondary.withAlphaComponent(0.60)
            }
        }

        refreshCalendar()
    }

    public func refreshCalendar() {
        let calendar = Calendar.current
        var noonComponents = calendar.dateComponents([.year, .month], from: displayedMonth)
        noonComponents.hour = 12
        noonComponents.minute = 0
        noonComponents.second = 0
        guard let startOfMonth = calendar.date(from: noonComponents) else { return }

        // Header Title
        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "LLLL yyyy"
        monthYearTitleLabel.stringValue = monthFormatter.string(from: startOfMonth).capitalized

        // Today Footer
        let footerFormatter = DateFormatter()
        footerFormatter.dateFormat = "EEEE, MMMM d, yyyy"
        todayFooterLabel.stringValue = footerFormatter.string(from: Date())

        let capsuleAlpha = HyprBarWindow.shared?.barView.capsuleAlpha ?? 0.65
        let resolved = ResolvedColors(theme: HyprTheme.shared, barColors: currentBarColors, backgroundAlpha: capsuleAlpha)

        let firstWeekday = calendar.firstWeekday
        let weekdayOfFirst = calendar.component(.weekday, from: startOfMonth)
        let leadingDays = (weekdayOfFirst - firstWeekday + 7) % 7

        guard let gridStartDate = calendar.date(byAdding: .day, value: -leadingDays, to: startOfMonth) else { return }

        for i in 0..<42 {
            guard i < cellViews.count,
                  let cellDate = calendar.date(byAdding: .day, value: i, to: gridStartDate) else { continue }
            let cell = cellViews[i]
            let dayNum = calendar.component(.day, from: cellDate)
            cell.label.stringValue = "\(dayNum)"

            let isInMonth = calendar.isDate(cellDate, equalTo: startOfMonth, toGranularity: .month)
            let isToday = calendar.isDateInToday(cellDate)

            if isToday {
                cell.pill.layer?.backgroundColor = resolved.accent.withAlphaComponent(0.25).cgColor
                cell.pill.layer?.borderWidth = 1.0
                cell.pill.layer?.borderColor = resolved.accent.withAlphaComponent(0.60).cgColor
                cell.label.textColor = resolved.accent
                cell.label.font = .barFont(ofSize: 11, weight: .bold, monospacedDigits: true)
            } else if isInMonth {
                cell.pill.layer?.backgroundColor = NSColor.clear.cgColor
                cell.pill.layer?.borderWidth = 0.0
                cell.label.textColor = resolved.textPrimary.withAlphaComponent(0.85)
                cell.label.font = .barFont(ofSize: 11, weight: .medium, monospacedDigits: true)
            } else {
                cell.pill.layer?.backgroundColor = NSColor.clear.cgColor
                cell.pill.layer?.borderWidth = 0.0
                cell.label.textColor = resolved.textSecondary.withAlphaComponent(0.25)
                cell.label.font = .barFont(ofSize: 11, weight: .regular, monospacedDigits: true)
            }

            cell.pill.onClick = { [weak self] in
                guard let self = self else { return }
                if !isInMonth {
                    self.displayedMonth = cellDate
                    self.refreshCalendar()
                }
            }
        }
    }

    public func showPopover(animate: Bool = true) {
        guard !isOpen else { return }
        isOpen = true

        displayedMonth = Date()
        refreshCalendar()

        if animate {
            alphaValue = 0.0
            orderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                animator().alphaValue = 1.0
            }
        } else {
            alphaValue = 1.0
            orderFront(nil)
        }

        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, self.isOpen else { return event }
            if let clickWindow = event.window, clickWindow === self {
                return event
            }
            if let clickWindow = event.window, clickWindow is HyprBarWindow {
                let ptInBar = clickWindow.contentView?.convert(event.locationInWindow, from: nil) ?? .zero
                if let bar = clickWindow.contentView as? BarView ?? (clickWindow as? HyprBarWindow)?.barView {
                    let ptInPill = bar.clockContainer.convert(ptInBar, from: bar)
                    if bar.clockContainer.bounds.contains(ptInPill) {
                        return event
                    }
                }
                self.dismissPopover()
                return event
            }
            self.dismissPopover()
            return event
        }

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.dismissPopover()
            }
        }
    }

    public func dismissPopover(animate: Bool = true) {
        guard isOpen else { return }
        isOpen = false

        if let mon = outsideClickMonitor {
            NSEvent.removeMonitor(mon)
            outsideClickMonitor = nil
        }
        if let gmon = globalClickMonitor {
            NSEvent.removeMonitor(gmon)
            globalClickMonitor = nil
        }

        onClose?()

        if animate {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                animator().alphaValue = 0.0
            }, completionHandler: { [weak self] in
                Task { @MainActor in
                    self?.orderOut(nil)
                }
            })
        } else {
            alphaValue = 0.0
            orderOut(nil)
        }
    }

    deinit {
        MainActor.assumeIsolated {
            if let mon = self.outsideClickMonitor {
                NSEvent.removeMonitor(mon)
            }
            if let gmon = self.globalClickMonitor {
                NSEvent.removeMonitor(gmon)
            }
        }
    }
}
