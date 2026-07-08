import Foundation
import AppRouterCore

/// Production `FileWatcher` backed by a `DispatchSourceFileSystemObject`. Watches the
/// config file for writes/renames and re-arms across atomic saves (many editors replace
/// the file rather than writing in place, which fires a `.delete`/`.rename` and drops
/// the original file descriptor — so we re-open on those events).
public final class FSFileWatcher: FileWatcher, @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "app-router.filewatcher")
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var onChange: (@Sendable () -> Void)?

    public init(url: URL) {
        self.url = url
    }

    public func start(onChange: @escaping @Sendable () -> Void) {
        queue.async { [weak self] in
            self?.onChange = onChange
            self?.arm()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            self?.teardown()
            self?.onChange = nil
        }
    }

    private func arm() {
        teardown()
        fileDescriptor = open(url.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename, .delete, .extend],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let events = src.data
            self.onChange?()
            // Editors that replace the file invalidate our fd; re-arm on those events.
            if events.contains(.rename) || events.contains(.delete) {
                self.arm()
            }
        }
        src.setCancelHandler { [fd = fileDescriptor] in
            if fd >= 0 { close(fd) }
        }
        source = src
        src.resume()
    }

    private func teardown() {
        source?.cancel()
        source = nil
        fileDescriptor = -1
    }
}
