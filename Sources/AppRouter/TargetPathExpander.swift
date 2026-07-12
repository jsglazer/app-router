import Foundation
import AppRouterCore

/// Expands shell-style wildcards (`*`, `?`, `[…]`) in a target's filesystem path fields to
/// the concrete bundle/executable currently on disk.
///
/// Update04: apps whose bundle name embeds a fast-moving version — `texstudio-4.9.5-osx-m1.app`
/// — break the config on every update. A pattern like `/Applications/texstudio-*.app` keeps
/// routing working across versions: at launch the pattern is resolved against the filesystem,
/// so the config never has to be re-edited when the app updates.
///
/// Resolution lives in the shell rather than the pure core because it must touch the
/// filesystem. When a pattern matches nothing the original pattern is returned unchanged, so
/// the existing "App not found" path surfaces a clear error instead of launching garbage.
public enum TargetPathExpander {

    /// Returns a copy of `target` with any wildcard in `app`, `exec`, `browser`, or `bin`
    /// resolved to a real path. Non-wildcard values pass through untouched.
    public static func expand(_ target: TargetConfig) -> TargetConfig {
        var resolved = target
        resolved.app = target.app.map(resolve)
        resolved.exec = target.exec.map(resolve)
        resolved.browser = target.browser.map(resolve)
        resolved.bin = target.bin.map(resolve)
        return resolved
    }

    /// True when `path` contains a glob metacharacter worth expanding.
    static func isWildcard(_ path: String) -> Bool {
        path.contains("*") || path.contains("?") || path.contains("[")
    }

    /// Resolves a single path. A non-wildcard path is returned verbatim. A wildcard is
    /// expanded against the filesystem; when several paths match (e.g. an old and a new
    /// version both present) the most recently modified wins — that is the version left in
    /// place by the latest install. With no match the pattern is returned unchanged so the
    /// caller's not-found handling can report it.
    static func resolve(_ path: String) -> String {
        guard isWildcard(path) else { return path }
        let matches = matchingPaths(path)
        guard !matches.isEmpty else { return path }
        return newestByModification(matches) ?? matches[0]
    }

    /// POSIX `glob(3)` wrapper: the existing paths matching `pattern`, or `[]` on no match
    /// or error. `GLOB_TILDE` expands a leading `~`.
    static func matchingPaths(_ pattern: String) -> [String] {
        var g = glob_t()
        defer { globfree(&g) }
        guard glob(pattern, GLOB_TILDE, nil, &g) == 0, let pathv = g.gl_pathv else { return [] }
        var results: [String] = []
        for i in 0..<Int(g.gl_pathc) where pathv[i] != nil {
            results.append(String(cString: pathv[i]!))
        }
        return results
    }

    private static func newestByModification(_ paths: [String]) -> String? {
        paths.max { modificationDate($0) < modificationDate($1) }
    }

    private static func modificationDate(_ path: String) -> Date {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.modificationDate] as? Date) ?? .distantPast
    }
}
