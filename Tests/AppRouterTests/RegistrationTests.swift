import Foundation
import Testing
@testable import AppRouter
@testable import AppRouterCore

/// Mock Launch Services registry: records what it was asked to set / restore and can fail
/// selected types to simulate a denied prompt (audit H2/C1, Update02).
private final class MockRegistry: HandlerRegistry, @unchecked Sendable {
    var currentUTI: [String: String]
    var currentScheme: [String: String]
    var failUTIs: Set<String>
    private(set) var setUTIs: [String] = []
    private(set) var setSchemes: [String] = []
    private(set) var restoredUTIs: [(uti: String, bundle: String)] = []
    private(set) var restoredSchemes: [(scheme: String, bundle: String)] = []

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
    func restoreDefaultHandler(forUTI uti: String, toBundleID bundleID: String) async throws {
        restoredUTIs.append((uti, bundleID))
    }
    func restoreDefaultHandler(forScheme scheme: String, toBundleID bundleID: String) async throws {
        restoredSchemes.append((scheme, bundleID))
    }
}

private final class MemoryStateStore: HandlerStateStore, @unchecked Sendable {
    var state = HandlerState()
    func load() -> HandlerState { state }
    func save(_ s: HandlerState) { state = s }
}

/// The config-driven reconciliation contract (Update02): app-router becomes the default
/// handler for exactly the extensions/schemes the config uses — build-time declared, not
/// over-broad — and relinquishes types the config no longer references.
@MainActor
@Suite struct RegistrationTests {

    // System-declared UTIs that `UTType(filenameExtension:)` resolves deterministically.
    private let jsonUTI = "public.json"
    private let htmlUTI = "public.html"

    private func makeController(
        registry: MockRegistry,
        stateStore: MemoryStateStore,
        selfID: String,
        declaredUTIs: [String] = ["public.json", "public.html", "com.adobe.pdf"],
        declaredSchemes: [String] = ["http", "https"]
    ) -> AppController {
        AppController(
            store: ConfigStore(initial: RouterConfig()),
            configURL: URL(fileURLWithPath: "/tmp/app-router-test/config.jsonc"),
            registry: registry,
            stateStore: stateStore,
            selfBundleID: selfID,
            declaredUTIs: { declaredUTIs },
            declaredSchemes: { declaredSchemes }
        )
    }

    private func config(extensions: [String], urls: Bool = false) -> RouterConfig {
        var ext: [String: [TargetConfig]] = [:]
        for e in extensions { ext[e] = [TargetConfig(name: e, app: "/\(e).app")] }
        let rules = urls ? [URLRule(match: "example\\.com", targets: [TargetConfig(name: "B", browser: "/B.app")])] : []
        return RouterConfig(extensions: ext, urls: rules)
    }

    @Test func registersConfigExtensionAndRecordsPriorHandler() async {
        let registry = MockRegistry(currentUTI: [jsonUTI: "com.macromates.textmate"])
        let state = MemoryStateStore()
        let controller = makeController(registry: registry, stateStore: state, selfID: "com.jsglazer.app-router")

        let result = await controller.reconcileHandlers(for: config(extensions: ["json"]))

        #expect(result.registered == 1)
        #expect(result.restored == 0)
        #expect(result.failed == 0)
        #expect(result.unsupported.isEmpty)
        #expect(registry.setUTIs == [jsonUTI])
        // The prior handler was recorded so the C1 fallback can dispatch back to it.
        #expect(state.state.utis[jsonUTI] == "com.macromates.textmate")
    }

    @Test func skipsTypeAlreadyOwnedBySelf() async {
        let selfID = "com.jsglazer.app-router"
        let registry = MockRegistry(currentUTI: [jsonUTI: selfID])
        let state = MemoryStateStore()
        let controller = makeController(registry: registry, stateStore: state, selfID: selfID)

        let result = await controller.reconcileHandlers(for: config(extensions: ["json"]))

        #expect(result.registered == 0)
        #expect(registry.setUTIs.isEmpty)
        // Must NOT record ourselves as the previous handler — that would reintroduce C1.
        #expect(state.state.utis.isEmpty)
    }

    @Test func restoresPriorHandlerWhenExtensionRemoved() async {
        let selfID = "com.jsglazer.app-router"
        // app-router currently owns .json and recorded TextMate as the prior handler…
        let registry = MockRegistry(currentUTI: [jsonUTI: selfID])
        let state = MemoryStateStore()
        state.state.utis[jsonUTI] = "com.macromates.textmate"
        let controller = makeController(registry: registry, stateStore: state, selfID: selfID)

        // …but the new config no longer references json.
        let result = await controller.reconcileHandlers(for: config(extensions: ["html"]))

        #expect(result.registered == 1)   // html taken over
        #expect(result.restored == 1)     // json handed back
        #expect(registry.restoredUTIs.count == 1)
        #expect(registry.restoredUTIs.first?.uti == jsonUTI)
        #expect(registry.restoredUTIs.first?.bundle == "com.macromates.textmate")
        // The recorded prior for json is cleared; html's prior isn't recorded (had none).
        #expect(state.state.utis[jsonUTI] == nil)
    }

    @Test func reportsUnsupportedExtensionNotInDeclaredSet() async {
        // .png resolves to public.png, which is not in the declared set.
        let registry = MockRegistry()
        let state = MemoryStateStore()
        let controller = makeController(registry: registry, stateStore: state, selfID: "self")

        let result = await controller.reconcileHandlers(for: config(extensions: ["png"]))

        #expect(result.registered == 0)
        #expect(registry.setUTIs.isEmpty)
        #expect(result.unsupported == ["png"])
    }

    @Test func refusesOverBroadUTIEvenIfDeclared() async {
        // .txt → public.plain-text: an over-broad supertype. Even if somehow declared, it
        // must never be claimed (this was the root of the focus-stealing over-capture).
        let registry = MockRegistry()
        let state = MemoryStateStore()
        let controller = makeController(
            registry: registry, stateStore: state, selfID: "self",
            declaredUTIs: ["public.plain-text", "public.json"]
        )

        let result = await controller.reconcileHandlers(for: config(extensions: ["txt"]))

        #expect(registry.setUTIs.isEmpty)
        #expect(result.unsupported == ["txt"])
    }

    @Test func registersSchemesOnlyWhenConfigHasURLRules() async {
        let selfID = "self"
        // With URL rules present, the declared schemes are claimed.
        let withURLs = MockRegistry(currentScheme: ["https": "com.apple.Safari", "http": "com.apple.Safari"])
        let stateA = MemoryStateStore()
        let controllerA = makeController(registry: withURLs, stateStore: stateA, selfID: selfID)
        let a = await controllerA.reconcileHandlers(for: config(extensions: [], urls: true))
        #expect(Set(withURLs.setSchemes) == ["http", "https"])
        #expect(a.registered == 2)

        // With no URL rules, app-router does not claim the browser role.
        let noURLs = MockRegistry(currentScheme: ["https": "com.apple.Safari"])
        let stateB = MemoryStateStore()
        let controllerB = makeController(registry: noURLs, stateStore: stateB, selfID: selfID)
        _ = await controllerB.reconcileHandlers(for: config(extensions: ["json"], urls: false))
        #expect(noURLs.setSchemes.isEmpty)
    }

    @Test func countsFailuresWithoutStopping() async {
        // json fails (denied prompt); html must still be attempted.
        let registry = MockRegistry(currentUTI: [jsonUTI: "x", htmlUTI: "y"], failUTIs: [jsonUTI])
        let state = MemoryStateStore()
        let controller = makeController(registry: registry, stateStore: state, selfID: "self")

        let result = await controller.reconcileHandlers(for: config(extensions: ["json", "html"]))

        #expect(result.failed == 1)
        #expect(result.registered == 1)
        #expect(registry.setUTIs == [htmlUTI])
    }
}
