import Foundation

/// Watches a folder for content changes using FSEvents. Coalesces events
/// with a short debounce so a flurry of writes (e.g. unzip) produces one
/// callback. The callback is delivered on the main queue.
@MainActor
final class FolderWatcher {
    private let url: URL
    private let onChange: @MainActor () -> Void
    private let debounce: TimeInterval

    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?

    init(url: URL, debounce: TimeInterval = 0.15, onChange: @escaping @MainActor () -> Void) {
        self.url = url
        self.debounce = debounce
        self.onChange = onChange
        start()
    }

    deinit {
        // Class is @MainActor; deinit is nonisolated. FSEvents APIs are
        // safe to call from any thread.
        MainActor.assumeIsolated {
            if let s = stream {
                FSEventStreamStop(s)
                FSEventStreamInvalidate(s)
                FSEventStreamRelease(s)
            }
        }
    }

    private func start() {
        let path = url.path as NSString
        let paths = [path] as CFArray

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer
        )

        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            FolderWatcher.callback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,  // latency
            flags
        ) else { return }

        FSEventStreamSetDispatchQueue(s, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(s)
        stream = s
    }

    // C-compatible trampoline; routes back to the instance. Nonisolated —
    // FSEvents invokes this from its dispatch queue.
    nonisolated private static let callback: FSEventStreamCallback = { _, clientInfo, _, _, _, _ in
        guard let info = clientInfo else { return }
        let me = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
        Task { @MainActor in me.schedule() }
    }

    private func schedule() {
        pending?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Already dispatched to DispatchQueue.main — safe to assume isolation.
            MainActor.assumeIsolated { self.onChange() }
        }
        pending = task
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: task)
    }
}
