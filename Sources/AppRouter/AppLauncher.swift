import Foundation
import AppRouterCore

/// Executes a resolved target's argv. This is the sole boundary at which the app
/// actually launches anything — the core only *computes* argv arrays.
public protocol AppLauncher: Sendable {
    /// Launches `argv[0]` with `argv[1...]`. Throws on spawn failure.
    func launch(argv: [String]) throws
}

/// Production launcher: runs the argv via `Process` with **no shell** (Decision 5).
/// `argv[0]` is the executable and every remaining element is a discrete argument, so
/// nothing from the config is ever interpreted by `/bin/sh`.
public struct SystemAppLauncher: AppLauncher {
    public init() {}

    public func launch(argv: [String]) throws {
        guard let executable = argv.first else {
            throw ConfigError("cannot launch: empty argv")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(argv.dropFirst())
        try process.run()
    }
}
