import Foundation

/// A single routing target: a GUI app, a shell executable/script, a browser, or a
/// browser + Chrome/Chromium profile, or the macOS system default handler.
///
/// Exactly one *primary* field (`app`, `exec`, `browser`, or `system: true`) must be
/// set; `ConfigValidator` enforces this. Every target resolves to an argv array that is
/// executed via `Process` without a shell (Developer Decision 5), so nothing in the
/// config is ever passed through `/bin/sh -c` or string-interpolated.
public struct TargetConfig: Codable, Equatable, Sendable {
    /// Human-readable label shown in the popup selector.
    public var name: String
    /// Path to a GUI application bundle (opened via `open -a`).
    public var app: String?
    /// Path to a shell executable or script (run directly, never via a shell).
    public var exec: String?
    /// Extra arguments passed to `exec` before the input argument.
    public var args: [String]?
    /// Path to a browser application bundle.
    public var browser: String?
    /// Chrome/Chromium profile directory id (e.g. "Profile 1"); requires `browser`.
    public var profile: String?
    /// Explicit executable path override (for `browser` + `profile` or `exec`).
    public var bin: String?
    /// When true, defer to the macOS system default handler (`open <input>`).
    public var system: Bool?

    public init(
        name: String,
        app: String? = nil,
        exec: String? = nil,
        args: [String]? = nil,
        browser: String? = nil,
        profile: String? = nil,
        bin: String? = nil,
        system: Bool? = nil
    ) {
        self.name = name
        self.app = app
        self.exec = exec
        self.args = args
        self.browser = browser
        self.profile = profile
        self.bin = bin
        self.system = system
    }
}

/// A URL routing rule: a regular expression tested against the full URL string, and the
/// ordered targets that a match contributes.
public struct URLRule: Codable, Equatable, Sendable {
    /// ICU regular expression matched against the input URL (case-insensitive).
    public var match: String
    /// Targets contributed when `match` hits.
    public var targets: [TargetConfig]

    public init(match: String, targets: [TargetConfig]) {
        self.match = match
        self.targets = targets
    }
}

/// The whole router configuration, decoded from the JSONC file.
public struct RouterConfig: Codable, Equatable, Sendable {
    /// Lowercased-extension → ordered candidate targets (e.g. `"md"`).
    public var extensions: [String: [TargetConfig]]
    /// URL rules evaluated top-to-bottom; every matching rule contributes its targets.
    public var urls: [URLRule]
    /// Optional fallback used when nothing matches (Developer Decision 6). A `system`
    /// target defers to the OS default handler; omit for a surfaced no-route error.
    public var `default`: TargetConfig?

    public init(
        extensions: [String: [TargetConfig]] = [:],
        urls: [URLRule] = [],
        default defaultTarget: TargetConfig? = nil
    ) {
        self.extensions = extensions
        self.urls = urls
        self.default = defaultTarget
    }

    private enum CodingKeys: String, CodingKey {
        case extensions, urls, `default`
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.extensions = try c.decodeIfPresent([String: [TargetConfig]].self, forKey: .extensions) ?? [:]
        self.urls = try c.decodeIfPresent([URLRule].self, forKey: .urls) ?? []
        self.default = try c.decodeIfPresent(TargetConfig.self, forKey: .default)
    }
}
