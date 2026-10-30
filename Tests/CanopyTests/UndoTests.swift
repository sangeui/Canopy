import XCTest
@testable import Canopy

/// 되돌리기. 작업 앞뒤 상태를 적어 두고, 작업이 바꾼 것만 앞 상태로 돌린다.
final class UndoTests: XCTestCase {
    private var root: URL!
    private var repo: GitRepository!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("undo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        repo = GitRepository(directory: root)
        try await repo.run(["init", "-q", "-b", "main"])
        try await repo.run(["config", "user.name", "Test"])
        try await repo.run(["config", "user.email", "t@example.com"])
        try write("a.txt", "one\n")
        try write("b.txt", "one\n")
        try await repo.stageAll()
        try await repo.commit(message: "first", amend: false)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ path: String, _ text: String) throws {
        try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    private func read(_ path: String) -> String? {
        try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// 작업 하나를 앞뒤 상태와 함께 실행한다
    private func record(_ label: String, _ body: () async throws -> Void) async throws -> UndoRecord {
        let before = try await repo.snapshot()
        try await body()
        let after = try await repo.snapshot()
        return UndoRecord(label: label, before: before, after: after)
    }

    private func undo(_ record: UndoRecord) async throws -> UndoPlan {
        let current = try await repo.snapshot()
        guard case .ready(let plan) = try await repo.checkUndo(from: record.after, to: record.before, current: current, lockedBranches: [], upstreams: [:]) else {
            XCTFail("되돌릴 수 있어야 합니다")
            throw CancellationError()
        }
        try await repo.apply(plan, to: record.before)
        return plan
    }

    /// 버린 A는 돌아오고, 그 뒤에 고친 B는 그대로 남는다
    func testUndoDiscardKeepsLaterEdits() async throws {
        try write("a.txt", "one\nmine\n")
        let discard = try await record("버리기") {
            try await repo.run(["checkout", "--", "a.txt"])
        }
        XCTAssertEqual(read("a.txt"), "one\n")
        try write("b.txt", "one\nlater\n")

        let plan = try await undo(discard)
        XCTAssertEqual(plan.paths, ["a.txt"])
        XCTAssertTrue(plan.overwritten.isEmpty)
        XCTAssertEqual(read("a.txt"), "one\nmine\n")
        XCTAssertEqual(read("b.txt"), "one\nlater\n")
    }

    /// 버린 파일을 그 뒤에 다시 고쳤으면 덮어쓰기 전에 알 수 있어야 한다
    func testOverwrittenPathsAreReported() async throws {
        try write("a.txt", "one\nmine\n")
        let discard = try await record("버리기") {
            try await repo.run(["checkout", "--", "a.txt"])
        }
        try write("a.txt", "one\nagain\n")
        let current = try await repo.snapshot()
        guard case .ready(let plan) = try await repo.checkUndo(from: discard.after, to: discard.before, current: current, lockedBranches: [], upstreams: [:]) else {
            return XCTFail("되돌릴 수 있어야 합니다")
        }
        XCTAssertEqual(plan.overwritten, ["a.txt"])
    }

    /// 커밋을 되돌리면 변경이 스테이징된 채로 남고, 다시 하면 커밋이 돌아온다
    func testUndoAndRedoCommit() async throws {
        try write("a.txt", "two\n")
        try await repo.stageAll()
        let commit = try await record("커밋") {
            try await repo.commit(message: "second", amend: false)
        }
        _ = try await undo(commit)
        var log = try await repo.log().map(\.subject)
        XCTAssertEqual(log, ["first"])
        let status = try await repo.status()
        XCTAssertEqual(status.staged.map(\.path), ["a.txt"])

        // 다시 하기: 반대 방향으로 같은 계산
        let current = try await repo.snapshot()
        guard case .ready(let plan) = try await repo.checkUndo(from: commit.before, to: commit.after, current: current, lockedBranches: [], upstreams: [:]) else {
            return XCTFail("다시 할 수 있어야 합니다")
        }
        try await repo.apply(plan, to: commit.after)
        log = try await repo.log().map(\.subject)
        XCTAssertEqual(log, ["second", "first"])
        let clean = try await repo.status()
        XCTAssertTrue(clean.changes.isEmpty)
    }

    /// 지운 브랜치와 지운 스태시가 돌아온다
    func testUndoBranchAndStashDelete() async throws {
        try await repo.createBranch("topic", from: nil, checkout: false)
        let deleteBranch = try await record("브랜치 삭제") {
            try await repo.run(["branch", "-D", "topic"])
        }
        _ = try await undo(deleteBranch)
        let branches = try await repo.branches()
        XCTAssertTrue(branches.contains { $0.name == "topic" })

        try write("a.txt", "stashed\n")
        try await repo.run(["stash", "push", "-q", "-m", "keep me"])
        let drop = try await record("스태시 삭제") {
            try await repo.run(["stash", "drop", "-q"])
        }
        _ = try await undo(drop)
        let stashes = try await repo.stashes()
        XCTAssertEqual(stashes.count, 1)
        XCTAssertTrue(stashes[0].message.contains("keep me"))
    }

    /// 체크아웃을 되돌리면 원래 브랜치와 그 파일로 돌아온다
    func testUndoCheckout() async throws {
        try await repo.createBranch("topic", from: nil, checkout: true)
        try write("t.txt", "topic\n")
        try await repo.stageAll()
        try await repo.commit(message: "topic", amend: false)
        try await repo.run(["checkout", "-q", "main"])
        let checkout = try await record("체크아웃") {
            try await repo.run(["checkout", "-q", "topic"])
        }
        _ = try await undo(checkout)
        let status = try await repo.status()
        XCTAssertEqual(status.branch, "main")
        XCTAssertNil(read("t.txt"))
        XCTAssertTrue(status.changes.isEmpty)
    }

    /// 풀을 되돌리면 원격보다 뒤로 갈 뿐이라 강제 푸시 경고가 없어야 한다.
    /// 푸시하고 나서 고친(amend) 커밋을 되돌리면 원격과 갈라지므로 경고해야 한다.
    func testPushedCommitWarnings() async throws {
        let bare = root.deletingLastPathComponent().appendingPathComponent("undo-bare-\(UUID().uuidString).git")
        let other = root.deletingLastPathComponent().appendingPathComponent("undo-other-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: bare)
            try? FileManager.default.removeItem(at: other)
        }
        try await repo.run(["init", "-q", "--bare", "-b", "main", bare.path])
        try await repo.addRemote("origin", url: bare.path)
        try await repo.run(["push", "-q", "-u", "origin", "main"])
        try await repo.run(["clone", "-q", bare.path, other.path])
        let otherRepo = GitRepository(directory: other)
        try await otherRepo.run(["config", "user.name", "Other"])
        try await otherRepo.run(["config", "user.email", "o@example.com"])
        try "remote\n".write(to: other.appendingPathComponent("r.txt"), atomically: true, encoding: .utf8)
        try await otherRepo.stageAll()
        try await otherRepo.commit(message: "remote work", amend: false)
        try await otherRepo.run(["push", "-q"])

        func upstream() async throws -> [String: String] {
            ["main": try await repo.run(["rev-parse", "origin/main"]).stdout.trimmed]
        }
        func plan(_ record: UndoRecord) async throws -> UndoPlan {
            let current = try await repo.snapshot()
            guard case .ready(let plan) = try await repo.checkUndo(from: record.after, to: record.before, current: current, lockedBranches: [], upstreams: try await upstream()) else {
                XCTFail("되돌릴 수 있어야 합니다")
                throw CancellationError()
            }
            return plan
        }

        let pull = try await record("풀") {
            try await repo.pull(remote: "origin", branch: "main", rebase: false, autostash: false)
        }
        let pullPlan = try await plan(pull)
        XCTAssertTrue(pullPlan.dropsPushed.isEmpty)

        try write("a.txt", "mine\n")
        try await repo.stageAll()
        try await repo.commit(message: "mine", amend: false)
        try await repo.run(["push", "-q"])
        try write("a.txt", "mine fixed\n")
        try await repo.stageAll()
        let amend = try await record("커밋 고치기") {
            try await repo.commit(message: "mine", amend: true)
            try await repo.run(["push", "-q", "--force"])
        }
        try await repo.run(["fetch", "-q"])
        let amendPlan = try await plan(amend)
        XCTAssertEqual(amendPlan.dropsPushed, ["main"])
    }

    /// 작업 뒤에 앱 밖에서 브랜치가 바뀌었으면 되돌리지 않는다
    func testBlockedWhenBranchMovedOutside() async throws {
        try write("a.txt", "two\n")
        try await repo.stageAll()
        let commit = try await record("커밋") {
            try await repo.commit(message: "second", amend: false)
        }
        try write("a.txt", "three\n")
        try await repo.stageAll()
        try await repo.commit(message: "third outside", amend: false)
        let current = try await repo.snapshot()
        guard case .blocked = try await repo.checkUndo(from: commit.after, to: commit.before, current: current, lockedBranches: [], upstreams: [:]) else {
            return XCTFail("막아야 합니다")
        }
    }
}
