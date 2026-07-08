import Foundation
import AppRouterCore

/// Resolves the config file location and ensures a starter config exists on first run.
public enum ConfigBootstrap {

    /// Result of seeding the store: the (never-nil) store plus an optional error the shell
    /// should surface once at launch (audit M3). Previously both the write and the load
    /// failures were swallowed via `try?`, leaving a silently dead routing table with no
    /// indication why.
    public struct BootstrapResult {
        public let store: ConfigStore
        public let loadError: ConfigError?
    }

    /// Default config path: `~/.config/app-router/config.jsonc`.
    public static var defaultPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("app-router", isDirectory: true)
            .appendingPathComponent("config.jsonc")
            .path
    }

    /// Loads the config at `path`, writing a starter config first if none exists.
    /// Always returns a usable `ConfigStore` (empty config on failure so the app still
    /// runs and hot-reload can recover once the file is fixed) — but now also returns any
    /// error encountered so the caller can tell the user their routing table is dead.
    public static func makeStore(path: String) -> BootstrapResult {
        let url = URL(fileURLWithPath: path)
        if !FileManager.default.fileExists(atPath: path) {
            if let writeError = writeStarterConfig(to: url) {
                return BootstrapResult(store: ConfigStore(initial: RouterConfig()), loadError: writeError)
            }
        }
        let raw: String
        do {
            raw = try String(contentsOf: url, encoding: .utf8)
        } catch {
            return BootstrapResult(
                store: ConfigStore(initial: RouterConfig()),
                loadError: ConfigError("cannot read config at \(path): \(error.localizedDescription)")
            )
        }
        do {
            let config = try ConfigLoader.load(jsonc: raw)
            return BootstrapResult(store: ConfigStore(initial: config), loadError: nil)
        } catch let error as ConfigError {
            return BootstrapResult(store: ConfigStore(initial: RouterConfig()), loadError: error)
        } catch {
            return BootstrapResult(
                store: ConfigStore(initial: RouterConfig()),
                loadError: ConfigError(error.localizedDescription)
            )
        }
    }

    /// Writes the starter config, returning a `ConfigError` if the directory couldn't be
    /// created or the file couldn't be written (audit M3: a read-only `~/.config` used to
    /// yield a silently non-functional app).
    private static func writeStarterConfig(to url: URL) -> ConfigError? {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(starterConfig.utf8).write(to: url)
            return nil
        } catch {
            return ConfigError("could not write starter config to \(url.path): \(error.localizedDescription)")
        }
    }

    static let starterConfig = """
    // app-router configuration (JSONC — comments allowed).
    // Edit and save; the app validates and hot-reloads automatically.
    {
      // File extension -> ordered candidate apps. Two or more => cursor popup.
      "extensions": {
        "md": [
          { "name": "mdView",       "app": "/Applications/mdView.app" },
          { "name": "Sublime Text", "app": "/Applications/Sublime Text.app" },
          { "name": "TextEdit",     "app": "/System/Applications/TextEdit.app" }
        ]
      },
      // URL rules: regex tested against the URL. Every matching rule contributes targets.
      "urls": [
        {
          "match": "github\\\\.com",
          "targets": [
            { "name": "Chrome — Work", "browser": "/Applications/Google Chrome.app", "profile": "Default" }
          ]
        }
      ],
      // Fallback when nothing matches. system:true defers to the macOS default handler.
      "default": { "name": "System Default", "system": true }
    }
    """
}
