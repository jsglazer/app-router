import Foundation
import AppRouterCore

/// Headless entry point. The `--route` mode is the end-to-end test harness for the
/// routing engine + config validation (Developer Decision 7): it prints the resolved
/// target(s) and their argv **without opening anything or showing the GUI**.
public enum CLI {

    /// Runs the invocation and returns a process exit code.
    public static func run(_ invocation: CLIInvocation, defaultConfigPath: String) -> Int32 {
        switch invocation.mode {
        case .help:
            printHelp()
            return 0
        case .validate:
            return validate(configPath: invocation.configPath ?? defaultConfigPath)
        case .route(let input):
            return route(input, configPath: invocation.configPath ?? defaultConfigPath)
        }
    }

    private static func loadConfig(_ path: String) -> Result<RouterConfig, ConfigError> {
        let raw: String
        do {
            raw = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            return .failure(ConfigError("cannot read config at \(path): \(error.localizedDescription)"))
        }
        do {
            return .success(try ConfigLoader.load(jsonc: raw))
        } catch let error as ConfigError {
            return .failure(error)
        } catch {
            return .failure(ConfigError(error.localizedDescription))
        }
    }

    private static func validate(configPath: String) -> Int32 {
        switch loadConfig(configPath) {
        case .success(let config):
            let extCount = config.extensions.count
            let urlCount = config.urls.count
            print("OK: config valid (\(extCount) extension rule(s), \(urlCount) url rule(s))")
            return 0
        case .failure(let error):
            FileHandle.standardError.write(Data("INVALID: \(error.message)\n".utf8))
            return 1
        }
    }

    private static func route(_ input: String, configPath: String) -> Int32 {
        let config: RouterConfig
        switch loadConfig(configPath) {
        case .success(let loaded):
            config = loaded
        case .failure(let error):
            FileHandle.standardError.write(Data("ERROR: \(error.message)\n".utf8))
            return 1
        }

        let engine = RoutingEngine(config: config)
        let resolution = engine.resolve(input)

        switch resolution {
        case .none(let classified):
            FileHandle.standardError.write(Data("NO ROUTE for \(describe(classified))\n".utf8))
            return 2
        case .fallback(let target, let classified):
            print("FALLBACK for \(describe(classified))")
            printTarget(target, input: input)
            return 0
        case .single(let target, let classified):
            print("SINGLE for \(describe(classified))")
            printTarget(target, input: input)
            return 0
        case .multiple(let targets, let classified):
            print("MULTIPLE (\(targets.count)) for \(describe(classified)) — GUI would show popup")
            for (index, target) in targets.enumerated() {
                print("  [\(index + 1)]")
                printTarget(target, input: input, indent: "    ")
            }
            return 0
        }
    }

    private static func describe(_ input: RouteInput) -> String {
        switch input {
        case .url(let s): return "url \(s)"
        case .file(let path, let ext): return "file \(path) (ext: \(ext.isEmpty ? "<none>" : ext))"
        }
    }

    private static func printTarget(_ target: TargetConfig, input: String, indent: String = "  ") {
        let argv = TargetResolver.argv(for: target, input: input)
        print("\(indent)\(target.name)")
        print("\(indent)argv: \(argv)")
    }

    private static func printHelp() {
        print("""
        app-router — lightweight macOS file/URL router

        USAGE:
          app-router                         Launch the GUI helper (menu bar).
          app-router --route <url|path>      Print the resolved target(s) without opening.
          app-router --test-url <url|path>   Alias of --route.
          app-router --validate              Validate the config and exit.
          app-router --config <path>         Use an alternate config file.
          app-router --help                  Show this help.

        Default config: ~/.config/app-router/config.jsonc
        """)
    }
}
