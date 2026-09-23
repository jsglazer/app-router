import AppKit

/// Launch-location guard (Update 1.0.9): app-router becomes the system default handler for
/// many file types and URL schemes, and Launch Services binds those to whichever registered
/// copy it prefers — so a stray build in `dist/`, a dev folder, a Dropbox backup, or an
/// App-Translocated copy opened straight from the DMG could silently take over routing.
/// The GUI therefore only runs from `/Applications` or `~/Applications`.
///
/// Bypass for testing a dev build (either works):
///   open --env APP_ROUTER_ALLOW_ANY_LOCATION=1 dist/app-router.app
///   defaults write com.jsglazer.app-router AllowAnyLocation -bool YES
enum InstallLocation {

    static let bypassEnvironmentKey = "APP_ROUTER_ALLOW_ANY_LOCATION"
    static let bypassDefaultsKey = "AllowAnyLocation"

    /// The folders app-router may run from.
    static func allowedFolders(home: String) -> [String] {
        ["/Applications", (home as NSString).appendingPathComponent("Applications")]
    }

    /// Whether `bundlePath` sits directly inside one of the allowed folders. Symlinks and
    /// `..` are resolved first so a link into a dev folder can't masquerade as installed.
    static func isAllowed(bundlePath: String, home: String) -> Bool {
        let resolved = (bundlePath as NSString).resolvingSymlinksInPath
        let parent = (resolved as NSString).deletingLastPathComponent
        return allowedFolders(home: home).contains {
            ($0 as NSString).resolvingSymlinksInPath == parent
        }
    }

    /// Runs the guard for the GUI launch. Returns normally when the app may continue;
    /// otherwise hands off to the installed copy (if any) or explains, then exits.
    @MainActor
    static func enforce(bundle: Bundle = .main,
                        environment: [String: String] = ProcessInfo.processInfo.environment) {
        // A bare `swift run` binary has no bundle — that's a developer run, not an install.
        guard bundle.bundleIdentifier != nil, bundle.bundlePath.hasSuffix(".app") else { return }
        if environment[bypassEnvironmentKey] == "1"
            || UserDefaults.standard.bool(forKey: bypassDefaultsKey) { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard !isAllowed(bundlePath: bundle.bundlePath, home: home) else { return }

        let name = (bundle.bundlePath as NSString).lastPathComponent
        let installed = allowedFolders(home: home)
            .map { ($0 as NSString).appendingPathComponent(name) }
            .first { FileManager.default.fileExists(atPath: $0) }

        Log.routing.error("refusing to run from \(bundle.bundlePath, privacy: .public)")
        if let installed {
            // An installed copy exists: switch to it instead of nagging.
            Log.routing.notice("handing off to installed copy at \(installed, privacy: .public)")
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: installed),
                                               configuration: NSWorkspace.OpenConfiguration()) { _, _ in
                exit(0)
            }
            // Backstop in case the completion never fires.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { exit(0) }
            RunLoop.main.run()
        }

        let alert = NSAlert()
        alert.messageText = "Move app-router to Applications"
        alert.informativeText = "app-router only runs from the Applications folder, so a stray copy can't take over as the default app for your files and links.\n\nThis copy is at:\n\(bundle.bundlePath)\n\nDrag app-router into /Applications and open it from there."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Show in Finder")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: bundle.bundlePath)])
        }
        exit(1)
    }
}
