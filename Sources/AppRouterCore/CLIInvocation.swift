import Foundation

/// The three distinct outcomes of parsing argv (audit H3). Keeping "no flags → GUI" and
/// "malformed usage → error" separate is what stops a one-character typo in a CLI flag
/// from silently launching a resident menu-bar process that writes files and auto-opens
/// stray arguments.
public enum CLIParse: Equatable {
    /// Launch the menu-bar GUI. Carries an optional `--config` override (audit L3): a bare
    /// `app-router --config <path>` with no mode flag now runs the GUI against that file
    /// instead of ignoring the flag.
    case gui(configPath: String?)
    /// Run a headless CLI mode and exit.
    case cli(CLIInvocation)
    /// Malformed usage. Carries a usage message; the entry point prints it to stderr and
    /// exits 64 (`EX_USAGE`) — it must never fall through to the GUI.
    case error(String)
}

/// A parsed headless CLI invocation (`--route`, `--validate`, `--help`), plus an optional
/// `--config` override. Lives in `AppRouterCore` (no AppKit dependency) so the parser can
/// be unit-tested — exactly where the H3 bugs lived when it was buried in the executable.
public struct CLIInvocation: Equatable {
    public enum Mode: Equatable {
        case route(String)   // --route / --test-url <input>
        case validate        // --validate
        case help            // --help
    }
    public let mode: Mode
    public let configPath: String?

    public init(mode: Mode, configPath: String?) {
        self.mode = mode
        self.configPath = configPath
    }

    /// Parses argv (already dropping the executable path) into one of three outcomes.
    ///
    /// Rules:
    /// - Empty argv, or argv consisting only of Finder-injected process-serial-number
    ///   arguments (`-psn_…`), → `.gui`.
    /// - Any token starting with `--` that isn't a recognized flag → `.error`.
    /// - A flag missing its value, or whose value itself looks like a flag (`--…`), →
    ///   `.error` (so `--route --config x` can't consume `--config` as the route input).
    /// - Any other unexpected positional token → `.error`.
    /// - Otherwise, a recognized mode → `.cli`; only `--config` (or nothing) → `.gui`.
    public static func parse(_ args: [String]) -> CLIParse {
        var mode: Mode?
        var configPath: String?
        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--route", "--test-url":
                guard let value = value(after: i, in: args) else {
                    return .error(usage("\(arg) requires a <url|path> value"))
                }
                mode = .route(value)
                i += 1
            case "--validate":
                mode = .validate
            case "--help", "-h":
                mode = .help
            case "--config":
                guard let value = value(after: i, in: args) else {
                    return .error(usage("--config requires a <path> value"))
                }
                configPath = value
                i += 1
            default:
                if arg.hasPrefix("-psn_") {
                    // Finder passes a process-serial-number argument on some launches;
                    // ignore it and treat the launch as a GUI launch.
                    break
                }
                return .error(usage("unknown argument: \(arg)"))
            }
            i += 1
        }

        if let mode {
            return .cli(CLIInvocation(mode: mode, configPath: configPath))
        }
        return .gui(configPath: configPath)
    }

    /// The value following the flag at `index`, or nil if it's missing or is itself a
    /// `--`-prefixed flag (a missing value that got swallowed by the next flag).
    private static func value(after index: Int, in args: [String]) -> String? {
        let next = index + 1
        guard next < args.count else { return nil }
        let candidate = args[next]
        if candidate.hasPrefix("--") { return nil }
        return candidate
    }

    /// Standard usage text, prefixed with a specific error line.
    public static func usage(_ reason: String) -> String {
        """
        error: \(reason)

        USAGE:
          app-router                         Launch the GUI helper (menu bar).
          app-router --route <url|path>      Print the resolved target(s) without opening.
          app-router --test-url <url|path>   Alias of --route.
          app-router --validate              Validate the config and exit.
          app-router --config <path>         Use an alternate config file.
          app-router --help                  Show this help.
        """
    }
}
