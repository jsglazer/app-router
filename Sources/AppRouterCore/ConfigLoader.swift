import Foundation

/// Turns raw JSONC text into a validated `RouterConfig`: strip comments → decode JSON →
/// validate. Pure (string in, config out); no file or network I/O. This is the atomic
/// unit the hot-reload path uses so a bad edit is rejected as a whole (Decision 4).
public enum ConfigLoader {

    /// Loads and validates config from raw JSONC text.
    /// - Throws: `ConfigError` on comment/JSON/schema problems.
    public static func load(jsonc: String) throws -> RouterConfig {
        let json = JSONCPreprocessor.strip(jsonc)
        let data = Data(json.utf8)

        let decoded: RouterConfig
        do {
            decoded = try JSONDecoder().decode(RouterConfig.self, from: data)
        } catch {
            throw ConfigError("JSON decode failed: \(error.localizedDescription)")
        }

        try ConfigValidator.validate(decoded)
        return decoded
    }
}
