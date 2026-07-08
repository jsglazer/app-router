import Testing
@testable import AppRouterCore

@Suite struct ConfigValidationTests {

    @Test func acceptsWellFormedConfig() throws {
        let jsonc = """
        {
          "extensions": { "md": [ { "name": "mdView", "app": "/Applications/mdView.app" } ] },
          "urls": [ { "match": "github\\\\.com", "targets": [ { "name": "Chrome", "browser": "/Applications/Google Chrome.app", "profile": "Default" } ] } ],
          "default": { "name": "System", "system": true }
        }
        """
        let config = try ConfigLoader.load(jsonc: jsonc)
        #expect(config.extensions["md"]?.first?.name == "mdView")
        #expect(config.urls.first?.match == #"github\.com"#)
        #expect(config.default?.system == true)
    }

    @Test func rejectsTargetWithNoPrimaryField() {
        let config = RouterConfig(extensions: ["md": [TargetConfig(name: "Bad")]])
        #expect(throws: ConfigError.self) { try ConfigValidator.validate(config) }
    }

    @Test func rejectsTargetWithMultiplePrimaryFields() {
        let target = TargetConfig(name: "Bad", app: "/A.app", exec: "/bin/x")
        let config = RouterConfig(extensions: ["md": [target]])
        #expect(throws: ConfigError.self) { try ConfigValidator.validate(config) }
    }

    @Test func rejectsProfileWithoutBrowser() {
        let target = TargetConfig(name: "Bad", app: "/A.app", profile: "Default")
        let config = RouterConfig(extensions: ["md": [target]])
        #expect(throws: ConfigError.self) { try ConfigValidator.validate(config) }
    }

    @Test func rejectsArgsWithoutExec() {
        let target = TargetConfig(name: "Bad", app: "/A.app", args: ["--x"])
        let config = RouterConfig(extensions: ["md": [target]])
        #expect(throws: ConfigError.self) { try ConfigValidator.validate(config) }
    }

    @Test func rejectsEmptyTargetName() {
        let config = RouterConfig(extensions: ["md": [TargetConfig(name: "  ", app: "/A.app")]])
        #expect(throws: ConfigError.self) { try ConfigValidator.validate(config) }
    }

    @Test func rejectsExtensionWithNoTargets() {
        let config = RouterConfig(extensions: ["md": []])
        #expect(throws: ConfigError.self) { try ConfigValidator.validate(config) }
    }

    @Test func rejectsInvalidRegex() {
        let rule = URLRule(match: "(unclosed", targets: [TargetConfig(name: "X", app: "/A.app")])
        let config = RouterConfig(urls: [rule])
        #expect(throws: ConfigError.self) { try ConfigValidator.validate(config) }
    }

    @Test func rejectsMalformedJSON() {
        #expect(throws: ConfigError.self) { try ConfigLoader.load(jsonc: "{ not json ") }
    }

    @Test func acceptsSystemDefaultTarget() throws {
        let config = RouterConfig(default: TargetConfig(name: "System", system: true))
        try ConfigValidator.validate(config)
    }

    // Audit L5: executable/bundle paths must be absolute so a relative path fails at
    // reload (with an error surface) rather than silently beeping at launch.
    @Test func rejectsRelativeAppPath() {
        let config = RouterConfig(extensions: ["md": [TargetConfig(name: "Rel", app: "MyApp.app")]])
        #expect(throws: ConfigError.self) { try ConfigValidator.validate(config) }
    }

    @Test func rejectsRelativeExecPath() {
        let config = RouterConfig(extensions: ["md": [TargetConfig(name: "Rel", exec: "handle")]])
        #expect(throws: ConfigError.self) { try ConfigValidator.validate(config) }
    }

    @Test func rejectsRelativeBinPath() {
        let t = TargetConfig(name: "Rel", browser: "/Applications/Chrome.app", profile: "Default", bin: "chromium")
        #expect(throws: ConfigError.self) { try ConfigValidator.validate(RouterConfig(extensions: ["md": [t]])) }
    }

    @Test func acceptsAbsolutePaths() throws {
        let t = TargetConfig(name: "OK", exec: "/usr/local/bin/handle", args: ["--x"])
        try ConfigValidator.validate(RouterConfig(extensions: ["md": [t]]))
    }

    @Test func missingSectionsDefaultToEmpty() throws {
        let config = try ConfigLoader.load(jsonc: "{}")
        #expect(config.extensions.isEmpty)
        #expect(config.urls.isEmpty)
        #expect(config.default == nil)
    }
}
