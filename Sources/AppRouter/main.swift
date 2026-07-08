import AppKit
import AppRouterCore

// Entry point. Parsing argv yields exactly one of three outcomes (audit H3):
//   .cli   → run the headless harness and exit, never touching AppKit.
//   .error → print usage to stderr and exit 64 (EX_USAGE); a typo'd flag must NOT fall
//            through to launching the GUI.
//   .gui   → launch the menu-bar helper (honoring an optional --config override, L3).

let arguments = Array(CommandLine.arguments.dropFirst())

let guiConfigPath: String?
switch CLIInvocation.parse(arguments) {
case .cli(let invocation):
    exit(CLI.run(invocation, defaultConfigPath: ConfigBootstrap.defaultPath))
case .error(let message):
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(64) // EX_USAGE
case .gui(let configPath):
    guiConfigPath = configPath
}

let configPath = guiConfigPath ?? ConfigBootstrap.defaultPath
let bootstrap = ConfigBootstrap.makeStore(path: configPath)

let app = NSApplication.shared
let controller = AppController(
    store: bootstrap.store,
    configURL: URL(fileURLWithPath: configPath),
    startupError: bootstrap.loadError
)
app.delegate = controller
app.setActivationPolicy(.accessory) // menu-bar helper, no Dock icon
app.run()
