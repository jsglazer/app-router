import Foundation
import Testing
@testable import AppRouter

/// The C1 sidecar state that lets `system: true` dispatch to the previous handler.
@Suite struct HandlerStateTests {

    @Test func recordIsFirstWriteWins() {
        var state = HandlerState()
        state.recordScheme("https", previous: "com.apple.Safari")
        state.recordScheme("https", previous: "com.jsglazer.app-router") // must NOT clobber
        state.recordUTI("net.daringfireball.markdown", previous: "com.macromates.textmate")
        state.recordUTI("net.daringfireball.markdown", previous: "com.jsglazer.app-router")

        #expect(state.schemes["https"] == "com.apple.Safari")
        #expect(state.utis["net.daringfireball.markdown"] == "com.macromates.textmate")
    }

    @Test func fileStoreRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-router-test-\(UUID().uuidString)")
            .appendingPathComponent("handler-state.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = FileHandlerStateStore(url: url)
        var state = HandlerState()
        state.recordScheme("http", previous: "com.apple.Safari")
        store.save(state)

        let reloaded = FileHandlerStateStore(url: url).load()
        #expect(reloaded == state)
    }

    @Test func missingFileLoadsEmpty() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).json")
        #expect(FileHandlerStateStore(url: url).load() == HandlerState())
    }
}
