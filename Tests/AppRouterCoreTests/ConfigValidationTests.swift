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

    @Test func missingSectionsDefaultToEmpty() throws {
        let config = try ConfigLoader.load(jsonc: "{}")
        #expect(config.extensions.isEmpty)
        #expect(config.urls.isEmpty)
        #expect(config.default == nil)
    }
}
