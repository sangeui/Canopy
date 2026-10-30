import Foundation

/// 되돌리기에 쓰는 저장소 상태. 브랜치·태그가 가리키는 커밋, HEAD, 스태시, index와 작업 트리의 내용.
/// 작업 트리는 추적하지 않는 파일까지 트리 하나로 담는다. 무시하는 파일은 뺀다.
struct RepositorySnapshot: Equatable {
    enum Head: Equatable {
        case branch(String)
        case detached(String)
    }

    struct StashEntry: Equatable {
        let hash: String
        let message: String
    }

    var head: Head
    /// `refs/heads/…`, `refs/tags/…` → 커밋
    var refs: [String: String]
    /// 위가 최신
    var stashes: [StashEntry]
    var indexTree: String
    var worktreeTree: String
}

/// 작업 하나의 앞뒤 상태
struct UndoRecord: Equatable {
    /// "커밋", "브랜치 삭제" 같은 이름. 메뉴에 "커밋 실행 취소"로 나온다.
    let label: String
    let before: RepositorySnapshot
    let after: RepositorySnapshot
}

/// 한 상태에서 다른 상태로 돌리는 데 필요한 변경. 작업이 바꾼 것만 담는다.
struct UndoPlan {
    /// 참조 → 돌릴 커밋. nil이면 지운다.
    var refs: [String: String?] = [:]
    var head: RepositorySnapshot.Head?
    var stashes: [RepositorySnapshot.StashEntry]?
    /// 작업이 바꾼 파일. 이 파일들만 돌린다.
    var paths: [String] = []
    /// 그중 작업 뒤에 따로 고친 파일. 돌리면 그 고친 내용이 사라지므로 먼저 묻는다.
    var overwritten: [String] = []
    /// 원격에 이미 올라간 커밋을 브랜치에서 빼게 되는 브랜치
    var dropsPushed: [String] = []

    var isEmpty: Bool { refs.isEmpty && head == nil && stashes == nil && paths.isEmpty }
}

enum UndoCheck {
    case ready(UndoPlan)
    /// 되돌릴 수 없는 이유
    case blocked(String)
}

extension GitRepository {
    /// 지금 상태를 적는다. 진행 중인 머지처럼 index에 충돌이 있으면 실패한다.
    func snapshot() async throws -> RepositorySnapshot {
        async let refsTask = run(["for-each-ref", "--format=%(refname)%00%(objectname)", "refs/heads", "refs/tags"])
        async let symbolicTask = run(["symbolic-ref", "-q", "HEAD"], allowedExitCodes: [0, 1])
        async let headTask = run(["rev-parse", "-q", "--verify", "HEAD"], allowedExitCodes: [0, 1])
        async let stashTask = run(["stash", "list", "--format=%H%x00%gs"])
        async let indexTask = run(["write-tree"])
        async let worktreeTask = worktreeTree()

        var refs: [String: String] = [:]
        for line in try await refsTask.stdout.split(separator: "\n") {
            let parts = line.split(separator: "\0", maxSplits: 1).map(String.init)
            if parts.count == 2 { refs[parts[0]] = parts[1] }
        }
        let symbolic = try await symbolicTask
        let head: RepositorySnapshot.Head
        if symbolic.exitCode == 0, case let name = symbolic.stdout.trimmed, name.hasPrefix("refs/heads/") {
            head = .branch(String(name.dropFirst("refs/heads/".count)))
        } else {
            head = .detached(try await headTask.stdout.trimmed)
        }
        let stashes = try await stashTask.stdout.split(separator: "\n").compactMap { line -> RepositorySnapshot.StashEntry? in
            let parts = line.split(separator: "\0", maxSplits: 1).map(String.init)
            return parts.count == 2 ? RepositorySnapshot.StashEntry(hash: parts[0], message: parts[1]) : nil
        }
        return RepositorySnapshot(
            head: head,
            refs: refs,
            stashes: stashes,
            indexTree: try await indexTask.stdout.trimmed,
            worktreeTree: try await worktreeTask
        )
    }

    /// 작업 트리 전체(추적하지 않는 파일 포함)를 트리로 쓴다. 실제 index와 작업 트리는 건드리지 않는다.
    /// 워크트리마다 따로 둔 index(Caches)에 `add -A`를 한다. 그 index가 파일 시각 정보를 기억해서
    /// 다음부터는 바뀐 파일만 다시 읽는다. 매번 실제 index를 복사하면 추적하지 않는 파일을 매번 다시 읽는다.
    private func worktreeTree() async throws -> String {
        let indexPath = try await run(["rev-parse", "--git-path", "index"]).stdout.trimmed
        let index = indexPath.hasPrefix("/") ? URL(fileURLWithPath: indexPath) : directory.appendingPathComponent(indexPath)
        let shadow = Self.shadowIndex(for: index.standardizedFileURL.path)
        if !FileManager.default.fileExists(atPath: shadow.path), FileManager.default.fileExists(atPath: index.path) {
            try? FileManager.default.copyItem(at: index, to: shadow)
        }
        do {
            let environment = ["GIT_INDEX_FILE": shadow.path]
            try await run(["add", "-A"], environment: environment)
            return try await run(["write-tree"], environment: environment).stdout.trimmed
        } catch {
            // 따로 둔 index가 깨졌거나 잠겨 있으면 버리고 이번만 새로 복사해서 쓴다
            try? FileManager.default.removeItem(at: shadow)
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("canopy-snapshot-\(UUID().uuidString).index")
            defer { try? FileManager.default.removeItem(at: temporary) }
            if FileManager.default.fileExists(atPath: index.path) {
                try FileManager.default.copyItem(at: index, to: temporary)
            }
            let environment = ["GIT_INDEX_FILE": temporary.path]
            try await run(["add", "-A"], environment: environment)
            return try await run(["write-tree"], environment: environment).stdout.trimmed
        }
    }

    /// 워크트리마다 하나. 경로를 FNV-1a로 줄여 파일 이름으로 쓴다(Swift의 hashValue는 실행마다 달라진다).
    private static func shadowIndex(for indexPath: String) -> URL {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in indexPath.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Canopy/snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        pruneShadowIndexes(in: folder)
        return folder.appendingPathComponent(String(hash, radix: 16) + ".index")
    }

    /// 2주 넘게 안 쓴 것은 지운다. 지운 저장소나 임시 저장소의 것이 쌓이지 않게.
    private static func pruneShadowIndexes(in folder: URL) {
        let limit = Date().addingTimeInterval(-14 * 24 * 3600)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantFuture
            if modified < limit { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// 두 트리에서 다른 경로
    private func changedPaths(_ a: String, _ b: String) async throws -> Set<String> {
        guard a != b else { return [] }
        let output = try await run(["diff", "--name-only", "-z", "--no-renames"] + Self.noExternalDiff + [a, b])
        return Set(output.stdout.split(separator: "\0").map(String.init))
    }

    /// `from` 상태를 `to` 상태로 돌릴 수 있는지 보고, 할 일을 정한다.
    /// - Parameters:
    ///   - current: 지금 상태. 작업 뒤에 앱 밖에서 브랜치가 바뀌었으면 되돌리지 않는다.
    ///   - lockedBranches: 다른 워크트리에 체크아웃된 브랜치. 옮기면 그 워크트리의 파일과 어긋난다.
    ///   - upstreams: 브랜치 → 추적하는 원격 브랜치의 커밋. 이미 올린 커밋을 빼는지 볼 때 쓴다.
    func checkUndo(from: RepositorySnapshot, to: RepositorySnapshot, current: RepositorySnapshot, lockedBranches: Set<String>, upstreams: [String: String]) async throws -> UndoCheck {
        var plan = UndoPlan()
        for ref in Set(from.refs.keys).union(to.refs.keys) where from.refs[ref] != to.refs[ref] {
            guard current.refs[ref] == from.refs[ref] else {
                return .blocked("그 뒤에 바뀐 참조(\(Self.shortName(ref)))가 있어 되돌릴 수 없습니다")
            }
            let branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : nil
            if let branch, lockedBranches.contains(branch) {
                return .blocked("\(branch) 브랜치가 다른 워크트리에 체크아웃되어 있어 되돌릴 수 없습니다")
            }
            plan.refs[ref] = to.refs[ref]
            // 이미 원격에 있는 커밋을 빼서 원격과 갈라지게 되면 알려 준다.
            // 그냥 원격보다 뒤로 가는 것(풀을 되돌리기, 푸시한 커밋을 되돌리기)은 다음 풀에서 다시 받으므로 알리지 않는다.
            // 이때 강제 푸시하라고 하면 원격에 있는 다른 사람의 커밋을 지우게 된다.
            if let branch, let upstream = upstreams[branch], let tip = from.refs[ref], let target = to.refs[ref] {
                func isAncestor(_ a: String, _ b: String) async throws -> Bool {
                    try await run(["merge-base", "--is-ancestor", a, b], allowedExitCodes: [0, 1]).exitCode == 0
                }
                let tipIsPushed = try await isAncestor(tip, upstream)
                let keepsTip = try await isAncestor(tip, target)
                let fallsBehind = try await isAncestor(target, upstream)
                if tipIsPushed, !keepsTip, !fallsBehind { plan.dropsPushed.append(branch) }
            }
        }
        if from.head != to.head {
            guard current.head == from.head else { return .blocked("HEAD 위치가 그 뒤에 바뀌어서 되돌릴 수 없습니다") }
            plan.head = to.head
        }
        if from.stashes != to.stashes {
            guard current.stashes == from.stashes else { return .blocked("스태시가 그 뒤에 바뀌어서 되돌릴 수 없습니다") }
            plan.stashes = to.stashes
        }
        // 작업이 바꾼 파일만 돌린다. 작업 뒤에 고친 다른 파일은 그대로 둔다.
        let touched = try await changedPaths(from.worktreeTree, to.worktreeTree)
            .union(try await changedPaths(from.indexTree, to.indexTree))
        let editedSince = try await changedPaths(from.worktreeTree, current.worktreeTree)
            .union(try await changedPaths(from.indexTree, current.indexTree))
        plan.paths = touched.sorted()
        plan.overwritten = touched.intersection(editedSince).sorted()
        return .ready(plan)
    }

    /// 정한 대로 돌린다. 참조 → HEAD → 스태시 → 작업 트리 → index 순서.
    func apply(_ plan: UndoPlan, to target: RepositorySnapshot) async throws {
        if !plan.refs.isEmpty {
            let lines = plan.refs.sorted { $0.key < $1.key }.map { ref, oid in
                oid.map { "update \(ref) \($0)" } ?? "delete \(ref)"
            }
            try await run(["update-ref", "--stdin"], input: lines.joined(separator: "\n") + "\n")
        }
        switch plan.head {
        case .branch(let name)?: try await run(["symbolic-ref", "HEAD", "refs/heads/\(name)"])
        case .detached(let oid)?: try await run(["update-ref", "--no-deref", "HEAD", oid])
        case nil: break
        }
        if let stashes = plan.stashes {
            try await run(["stash", "clear"])
            for entry in stashes.reversed() {
                try await run(["stash", "store", "-m", entry.message, entry.hash])
            }
        }
        guard !plan.paths.isEmpty else { return }
        try await restoreWorktree(plan.paths, from: target.worktreeTree)
        try await restoreIndex(plan.paths, from: target.indexTree)
    }

    /// 경로들의 파일을 트리의 내용으로 쓴다. 트리에 없는 파일은 지운다.
    private func restoreWorktree(_ paths: [String], from tree: String) async throws {
        let present = try await pathsIn(tree, paths)
        if !present.isEmpty {
            // 임시 index에 트리를 읽고 거기서 꺼내 쓴다. 실행 권한과 심볼릭 링크도 그대로 나온다.
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("canopy-restore-\(UUID().uuidString).index")
            defer { try? FileManager.default.removeItem(at: temporary) }
            let environment = ["GIT_INDEX_FILE": temporary.path]
            try await run(["read-tree", tree], environment: environment)
            try await run(["checkout-index", "-f", "-z", "--stdin"], input: present.joined(separator: "\0") + "\0", environment: environment)
        }
        for path in paths where !present.contains(path) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(path))
        }
    }

    /// 경로들의 index 항목을 트리의 것으로 바꾼다. 트리에 없으면 index에서 뺀다.
    private func restoreIndex(_ paths: [String], from tree: String) async throws {
        let listing = try await run(["ls-tree", "-r", "-z", tree, "--"] + paths, environment: Self.literal).stdout
        let present = listing.split(separator: "\0").compactMap { $0.split(separator: "\t", maxSplits: 1).last.map(String.init) }
        if !listing.isEmpty {
            try await run(["update-index", "-z", "--index-info"], input: listing)
        }
        let absent = paths.filter { !present.contains($0) }
        if !absent.isEmpty {
            try await run(["update-index", "-z", "--force-remove", "--stdin"], input: absent.joined(separator: "\0") + "\0")
        }
    }

    /// 트리에 있는 경로만
    private func pathsIn(_ tree: String, _ paths: [String]) async throws -> [String] {
        guard !paths.isEmpty else { return [] }
        let output = try await run(["ls-tree", "-r", "-z", "--name-only", tree, "--"] + paths, environment: Self.literal)
        return output.stdout.split(separator: "\0").map(String.init)
    }

    /// 경로를 패턴이 아니라 글자 그대로 본다. 파일 이름에 `*`나 `?`가 있어도 그 파일만 고른다.
    private static let literal = ["GIT_LITERAL_PATHSPECS": "1"]

    private static func shortName(_ ref: String) -> String {
        for prefix in ["refs/heads/", "refs/tags/"] where ref.hasPrefix(prefix) {
            return String(ref.dropFirst(prefix.count))
        }
        return ref
    }
}
