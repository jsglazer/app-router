import Foundation

/// The outcome of a hot-reload attempt.
public enum ReloadResult: Equatable, Sendable {
    /// New config validated and is now current.
    case applied
    /// New config rejected; the last-known-good config was retained (Decision 4).
    case rejected(ConfigError)
}

/// In-memory holder for the active `RouterConfig` with atomic hot-reload semantics
/// (Developer Decision 4): a candidate is fully loaded and validated before it takes
/// effect, and on *any* failure the last-known-good config is kept — the routing table
/// is never partially applied or cleared by a bad edit.
///
/// Thread-safe via an internal lock so a filesystem-watcher callback (which fires off
/// the main thread) can apply a reload while the router reads `current`. Pure otherwise:
/// it performs no I/O — callers hand it raw JSONC text.
public final class ConfigStore: @unchecked Sendable {
    private let lock = NSLock()
    private var _current: RouterConfig

    public init(initial: RouterConfig) {
        self._current = initial
    }

    /// The currently active configuration.
    public var current: RouterConfig {
        lock.withLock { _current }
    }

    /// Validates `rawJSONC` and, only if it loads cleanly, swaps it in as `current`.
    /// On failure the existing config is retained and the error is returned.
    @discardableResult
    public func apply(rawJSONC: String) -> ReloadResult {
        let candidate: RouterConfig
        do {
            candidate = try ConfigLoader.load(jsonc: rawJSONC)
        } catch let error as ConfigError {
            return .rejected(error)
        } catch {
            return .rejected(ConfigError("reload failed: \(error.localizedDescription)"))
        }
        lock.withLock { _current = candidate }
        return .applied
    }
}
