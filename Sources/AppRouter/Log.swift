import Foundation
import os

/// Unified-logging channels for the shell (audit L4). Before this, no-route, spawn
/// failure, and registration failure all surfaced as an indistinguishable `NSSound.beep()`
/// or nothing — there was no way for a user to debug "clicked a link, nothing happened."
/// View with: `log stream --predicate 'subsystem == "com.jsglazer.app-router"'`.
enum Log {
    private static let subsystem = "com.jsglazer.app-router"

    /// Route decisions and launch outcomes.
    static let routing = Logger(subsystem: subsystem, category: "routing")
    /// Config load / hot-reload results.
    static let config = Logger(subsystem: subsystem, category: "config")
    /// Default-handler registration.
    static let registration = Logger(subsystem: subsystem, category: "registration")
}
