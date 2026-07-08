import Foundation

/// A configuration problem surfaced by loading or validation. Carries a human-readable
/// message; equatable so tests can assert specific failures.
public struct ConfigError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}
