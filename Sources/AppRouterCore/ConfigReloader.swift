import Foundation

/// Supplies the raw JSONC text of the config (e.g. by reading a file). Abstracted so
/// hot-reload can be unit-tested without touching the filesystem.
public protocol ConfigSource: Sendable {
    func read() throws -> String
}

/// Watches for config changes and invokes a callback. Abstracted behind a protocol so
/// tests can drive reloads with *simulated* filesystem change notifications instead of
/// real `DispatchSource` events.
public protocol FileWatcher: AnyObject {
    func start(onChange: @escaping @Sendable () -> Void)
    func stop()
}

/// Wires a `FileWatcher` to a `ConfigSource` and a `ConfigStore`: on each change it
/// re-reads the source and applies it atomically, keeping last-known-good on failure.
/// Reports every attempt through `onResult` so the shell can surface a non-blocking
/// error (Decision 4) without the core knowing about UI.
public final class ConfigReloader: @unchecked Sendable {
    private let store: ConfigStore
    private let source: ConfigSource
    private let watcher: FileWatcher
    private let onResult: (@Sendable (ReloadResult) -> Void)?

    public init(
        store: ConfigStore,
        source: ConfigSource,
        watcher: FileWatcher,
        onResult: (@Sendable (ReloadResult) -> Void)? = nil
    ) {
        self.store = store
        self.source = source
        self.watcher = watcher
        self.onResult = onResult
    }

    /// Begins watching. Each change triggers a re-read + atomic apply.
    public func begin() {
        watcher.start { [store, source, onResult] in
            let result: ReloadResult
            do {
                result = store.apply(rawJSONC: try source.read())
            } catch {
                result = .rejected(ConfigError("config read failed: \(error.localizedDescription)"))
            }
            onResult?(result)
        }
    }

    public func stop() {
        watcher.stop()
    }
}
