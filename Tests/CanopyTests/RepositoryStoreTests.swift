import XCTest
@testable import Canopy

/// 화면 없이 store만 돌려서 열기 → 선택 → diff → 커밋 → 워크트리 전환이 이어지는지 본다.
@MainActor
final class RepositoryStoreTests: XCTestCase {
    private var root: URL!
    private var repo: GitRepository!

    override func setUp() async throws {
        setenv("GIT_CONFIG_GLOBAL", "/dev/null", 1)
        setenv("GIT_CONFIG_NOSYSTEM", "1", 1)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grove-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        repo = GitRepository(directory: root)
        try await repo.run(["init", "-q", "-b", "main"])
        try await repo.run(["config", "user.name", "Grove Test"])
        try await repo.run(["config", "user.email", "grove@example.com"])
        try "one\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await repo.stageAll()
        try await repo.commit(message: "init", amend: false)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testOpenSelectCommitAndSwitchWorktree() async throws {
        let store = RepositoryStore()
        await store.open(root)
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(store.isOpen)
        XCTAssertEqual(store.worktrees.count, 1)
        XCTAssertEqual(store.currentBranch?.name, "main")
        XCTAssertNil(store.sidebarSelection)
        XCTAssertEqual(store.graph.rows.count, 1)

        // 작업 트리 변경 → 선택 → diff
        try "one\ntwo\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        await store.refresh()
        XCTAssertEqual(store.status.unstaged.map(\.path), ["a.txt"])
        store.selectedChangeID = store.status.unstaged[0].id
        await store.updateDetail()
        guard case .change(let change)? = store.detail else { return XCTFail("expected change detail") }
        XCTAssertEqual(change.path, "a.txt")
        XCTAssertEqual(store.diffFiles.first?.hunks.first?.lines.filter { $0.kind == .addition }.map(\.text), ["two"])

        // 스테이징 → 커밋
        await store.stage(change)
        XCTAssertEqual(store.status.staged.count, 1)
        XCTAssertFalse(store.canCommit)
        store.commitMessage = "second"
        XCTAssertTrue(store.canCommit)
        await store.commit()
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.commitMessage, "")
        XCTAssertEqual(store.commits.map(\.subject), ["second", "init"])
        XCTAssertTrue(store.status.changes.isEmpty)

        // 히스토리에서 커밋 선택 → diff
        store.pane = .history
        store.selectedCommitID = store.commits[0].id
        await store.updateDetail(force: true)
        guard case .commit(let commit)? = store.detail else { return XCTFail("expected commit detail") }
        XCTAssertEqual(commit.subject, "second")
        XCTAssertEqual(store.diffFiles.count, 1)

        // 새 워크트리를 store로 만들면 그쪽으로 선택이 옮겨 간다.
        let worktreePath = root.deletingLastPathComponent().appendingPathComponent("grove-store-wt-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: worktreePath) }
        let added = await store.addWorktree(path: worktreePath, branch: "feature", createBranch: true, from: nil)
        XCTAssertTrue(added)
        XCTAssertEqual(store.worktrees.count, 2)
        XCTAssertEqual(canonicalPath(store.activeWorktreePath!), canonicalPath(worktreePath))
        XCTAssertEqual(store.currentBranch?.name, "feature")
        XCTAssertEqual(store.status.branch, "feature")

        // 브랜치를 고르면 그 브랜치의 히스토리가 뜬다.
        store.sidebarSelection = .branch("refs/heads/main")
        await store.handleSidebarSelection()
        XCTAssertEqual(store.refCommits.map(\.subject), ["second", "init"])

        // 다른 워크트리에 체크아웃된 브랜치로 체크아웃하면 git이 거부하고 메시지가 남는다.
        let main = store.branches.first { $0.name == "main" }!
        await store.checkout(main)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(store.errorMessage!.contains("already"), store.errorMessage!)
    }
}
