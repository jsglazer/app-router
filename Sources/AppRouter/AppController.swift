import AppKit
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
    private let configURL: URL
    private var reloader: ConfigReloader?
    private var statusItem: NSStatusItem?
    private var activePanel: PopupPanel?

    public init(
        store: ConfigStore,
        configURL: URL,
        launcher: AppLauncher = SystemAppLauncher(),
        registry: HandlerRegistry = SystemHandlerRegistry()
    ) {
        self.store = store
        self.configURL = configURL
        self.launcher = launcher
        self.registry = registry
    }

    // MARK: - Lifecycle

    public func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        startHotReload()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "⇄"
        let menu = NSMenu()
        menu.addItem(withTitle: "app-router", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Reveal Config in Finder", action: #selector(revealConfig), keyEquivalent: "")
        menu.addItem(withTitle: "Register as Default Handler…", action: #selector(registerDefaults), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
    }

    private func startHotReload() {
        let watcher = FSFileWatcher(url: configURL)
        let source = FileConfigSource(url: configURL)
        let reloader = ConfigReloader(store: store, source: source, watcher: watcher) { result in
            if case .rejected(let error) = result {
                DispatchQueue.main.async { Self.notifyReloadFailure(error) }
            }
        }
        reloader.begin()
        self.reloader = reloader
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
        let engine = RoutingEngine(config: store.current)
        switch engine.resolve(raw) {
        case .none:
            NSSound.beep()
        case .fallback(let target, _), .single(let target, _):
            launch(target, input: raw)
        case .multiple(let targets, _):
            presentPopup(targets: targets, input: raw)
        }
    }

    private func launch(_ target: TargetConfig, input: String) {
        let argv = TargetResolver.argv(for: target, input: input)
        do {
            try launcher.launch(argv: argv)
        } catch {
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

    // MARK: - Menu actions

    @objc private func revealConfig() {
        NSWorkspace.shared.activateFileViewerSelecting([configURL])
    }

    /// Explicit, idempotent default-handler registration (Decision 2). Checks the
    /// current default and skips types already pointing at app-router to minimise the
    /// non-bypassable system prompts.
    @objc private func registerDefaults() {
        let bundleID = Bundle.main.bundleIdentifier
        let utis = declaredUTIs()
        let schemes = declaredSchemes()

        for uti in utis where registry.currentDefaultHandler(forUTI: uti) != bundleID {
            try? registry.setDefaultHandler(forUTI: uti)
        }
        for scheme in schemes where registry.currentDefaultHandler(forScheme: scheme) != bundleID {
            try? registry.setDefaultHandler(forScheme: scheme)
        }
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

    @MainActor
    private static func notifyReloadFailure(_ error: ConfigError) {
        let alert = NSAlert()
        alert.messageText = "Config not reloaded"
        alert.informativeText = "The previous configuration is still active.\n\n\(error.message)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
