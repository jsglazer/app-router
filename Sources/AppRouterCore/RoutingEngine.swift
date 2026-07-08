import Foundation

/// A classified router input.
public enum RouteInput: Equatable, Sendable {
    /// A URL string (had a `scheme://` prefix).
    case url(String)
    /// A filesystem path with its lowercased extension (may be empty).
    case file(path: String, ext: String)
}

/// The outcome of resolving an input against the config, following the match-count
/// policy in Developer Decision 6.
public enum RouteResolution: Equatable, Sendable {
    /// Zero matches and no configured fallback → surfaced no-route error.
    case none(RouteInput)
    /// Zero matches, resolved to the configured `default` fallback.
    case fallback(TargetConfig, RouteInput)
    /// Exactly one match → open immediately, no popup.
    case single(TargetConfig, RouteInput)
    /// Two or more matches → show the cursor-aligned popup selector.
    case multiple([TargetConfig], RouteInput)
}

/// The pure routing engine. Classifies an input, gathers candidate targets, and applies
/// the 0 / 1 / ≥2 match-count policy. No AppKit, no I/O — 100% headlessly testable, and
/// the same code path backs both the GUI and the `--route` CLI harness.
public struct RoutingEngine: Sendable {
    public let config: RouterConfig

    private let extensionLookup: [String: [TargetConfig]]

    public init(config: RouterConfig) {
        self.config = config
        // Normalise extension keys to lowercase once for case-insensitive lookup.
        var lookup: [String: [TargetConfig]] = [:]
        for (ext, targets) in config.extensions {
            lookup[ext.lowercased()] = targets
        }
        self.extensionLookup = lookup
    }

    /// Classifies a raw argument as a URL (has a `scheme://` prefix) or a file path.
    public func classify(_ raw: String) -> RouteInput {
        if Self.hasURLScheme(raw) {
            return .url(raw)
        }
        return .file(path: raw, ext: Self.pathExtension(of: raw))
    }

    /// Resolves a raw input string to a `RouteResolution`.
    public func resolve(_ raw: String) -> RouteResolution {
        let input = classify(raw)
        let matches = candidates(for: input)

        switch matches.count {
        case 0:
            if let fallback = config.default {
                return .fallback(fallback, input)
            }
            return .none(input)
        case 1:
            return .single(matches[0], input)
        default:
            return .multiple(matches, input)
        }
    }

    /// Gathers candidate targets for an already-classified input, preserving config
    /// order and dropping later duplicates.
    public func candidates(for input: RouteInput) -> [TargetConfig] {
        switch input {
        case .url(let urlString):
            var collected: [TargetConfig] = []
            for rule in config.urls where Self.regexMatches(rule.match, urlString) {
                collected.append(contentsOf: rule.targets)
            }
            return dedupe(collected)
        case .file(_, let ext):
            let targets = extensionLookup[ext.lowercased()] ?? []
            return dedupe(targets)
        }
    }

    // MARK: - Helpers

    private func dedupe(_ targets: [TargetConfig]) -> [TargetConfig] {
        var seen: [TargetConfig] = []
        for target in targets where !seen.contains(target) {
            seen.append(target)
        }
        return seen
    }

    /// True when `raw` begins with a URL scheme followed by `://` (e.g. `https://`,
    /// `file://`, `obsidian://`). File paths never contain `://`, so this keeps
    /// classification deterministic and unambiguous.
    static func hasURLScheme(_ raw: String) -> Bool {
        guard let colonSlashSlash = raw.range(of: "://") else { return false }
        let scheme = raw[raw.startIndex..<colonSlashSlash.lowerBound]
        guard let first = scheme.first, first.isLetter else { return false }
        return scheme.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }
    }

    /// Extracts the lowercased extension from a path using pure string scanning (no
    /// Foundation path APIs) so behaviour is identical on every host.
    static func pathExtension(of path: String) -> String {
        let lastComponent = path.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? path
        guard let dotIndex = lastComponent.lastIndex(of: "."),
              dotIndex != lastComponent.startIndex else {
            return ""
        }
        let ext = lastComponent[lastComponent.index(after: dotIndex)...]
        return ext.lowercased()
    }

    static func regexMatches(_ pattern: String, _ input: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return regex.firstMatch(in: input, options: [], range: range) != nil
    }
}
