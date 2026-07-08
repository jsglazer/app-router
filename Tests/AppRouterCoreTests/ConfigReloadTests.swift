import Foundation
import Testing
@testable import AppRouterCore

/// Hot-reload via *simulated* filesystem change notifications (deterministic test
/// requirement): a mock `FileWatcher` fires the change closure on demand and a mock
/// `ConfigSource` serves queued documents. Verifies atomic apply + last-known-good
/// retention (Decision 4).

/// Captures the change closure and lets a test fire it synchronously.
private final class MockFileWatcher: FileWatcher, @unchecked Sendable {
    private var handler: (@Sendable () -> Void)?
    private(set) var stopped = false

    func start(onChange: @escaping @Sendable () -> Void) { handler = onChange }
    func stop() { stopped = true }
    /// Simulate a filesystem change notification.
    func fire() { handler?() }
}

/// Thread-safe sink for reload results captured from the `@Sendable` callback.
private final class ResultCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _results: [ReloadResult] = []
    func append(_ result: ReloadResult) { lock.withLock { _results.append(result) } }
    var results: [ReloadResult] { lock.withLock { _results } }
    var first: ReloadResult? { results.first }
}

/// Serves queued JSONC documents; can also throw to simulate a read error.
private final class MockConfigSource: ConfigSource, @unchecked Sendable {
    private var queue: [String]
    private let throwsOnRead: Bool
    init(documents: [String], throwsOnRead: Bool = false) {
        self.queue = documents
        self.throwsOnRead = throwsOnRead
    }
    func read() throws -> String {
        if throwsOnRead { throw ConfigError("simulated read failure") }
        return queue.isEmpty ? "{}" : queue.removeFirst()
    }
}

@Suite struct ConfigReloadTests {

    private let good = #"{ "extensions": { "md": [ { "name": "A", "app": "/A.app" } ] } }"#
    private let good2 = #"{ "extensions": { "txt": [ { "name": "B", "app": "/B.app" } ] } }"#
    private let broken = #"{ "extensions": { "md": [ { "name": "A" } ] } }"# // no primary field

    @Test func validChangeIsApplied() throws {
        let store = ConfigStore(initial: try ConfigLoader.load(jsonc: good))
        let watcher = MockFileWatcher()
        let source = MockConfigSource(documents: [good2])
        let reloader = ConfigReloader(store: store, source: source, watcher: watcher)
        reloader.begin()

        watcher.fire()

        #expect(store.current.extensions["txt"]?.first?.name == "B")
        #expect(store.current.extensions["md"] == nil)
    }

    @Test func invalidChangeRetainsLastKnownGood() throws {
        let initial = try ConfigLoader.load(jsonc: good)
        let store = ConfigStore(initial: initial)
        let watcher = MockFileWatcher()
        let source = MockConfigSource(documents: [broken])

        let collector = ResultCollector()
        let reloader = ConfigReloader(store: store, source: source, watcher: watcher) { collector.append($0) }
        reloader.begin()

        watcher.fire()

        // Config unchanged; last-known-good retained.
        #expect(store.current == initial)
        #expect(store.current.extensions["md"]?.first?.name == "A")
        guard case .rejected = collector.first else {
            Issue.record("expected .rejected result, got \(String(describing: collector.first))"); return
        }
    }

    @Test func recoversAfterBadThenGoodEdit() throws {
        let store = ConfigStore(initial: try ConfigLoader.load(jsonc: good))
        let watcher = MockFileWatcher()
        let source = MockConfigSource(documents: [broken, good2])
        let reloader = ConfigReloader(store: store, source: source, watcher: watcher)
        reloader.begin()

        watcher.fire() // bad — retains good
        #expect(store.current.extensions["md"]?.first?.name == "A")

        watcher.fire() // good2 — applies
        #expect(store.current.extensions["txt"]?.first?.name == "B")
    }

    @Test func readFailureRetainsLastKnownGood() throws {
        let initial = try ConfigLoader.load(jsonc: good)
        let store = ConfigStore(initial: initial)
        let watcher = MockFileWatcher()
        let source = MockConfigSource(documents: [], throwsOnRead: true)

        let collector = ResultCollector()
        let reloader = ConfigReloader(store: store, source: source, watcher: watcher) { collector.append($0) }
        reloader.begin()

        watcher.fire()

        #expect(store.current == initial)
        guard case .rejected = collector.first else {
            Issue.record("expected .rejected on read failure"); return
        }
    }

    @Test func directApplyReturnsResults() throws {
        let store = ConfigStore(initial: try ConfigLoader.load(jsonc: good))
        #expect(store.apply(rawJSONC: good2) == .applied)
        if case .applied = store.apply(rawJSONC: broken) {
            Issue.record("expected rejection for broken config")
        }
        // Still holds good2 after the rejected apply.
        #expect(store.current.extensions["txt"]?.first?.name == "B")
    }

    @Test func stopForwardsToWatcher() throws {
        let store = ConfigStore(initial: try ConfigLoader.load(jsonc: good))
        let watcher = MockFileWatcher()
        let reloader = ConfigReloader(store: store, source: MockConfigSource(documents: []), watcher: watcher)
        reloader.begin()
        reloader.stop()
        #expect(watcher.stopped)
    }
}
