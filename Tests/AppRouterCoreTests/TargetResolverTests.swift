import Testing
@testable import AppRouterCore

/// argv building (Decision 5): input is always the final discrete argument; no shell.
@Suite struct TargetResolverTests {

    @Test func appTargetUsesOpenDashA() {
        let t = TargetConfig(name: "mdView", app: "/Applications/mdView.app")
        let argv = TargetResolver.argv(for: t, input: "/x/note.md")
        #expect(argv == ["/usr/bin/open", "-a", "/Applications/mdView.app", "/x/note.md"])
    }

    @Test func systemTargetDefersToOpen() {
        let t = TargetConfig(name: "System", system: true)
        let argv = TargetResolver.argv(for: t, input: "https://a.com")
        #expect(argv == ["/usr/bin/open", "https://a.com"])
    }

    @Test func browserWithoutProfileUsesOpenDashA() {
        let t = TargetConfig(name: "Chrome", browser: "/Applications/Google Chrome.app")
        let argv = TargetResolver.argv(for: t, input: "https://a.com")
        #expect(argv == ["/usr/bin/open", "-a", "/Applications/Google Chrome.app", "https://a.com"])
    }

    @Test func browserWithProfileLaunchesExecutableWithProfileFlag() {
        let t = TargetConfig(name: "Chrome Work", browser: "/Applications/Google Chrome.app", profile: "Profile 1")
        let argv = TargetResolver.argv(for: t, input: "https://a.com")
        #expect(argv == [
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "--profile-directory=Profile 1",
            "https://a.com"
        ])
    }

    @Test func browserWithProfileHonoursExplicitBin() {
        let t = TargetConfig(name: "Chromium", browser: "/A.app", profile: "Default", bin: "/custom/chromium")
        let argv = TargetResolver.argv(for: t, input: "https://a.com")
        #expect(argv == ["/custom/chromium", "--profile-directory=Default", "https://a.com"])
    }

    @Test func execTargetPassesArgsThenInput() {
        let t = TargetConfig(name: "Script", exec: "/usr/local/bin/handle", args: ["--flag", "value"])
        let argv = TargetResolver.argv(for: t, input: "/x/note.md")
        #expect(argv == ["/usr/local/bin/handle", "--flag", "value", "/x/note.md"])
    }

    @Test func execTargetWithoutArgsIsExecutableThenInput() {
        let t = TargetConfig(name: "Script", exec: "/bin/handle")
        let argv = TargetResolver.argv(for: t, input: "x")
        #expect(argv == ["/bin/handle", "x"])
    }

    // Injection safety: a malicious-looking input is never split or interpreted; it is a
    // single discrete argv element.
    @Test func inputWithShellMetacharsStaysOneArgument() {
        let t = TargetConfig(name: "mdView", app: "/A.app")
        let nasty = "/x/note.md; rm -rf ~ && echo pwned"
        let argv = TargetResolver.argv(for: t, input: nasty)
        #expect(argv.last == nasty)
        #expect(argv.count == 4)
    }

    @Test func browserExecutablePathDerivation() {
        #expect(
            TargetResolver.browserExecutablePath(forBundle: "/Applications/Google Chrome.app")
            == "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        )
        #expect(
            TargetResolver.browserExecutablePath(forBundle: "/Applications/Brave.app/")
            == "/Applications/Brave.app/Contents/MacOS/Brave"
        )
    }
}
