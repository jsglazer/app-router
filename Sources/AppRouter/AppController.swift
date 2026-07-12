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
    /// True when this process was launched as a *duplicate* while another app-router was
    /// already resident (Update03). Such an instance routes whatever open event it was
    /// launched for, then terminates — it never installs a second menu-bar item.
    private var isTransientInstance = false

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
        // Single-instance guard (Update03): app-router is a resident menu-bar singleton,
        // but macOS can spawn a *second* copy to deliver an open event — when more than
        // one bundle with this identifier is registered with Launch Services (e.g. a
        // backup copy in Dropbox/iCloud) or the primary copy is App-Translocated out of a
        // quarantined download. A second resident instance leaves a duplicate ⇄ menu-bar
        // icon that never quits. If another instance is already running, treat this launch
        // as transient: skip the status item and hot-reload, route the open event we were
        // launched for, then terminate — leaving the original as the sole handler.
        if hasOtherRunningInstance() {
            isTransientInstance = true
            Log.routing.notice("another app-router instance is running; this launch is transient")
            // Backstop for a bare relaunch that carries no open event: exit once idle.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.finishTransientIfNeeded()
            }
            return
        }
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
        menu.addItem(withTitle: "Validate Config…", action: #selector(validateConfig), keyEquivalent: "")
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
            finishTransientIfNeeded()
        case .fallback(let target, _), .single(let target, _):
            launch(target, input: raw)
            finishTransientIfNeeded()
        case .multiple(let targets, _):
            presentPopup(targets: targets, input: raw)
        }
    }

    private func launch(_ rawTarget: TargetConfig, input: String) {
        // Wildcard expansion (Update04): resolve any glob in the target's path fields to the
        // real bundle on disk *before* the existence check and argv build, so a config like
        // `/Applications/texstudio-*.app` keeps working across version-stamped renames.
        let target = TargetPathExpander.expand(rawTarget)
        // App-not-found error (Update03): surface a mistyped/missing path as a clear
        // message instead of a silent `open` failure. A `system` target has no local path
        // to verify (nil), so it is never blocked here.
        if let path = TargetResolver.primaryExecutablePath(for: target),
           !FileManager.default.fileExists(atPath: path) {
            Log.routing.error("target \"\(target.name, privacy: .public)\" not found at \(path, privacy: .public)")
            showStatus("“\(target.name)” not found at \(path) — check config.jsonc.", isError: true)
            presentInfo("App not found",
                        body: "Can't open with “\(target.name)”.\n\nNothing exists at:\n\(path)\n\nCheck the path in config.jsonc — it may be misspelled.")
            NSSound.beep()
            return
        }

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
            if let chosen { self?.launch(chosen, input: input) }
            self?.finishTransientIfNeeded()
        }
        activePanel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: - Single-instance lifecycle (Update03)

    /// Whether another app-router process (any registered copy, at any path) is already
    /// running. Matching on the bundle identifier catches duplicates launched from a
    /// backup copy or an App-Translocation path, not just the primary in /Applications.
    private func hasOtherRunningInstance() -> Bool {
        guard let selfID = selfBundleID else { return false }
        let current = NSRunningApplication.current
        return NSRunningApplication
            .runningApplications(withBundleIdentifier: selfID)
            .contains { $0 != current }
    }

    /// Terminate a transient instance once it has finished routing (no popup still open).
    /// A no-op for the resident instance and while a selection popup is on screen.
    private func finishTransientIfNeeded() {
        guard isTransientInstance, activePanel == nil else { return }
        Log.routing.notice("transient app-router instance done; terminating")
        NSApp.terminate(nil)
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

    /// "Validate Config…" menu action (Update03): re-reads config.jsonc from disk, runs the
    /// full JSONC → decode → schema-validate pipeline, and additionally checks that every
    /// referenced app/exec/browser path exists on disk. Reports the outcome in a modal
    /// alert (a user-initiated action, so blocking is appropriate — unlike hot-reload).
    @objc private func validateConfig() {
        let result = Self.validateConfigFile(at: configURL)
        presentAlert(title: result.title, body: result.body, style: result.style)
    }

    /// Pure-ish validation summary used by the Validate Config action. Reads the file, then
    /// classifies the outcome as valid, valid-with-missing-paths, or invalid.
    static func validateConfigFile(at url: URL) -> (title: String, body: String, style: NSAlert.Style) {
        let raw: String
        do {
            raw = try String(contentsOf: url, encoding: .utf8)
        } catch {
            return ("Can’t read config", "Couldn’t read \(url.path):\n\n\(error.localizedDescription)", .critical)
        }
        let config: RouterConfig
        do {
            config = try ConfigLoader.load(jsonc: raw)
        } catch let error as ConfigError {
            return ("Config is invalid", "\(error.message)\n\nThe previously loaded config is still active.", .critical)
        } catch {
            return ("Config is invalid", "\(error.localizedDescription)\n\nThe previously loaded config is still active.", .critical)
        }

        let extCount = config.extensions.count
        let urlCount = config.urls.count
        let summary = "\(extCount) extension\(extCount == 1 ? "" : "s"), "
            + "\(urlCount) URL rule\(urlCount == 1 ? "" : "s")"
            + (config.default != nil ? ", plus a default target." : ".")

        let missing = missingTargetPaths(in: config)
        if missing.isEmpty {
            return ("Config is valid ✓",
                    "JSONC parsed and the routing table is valid.\n\n\(summary)\n\nAll referenced apps were found on disk.",
                    .informational)
        }
        let list = missing.map { "•  “\($0.name)” → \($0.path)" }.joined(separator: "\n")
        return ("Config is valid, with warnings",
                "JSONC parsed and the routing table is valid.\n\n\(summary)\n\n"
                    + "⚠️ \(missing.count) referenced path\(missing.count == 1 ? "" : "s") not found on disk:\n\(list)\n\n"
                    + "These targets will report “App not found” until the paths are corrected.",
                .warning)
    }

    /// Every target whose primary app/exec/browser path does not exist on disk.
    private static func missingTargetPaths(in config: RouterConfig) -> [(name: String, path: String)] {
        var missing: [(name: String, path: String)] = []
        func check(_ target: TargetConfig) {
            // Expand wildcards first (Update04) so a pattern that *does* resolve to a real
            // bundle isn't falsely reported as missing.
            let resolved = TargetPathExpander.expand(target)
            if let path = TargetResolver.primaryExecutablePath(for: resolved),
               !FileManager.default.fileExists(atPath: path) {
                missing.append((target.name, path))
            }
        }
        for targets in config.extensions.values { targets.forEach(check) }
        for rule in config.urls { rule.targets.forEach(check) }
        if let fallback = config.default { check(fallback) }
        return missing
    }

    /// Modal alert for user-initiated actions (Validate Config). Activates the accessory
    /// app first so the alert comes to the front.
    private func presentAlert(title: String, body: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = style
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
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
