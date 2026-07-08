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
        selfBundleID: String? = Bundle.main.bundleIdentifier
    ) {
        self.store = store
        self.configURL = configURL
        self.startupError = startupError
        self.launcher = launcher
        self.registry = registry
        self.selfBundleID = selfBundleID
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
        }
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

    /// Explicit, idempotent default-handler registration (Decision 2). Runs off the main
    /// thread (audit H2) and records the prior handler for each type (audit C1) so the
    /// `system: true` fallback can later dispatch back to it instead of looping.
    @objc private func registerDefaults() {
        Task {
            let result = await register(utis: declaredUTIs(), schemes: declaredSchemes())
            let summary = "Registered \(result.registered), skipped \(result.skipped), failed \(result.failed)."
            Log.registration.notice("registration complete — \(summary, privacy: .public)")
            showStatus(result.failed > 0 ? "\(result.failed) handler registration(s) failed or were denied." : nil,
                       isError: result.failed > 0)
            presentInfo("Default handler registration", body: summary)
        }
    }

    /// The registration core (audit H2/C1), separated from menu/UI so it can be unit-tested
    /// with a mock registry: skips types already pointing at app-router, records the prior
    /// handler for each type it takes over (so the C1 fallback can dispatch back to it),
    /// persists the recorded state, and reports how many succeeded / were skipped / failed.
    @discardableResult
    func register(utis: [String], schemes: [String]) async -> (registered: Int, skipped: Int, failed: Int) {
        let selfID = selfBundleID
        var state = stateStore.load()
        var registered = 0, skipped = 0, failed = 0

        for uti in utis {
            let current = registry.currentDefaultHandler(forUTI: uti)
            if current == selfID { skipped += 1; continue }
            if let current { state.recordUTI(uti, previous: current) }
            do {
                try await registry.setDefaultHandler(forUTI: uti)
                registered += 1
            } catch {
                failed += 1
                Log.registration.error("UTI \(uti, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        for scheme in schemes {
            let current = registry.currentDefaultHandler(forScheme: scheme)
            if current == selfID { skipped += 1; continue }
            if let current { state.recordScheme(scheme, previous: current) }
            do {
                try await registry.setDefaultHandler(forScheme: scheme)
                registered += 1
            } catch {
                failed += 1
                Log.registration.error("scheme \(scheme, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        stateStore.save(state)
        return (registered, skipped, failed)
    }

    private func declaredUTIs() -> [String] {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]])?
            .compactMap { $0["LSItemContentTypes"] as? [String] }
            .flatMap { $0 } ?? []
    }

    private func declaredSchemes() -> [String] {
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
