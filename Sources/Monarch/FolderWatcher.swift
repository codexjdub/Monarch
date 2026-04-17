import Foundation

/// Watches a folder for content changes using FSEvents. Coalesces events
/// with a short debounce so a flurry of writes (e.g. unzip) produces one
/// callback. The callback is delivered on the main queue.
final class FolderWatcher {
    private let url: URL
    private let onChange: () -> Void
    private let debounce: TimeInterval

    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?

    init(url: URL, debounce: TimeInterval = 0.15, onChange: @escaping () -> Void) {
        self.url = url
        self.debounce = debounce
        self.onChange = onChange
        start()
    }

    deinit { stop() }

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

    private func stop() {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
        pending?.cancel(); pending = nil
    }

    // C-compatible trampoline; routes back to the instance.
    private static let callback: FSEventStreamCallback = { _, clientInfo, _, _, _, _ in
        guard let info = clientInfo else { return }
        let me = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
        me.schedule()
    }

    private func schedule() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pending?.cancel()
            let task = DispatchWorkItem { [weak self] in self?.onChange() }
            self.pending = task
            DispatchQueue.main.asyncAfter(deadline: .now() + self.debounce, execute: task)
        }
    }
}
