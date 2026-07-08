import Foundation
import Testing
@testable import AppRouter
@testable import AppRouterCore

/// Mock Launch Services registry: records what it was asked to set and can fail selected
/// types to simulate a denied prompt (audit H2/C1).
private final class MockRegistry: HandlerRegistry, @unchecked Sendable {
    var currentUTI: [String: String]
    var currentScheme: [String: String]
    var failUTIs: Set<String>
    private(set) var setUTIs: [String] = []
    private(set) var setSchemes: [String] = []

    init(currentUTI: [String: String] = [:], currentScheme: [String: String] = [:], failUTIs: Set<String> = []) {
        self.currentUTI = currentUTI
        self.currentScheme = currentScheme
        self.failUTIs = failUTIs
    }

    func currentDefaultHandler(forUTI uti: String) -> String? { currentUTI[uti] }
    func currentDefaultHandler(forScheme scheme: String) -> String? { currentScheme[scheme] }
    func setDefaultHandler(forUTI uti: String) async throws {
        if failUTIs.contains(uti) { throw ConfigError("denied") }
        setUTIs.append(uti)
    }
    func setDefaultHandler(forScheme scheme: String) async throws { setSchemes.append(scheme) }
}

private final class MemoryStateStore: HandlerStateStore, @unchecked Sendable {
    var state = HandlerState()
    func load() -> HandlerState { state }
    func save(_ s: HandlerState) { state = s }
}

@MainActor
@Suite struct RegistrationTests {

    private func makeController(registry: MockRegistry, stateStore: MemoryStateStore, selfID: String) -> AppController {
        AppController(
            store: ConfigStore(initial: RouterConfig()),
            configURL: URL(fileURLWithPath: "/tmp/app-router-test/config.jsonc"),
            registry: registry,
            stateStore: stateStore,
            selfBundleID: selfID
        )
    }

    @Test func recordsPreviousHandlerAndRegisters() async {
        let registry = MockRegistry(
            currentUTI: ["net.daringfireball.markdown": "com.macromates.textmate"],
            currentScheme: ["https": "com.apple.Safari"]
        )
        let state = MemoryStateStore()
        let controller = makeController(registry: registry, stateStore: state, selfID: "com.jsglazer.app-router")

        let result = await controller.register(
            utis: ["net.daringfireball.markdown"],
            schemes: ["https"]
        )

        #expect(result.registered == 2)
        #expect(result.skipped == 0)
        #expect(result.failed == 0)
        // The prior handlers were recorded so the C1 fallback can dispatch back to them.
        #expect(state.state.utis["net.daringfireball.markdown"] == "com.macromates.textmate")
        #expect(state.state.schemes["https"] == "com.apple.Safari")
        #expect(registry.setUTIs == ["net.daringfireball.markdown"])
        #expect(registry.setSchemes == ["https"])
    }

    @Test func skipsTypesAlreadyOwnedBySelf() async {
        let selfID = "com.jsglazer.app-router"
        let registry = MockRegistry(currentUTI: ["net.daringfireball.markdown": selfID])
        let state = MemoryStateStore()
        let controller = makeController(registry: registry, stateStore: state, selfID: selfID)

        let result = await controller.register(utis: ["net.daringfireball.markdown"], schemes: [])

        #expect(result.skipped == 1)
        #expect(result.registered == 0)
        // Must NOT record ourselves as the previous handler — that would reintroduce C1.
        #expect(state.state.utis.isEmpty)
        #expect(registry.setUTIs.isEmpty)
    }

    @Test func countsFailuresWithoutStopping() async {
        // Type "a" simulates a denied/failed prompt; "b" must still be attempted.
        let registry = MockRegistry(currentUTI: ["a": "x", "b": "y"], failUTIs: ["a"])
        let state = MemoryStateStore()
        let controller = makeController(registry: registry, stateStore: state, selfID: "self")

        let result = await controller.register(utis: ["a", "b"], schemes: [])

        #expect(result.failed == 1)
        #expect(result.registered == 1)
        #expect(registry.setUTIs == ["b"])
    }
}
