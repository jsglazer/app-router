import AppKit
import AppRouterCore

/// Cursor-aligned selector shown when two or more targets match (Decision 6). A
/// borderless `NSPanel` subclass with `.nonactivatingPanel` — it takes keyboard focus
/// without stealing app activation, and **all key handling is local** to the panel
/// (overridden `keyDown`/`cancelOperation`). No global accessibility APIs, no `NSEvent`
/// tap monitors (reviewer criterion): the audit's permission-free keyboard requirement.
public final class PopupPanel: NSPanel {

    /// Called with the chosen target, or `nil` if the user cancelled (Escape / focus loss).
    private let onSelect: (TargetConfig?) -> Void
    private let targets: [TargetConfig]
    private var rows: [RowView] = []
    private var highlighted = 0
    /// Guards against the callback firing more than once (audit M4). `choose(index:)`
    /// closes the window, which synchronously triggers `resignKey()` → `cancel()` — a
    /// second `close()` + `onSelect(nil)`. First finisher wins; the rest are no-ops.
    private var didFinish = false

    public init(targets: [TargetConfig], at origin: NSPoint, onSelect: @escaping (TargetConfig?) -> Void) {
        self.targets = targets
        self.onSelect = onSelect

        let rowHeight: CGFloat = 28
        let width: CGFloat = 320
        let height = rowHeight * CGFloat(targets.count) + 8
        let frame = Self.clampedFrame(at: origin, width: width, height: height)

        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // A programmatically created NSPanel defaults to isReleasedWhenClosed = true;
        // combined with the outstanding strong reference the controller holds, a
        // close-triggered release is a classic over-release/UAF (audit M4). Own the
        // lifetime via ARC instead.
        isReleasedWhenClosed = false
        isFloatingPanel = true
        level = .popUpMenu
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        becomesKeyOnlyIfNeeded = false

        buildContent(rowHeight: rowHeight, width: width)
        refreshHighlight()
    }

    /// Places the panel at the cursor but keeps it fully within the cursor's screen
    /// (audit L2): the raw `origin.y - height` can push rows below the Dock or off the
    /// bottom/right edge where they're clipped or invisible.
    private static func clampedFrame(at origin: NSPoint, width: CGFloat, height: CGFloat) -> NSRect {
        var x = origin.x
        var y = origin.y - height
        let screen = NSScreen.screens.first { NSMouseInRect(origin, $0.frame, false) }
            ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            x = min(max(x, visible.minX), visible.maxX - width)
            y = min(max(y, visible.minY), visible.maxY - height)
        }
        return NSRect(x: x, y: y, width: width, height: height)
    }

    public override var canBecomeKey: Bool { true }

    private func buildContent(rowHeight: CGFloat, width: CGFloat) {
        let container = NSVisualEffectView(frame: contentView?.bounds ?? .zero)
        container.autoresizingMask = [.width, .height]
        container.material = .menu
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        container.layer?.masksToBounds = true

        for (index, target) in targets.enumerated() {
            let y = container.bounds.height - rowHeight * CGFloat(index + 1) - 4
            let row = RowView(frame: NSRect(x: 4, y: y, width: width - 8, height: rowHeight))
            row.configure(index: index, label: target.name)
            row.onClick = { [weak self] in self?.choose(index: index) }
            row.onHover = { [weak self] in self?.setHighlight(index) }
            container.addSubview(row)
            rows.append(row)
        }
        contentView = container
    }

    // MARK: - Local keyboard handling (no global monitors)

    public override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: // down arrow
            setHighlight((highlighted + 1) % targets.count)
        case 126: // up arrow
            setHighlight((highlighted - 1 + targets.count) % targets.count)
        case 36, 76: // return / enter
            choose(index: highlighted)
        case 53: // escape
            cancel()
        default:
            // Direct 1–9 selection.
            if let chars = event.charactersIgnoringModifiers,
               let digit = Int(chars), digit >= 1, digit <= targets.count {
                choose(index: digit - 1)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    public override func cancelOperation(_ sender: Any?) {
        cancel()
    }

    public override func resignKey() {
        super.resignKey()
        // Dismiss without selecting if focus is lost.
        cancel()
    }

    // MARK: - Selection

    private func setHighlight(_ index: Int) {
        highlighted = index
        refreshHighlight()
    }

    private func refreshHighlight() {
        for (index, row) in rows.enumerated() {
            row.setHighlighted(index == highlighted)
        }
    }

    func choose(index: Int) {
        guard index >= 0, index < targets.count else { cancel(); return }
        finish(with: targets[index])
    }

    func cancel() {
        finish(with: nil)
    }

    /// Closes the panel and invokes `onSelect` exactly once (audit M4).
    private func finish(with target: TargetConfig?) {
        guard !didFinish else { return }
        didFinish = true
        close()
        onSelect(target)
    }
}

/// A single selectable row: "N. Label", highlightable, clickable, hover-aware.
private final class RowView: NSView {
    var onClick: (() -> Void)?
    var onHover: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 5
        label.frame = bounds.insetBy(dx: 8, dy: 4)
        label.autoresizingMask = [.width, .height]
        label.font = .menuFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(index: Int, label text: String) {
        let prefix = index < 9 ? "\(index + 1).  " : ""
        label.stringValue = "\(prefix)\(text)"
    }

    func setHighlighted(_ on: Bool) {
        layer?.backgroundColor = on ? NSColor.selectedContentBackgroundColor.cgColor : NSColor.clear.cgColor
        label.textColor = on ? .white : .labelColor
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?()
    }
}
