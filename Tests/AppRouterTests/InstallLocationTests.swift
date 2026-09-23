import Testing
@testable import AppRouter

/// The launch-location guard (1.0.9): only /Applications and ~/Applications are allowed.
@Suite struct InstallLocationTests {
    private let home = "/Users/tester"

    @Test func allowsSystemApplications() {
        #expect(InstallLocation.isAllowed(bundlePath: "/Applications/app-router.app", home: home))
    }

    @Test func allowsUserApplications() {
        #expect(InstallLocation.isAllowed(bundlePath: "/Users/tester/Applications/app-router.app", home: home))
    }

    @Test func refusesDistAndDevFolders() {
        #expect(!InstallLocation.isAllowed(bundlePath: "/Users/tester/Dev/2-Projects/Apps/app-router/dist/app-router.app", home: home))
        #expect(!InstallLocation.isAllowed(bundlePath: "/Users/tester/Dropbox/Backup/app-router.app", home: home))
    }

    @Test func refusesNestedSubfolderOfApplications() {
        #expect(!InstallLocation.isAllowed(bundlePath: "/Applications/Old/app-router.app", home: home))
    }

    @Test func refusesAppTranslocation() {
        #expect(!InstallLocation.isAllowed(bundlePath: "/private/var/folders/xy/abc/T/AppTranslocation/1234/d/app-router.app", home: home))
    }

    @Test func refusesDotDotEscape() {
        #expect(!InstallLocation.isAllowed(bundlePath: "/Applications/../Users/tester/Dev/app-router.app", home: home))
    }
}
