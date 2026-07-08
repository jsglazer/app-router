import Foundation

/// Resolves a `TargetConfig` into the exact argv array to execute for a given input
/// (a file path or a URL string).
///
/// Developer Decision 5: every target is an argv array run via `Process` with **no
/// shell** — no `/bin/sh -c`, no string interpolation. The input is always the final,
/// discrete argument, so a path or URL can never be re-parsed as shell syntax. This is
/// the mechanism that eliminates config-driven shell injection.
public enum TargetResolver {

    /// Builds the argv for `target` opening `input`.
    ///
    /// Precondition: `target` passed `ConfigValidator` (exactly one primary field). The
    /// precedence below matches the validator's exclusivity so the result is total.
    public static func argv(for target: TargetConfig, input: String) -> [String] {
        if target.system == true {
            // Defer to the macOS default handler.
            return ["/usr/bin/open", input]
        }

        if let browser = target.browser {
            if let profile = target.profile, !profile.isEmpty {
                // Chrome/Chromium profile selection requires launching the executable
                // directly with --profile-directory=<id>.
                let executable = target.bin ?? browserExecutablePath(forBundle: browser)
                return [executable, "--profile-directory=\(profile)", input]
            }
            // Plain browser: let `open` route to the bundle.
            return ["/usr/bin/open", "-a", browser, input]
        }

        if let exec = target.exec {
            let executable = target.bin ?? exec
            return [executable] + (target.args ?? []) + [input]
        }

        if let app = target.app {
            return ["/usr/bin/open", "-a", app, input]
        }

        // Unreachable for a validated target; degrade to the system handler rather than
        // crash.
        return ["/usr/bin/open", input]
    }

    /// Derives the CLI executable inside an app bundle from the bundle path, e.g.
    /// `/Applications/Google Chrome.app` → `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`.
    /// Pure string manipulation (no filesystem probing) to keep the core deterministic.
    static func browserExecutablePath(forBundle bundlePath: String) -> String {
        let trimmed = bundlePath.hasSuffix("/") ? String(bundlePath.dropLast()) : bundlePath
        let lastComponent = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        let baseName = lastComponent.hasSuffix(".app")
            ? String(lastComponent.dropLast(4))
            : lastComponent
        return "\(trimmed)/Contents/MacOS/\(baseName)"
    }
}
