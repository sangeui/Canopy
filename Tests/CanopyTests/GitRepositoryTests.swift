import XCTest
@testable import Canopy

/// 임시 저장소를 만들어 실제 git을 상대로 명령 묶음을 확인한다.
final class GitRepositoryTests: XCTestCase {
    private var root: URL!
    private var repo: GitRepository!

    override func setUp() async throws {
        // 사용자 전역 설정(gpgsign, hooks 등)이 끼어들지 않게 한다.
        setenv("GIT_CONFIG_GLOBAL", "/dev/null", 1)
        setenv("GIT_CONFIG_NOSYSTEM", "1", 1)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grove-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        repo = GitRepository(directory: root)
        try await repo.run(["init", "-q", "-b", "main"])
        try await repo.run(["config", "user.name", "Grove Test"])
        try await repo.run(["config", "user.email", "grove@example.com"])
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ name: String, _ contents: String) throws {
        try contents.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testStatusStageCommitLog() async throws {
        var hasHead = try await repo.hasHead()
        XCTAssertFalse(hasHead)

        try write("hello.txt", "hello\n")
        var status = try await repo.status()
        XCTAssertEqual(status.branch, "main")
        XCTAssertEqual(status.unstaged.map(\.path), ["hello.txt"])
        XCTAssertEqual(status.unstaged[0].kind, .untracked)

        let untrackedDiff = try await repo.diff(for: status.unstaged[0])
        XCTAssertEqual(untrackedDiff.count, 1)
        XCTAssertEqual(untrackedDiff[0].hunks[0].lines.map(\.text), ["hello"])

        try await repo.stage(["hello.txt"])
        status = try await repo.status()
        XCTAssertEqual(status.staged.map(\.path), ["hello.txt"])
        XCTAssertEqual(status.staged[0].kind, .added)

        try await repo.unstage(["hello.txt"], hasHead: false)
        status = try await repo.status()
        XCTAssertTrue(status.staged.isEmpty)

        try await repo.stageAll()
        try await repo.commit(message: "First commit\n\nWith a body.", amend: false)
        hasHead = try await repo.hasHead()
        XCTAssertTrue(hasHead)

        let log = try await repo.log()
        XCTAssertEqual(log.count, 1)
        XCTAssertEqual(log[0].subject, "First commit")
        XCTAssertEqual(log[0].body, "With a body.")
        XCTAssertEqual(log[0].authorName, "Grove Test")
        XCTAssertTrue(log[0].refs.contains("HEAD -> main"))

        try write("hello.txt", "hello\nworld\n")
        status = try await repo.status()
        XCTAssertEqual(status.unstaged[0].kind, .modified)
        let diff = try await repo.diff(for: status.unstaged[0])
        XCTAssertEqual(diff[0].hunks[0].lines.filter { $0.kind == .addition }.map(\.text), ["world"])

        try await repo.discardWorkingTreeChanges(["hello.txt"])
        status = try await repo.status()
        XCTAssertTrue(status.changes.isEmpty)

        let commitDiff = try await repo.diff(forCommit: log[0].hash)
        XCTAssertEqual(commitDiff.count, 1)
        XCTAssertEqual(commitDiff[0].newPath, "hello.txt")
    }

    func testBranchesAndWorktrees() async throws {
        try write("a.txt", "a\n")
        try await repo.stageAll()
        try await repo.commit(message: "init", amend: false)

        try await repo.createBranch("feature", from: nil, checkout: false)
        var branches = try await repo.branches()
        XCTAssertEqual(branches.map(\.name).sorted(), ["feature", "main"])
        XCTAssertEqual(branches.first { $0.name == "main" }?.isHead, true)
        XCTAssertNotNil(branches.first { $0.name == "main" }?.worktreePath)
        XCTAssertNil(branches.first { $0.name == "feature" }?.worktreePath)

        let worktreePath = root.deletingLastPathComponent().appendingPathComponent("grove-wt-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: worktreePath) }
        try await repo.addWorktree(at: worktreePath, branch: "feature", createBranch: false, from: nil)

        let worktrees = try await repo.worktrees()
        XCTAssertEqual(worktrees.count, 2)
        XCTAssertTrue(worktrees[0].isMain)
        XCTAssertEqual(worktrees[1].branch, "feature")
        XCTAssertEqual(canonicalPath(worktrees[1].path), canonicalPath(worktreePath))

        branches = try await repo.branches()
        XCTAssertNotNil(branches.first { $0.name == "feature" }?.worktreePath)

        // 다른 워크트리에서 보면 HEAD 표시가 그쪽 브랜치로 바뀐다.
        let other = GitRepository(path: worktreePath)
        let otherBranches = try await other.branches()
        XCTAssertEqual(otherBranches.first { $0.isHead }?.name, "feature")
        let otherStatus = try await other.status()
        XCTAssertEqual(otherStatus.branch, "feature")

        try await repo.removeWorktree(worktreePath, force: false)
        let after = try await repo.worktrees()
        XCTAssertEqual(after.count, 1)

        try await repo.deleteBranch("feature", force: false)
        branches = try await repo.branches()
        XCTAssertEqual(branches.map(\.name), ["main"])
    }

    func testLocateFromSubdirectory() async throws {
        try write("a.txt", "a\n")
        try await repo.stageAll()
        try await repo.commit(message: "init", amend: false)
        let sub = root.appendingPathComponent("nested/deeper", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        let location = try await GitRepository.locate(sub)
        XCTAssertEqual(location.worktree, canonicalPath(root.path))
        XCTAssertEqual(location.mainRoot, canonicalPath(root.path))
    }

    func testFailureSurfacesStderr() async {
        do {
            try await repo.checkout("no-such-branch")
            XCTFail("expected an error")
        } catch let error as GitError {
            XCTAssertEqual(error.exitCode, 1)
            XCTAssertTrue(error.localizedDescription.contains("no-such-branch"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}

final class GitRepositoryExtraTests: XCTestCase {
    private var root: URL!
    private var repo: GitRepository!

    override func setUp() async throws {
        setenv("GIT_CONFIG_GLOBAL", "/dev/null", 1)
        setenv("GIT_CONFIG_NOSYSTEM", "1", 1)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grove-extra-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        repo = GitRepository(directory: root)
        try await repo.run(["init", "-q", "-b", "main"])
        try await repo.run(["config", "user.name", "Grove Test"])
        try await repo.run(["config", "user.email", "grove@example.com"])
        try write("a.txt", (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n")
        try await repo.stageAll()
        try await repo.commit(message: "init", amend: false)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ name: String, _ contents: String) throws {
        try contents.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// 멀리 떨어진 두 곳을 고치면 hunk가 둘 생기고, 하나만 스테이징할 수 있다.
    func testStageSingleHunk() async throws {
        var lines = (1...20).map { "line \($0)" }
        lines[1] = "line 2 changed"
        lines[18] = "line 19 changed"
        try write("a.txt", lines.joined(separator: "\n") + "\n")

        let status = try await repo.status()
        let diff = try await repo.diff(for: status.unstaged[0])
        XCTAssertEqual(diff[0].hunks.count, 2)

        try await repo.applyPatch(diff[0].patch(for: diff[0].hunks[0]), cached: true, reverse: false)
        let after = try await repo.status()
        XCTAssertEqual(after.staged.map(\.path), ["a.txt"])
        XCTAssertEqual(after.unstaged.map(\.path), ["a.txt"])
        let staged = try await repo.diff(for: after.staged[0])
        XCTAssertEqual(staged[0].hunks.count, 1)
        XCTAssertTrue(staged[0].hunks[0].lines.contains { $0.text == "line 2 changed" })

        // 되돌리면 다시 스테이징이 빈다.
        try await repo.applyPatch(staged[0].patch(for: staged[0].hunks[0]), cached: true, reverse: true)
        let afterReverse = try await repo.status()
        XCTAssertTrue(afterReverse.staged.isEmpty)

        // 작업 트리에서 hunk 하나만 버린다.
        let unstagedStatus = try await repo.status()
        let unstaged = try await repo.diff(for: unstagedStatus.unstaged[0])
        try await repo.applyPatch(unstaged[0].patch(for: unstaged[0].hunks[1]), cached: false, reverse: true)
        let remainingStatus = try await repo.status()
        let remaining = try await repo.diff(for: remainingStatus.unstaged[0])
        XCTAssertEqual(remaining[0].hunks.count, 1)
    }

    func testStashTagMergeAndOperationState() async throws {
        try write("b.txt", "b\n")
        try await repo.stashPush(message: "keep b", includeUntracked: true)
        var stashes = try await repo.stashes()
        XCTAssertEqual(stashes.count, 1)
        XCTAssertEqual(stashes[0].title, "keep b")
        let clean = try await repo.status()
        XCTAssertTrue(clean.changes.isEmpty)
        let stashDiff = try await repo.diff(forStash: stashes[0].ref)
        XCTAssertEqual(stashDiff.map(\.displayPath), ["b.txt"])
        try await repo.stashApply(stashes[0].ref, pop: true)
        stashes = try await repo.stashes()
        XCTAssertTrue(stashes.isEmpty)
        let popped = try await repo.status()
        XCTAssertEqual(popped.unstaged.map(\.path), ["b.txt"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("b.txt"))

        let head = try await repo.log()[0].hash
        try await repo.createTag("v1", at: head, message: "first")
        try await repo.createTag("light", at: head, message: nil)
        let tags = try await repo.tags()
        XCTAssertEqual(Set(tags.map(\.name)), ["v1", "light"])
        XCTAssertEqual(tags.first { $0.name == "v1" }?.isAnnotated, true)
        let containing = try await repo.refsContaining(head)
        XCTAssertEqual(containing.branches, ["main"])
        XCTAssertEqual(containing.tags.sorted(), ["light", "v1"])
        XCTAssertTrue(containing.remotes.isEmpty)
        try await repo.deleteTag("light")

        // 충돌이 나는 머지 → 작업 상태 감지 → 정리 → 중단
        try await repo.createBranch("other", from: nil, checkout: true)
        try write("a.txt", "other\n")
        try await repo.stageAll()
        try await repo.commit(message: "other change", amend: false)
        try await repo.checkout("main")
        try write("a.txt", "main\n")
        try await repo.stageAll()
        try await repo.commit(message: "main change", amend: false)

        let before = try await repo.operationState()
        XCTAssertNil(before)
        do {
            try await repo.merge("other")
            XCTFail("expected conflict")
        } catch {}
        let during = try await repo.operationState()
        XCTAssertEqual(during, .merging)
        let conflicted = try await repo.status()
        XCTAssertEqual(conflicted.changes.first?.area, .conflicted)
        try await repo.resolveConflict("a.txt", keepOurs: true)
        let resolved = try await repo.status()
        XCTAssertTrue(resolved.conflictsResolved)
        try await repo.abort(.merging)
        let after = try await repo.operationState()
        XCTAssertNil(after)

        let all = try await repo.logAll()
        XCTAssertEqual(Set(all.map(\.subject)), ["init", "other change", "main change"])
    }
}

private extension StatusSnapshot {
    var conflictsResolved: Bool { !changes.contains { $0.area == .conflicted } }
}

extension GitRepositoryTests {
    /// 기준 브랜치와 견주기, 파일 역사, blame, 머지된 브랜치 목록.
    func testCompareFileHistoryBlameAndMerged() async throws {
        try write("a.txt", "one\n")
        try await repo.stageAll()
        try await repo.commit(message: "first", amend: false)
        try await repo.createBranch("topic", from: nil, checkout: true)
        try write("a.txt", "one\ntwo\n")
        try await repo.stageAll()
        try await repo.commit(message: "second", amend: false)

        let counts = try await repo.aheadBehind(base: "main", head: "topic")
        XCTAssertEqual(counts.ahead, 1)
        XCTAssertEqual(counts.behind, 0)
        let stat = try await repo.diffStat(base: "main", head: "topic")
        XCTAssertEqual(stat.files, 1)
        XCTAssertEqual(stat.additions, 1)
        let files = try await repo.diff(base: "main", head: "topic")
        XCTAssertEqual(files.map(\.displayPath), ["a.txt"])

        let history = try await repo.log(path: "a.txt")
        XCTAssertEqual(history.map(\.subject), ["second", "first"])

        let blame = try await repo.blame(path: "a.txt")
        XCTAssertEqual(blame.map(\.text), ["one", "two"])
        XCTAssertEqual(blame.map(\.summary), ["first", "second"])
        XCTAssertEqual(blame[0].author, "Grove Test")
        XCTAssertEqual(blame.map(\.number), [1, 2])

        // topic은 main을 담고 있으니 main은 topic에 머지된 상태다.
        let merged = try await repo.mergedBranches(into: "topic")
        XCTAssertTrue(merged.contains("main"))
        let notMerged = try await repo.mergedBranches(into: "main")
        XCTAssertFalse(notMerged.contains("topic"))
    }
}


extension GitRepositoryTests {
    /// 기준 브랜치의 옛 커밋을 가리키기만 하는 브랜치와, 머지 커밋으로 들어간 브랜치를 가른다.
    func testFirstParentHashesAndBranchHash() async throws {
        try write("a.txt", "one\n")
        try await repo.stageAll()
        try await repo.commit(message: "first", amend: false)
        try await repo.createBranch("idle", from: nil, checkout: false)
        try await repo.createBranch("topic", from: nil, checkout: true)
        try write("a.txt", "one\ntwo\n")
        try await repo.stageAll()
        try await repo.commit(message: "work", amend: false)
        try await repo.run(["checkout", "-q", "main"])
        try await repo.run(["merge", "--no-ff", "--no-edit", "topic"])

        let branches = try await repo.branches()
        let idle = try XCTUnwrap(branches.first { $0.name == "idle" })
        let topic = try XCTUnwrap(branches.first { $0.name == "topic" })
        XCTAssertEqual(idle.hash.count, 40)
        let firstParents = try await repo.firstParentHashes(of: "main")
        XCTAssertTrue(firstParents.contains(idle.hash))
        XCTAssertFalse(firstParents.contains(topic.hash))
        let merged = try await repo.mergedBranches(into: "main")
        XCTAssertTrue(merged.contains("idle"))
        XCTAssertTrue(merged.contains("topic"))
    }
}

extension GitRepositoryTests {
    /// 이름 바꾸기, 추적 브랜치 설정·해제, 원격 브랜치 삭제, 리베이스 풀.
    func testBranchAndRemoteOperations() async throws {
        try write("a.txt", "one\n")
        try await repo.stageAll()
        try await repo.commit(message: "first", amend: false)

        // 맨 저장소를 원격으로 붙인다
        let bare = root.deletingLastPathComponent().appendingPathComponent("bare-\(UUID().uuidString).git")
        try await repo.run(["init", "-q", "--bare", "-b", "main", bare.path])
        defer { try? FileManager.default.removeItem(at: bare) }
        try await repo.addRemote("origin", url: bare.path)
        try await repo.push(branch: "main", remote: "origin", target: "main", setUpstream: true, force: false, tags: false)

        try await repo.createBranch("topic", from: nil, checkout: false)
        try await repo.renameBranch("topic", to: "renamed")
        var names = try await repo.branches().map(\.name)
        XCTAssertTrue(names.contains("renamed"))
        XCTAssertFalse(names.contains("topic"))

        try await repo.run(["push", "-q", "origin", "renamed"])
        try await repo.fetch()
        try await repo.setUpstream("renamed", to: "origin/renamed")
        var all = try await repo.branches()
        var renamed = try XCTUnwrap(all.first { $0.name == "renamed" })
        XCTAssertEqual(renamed.upstream, "origin/renamed")
        try await repo.setUpstream("renamed", to: nil)
        all = try await repo.branches()
        renamed = try XCTUnwrap(all.first { $0.name == "renamed" })
        XCTAssertNil(renamed.upstream)

        try await repo.deleteRemoteBranch(remote: "origin", branch: "renamed")
        try await repo.fetch()
        names = try await repo.branches().map(\.name)
        XCTAssertFalse(names.contains("origin/renamed"))

        // 다른 곳에서 원격에 커밋이 생긴 상태에서, 로컬에도 커밋을 하고 리베이스로 풀한다
        let other = root.deletingLastPathComponent().appendingPathComponent("other-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: other) }
        try await repo.run(["clone", "-q", "-b", "main", bare.path, other.path])
        let otherRepo = GitRepository(directory: other)
        try await otherRepo.run(["config", "user.name", "Other"])
        try await otherRepo.run(["config", "user.email", "o@example.com"])
        try "remote\n".write(to: other.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try await otherRepo.stageAll()
        try await otherRepo.commit(message: "remote work", amend: false)
        try await otherRepo.run(["push", "-q"])

        try write("c.txt", "local\n")
        try await repo.stageAll()
        try await repo.commit(message: "local work", amend: false)
        try write("a.txt", "one\ndirty\n")  // 커밋 안 한 변경: 자동 스태시가 치웠다가 되돌려야 한다
        try await repo.pull(remote: "origin", branch: "main", rebase: true, autostash: true)
        let log = try await repo.log().map(\.subject)
        XCTAssertEqual(log, ["local work", "remote work", "first"])
        let status = try await repo.status()
        XCTAssertEqual(status.unstaged.map(\.path), ["a.txt"])
    }
}

extension GitRepositoryTests {
    /// 푸시는 늘 원격과 대상을 적어서 보낸다. 이름이 다른 원격 브랜치로도, 강제로도 보낼 수 있어야 한다.
    func testPushToNamedTargetAndForce() async throws {
        try write("a.txt", "one\n")
        try await repo.stageAll()
        try await repo.commit(message: "first", amend: false)
        let bare = root.deletingLastPathComponent().appendingPathComponent("bare-\(UUID().uuidString).git")
        try await repo.run(["init", "-q", "--bare", "-b", "main", bare.path])
        defer { try? FileManager.default.removeItem(at: bare) }
        try await repo.addRemote("fork", url: bare.path)

        // 추적이 없는 새 브랜치: 다른 이름으로 보내고 추적을 건다
        try await repo.push(branch: "main", remote: "fork", target: "review/main", setUpstream: true, force: false, tags: false)
        var all = try await repo.branches()
        var main = try XCTUnwrap(all.first { $0.name == "main" })
        XCTAssertEqual(main.upstream, "fork/review/main")
        var unpushed = try await repo.countCommits(["refs/heads/main", "--not", "--remotes=fork"])
        XCTAssertEqual(unpushed, 0)

        // 마지막 커밋을 고쳐 쓰면 일반 푸시는 거부되고 강제 푸시는 된다
        try write("a.txt", "two\n")
        try await repo.stageAll()
        try await repo.commit(message: "rewritten", amend: true)
        unpushed = try await repo.countCommits(["refs/heads/main", "--not", "--remotes=fork"])
        XCTAssertEqual(unpushed, 1)
        do {
            try await repo.push(branch: "main", remote: "fork", target: "review/main", setUpstream: false, force: false, tags: false)
            XCTFail("앞서 나가지 않은 푸시는 거부되어야 합니다")
        } catch {}
        try await repo.push(branch: "main", remote: "fork", target: "review/main", setUpstream: false, force: true, tags: false)
        all = try await repo.branches()
        main = try XCTUnwrap(all.first { $0.name == "main" })
        XCTAssertEqual(main.ahead, 0)
        XCTAssertEqual(main.behind, 0)
    }
}

extension GitRepositoryTests {
    /// 리베이스 중에는 HEAD가 떨어져 있어도 원래 브랜치 이름과 진행 정도를 읽는다. 태그를 체크아웃하면 태그 이름을 읽는다.
    func testDetachedPlace() async throws {
        try write("a.txt", "base\n")
        try await repo.stageAll()
        try await repo.commit(message: "base", amend: false)
        try await repo.run(["tag", "v1.0"])
        try await repo.createBranch("topic", from: nil, checkout: true)
        for (index, text) in ["one", "two", "three"].enumerated() {
            try write("t\(index).txt", text + "\n")
            try await repo.stageAll()
            try await repo.commit(message: text, amend: false)
        }
        try write("a.txt", "topic\n")
        try await repo.stageAll()
        try await repo.commit(message: "conflicting", amend: false)
        try await repo.run(["checkout", "-q", "main"])
        try write("a.txt", "main\n")
        try await repo.stageAll()
        try await repo.commit(message: "main change", amend: false)
        try await repo.run(["checkout", "-q", "topic"])

        // 넷째 커밋에서 충돌로 멈춘다
        do { try await repo.run(["rebase", "main"]) } catch {}
        var status = try await repo.status()
        XCTAssertTrue(status.isDetached)
        var place = try await repo.detachedPlace()
        XCTAssertEqual(place.rebasingBranch, "topic")
        XCTAssertEqual(place.step, 4)
        XCTAssertEqual(place.total, 4)
        // 충돌 파일의 diff가 비지 않아야 한다. 그냥 `git diff`는 combined diff라 읽지 못했다.
        let conflicted = try XCTUnwrap(status.changes.first { $0.area == .conflicted && $0.path == "a.txt" })
        let files = try await repo.diff(for: conflicted)
        let added = files.flatMap { $0.hunks }.flatMap { $0.lines }.filter { $0.kind == .addition }.map { $0.text }
        XCTAssertTrue(added.contains { $0.hasPrefix("<<<<<<<") })
        XCTAssertTrue(added.contains("topic"))
        try await repo.run(["rebase", "--abort"])

        try await repo.run(["checkout", "-q", "v1.0"])
        status = try await repo.status()
        XCTAssertTrue(status.isDetached)
        place = try await repo.detachedPlace()
        XCTAssertNil(place.rebasingBranch)
        XCTAssertEqual(place.tag, "v1.0")
    }

    func testLastFetchDate() async throws {
        try write("a.txt", "one\n")
        try await repo.stageAll()
        try await repo.commit(message: "first", amend: false)
        var fetched = try await repo.lastFetchDate()
        XCTAssertNil(fetched)
        let bare = root.deletingLastPathComponent().appendingPathComponent("bare-\(UUID().uuidString).git")
        try await repo.run(["init", "-q", "--bare", "-b", "main", bare.path])
        defer { try? FileManager.default.removeItem(at: bare) }
        try await repo.addRemote("origin", url: bare.path)
        let before = Date().addingTimeInterval(-2)
        try await repo.fetch()
        fetched = try await repo.lastFetchDate()
        XCTAssertGreaterThan(try XCTUnwrap(fetched), before)
    }
}

extension GitRepositoryTests {
    /// 합쳐 보기만 하고 작업 트리·브랜치는 그대로여야 한다. 충돌 파일과 그 안의 충돌 표시를 얻는다.
    func testPreviewMerge() async throws {
        try write("a.txt", "base\n")
        try write("b.txt", "base\n")
        try await repo.stageAll()
        try await repo.commit(message: "base", amend: false)
        try await repo.createBranch("topic", from: nil, checkout: true)
        try write("a.txt", "topic\n")
        try await repo.stageAll()
        try await repo.commit(message: "topic a", amend: false)
        try write("c.txt", "only topic\n")
        try await repo.stageAll()
        try await repo.commit(message: "topic c", amend: false)
        let topicC = try await repo.log(revision: "topic", limit: 1)[0]
        try await repo.run(["checkout", "-q", "main"])
        try write("a.txt", "main\n")
        try await repo.stageAll()
        try await repo.commit(message: "main a", amend: false)
        let mainBefore = try await repo.log(revision: "main", limit: 1)[0].hash

        let conflicted = try await repo.previewMerge(ours: "main", theirs: "topic")
        XCTAssertEqual(conflicted.conflicts, ["a.txt"])
        let files = try await repo.diff(from: "main", toTree: conflicted.tree, paths: conflicted.conflicts)
        let added = files.flatMap { $0.hunks }.flatMap { $0.lines }.filter { $0.kind == .addition }.map { $0.text }
        XCTAssertTrue(added.contains { $0.hasPrefix("<<<<<<<") })

        // 체리픽: topic의 마지막 커밋(c.txt 추가)만 옮기면 충돌이 없다
        let pick = try await repo.previewMerge(ours: "main", theirs: topicC.hash, mergeBase: topicC.parents[0])
        XCTAssertTrue(pick.isClean)

        // 아무것도 바뀌지 않았다
        let status = try await repo.status()
        XCTAssertEqual(status.branch, "main")
        XCTAssertTrue(status.changes.isEmpty)
        let mainAfter = try await repo.log(revision: "main", limit: 1)[0].hash
        XCTAssertEqual(mainAfter, mainBefore)
    }
}

extension GitRepositoryTests {
    /// 원격 브랜치에만 있는 커밋을 찾고, 원격에서 지운 브랜치를 같은 커밋으로 다시 올린다.
    func testRemoteBranchDeleteSafetyNet() async throws {
        try write("a.txt", "one\n")
        try await repo.stageAll()
        try await repo.commit(message: "first", amend: false)
        let bare = root.deletingLastPathComponent().appendingPathComponent("del-bare-\(UUID().uuidString).git")
        try await repo.run(["init", "-q", "--bare", "-b", "main", bare.path])
        defer { try? FileManager.default.removeItem(at: bare) }
        try await repo.addRemote("origin", url: bare.path)
        try await repo.run(["push", "-q", "origin", "main"])

        // 원격에만 남는 커밋: 브랜치를 올리고 이 컴퓨터의 브랜치는 지운다
        try await repo.createBranch("topic", from: nil, checkout: true)
        try write("t.txt", "topic\n")
        try await repo.stageAll()
        try await repo.commit(message: "topic only", amend: false)
        try await repo.run(["push", "-q", "origin", "topic"])
        try await repo.run(["checkout", "-q", "main"])
        try await repo.run(["branch", "-D", "topic"])
        try await repo.fetch()
        let onlyHere = try await repo.log(revisions: ["refs/remotes/origin/topic", "--not", "--branches", "--tags", "--exclude=origin/topic", "--remotes"], limit: 50)
        XCTAssertEqual(onlyHere.map(\.subject), ["topic only"])

        // 이 컴퓨터에만 있는 커밋(푸시 안 함)
        try write("a.txt", "local\n")
        try await repo.stageAll()
        try await repo.commit(message: "not pushed", amend: false)
        let unpushed = try await repo.log(revisions: ["main", "--not", "--remotes"], limit: 50)
        XCTAssertEqual(unpushed.map(\.subject), ["not pushed"])

        // 원격에서 지우고 다시 올린다
        let tip = try await repo.run(["rev-parse", "refs/remotes/origin/topic"]).stdout.trimmed
        try await repo.deleteRemoteBranch(remote: "origin", branch: "topic")
        try await repo.fetch()
        var names = try await repo.branches().map(\.name)
        XCTAssertFalse(names.contains("origin/topic"))
        try await repo.pushBranch(remote: "origin", name: "topic", commit: tip)
        try await repo.fetch()
        names = try await repo.branches().map(\.name)
        XCTAssertTrue(names.contains("origin/topic"))
    }
}

extension GitRepositoryTests {
    /// 실행 명령이 되는 저장소 설정과 훅을 찾는다. 평범한 저장소는 아무것도 걸리지 않아야 한다.
    func testRepositoryTrustDetection() async throws {
        try write("a.txt", "one\n")
        try await repo.stageAll()
        try await repo.commit(message: "first", amend: false)
        var found = await RepositoryTrust.executableSettings(in: repo)
        XCTAssertEqual(found, [])

        // 내장 자격 증명 도우미는 괜찮다
        try await repo.run(["config", "credential.helper", "osxkeychain"])
        found = await RepositoryTrust.executableSettings(in: repo)
        XCTAssertEqual(found, [])

        try await repo.run(["config", "merge.evil.driver", "touch /tmp/x %A"])
        try await repo.run(["config", "filter.lfsx.clean", "sh -c evil"])
        let hook = root.appendingPathComponent(".git/hooks/post-checkout")
        try "#!/bin/sh\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        found = await RepositoryTrust.executableSettings(in: repo)
        XCTAssertTrue(found.contains { $0.hasPrefix("merge.evil.driver") })
        XCTAssertTrue(found.contains { $0.hasPrefix("filter.lfsx.clean") })
        XCTAssertTrue(found.contains("훅 post-checkout"))

        // 신뢰를 적어 두면 같은 설정은 다시 묻지 않고, 바뀌면 다시 묻는다
        let key = "test-trust-\(UUID().uuidString)"
        RepositoryTrust.trust(root: key, settings: found)
        XCTAssertTrue(RepositoryTrust.isTrusted(root: key, settings: found))
        XCTAssertFalse(RepositoryTrust.isTrusted(root: key, settings: found + ["core.sshCommand = evil"]))
    }
}

final class RemoteDisplayTests: XCTestCase {
    func testRepositoryPath() {
        XCTAssertEqual(Remote(name: "a", url: "git@github.com:acme/pantry-ios.git").repositoryPath, "acme/pantry-ios")
        XCTAssertEqual(Remote(name: "a", url: "https://github.com/jdoe/pantry-ios").repositoryPath, "jdoe/pantry-ios")
        XCTAssertEqual(Remote(name: "a", url: "ssh://git@host:2222/team/repo.git").repositoryPath, "team/repo")
        XCTAssertEqual(Remote(name: "a", url: "https://gitlab.com/group/sub/repo.git/").repositoryPath, "sub/repo")
        XCTAssertEqual(Remote(name: "a", url: "/tmp/bare.git").repositoryPath, "/tmp/bare.git")
    }
}

extension GitRepositoryTests {
    /// 줄 단위로 스테이징·해제·버리기. hunk 하나에 바뀐 줄이 여럿일 때 고른 줄만 움직여야 한다.
    func testLineLevelStaging() async throws {
        try write("f.txt", "a\nb\nc\nd\ne\n")
        try await repo.stageAll()
        try await repo.commit(message: "base", amend: false)
        // b → B, d 지움, e 뒤에 f 추가: hunk 하나
        try write("f.txt", "a\nB\nc\ne\nf\n")

        var status = try await repo.status()
        var files = try await repo.diff(for: status.unstaged[0])
        var hunk = try XCTUnwrap(files.first?.hunks.first)
        // "+B"와 "-b"만 고른다
        let pick = Set(hunk.lines.filter { ($0.kind == .addition && $0.text == "B") || ($0.kind == .deletion && $0.text == "b") }.map(\.id))
        let stagePatch = try XCTUnwrap(files[0].patch(for: hunk, selecting: pick, reverse: false))
        try await repo.applyPatch(stagePatch, cached: true, reverse: false)
        var cached = try await repo.run(["show", ":f.txt"]).stdout
        XCTAssertEqual(cached, "a\nB\nc\nd\ne\n")

        // 스테이징된 쪽에서 다시 그 줄을 해제하면 처음으로 돌아간다
        status = try await repo.status()
        files = try await repo.diff(for: status.staged[0])
        hunk = try XCTUnwrap(files.first?.hunks.first)
        let unpick = Set(hunk.lines.filter { $0.kind == .addition || $0.kind == .deletion }.map(\.id))
        let unstagePatch = try XCTUnwrap(files[0].patch(for: hunk, selecting: unpick, reverse: true))
        try await repo.applyPatch(unstagePatch, cached: true, reverse: true)
        cached = try await repo.run(["show", ":f.txt"]).stdout
        XCTAssertEqual(cached, "a\nb\nc\nd\ne\n")

        // 작업 트리에서 "+f" 줄만 버린다
        status = try await repo.status()
        files = try await repo.diff(for: status.unstaged[0])
        hunk = try XCTUnwrap(files.first?.hunks.first)
        let dropF = Set(hunk.lines.filter { $0.kind == .addition && $0.text == "f" }.map(\.id))
        let discardPatch = try XCTUnwrap(files[0].patch(for: hunk, selecting: dropF, reverse: true))
        try await repo.applyPatch(discardPatch, cached: false, reverse: true)
        let worktree = try String(contentsOf: root.appendingPathComponent("f.txt"), encoding: .utf8)
        XCTAssertEqual(worktree, "a\nB\nc\ne\n")

        // 바뀐 줄을 하나도 안 고르면 패치를 만들지 않는다
        let contextOnly = Set(hunk.lines.filter { $0.kind == .context }.map(\.id))
        XCTAssertNil(files[0].patch(for: hunk, selecting: contextOnly, reverse: false))
    }
}
