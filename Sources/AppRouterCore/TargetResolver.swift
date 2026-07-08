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
    ///
    /// `systemHandlerBundleID` resolves the self-routing loop (audit C1): once app-router
    /// registers itself as the default handler, a bare `open <input>` for a `system: true`
    /// target asks Launch Services for the default handler — which is now app-router — and
    /// loops forever. The shell records the *previous* default handler per type at
    /// registration time and passes its bundle id here, so `system: true` dispatches to
    /// `open -b <previous-handler>` and never back to itself. When nil (app-router is not a
    /// default handler, or no prior handler was recorded) the bare `open` is safe.
    public static func argv(
        for target: TargetConfig,
        input: String,
        systemHandlerBundleID: String? = nil
    ) -> [String] {
        if target.system == true {
            return systemArgv(input: input, bundleID: systemHandlerBundleID)
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
        return systemArgv(input: input, bundleID: systemHandlerBundleID)
    }

    /// argv for deferring to the macOS default handler. With a recorded previous-handler
    /// bundle id, dispatch explicitly to it (`open -b`) so app-router never re-dispatches
    /// to itself; otherwise fall back to a bare `open`.
    private static func systemArgv(input: String, bundleID: String?) -> [String] {
        if let bundleID, !bundleID.isEmpty {
            return ["/usr/bin/open", "-b", bundleID, input]
        }
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
