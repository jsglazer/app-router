import AppKit
import Testing
@testable import AppRouter
@testable import AppRouterCore

/// The popup's selection contract (audit M4): `onSelect` must fire exactly once with the
/// winning value. The old code fired twice — `nil` (from the close→resignKey→cancel
/// re-entry) and then the real target — violating the "called with the chosen target, or
/// nil if cancelled" contract.
@MainActor
@Suite struct PopupPanelTests {

    /// Collects callback invocations across the escaping selection closure.
    private final class Collector {
        var values: [TargetConfig?] = []
    }

    private let targets = [
        TargetConfig(name: "A", app: "/A.app"),
        TargetConfig(name: "B", app: "/B.app")
    ]

    @Test func selectionFiresExactlyOnce() {
        _ = NSApplication.shared // ensure AppKit is initialised for panel construction
        let collector = Collector()
        let panel = PopupPanel(targets: targets, at: NSPoint(x: 100, y: 100)) { collector.values.append($0) }

        panel.choose(index: 0)
        panel.cancel() // a second finisher (as resignKey would trigger) must be a no-op

        #expect(collector.values.count == 1)
        #expect(collector.values.first??.name == "A")
    }

    @Test func cancelFiresNilOnce() {
        _ = NSApplication.shared
        let collector = Collector()
        let panel = PopupPanel(targets: targets, at: NSPoint(x: 100, y: 100)) { collector.values.append($0) }

        panel.cancel()
        panel.choose(index: 1) // ignored after cancel

        #expect(collector.values.count == 1)
        #expect(collector.values.first! == nil)
    }
}
