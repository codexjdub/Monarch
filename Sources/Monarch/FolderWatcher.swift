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

        // The context owns a retained box (+1 from passRetained), balanced by
        // the release callback when FSEvents deallocates the stream.
        let box = Unmanaged.passRetained(FolderWatcherBox(self))
        var context = FSEventStreamContext(
            version: 0,
            info: box.toOpaque(),
            retain: nil,
            release: releaseFolderWatcherBox,
            copyDescription: nil
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
        ) else {
            box.release()
            return
        }

        FSEventStreamSetDispatchQueue(s, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(s)
        stream = s
    }

    // C-compatible trampoline; routes back to the instance through the weak
    // box. Nonisolated — FSEvents invokes this from its dispatch queue.
    nonisolated private static let callback: FSEventStreamCallback = { _, clientInfo, _, _, _, _ in
        guard let info = clientInfo else { return }
        let box = Unmanaged<FolderWatcherBox>.fromOpaque(info).takeUnretainedValue()
        guard let watcher = box.watcher else { return }
        Task { @MainActor in watcher.schedule() }
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

/// Sits between the FSEvents context and the watcher. The context retains the
/// box (released by `releaseFolderWatcherBox` when FSEvents deallocates the
/// stream), and the event callback reaches the watcher through a weak
/// reference — a weak load of a deallocating object safely yields nil,
/// closing the race between an in-flight callback on the FSEvents queue and
/// deinit tearing the stream down. Holding the watcher unretained in the
/// context instead (the original design) could resurrect it mid-deallocation.
///
/// Deliberately a top-level type with a free-function release callback:
/// anything nested in a @MainActor class — including closure literals formed
/// in its methods — picks up main-actor isolation, and Swift 6 stamps a
/// runtime executor check onto such a closure even when it's converted to a
/// C function pointer. FSEvents invokes the release callback on its own
/// dispatch queue during async stream deallocation, so an isolated callback
/// dies in dispatch_assert_queue (EXC_BREAKPOINT). Same footgun family as
/// the @MainActor-DispatchWorkItem SIGBUS rule in AGENTS.md.
private final class FolderWatcherBox: @unchecked Sendable {
    weak var watcher: FolderWatcher?
    init(_ watcher: FolderWatcher) { self.watcher = watcher }
}

private func releaseFolderWatcherBox(_ info: UnsafeRawPointer?) {
    guard let info else { return }
    Unmanaged<FolderWatcherBox>.fromOpaque(info).release()
}
