import Foundation
import AppRouterCore

/// Resolves the config file location and ensures a starter config exists on first run.
public enum ConfigBootstrap {

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
    /// Returns a `ConfigStore` seeded with whatever loads (empty config on failure so
    /// the app still runs and the hot-reload path can recover once the file is fixed).
    public static func makeStore(path: String) -> ConfigStore {
        let url = URL(fileURLWithPath: path)
        if !FileManager.default.fileExists(atPath: path) {
            writeStarterConfig(to: url)
        }
        if let raw = try? String(contentsOf: url, encoding: .utf8),
           let config = try? ConfigLoader.load(jsonc: raw) {
            return ConfigStore(initial: config)
        }
        return ConfigStore(initial: RouterConfig())
    }

    private static func writeStarterConfig(to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? Data(starterConfig.utf8).write(to: url)
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
