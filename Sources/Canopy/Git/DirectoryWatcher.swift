import CoreServices
import Foundation

/// FSEvents로 폴더를 지켜보다가 잠잠해지면 한 번 알려 준다.
final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    private let onChange: ([String]) -> Void
    /// 마지막 묶음에서 바뀐 경로. 무엇 때문에 새로고침했는지 알 수 있게 넘긴다.
    private var changedPaths: [String] = []
    private let debounce: TimeInterval

    init(path: String, debounce: TimeInterval = 0.5, onChange: @escaping ([String]) -> Void) {
        self.onChange = onChange
        self.debounce = debounce

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            watcher.schedule(list)
        }
        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
        ) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit {
        pending?.cancel()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    private func schedule(_ paths: [String]) {
        changedPaths += paths
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let paths = self.changedPaths
            self.changedPaths = []
            self.onChange(paths)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
