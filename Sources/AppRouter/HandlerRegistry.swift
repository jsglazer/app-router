import Foundation
import AppKit
import UniformTypeIdentifiers
import AppRouterCore

/// Registers app-router as the default handler for file types / URL schemes. Isolated
/// behind a protocol (audit §4) so the `NSWorkspace.setDefaultApplication` calls — which
/// trigger non-bypassable macOS approval prompts — live in exactly one adapter and are
/// mockable in tests. Core logic never touches Launch Services.
///
/// Registration is `async` (audit H2): the previous implementation blocked the main
/// thread on a `DispatchSemaphore` per UTI/scheme while the user decided on a modal
/// prompt (a beachball, and a hard deadlock if the completion fired on the main queue).
public protocol HandlerRegistry: Sendable {
    /// The current default handler bundle identifier for a UTI, if known.
    func currentDefaultHandler(forUTI uti: String) -> String?
    /// The current default handler bundle identifier for a URL scheme, if known.
    func currentDefaultHandler(forScheme scheme: String) -> String?
    /// Registers this app as default for a UTI. May prompt the user.
    func setDefaultHandler(forUTI uti: String) async throws
    /// Registers this app as default for a URL scheme. May prompt the user.
    func setDefaultHandler(forScheme scheme: String) async throws
    /// Hands a UTI back to `bundleID` — the handler that owned it before app-router took
    /// over. Used when the config no longer references a type (Update02), so app-router
    /// relinquishes it instead of remaining the stale default. May prompt the user.
    func restoreDefaultHandler(forUTI uti: String, toBundleID bundleID: String) async throws
    /// Hands a URL scheme back to its prior handler `bundleID`. May prompt the user.
    func restoreDefaultHandler(forScheme scheme: String, toBundleID bundleID: String) async throws
}

/// Production Launch Services adapter. The **only** place in the codebase that calls
/// `NSWorkspace.shared.setDefaultApplication`. Registration is an explicit, idempotent,
/// user-initiated action (Decision 2): callers check `currentDefaultHandler` first and
/// skip types already pointing at app-router to minimise system prompts.
public final class SystemHandlerRegistry: HandlerRegistry, @unchecked Sendable {
    private let workspace = NSWorkspace.shared
    private let selfBundleURL: URL

    public init(selfBundleURL: URL = Bundle.main.bundleURL) {
        self.selfBundleURL = selfBundleURL
    }

    public func currentDefaultHandler(forUTI uti: String) -> String? {
        guard let type = UTType(uti),
              let url = workspace.urlForApplication(toOpen: type) else {
            return nil
        }
        return Bundle(url: url)?.bundleIdentifier
    }

    public func currentDefaultHandler(forScheme scheme: String) -> String? {
        guard let probe = URL(string: "\(scheme)://example"),
              let url = workspace.urlForApplication(toOpen: probe) else {
            return nil
        }
        return Bundle(url: url)?.bundleIdentifier
    }

    public func setDefaultHandler(forUTI uti: String) async throws {
        guard let type = UTType(uti) else {
            throw ConfigError("unknown UTI: \(uti)")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            workspace.setDefaultApplication(at: selfBundleURL, toOpen: type) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    public func setDefaultHandler(forScheme scheme: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            workspace.setDefaultApplication(at: selfBundleURL, toOpenURLsWithScheme: scheme) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    public func restoreDefaultHandler(forUTI uti: String, toBundleID bundleID: String) async throws {
        guard let type = UTType(uti) else {
            throw ConfigError("unknown UTI: \(uti)")
        }
        guard let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID) else {
            throw ConfigError("previous handler \(bundleID) for \(uti) is no longer installed")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            workspace.setDefaultApplication(at: appURL, toOpen: type) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    public func restoreDefaultHandler(forScheme scheme: String, toBundleID bundleID: String) async throws {
        guard let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID) else {
            throw ConfigError("previous handler \(bundleID) for scheme \(scheme) is no longer installed")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            workspace.setDefaultApplication(at: appURL, toOpenURLsWithScheme: scheme) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}
