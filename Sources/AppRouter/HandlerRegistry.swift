import Foundation
import AppKit
import UniformTypeIdentifiers
import AppRouterCore

/// Sendable box so a completion handler running off-thread can hand a result back to the
/// waiting synchronous caller without tripping strict-concurrency capture diagnostics.
private final class ResultBox: @unchecked Sendable {
    var error: Error?
}

/// Registers app-router as the default handler for file types / URL schemes. Isolated
/// behind a protocol (audit §4) so the `NSWorkspace.setDefaultApplication` calls — which
/// trigger non-bypassable macOS approval prompts — live in exactly one adapter and are
/// mockable in tests. Core logic never touches Launch Services.
public protocol HandlerRegistry {
    /// The current default handler bundle identifier for a UTI, if known.
    func currentDefaultHandler(forUTI uti: String) -> String?
    /// The current default handler bundle identifier for a URL scheme, if known.
    func currentDefaultHandler(forScheme scheme: String) -> String?
    /// Registers this app as default for a UTI. May prompt the user.
    func setDefaultHandler(forUTI uti: String) throws
    /// Registers this app as default for a URL scheme. May prompt the user.
    func setDefaultHandler(forScheme scheme: String) throws
}

/// Production Launch Services adapter. The **only** place in the codebase that calls
/// `NSWorkspace.shared.setDefaultApplication`. Registration is an explicit, idempotent,
/// user-initiated action (Decision 2): callers check `currentDefaultHandler` first and
/// skip types already pointing at app-router to minimise system prompts.
public final class SystemHandlerRegistry: HandlerRegistry {
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

    public func setDefaultHandler(forUTI uti: String) throws {
        guard let type = UTType(uti) else {
            throw ConfigError("unknown UTI: \(uti)")
        }
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        workspace.setDefaultApplication(at: selfBundleURL, toOpen: type) { error in
            box.error = error
            semaphore.signal()
        }
        semaphore.wait()
        if let error = box.error { throw error }
    }

    public func setDefaultHandler(forScheme scheme: String) throws {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        workspace.setDefaultApplication(at: selfBundleURL, toOpenURLsWithScheme: scheme) { error in
            box.error = error
            semaphore.signal()
        }
        semaphore.wait()
        if let error = box.error { throw error }
    }
}
