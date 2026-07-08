import Foundation
import AppRouterCore

/// Production `FileWatcher` backed by a `DispatchSourceFileSystemObject`.
///
/// Editors save in ways that swap the file out from under an open descriptor — atomic
/// (write temp → rename over target) or vim-style (rename original → write new). The
/// naive "on rename/delete, call onChange then re-open" approach has two audited failures
/// (M1): in the brief window where the target doesn't exist yet, `open()` fails and the
/// watcher dies *permanently*; and a single logical save fires several events, each
/// triggering a full read/parse of a possibly half-written file.
///
/// This implementation fixes both:
///   • **Retry re-arm** — on rename/delete it re-opens with a short retry loop so a
///     transiently-missing file (the replacement landing a beat later) doesn't kill the
///     watcher.
///   • **Debounce** — change notifications are coalesced into a single `onChange` after a
///     quiet window, so multi-event saves read the file once, after it has settled.
public final class FSFileWatcher: FileWatcher, @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "app-router.filewatcher")
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var onChange: (@Sendable () -> Void)?
    private var debounceWorkItem: DispatchWorkItem?

    private let debounceInterval: DispatchTimeInterval = .milliseconds(150)
    private let rearmRetryDelay: DispatchTimeInterval = .milliseconds(100)
    private let maxRearmRetries = 5

    public init(url: URL) {
        self.url = url
    }

    public func start(onChange: @escaping @Sendable () -> Void) {
        queue.async { [weak self] in
            self?.onChange = onChange
            self?.arm(retriesLeft: self?.maxRearmRetries ?? 0)
        }
    }

    public func stop() {
        queue.async { [weak self] in
            self?.debounceWorkItem?.cancel()
            self?.debounceWorkItem = nil
            self?.teardown()
            self?.onChange = nil
        }
    }

    /// (Re)opens the file and installs the dispatch source. If the file is momentarily
    /// absent (mid atomic-save), retries a few times before giving up rather than dying
    /// silently for the rest of the process (audit M1).
    private func arm(retriesLeft: Int) {
        teardown()
        fileDescriptor = open(url.path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            if retriesLeft > 0 {
                queue.asyncAfter(deadline: .now() + rearmRetryDelay) { [weak self] in
                    self?.arm(retriesLeft: retriesLeft - 1)
                }
            }
            return
        }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename, .delete, .extend],
            queue: queue
        )
        // Capture the source weakly to avoid a retain cycle (audit L6): read the event
        // mask off `self.source` rather than a strong capture of `src`.
        src.setEventHandler { [weak self] in
            guard let self, let events = self.source?.data else { return }
            self.scheduleDebouncedChange()
            // Editors that replace the file invalidate our fd; re-arm on those events.
            if events.contains(.rename) || events.contains(.delete) {
                self.arm(retriesLeft: self.maxRearmRetries)
            }
        }
        src.setCancelHandler { [fd = fileDescriptor] in
            if fd >= 0 { close(fd) }
        }
        source = src
        src.resume()
    }

    /// Coalesce a burst of filesystem events (a single save often fires several) into one
    /// `onChange`, fired only after the file has been quiet for `debounceInterval`.
    private func scheduleDebouncedChange() {
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onChange?()
        }
        debounceWorkItem = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    private func teardown() {
        source?.cancel()
        source = nil
        fileDescriptor = -1
    }
}
