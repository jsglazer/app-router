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

    // Audit C1 regression: when a previous default handler is known, a `system: true`
    // target must dispatch to it explicitly via `open -b`, never bare `open` (which, once
    // app-router is the default handler, would resolve straight back to itself and loop).
    @Test func systemTargetWithRecordedHandlerUsesOpenDashB() {
        let t = TargetConfig(name: "System", system: true)
        let argv = TargetResolver.argv(for: t, input: "https://a.com", systemHandlerBundleID: "com.apple.Safari")
        #expect(argv == ["/usr/bin/open", "-b", "com.apple.Safari", "https://a.com"])
        // Never the dangerous bare-open shape when a handler is supplied.
        #expect(argv != ["/usr/bin/open", "https://a.com"])
    }

    @Test func systemTargetIgnoresEmptyRecordedHandler() {
        let t = TargetConfig(name: "System", system: true)
        let argv = TargetResolver.argv(for: t, input: "https://a.com", systemHandlerBundleID: "")
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

    // Update04: Safari doesn't understand `--profile-directory` and launching its binary
    // directly spawns a fresh copy on every URL. A profile on a Safari target must be
    // ignored and routed via `open -a`, which reuses the running instance.
    @Test func safariWithProfileIgnoresProfileAndUsesOpenDashA() {
        let safari = "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/"
        let t = TargetConfig(name: "Safari", browser: safari, profile: "default")
        let argv = TargetResolver.argv(for: t, input: "https://a.com")
        #expect(argv == ["/usr/bin/open", "-a", safari, "https://a.com"])
        // Never the direct-binary shape that duplicates Safari.
        #expect(!argv.contains("--profile-directory=default"))
    }

    @Test func firefoxWithProfileAlsoUsesOpenDashA() {
        let t = TargetConfig(name: "Firefox", browser: "/Applications/Firefox.app", profile: "dev")
        let argv = TargetResolver.argv(for: t, input: "https://a.com")
        #expect(argv == ["/usr/bin/open", "-a", "/Applications/Firefox.app", "https://a.com"])
    }

    // A Chromium-family browser keeps the direct `--profile-directory` launch.
    @Test func chromeStillUsesProfileDirectoryLaunch() {
        #expect(TargetResolver.supportsProfileDirectory(bundlePath: "/Applications/Google Chrome.app"))
        #expect(!TargetResolver.supportsProfileDirectory(bundlePath: "/Applications/Safari.app/"))
        #expect(!TargetResolver.supportsProfileDirectory(bundlePath: "/Applications/Firefox.app"))
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

    // primaryExecutablePath (Update03): the one path the shell must confirm exists before
    // launching, so a mistyped config path becomes a clear error instead of a silent fail.
    @Test func primaryPathIsNilForSystemTarget() {
        #expect(TargetResolver.primaryExecutablePath(for: TargetConfig(name: "System", system: true)) == nil)
    }

    @Test func primaryPathForAppIsTheBundle() {
        let t = TargetConfig(name: "mdView", app: "/Applications/mdView.app")
        #expect(TargetResolver.primaryExecutablePath(for: t) == "/Applications/mdView.app")
    }

    @Test func primaryPathForExecIsTheExecutable() {
        let t = TargetConfig(name: "Script", exec: "/usr/local/bin/handle", args: ["--flag"])
        #expect(TargetResolver.primaryExecutablePath(for: t) == "/usr/local/bin/handle")
    }

    @Test func primaryPathForBrowserIsTheBundle() {
        let t = TargetConfig(name: "Chrome", browser: "/Applications/Google Chrome.app")
        #expect(TargetResolver.primaryExecutablePath(for: t) == "/Applications/Google Chrome.app")
    }

    @Test func primaryPathHonoursExplicitBinOverBrowserBundle() {
        let t = TargetConfig(name: "Chromium", browser: "/A.app", profile: "Default", bin: "/custom/chromium")
        #expect(TargetResolver.primaryExecutablePath(for: t) == "/custom/chromium")
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
