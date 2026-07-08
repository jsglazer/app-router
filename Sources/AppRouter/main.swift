import AppKit
import AppRouterCore

// Entry point. If a headless flag is present (`--route`, `--test-url`, `--validate`,
// `--help`) run the CLI harness and exit without touching AppKit. Otherwise launch the
// menu-bar GUI helper.

let arguments = Array(CommandLine.arguments.dropFirst())

if let invocation = CLIInvocation(parsing: arguments) {
    let code = CLI.run(invocation, defaultConfigPath: ConfigBootstrap.defaultPath)
    exit(code)
}

let configPath = ConfigBootstrap.defaultPath
let store = ConfigBootstrap.makeStore(path: configPath)

let app = NSApplication.shared
let controller = AppController(store: store, configURL: URL(fileURLWithPath: configPath))
app.delegate = controller
app.setActivationPolicy(.accessory) // menu-bar helper, no Dock icon
app.run()
