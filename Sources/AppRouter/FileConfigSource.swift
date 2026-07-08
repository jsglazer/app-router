import Foundation
import AppRouterCore

/// Reads config JSONC from a file on disk. The filesystem boundary for the core's
/// `ConfigSource` protocol.
public struct FileConfigSource: ConfigSource {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func read() throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }
}
