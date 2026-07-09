import AppKit
import UniformTypeIdentifiers
import UserNotifications
import AppRouterCore

/// The GUI shell: wires the pure routing engine to AppKit, hosts the config store +
/// hot-reload, handles incoming open-file / open-URL events, and offers the explicit
/// default-handler registration action.
///
/// It never routes by itself — it asks `RoutingEngine` for a `RouteResolution` and then
/// only *presents* (popup) or *launches* (via `AppLauncher`). All Launch Services access
/// goes through `HandlerRegistry`.
@MainActor
public final class AppController: NSObject, NSApplicationDelegate {

    private let store: ConfigStore
    private let launcher: AppLauncher
    private let registry: HandlerRegistry
    private let stateStore: HandlerStateStore
    private let configURL: URL
    private let startupError: ConfigError?
    /// This app's bundle identifier (injectable for tests, where `Bundle.main` has none).
    private let selfBundleID: String?
    /// The build-time set of document-type UTIs / URL schemes declared in `Info.plist`.
    /// Injectable so reconciliation can be unit-tested without a real app bundle (the test
    /// bundle's `Bundle.main` declares none).
    private let declaredUTIsProvider: @MainActor () -> [String]
    private let declaredSchemesProvider: @MainActor () -> [String]
    private var reloader: ConfigReloader?
    private var statusItem: NSStatusItem?
    private var statusMenuItem: NSMenuItem?
    private var activePanel: PopupPanel?

    public init(
        store: ConfigStore,
        configURL: URL,
        startupError: ConfigError? = nil,
        launcher: AppLauncher = SystemAppLauncher(),
        registry: HandlerRegistry = SystemHandlerRegistry(),
        stateStore: HandlerStateStore? = nil,
        selfBundleID: String? = Bundle.main.bundleIdentifier,
        declaredUTIs: (@MainActor () -> [String])? = nil,
        declaredSchemes: (@MainActor () -> [String])? = nil
    ) {
        self.store = store
        self.configURL = configURL
        self.startupError = startupError
        self.launcher = launcher
        self.registry = registry
        self.selfBundleID = selfBundleID
        self.declaredUTIsProvider = declaredUTIs ?? { Self.infoPlistUTIs() }
        self.declaredSchemesProvider = declaredSchemes ?? { Self.infoPlistSchemes() }
        self.stateStore = stateStore
            ?? FileHandlerStateStore(url: FileHandlerStateStore.defaultURL(configPath: configURL.path))
    }

    // MARK: - Lifecycle

    public func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        startHotReload()
        // Surface a startup config failure once (audit M3): otherwise the menu bar looks
        // normal while every route silently dies against an empty config.
        if let startupError {
            Log.config.error("startup config error: \(startupError.message, privacy: .public)")
            showStatus("Config not loaded: \(startupError.message)", isError: true)
            presentInfo("Config not loaded", body: "app-router started with an empty routing table.\n\n\(startupError.message)")
            return
        }
        // Config-driven registration (Update02): on launch make app-router the default
        // handler for exactly the extensions/schemes the current config uses. Idempotent —
        // types already owned are skipped, so this only prompts for genuinely new types.
        Task { await self.autoReconcileHandlers() }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "⇄"
        let menu = NSMenu()
        let status = NSMenuItem(title: "app-router", action: nil, keyEquivalent: "")
        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Reveal Config in Finder", action: #selector(revealConfig), keyEquivalent: "")
        menu.addItem(withTitle: "Register as Default Handler…", action: #selector(registerDefaults), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
        statusMenuItem = status
    }

    private func startHotReload() {
        let watcher = FSFileWatcher(url: configURL)
        let source = FileConfigSource(url: configURL)
        let reloader = ConfigReloader(store: store, source: source, watcher: watcher) { [weak self] result in
            Task { @MainActor in self?.handleReloadResult(result) }
        }
        reloader.begin()
        self.reloader = reloader
    }

    /// Non-blocking reload feedback (audit M2): a rejected reload updates the menu-bar
    /// state and posts a notification instead of seizing the app with a modal `NSAlert`.
    private func handleReloadResult(_ result: ReloadResult) {
        switch result {
        case .applied:
            Log.config.info("config reloaded successfully")
            showStatus(nil, isError: false)
            // Auto-register on save (Update02): reconcile the OS default handlers to the
            // just-applied config — register newly-added extensions, restore the prior
            // handler for any the config no longer references.
            Task { await self.autoReconcileHandlers() }
        case .rejected(let error):
            Log.config.error("reload rejected: \(error.message, privacy: .public)")
            showStatus("Config not reloaded: \(error.message)", isError: true)
            presentInfo("Config not reloaded", body: "The previous configuration is still active.\n\n\(error.message)")
        }
    }

    // MARK: - Incoming open events

    public func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            route(url.isFileURL ? url.path : url.absoluteString)
        }
    }

    public func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        route(filename)
        return true
    }

    /// The single routing path shared by every incoming event.
    private func route(_ raw: String) {
        switch store.currentEngine.resolve(raw) {
        case .none:
            Log.routing.notice("no route for input: \(raw, privacy: .public)")
            NSSound.beep()
        case .fallback(let target, _), .single(let target, _):
            launch(target, input: raw)
        case .multiple(let targets, _):
            presentPopup(targets: targets, input: raw)
        }
    }

    private func launch(_ target: TargetConfig, input: String) {
        let routeInput = store.currentEngine.classify(input)
        var systemBundleID: String?
        if target.system == true {
            systemBundleID = recordedSystemHandler(for: routeInput)
            // Loop guard (audit C1): if app-router is itself the current default for this
            // type and we have no recorded prior handler, a bare `open` would dispatch
            // straight back to us forever. Refuse with a visible signal instead.
            if systemBundleID == nil, isSelfDefaultHandler(for: routeInput) {
                Log.routing.error("refusing system fallback for \(input, privacy: .public): app-router is the default and no previous handler is recorded")
                showStatus("No prior system handler recorded for this type; not opening to avoid a loop.", isError: true)
                NSSound.beep()
                return
            }
        }

        let argv = TargetResolver.argv(for: target, input: input, systemHandlerBundleID: systemBundleID)
        do {
            try launcher.launch(argv: argv)
            Log.routing.info("launched \"\(target.name, privacy: .public)\" argv: \(argv, privacy: .public)")
        } catch {
            Log.routing.error("launch failed for \"\(target.name, privacy: .public)\": \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    private func presentPopup(targets: [TargetConfig], input: String) {
        let origin = NSEvent.mouseLocation
        let panel = PopupPanel(targets: targets, at: origin) { [weak self] chosen in
            self?.activePanel = nil
            guard let chosen else { return }
            self?.launch(chosen, input: input)
        }
        activePanel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: - C1 system-handler resolution

    /// The bundle id of the handler that owned this input's type *before* app-router
    /// registered itself, recorded at registration time (audit C1).
    private func recordedSystemHandler(for input: RouteInput) -> String? {
        let state = stateStore.load()
        switch input {
        case .url(let urlString):
            guard let scheme = Self.scheme(of: urlString) else { return nil }
            return state.schemes[scheme]
        case .file(_, let ext):
            guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return nil }
            return state.utis[type.identifier]
        }
    }

    /// Whether app-router is currently the registered default handler for this input's
    /// type — the precondition for the C1 loop.
    private func isSelfDefaultHandler(for input: RouteInput) -> Bool {
        guard let selfID = selfBundleID else { return false }
        switch input {
        case .url(let urlString):
            guard let scheme = Self.scheme(of: urlString) else { return false }
            return registry.currentDefaultHandler(forScheme: scheme) == selfID
        case .file(_, let ext):
            guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
            return registry.currentDefaultHandler(forUTI: type.identifier) == selfID
        }
    }

    private static func scheme(of urlString: String) -> String? {
        guard let range = urlString.range(of: "://") else { return nil }
        let scheme = urlString[urlString.startIndex..<range.lowerBound]
        return scheme.isEmpty ? nil : scheme.lowercased()
    }

    // MARK: - Menu actions

    @objc private func revealConfig() {
        NSWorkspace.shared.activateFileViewerSelecting([configURL])
    }

    /// Manual "Register as Default Handler…" menu action. Now config-driven (Update02): it
    /// reconciles the OS default handlers to the *current* config and reports the result,
    /// including any config extensions that fall outside app-router's built-in type set.
    @objc private func registerDefaults() {
        Task {
            let result = await reconcileHandlers(for: store.current)
            var summary = "Registered \(result.registered), restored \(result.restored), failed \(result.failed)."
            if !result.unsupported.isEmpty {
                summary += "\n\nNot in app-router's built-in type set (can't be registered without an app update): "
                    + result.unsupported.sorted().map { ".\($0)" }.joined(separator: ", ") + "."
            }
            Log.registration.notice("registration complete — \(summary, privacy: .public)")
            showStatus(result.failed > 0 ? "\(result.failed) handler change(s) failed or were denied." : nil,
                       isError: result.failed > 0)
            presentInfo("Default handler registration", body: summary)
        }
    }

    /// Fire-and-forget reconcile used by launch and hot-reload. Silent on a clean pass;
    /// only surfaces the non-blocking menu-bar state when something failed or a config
    /// extension can't be registered — auto-registration must never nag with a modal.
    private func autoReconcileHandlers() async {
        let result = await reconcileHandlers(for: store.current)
        if result.registered > 0 || result.restored > 0 {
            Log.registration.notice("auto-reconcile — registered \(result.registered, privacy: .public), restored \(result.restored, privacy: .public)")
        }
        if result.failed > 0 {
            showStatus("\(result.failed) handler change(s) failed or were denied.", isError: true)
        } else if !result.unsupported.isEmpty {
            let list = result.unsupported.sorted().map { ".\($0)" }.joined(separator: ", ")
            showStatus("Not registerable (not in built-in type set): \(list)", isError: true)
        } else {
            showStatus(nil, isError: false)
        }
    }

    // MARK: - Config-driven handler reconciliation (Update02)

    /// UTIs app-router must never claim, even if a config extension resolves to one. These
    /// supertypes match huge swaths of files; declaring/registering them is exactly what
    /// made app-router the handler for every text file (including its own config.jsonc) and
    /// fed the focus-stealing routing loop. This denylist enforces "config extensions,
    /// nothing else" defensively, independent of what Info.plist happens to declare.
    private static let overBroadUTIs: Set<String> = [
        "public.item", "public.content", "public.composite-content",
        "public.data", "public.text", "public.plain-text",
        "public.source-code", "public.script", "public.executable"
    ]

    /// Reconciles OS default handlers to `config` (audit H2/C1, Update02): registers the
    /// extensions/schemes the config uses (recording each prior handler so the C1 fallback
    /// can dispatch back to it), and restores the prior handler for any type app-router
    /// owns that the config no longer references. Skips types already pointing at
    /// app-router. Returns counts plus the config extensions that can't be registered
    /// because they're outside the build-time declared set.
    @discardableResult
    func reconcileHandlers(for config: RouterConfig) async -> (registered: Int, restored: Int, failed: Int, unsupported: [String]) {
        let selfID = selfBundleID
        var state = stateStore.load()
        let (wantUTIs, unsupported) = desiredUTIs(for: config)
        let wantSchemes = desiredSchemes(for: config)
        var registered = 0, restored = 0, failed = 0

        // Take over newly-desired UTIs we don't already own.
        for uti in wantUTIs {
            let current = registry.currentDefaultHandler(forUTI: uti)
            if current == selfID { continue }
            if let current { state.recordUTI(uti, previous: current) }
            do {
                try await registry.setDefaultHandler(forUTI: uti)
                registered += 1
            } catch {
                failed += 1
                Log.registration.error("UTI \(uti, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        // Relinquish UTIs we own but the config no longer references.
        for (uti, previous) in state.utis where !wantUTIs.contains(uti) {
            if registry.currentDefaultHandler(forUTI: uti) == selfID {
                do {
                    try await registry.restoreDefaultHandler(forUTI: uti, toBundleID: previous)
                    restored += 1
                } catch {
                    failed += 1
                    Log.registration.error("restore UTI \(uti, privacy: .public) → \(previous, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            state.utis[uti] = nil
        }
        // Take over newly-desired schemes we don't already own.
        for scheme in wantSchemes {
            let current = registry.currentDefaultHandler(forScheme: scheme)
            if current == selfID { continue }
            if let current { state.recordScheme(scheme, previous: current) }
            do {
                try await registry.setDefaultHandler(forScheme: scheme)
                registered += 1
            } catch {
                failed += 1
                Log.registration.error("scheme \(scheme, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        // Relinquish schemes we own but the config no longer references.
        for (scheme, previous) in state.schemes where !wantSchemes.contains(scheme) {
            if registry.currentDefaultHandler(forScheme: scheme) == selfID {
                do {
                    try await registry.restoreDefaultHandler(forScheme: scheme, toBundleID: previous)
                    restored += 1
                } catch {
                    failed += 1
                    Log.registration.error("restore scheme \(scheme, privacy: .public) → \(previous, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            state.schemes[scheme] = nil
        }

        stateStore.save(state)
        return (registered, restored, failed, unsupported)
    }

    /// The UTIs app-router should own for `config`: each config extension resolved to its
    /// system UTI, kept only when that UTI is build-time declared *and* not over-broad.
    /// Extensions that resolve to no UTI, an undeclared UTI, or an over-broad supertype are
    /// returned as `unsupported` so the shell can tell the user they need an app update.
    private func desiredUTIs(for config: RouterConfig) -> (utis: Set<String>, unsupported: [String]) {
        let declared = Set(declaredUTIsProvider())
        var utis = Set<String>()
        var unsupported: [String] = []
        for ext in config.extensions.keys {
            let key = ext.lowercased()
            guard let uti = UTType(filenameExtension: key)?.identifier,
                  !Self.overBroadUTIs.contains(uti),
                  declared.contains(uti) else {
                unsupported.append(key)
                continue
            }
            utis.insert(uti)
        }
        return (utis, unsupported)
    }

    /// The URL schemes app-router should own for `config`: the declared schemes, but only
    /// when the config actually has URL rules to route. With no `urls`, app-router does not
    /// claim the browser role — matching "default for what the config uses, nothing else."
    private func desiredSchemes(for config: RouterConfig) -> Set<String> {
        config.urls.isEmpty ? [] : Set(declaredSchemesProvider())
    }

    private static func infoPlistUTIs() -> [String] {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]])?
            .compactMap { $0["LSItemContentTypes"] as? [String] }
            .flatMap { $0 } ?? []
    }

    private static func infoPlistSchemes() -> [String] {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])?
            .compactMap { $0["CFBundleURLSchemes"] as? [String] }
            .flatMap { $0 } ?? []
    }

    // MARK: - Non-blocking user feedback

    /// Reflect state in the menu-bar item and its first (info) menu entry. A `nil` message
    /// clears back to the normal, healthy state.
    private func showStatus(_ message: String?, isError: Bool) {
        statusItem?.button?.title = isError ? "⇄⚠︎" : "⇄"
        statusMenuItem?.title = message ?? "app-router"
        statusMenuItem?.toolTip = message
    }

    /// Post a system notification, when possible. `UNUserNotificationCenter` requires a
    /// real app bundle; a bare binary (H1 packaging is deferred) has no bundle identifier
    /// and calling `.current()` would trap — so we degrade to the menu-bar state only.
    private func presentInfo(_ title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            // Re-fetch the singleton here rather than capturing it, to keep this
            // `@Sendable` completion free of non-Sendable captures.
            UNUserNotificationCenter.current()
                .add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
