import Foundation
import Testing
@testable import AppRouter
@testable import AppRouterCore

/// Wildcard expansion (Update04): a config path with a glob is resolved to the real bundle
/// on disk at launch, so version-stamped app names (`texstudio-4.9.5-osx-m1.app`) keep
/// routing across updates without re-editing the config.
@Suite struct TargetPathExpanderTests {

    /// A unique temp directory seeded with the given (relative) files/dirs; returns its path.
    private func makeTempDir(_ entries: [String]) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("apr-expander-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for entry in entries {
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent(entry, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        return dir.path
    }

    @Test func nonWildcardPathPassesThrough() {
        #expect(TargetPathExpander.resolve("/Applications/mdView.app") == "/Applications/mdView.app")
        #expect(!TargetPathExpander.isWildcard("/Applications/mdView.app"))
        #expect(TargetPathExpander.isWildcard("/Applications/texstudio-*.app"))
    }

    @Test func wildcardResolvesToMatchingBundle() throws {
        let dir = try makeTempDir(["texstudio-4.9.5-osx-m1.app"])
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let resolved = TargetPathExpander.resolve("\(dir)/texstudio-*.app")
        #expect(resolved == "\(dir)/texstudio-4.9.5-osx-m1.app")
    }

    @Test func unmatchedWildcardKeepsPatternForNotFoundReporting() throws {
        let dir = try makeTempDir([])
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let pattern = "\(dir)/texstudio-*.app"
        #expect(TargetPathExpander.resolve(pattern) == pattern)
    }

    @Test func multipleMatchesPickNewestByModification() throws {
        let dir = try makeTempDir(["texstudio-4.9.5-osx-m1.app", "texstudio-4.9.6-osx-m1.app"])
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // Make the .6 bundle the most recently modified regardless of enumeration order.
        let newer = "\(dir)/texstudio-4.9.6-osx-m1.app"
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: newer)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)],
            ofItemAtPath: "\(dir)/texstudio-4.9.5-osx-m1.app"
        )
        #expect(TargetPathExpander.resolve("\(dir)/texstudio-*.app") == newer)
    }

    @Test func expandResolvesAppFieldWithinTarget() throws {
        let dir = try makeTempDir(["texstudio-4.9.5-osx-m1.app"])
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let target = TargetConfig(name: "Tex Studio", app: "\(dir)/texstudio-*.app")
        let resolved = TargetPathExpander.expand(target)
        #expect(resolved.app == "\(dir)/texstudio-4.9.5-osx-m1.app")
        // The resolved target produces a concrete argv.
        #expect(TargetResolver.argv(for: resolved, input: "/x/paper.tex")
            == ["/usr/bin/open", "-a", "\(dir)/texstudio-4.9.5-osx-m1.app", "/x/paper.tex"])
    }

    @Test func expandLeavesNonPathFieldsUntouched() {
        let target = TargetConfig(name: "System", system: true)
        #expect(TargetPathExpander.expand(target) == target)
    }
}
