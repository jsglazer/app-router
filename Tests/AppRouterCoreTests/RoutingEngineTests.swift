import Testing
@testable import AppRouterCore

@Suite struct RoutingEngineTests {

    private func engine(_ config: RouterConfig) -> RoutingEngine { RoutingEngine(config: config) }

    // MARK: - Input classification

    @Test func classifiesURLs() {
        let e = engine(RouterConfig())
        #expect(e.classify("https://example.com") == .url("https://example.com"))
        #expect(e.classify("obsidian://open?x=1") == .url("obsidian://open?x=1"))
    }

    @Test func classifiesFilePaths() {
        let e = engine(RouterConfig())
        #expect(e.classify("/Users/x/note.md") == .file(path: "/Users/x/note.md", ext: "md"))
        #expect(e.classify("report.PDF") == .file(path: "report.PDF", ext: "pdf"))
        #expect(e.classify("/no/extension") == .file(path: "/no/extension", ext: ""))
    }

    @Test func dotfileWithoutExtensionHasNoExtension() {
        // A leading-dot filename with no further dot is not an extension (Unix semantics).
        let e = engine(RouterConfig())
        #expect(e.classify("/home/.bashrc") == .file(path: "/home/.bashrc", ext: ""))
        #expect(e.classify("/home/.gitignore") == .file(path: "/home/.gitignore", ext: ""))
        // But a dotfile with a real extension keeps it.
        #expect(e.classify("/home/.config.json") == .file(path: "/home/.config.json", ext: "json"))
    }

    // MARK: - Match-count policy (Decision 6)

    @Test func zeroMatchesNoDefaultIsNone() {
        let result = engine(RouterConfig()).resolve("/x/file.md")
        guard case .none = result else { Issue.record("expected .none, got \(result)"); return }
    }

    @Test func zeroMatchesWithDefaultIsFallback() {
        let config = RouterConfig(default: TargetConfig(name: "System", system: true))
        let result = engine(config).resolve("/x/file.md")
        guard case .fallback(let target, _) = result else {
            Issue.record("expected .fallback, got \(result)"); return
        }
        #expect(target.name == "System")
    }

    @Test func exactlyOneMatchIsSingle() {
        let config = RouterConfig(extensions: ["md": [TargetConfig(name: "mdView", app: "/A.app")]])
        let result = engine(config).resolve("/x/file.md")
        guard case .single(let target, _) = result else {
            Issue.record("expected .single, got \(result)"); return
        }
        #expect(target.name == "mdView")
    }

    @Test func twoOrMoreMatchesIsMultiple() {
        let config = RouterConfig(extensions: ["md": [
            TargetConfig(name: "A", app: "/A.app"),
            TargetConfig(name: "B", app: "/B.app")
        ]])
        let result = engine(config).resolve("/x/file.md")
        guard case .multiple(let targets, _) = result else {
            Issue.record("expected .multiple, got \(result)"); return
        }
        #expect(targets.map(\.name) == ["A", "B"])
    }

    // MARK: - Extension matching

    @Test func extensionMatchIsCaseInsensitive() {
        let config = RouterConfig(extensions: ["md": [TargetConfig(name: "A", app: "/A.app")]])
        let result = engine(config).resolve("/x/FILE.MD")
        guard case .single = result else { Issue.record("expected .single"); return }
    }

    @Test func uppercaseConfigKeyStillMatches() {
        let config = RouterConfig(extensions: ["MD": [TargetConfig(name: "A", app: "/A.app")]])
        let result = engine(config).resolve("/x/file.md")
        guard case .single = result else { Issue.record("expected .single"); return }
    }

    // MARK: - URL matching

    @Test func urlRegexMatchContributesTargets() {
        let config = RouterConfig(urls: [
            URLRule(match: #"github\.com"#, targets: [TargetConfig(name: "Work", browser: "/C.app")])
        ])
        let result = engine(config).resolve("https://github.com/foo")
        guard case .single(let t, _) = result else { Issue.record("expected .single"); return }
        #expect(t.name == "Work")
    }

    @Test func multipleMatchingURLRulesAggregate() {
        let config = RouterConfig(urls: [
            URLRule(match: #"github"#, targets: [TargetConfig(name: "A", browser: "/A.app")]),
            URLRule(match: #"\.com"#, targets: [TargetConfig(name: "B", browser: "/B.app")])
        ])
        let result = engine(config).resolve("https://github.com")
        guard case .multiple(let targets, _) = result else { Issue.record("expected .multiple"); return }
        #expect(targets.map(\.name) == ["A", "B"])
    }

    @Test func duplicateTargetsAreDeduped() {
        let shared = TargetConfig(name: "A", browser: "/A.app")
        let config = RouterConfig(urls: [
            URLRule(match: #"github"#, targets: [shared]),
            URLRule(match: #"\.com"#, targets: [shared])
        ])
        let result = engine(config).resolve("https://github.com")
        guard case .single = result else { Issue.record("expected .single after dedupe"); return }
    }

    @Test func nonMatchingURLFallsThrough() {
        let config = RouterConfig(
            urls: [URLRule(match: #"github\.com"#, targets: [TargetConfig(name: "A", browser: "/A.app")])],
            default: TargetConfig(name: "System", system: true)
        )
        let result = engine(config).resolve("https://example.org")
        guard case .fallback = result else { Issue.record("expected .fallback"); return }
    }
}
