import Foundation

/// Validates a decoded `RouterConfig`. Pure and dependency-free (Developer Decision:
/// pure configuration validation engine). Throws the first `ConfigError` it finds so
/// callers can retain a last-known-good config on failure.
public enum ConfigValidator {

    public static func validate(_ config: RouterConfig) throws {
        for (ext, targets) in config.extensions {
            if ext.isEmpty {
                throw ConfigError("extension key must not be empty")
            }
            if targets.isEmpty {
                throw ConfigError("extension \"\(ext)\" has no targets")
            }
            for target in targets {
                try validate(target: target, context: "extension \"\(ext)\"")
            }
        }

        for (index, rule) in config.urls.enumerated() {
            if rule.match.isEmpty {
                throw ConfigError("url rule #\(index) has an empty match pattern")
            }
            // Reject patterns that will crash the engine at match time.
            if (try? NSRegularExpression(pattern: rule.match)) == nil {
                throw ConfigError("url rule #\(index) has an invalid regex: \(rule.match)")
            }
            if rule.targets.isEmpty {
                throw ConfigError("url rule #\(index) (\(rule.match)) has no targets")
            }
            for target in rule.targets {
                try validate(target: target, context: "url rule #\(index)")
            }
        }

        if let fallback = config.default {
            try validate(target: fallback, context: "default")
        }
    }

    /// A target must name exactly one primary destination and use `profile` only with a
    /// browser.
    private static func validate(target: TargetConfig, context: String) throws {
        if target.name.trimmingCharacters(in: .whitespaces).isEmpty {
            throw ConfigError("\(context): target has an empty name")
        }

        var primaries = 0
        if target.app != nil { primaries += 1 }
        if target.exec != nil { primaries += 1 }
        if target.browser != nil { primaries += 1 }
        if target.system == true { primaries += 1 }

        if primaries == 0 {
            throw ConfigError("\(context): target \"\(target.name)\" must set one of app / exec / browser / system")
        }
        if primaries > 1 {
            throw ConfigError("\(context): target \"\(target.name)\" sets more than one of app/exec/browser/system")
        }

        if target.profile != nil && target.browser == nil {
            throw ConfigError("\(context): target \"\(target.name)\" sets profile without browser")
        }
        if target.args != nil && target.exec == nil {
            throw ConfigError("\(context): target \"\(target.name)\" sets args without exec")
        }

        // Executable/bundle paths must be absolute (audit L5). A relative path is resolved
        // against the GUI app's working directory (`/`) and fails silently as a beep at
        // launch time; rejecting it here surfaces the problem at reload with a clear error.
        try requireAbsolute(target.app, field: "app", context: context, name: target.name)
        try requireAbsolute(target.exec, field: "exec", context: context, name: target.name)
        try requireAbsolute(target.browser, field: "browser", context: context, name: target.name)
        try requireAbsolute(target.bin, field: "bin", context: context, name: target.name)
    }

    private static func requireAbsolute(_ path: String?, field: String, context: String, name: String) throws {
        guard let path, !path.isEmpty else { return }
        if !path.hasPrefix("/") {
            throw ConfigError("\(context): target \"\(name)\" \(field) path must be absolute (start with \"/\"): \(path)")
        }
    }
}
