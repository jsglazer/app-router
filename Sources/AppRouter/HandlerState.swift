import Foundation
import AppRouterCore

/// Persisted record of the default handlers that were in place *before* app-router
/// registered itself (audit C1). When a `system: true` target fires, the shell looks up
/// the prior handler for the input's type here and dispatches to it explicitly
/// (`open -b <bundle-id>`) instead of to `open`, which — once app-router is the default —
/// would resolve straight back to app-router and loop forever.
public struct HandlerState: Codable, Equatable {
    /// URL scheme (e.g. "https") → the bundle id that handled it before app-router.
    public var schemes: [String: String]
    /// UTI (e.g. "net.daringfireball.markdown") → the bundle id that handled it before.
    public var utis: [String: String]

    public init(schemes: [String: String] = [:], utis: [String: String] = [:]) {
        self.schemes = schemes
        self.utis = utis
    }

    /// Records `bundleID` as the previous handler for `scheme`, unless one is already
    /// recorded — the first capture is the genuine pre-app-router handler; later captures
    /// could be app-router itself and would reintroduce the loop.
    public mutating func recordScheme(_ scheme: String, previous bundleID: String) {
        if schemes[scheme] == nil { schemes[scheme] = bundleID }
    }

    /// Records `bundleID` as the previous handler for `uti` (first capture wins).
    public mutating func recordUTI(_ uti: String, previous bundleID: String) {
        if utis[uti] == nil { utis[uti] = bundleID }
    }
}

/// Read/write the `HandlerState`. Abstracted behind a protocol so registration and
/// resolution logic can be unit-tested without touching the real filesystem.
public protocol HandlerStateStore {
    func load() -> HandlerState
    func save(_ state: HandlerState)
}

/// JSON-file-backed store at `~/.config/app-router/handler-state.json` (alongside the
/// config). A missing or unreadable file is treated as empty state.
public final class FileHandlerStateStore: HandlerStateStore {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Default location, next to the config file.
    public static func defaultURL(configPath: String) -> URL {
        URL(fileURLWithPath: configPath)
            .deletingLastPathComponent()
            .appendingPathComponent("handler-state.json")
    }

    public func load() -> HandlerState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(HandlerState.self, from: data) else {
            return HandlerState()
        }
        return state
    }

    public func save(_ state: HandlerState) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: url)
        } catch {
            Log.registration.error("could not persist handler state: \(error.localizedDescription, privacy: .public)")
        }
    }
}
