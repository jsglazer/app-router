import Testing
@testable import AppRouterCore

/// CLI parsing (audit H3). The parser now returns three distinct outcomes so a malformed
/// invocation errors out instead of silently launching the resident GUI. These tests live
/// in the core because `CLIInvocation` was moved here to make them possible.
@Suite struct CLIInvocationTests {

    // MARK: - GUI outcome

    @Test func emptyArgsIsGUI() {
        #expect(CLIInvocation.parse([]) == .gui(configPath: nil))
    }

    @Test func finderProcessSerialNumberArgIsGUI() {
        #expect(CLIInvocation.parse(["-psn_0_12345"]) == .gui(configPath: nil))
    }

    @Test func configOnlyIsGUIWithOverride() {
        // Audit L3: a bare --config now runs the GUI against that file instead of ignoring it.
        #expect(CLIInvocation.parse(["--config", "/tmp/x.jsonc"]) == .gui(configPath: "/tmp/x.jsonc"))
    }

    // MARK: - CLI outcome

    @Test func routeParsesInputAndConfig() {
        let parsed = CLIInvocation.parse(["--route", "https://a.com", "--config", "/c.jsonc"])
        #expect(parsed == .cli(CLIInvocation(mode: .route("https://a.com"), configPath: "/c.jsonc")))
    }

    @Test func testURLIsAliasOfRoute() {
        #expect(CLIInvocation.parse(["--test-url", "x"]) == .cli(CLIInvocation(mode: .route("x"), configPath: nil)))
    }

    @Test func validateAndHelpParse() {
        #expect(CLIInvocation.parse(["--validate"]) == .cli(CLIInvocation(mode: .validate, configPath: nil)))
        #expect(CLIInvocation.parse(["--help"]) == .cli(CLIInvocation(mode: .help, configPath: nil)))
        #expect(CLIInvocation.parse(["-h"]) == .cli(CLIInvocation(mode: .help, configPath: nil)))
    }

    // MARK: - Error outcome (the H3 bugs)

    @Test func typoedFlagIsErrorNotGUI() {
        // The reproduced bug: `--validte` used to fall through to launching the GUI.
        guard case .error = CLIInvocation.parse(["--validte", "--config", "/c.jsonc"]) else {
            Issue.record("expected .error for an unknown flag"); return
        }
    }

    @Test func routeMissingValueIsError() {
        guard case .error = CLIInvocation.parse(["--route"]) else {
            Issue.record("expected .error for --route with no value"); return
        }
    }

    @Test func flagValueThatLooksLikeAFlagIsError() {
        // `--route --config x` must not consume `--config` as the route input.
        guard case .error = CLIInvocation.parse(["--route", "--config", "/c.jsonc"]) else {
            Issue.record("expected .error when a flag value is itself a flag"); return
        }
    }

    @Test func unknownPositionalIsError() {
        guard case .error = CLIInvocation.parse(["gibberish"]) else {
            Issue.record("expected .error for an unrecognized positional argument"); return
        }
    }
}
