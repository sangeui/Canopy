import XCTest
@testable import Canopy

/// 히스토리 범위: 기준 브랜치 커밋 가리기, 사이드바 브랜치의 추적 브랜치, 현재 브랜치 선택
@MainActor
final class HistoryScopeTests: XCTestCase {
    private var root: URL!
    private var repo: GitRepository!

    override func setUp() async throws {
        setenv("GIT_CONFIG_GLOBAL", "/dev/null", 1)
        setenv("GIT_CONFIG_NOSYSTEM", "1", 1)
        UserDefaults.standard.set("current", forKey: "historyScope.v2")
        root = FileManager.default.temporaryDirectory.appendingPathComponent("grove-scope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        repo = GitRepository(directory: root)
        try await repo.run(["init", "-q", "-b", "main"])
        try await repo.run(["config", "user.name", "Grove Test"])
        try await repo.run(["config", "user.email", "grove@example.com"])
        try await commit("init", file: "a.txt")
        try await repo.run(["checkout", "-q", "-b", "develop"])
        try await commit("develop work", file: "d.txt")
        try await repo.run(["checkout", "-q", "-b", "feature/x"])
        try await commit("feature 1", file: "f1.txt")
        try await commit("feature 2", file: "f2.txt")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func commit(_ message: String, file: String) async throws {
        try message.write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
        try await repo.stageAll()
        try await repo.commit(message: message, amend: false)
    }

    func testBaseCommitsAreMarkedAndCounted() async throws {
        let store = RepositoryStore()
        await store.open(root)
        XCTAssertEqual(store.historyScope, .current)
        XCTAssertEqual(store.historyInfo.base, "develop")
        XCTAssertEqual(store.historyInfo.ownCount, 2)
        let dimmed = Set(store.commits.filter { store.historyInfo.baseHashes.contains($0.hash) }.map(\.subject))
        XCTAssertEqual(dimmed, ["develop work", "init"], "develop에 이미 있는 커밋만 흐리게")
        XCTAssertEqual(store.historyScopeNote, "develop에 없는 커밋 2개, develop에 이미 있는 커밋은 흐리게")
    }

    func testSidebarBranchShowsItsUpstreamAhead() async throws {
        try await repo.run(["remote", "add", "origin", "git@github.com:team/app.git"])
        try await repo.run(["checkout", "-q", "develop"])
        // origin/develop이 로컬 develop보다 하나 앞서 있다
        try await commit("teammate work", file: "t.txt")
        let ahead = try await repo.run(["rev-parse", "HEAD"]).stdout.trimmed
        try await repo.run(["reset", "-q", "--hard", "HEAD~1"])
        try await repo.run(["update-ref", "refs/remotes/origin/develop", ahead])
        try await repo.setUpstream("develop", to: "origin/develop")
        try await repo.run(["checkout", "-q", "feature/x"])

        let store = RepositoryStore()
        await store.open(root)
        let develop = try XCTUnwrap(store.localBranches.first { $0.name == "develop" })
        store.selectBranch(develop)
        await store.handleSidebarSelection()
        XCTAssertTrue(store.refCommits.contains { $0.subject == "teammate work" }, "추적 브랜치에서 받아 올 커밋도 보인다")
        XCTAssertEqual(store.refHistoryInfo.incomingCount, 1)
    }

    func testChoosingTheCurrentBranchOpensHistory() async throws {
        let store = RepositoryStore()
        await store.open(root)
        store.pane = .changes
        let current = try XCTUnwrap(store.localBranches.first { $0.isHead })
        store.selectBranch(current)
        XCTAssertNil(store.sidebarSelection, "같은 목록을 따로 열지 않는다")
        XCTAssertEqual(store.pane, .history)
        let other = try XCTUnwrap(store.localBranches.first { !$0.isHead })
        store.selectBranch(other)
        XCTAssertEqual(store.sidebarSelection, .branch(other.id))
    }
}
