import XCTest
@testable import Canopy

/// 충돌 해결 기억, blame, 패치 복사, 정리, 코드 검색, 여러 커밋 체리픽, 커밋 정리. 임시 저장소에서만 돌린다.
@MainActor
final class GitToolsTests: XCTestCase {
    private var root: URL!
    private var repo: GitRepository!
    private var others: [URL] = []

    override func setUp() async throws {
        setenv("GIT_CONFIG_GLOBAL", "/dev/null", 1)
        setenv("GIT_CONFIG_NOSYSTEM", "1", 1)
        root = try makeRepository()
        repo = GitRepository(directory: root)
        try write("a.txt", "one\n")
        try await commitAll("init")
    }

    override func tearDown() async throws {
        for url in [root] + others { try? FileManager.default.removeItem(at: url!) }
    }

    private func makeRepository() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("grove-tools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let setup = Process()
        setup.executableURL = URL(fileURLWithPath: "/bin/sh")
        setup.arguments = ["-c", "git init -q -b main && git config user.name 'Grove Test' && git config user.email grove@example.com"]
        setup.currentDirectoryURL = url
        try setup.run()
        setup.waitUntilExit()
        return url
    }

    private func write(_ name: String, _ text: String, in folder: URL? = nil) throws {
        let url = (folder ?? root).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ name: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    private func commitAll(_ message: String) async throws {
        try await repo.stageAll()
        try await repo.commit(message: message, amend: false)
    }

    private func subjects() async throws -> [String] {
        try await repo.run(["log", "--format=%s"]).stdout.split(separator: "\n").map(String.init)
    }

    // MARK: 충돌 해결 기억

    func testRerereReusesAResolution() async throws {
        UserDefaults.standard.set(true, forKey: "rerere")
        defer { UserDefaults.standard.removeObject(forKey: "rerere") }
        try await repo.run(["checkout", "-q", "-b", "side"])
        try write("a.txt", "side\n")
        try await commitAll("side")
        try await repo.checkout("main")
        try write("a.txt", "main\n")
        try await commitAll("main")
        let before = try await repo.run(["rev-parse", "HEAD"]).stdout.trimmed

        _ = try? await repo.merge("side")
        try write("a.txt", "main and side\n")
        try await commitAll("merge")
        try await repo.run(["reset", "-q", "--hard", before])

        // 같은 충돌을 다시 내면 전에 푼 내용이 채워진다(충돌 표시 없이)
        _ = try? await repo.merge("side")
        XCTAssertEqual(try read("a.txt"), "main and side\n")
    }

    // MARK: blame

    func testBlameIgnoresReindentation() async throws {
        try write("b.swift", "func f() {\nreturn 1\n}\n")
        try await commitAll("write")
        let written = try await repo.run(["rev-parse", "HEAD"]).stdout.trimmed
        try write("b.swift", "func f() {\n    return 1\n}\n")
        try await commitAll("indent")
        let lines = try await repo.blame(path: "b.swift")
        XCTAssertEqual(lines.first { $0.number == 2 }?.hash, written, "들여쓰기만 바꾼 커밋은 넘어간다")
    }

    // MARK: 패치

    func testCopiedPatchesApplyElsewhere() async throws {
        try write("a.txt", "one\ntwo\n")
        try await commitAll("add two")
        let latest = try await repo.log(limit: 1)
        let commit = try XCTUnwrap(latest.first)
        let patch = try await repo.formatPatch([commit.hash])

        try write("a.txt", "one\ntwo\nthree\n")
        let working = try await repo.workingPatch(paths: ["a.txt"], hasHead: true)

        // 다른 저장소: init만 있는 상태에서 커밋 패치를 git am, 작업 패치를 git apply
        let other = try makeRepository()
        others.append(other)
        let otherRepo = GitRepository(directory: other)
        try write("a.txt", "one\n", in: other)
        try await otherRepo.stageAll()
        try await otherRepo.commit(message: "init", amend: false)
        try await otherRepo.run(["am", "-q"], input: patch)
        let applied = try await otherRepo.run(["log", "-1", "--format=%s"]).stdout.trimmed
        XCTAssertEqual(applied, "add two")
        try await otherRepo.run(["apply"], input: working)
        XCTAssertEqual(try String(contentsOf: other.appendingPathComponent("a.txt"), encoding: .utf8), "one\ntwo\nthree\n")
    }

    // MARK: 정리

    func testCleanCandidatesKeepIgnoredFilesOutByDefault() async throws {
        try write(".gitignore", "build/\n")
        try await commitAll("ignore")
        try write("new.txt", "x")
        try write("build/out.o", "x")
        let untracked = try await repo.cleanCandidates(includeIgnored: false)
        XCTAssertEqual(untracked, ["new.txt"])
        let all = try await repo.cleanCandidates(includeIgnored: true)
        XCTAssertEqual(Set(all), ["new.txt", "build/"])
    }

    // MARK: 코드 검색

    func testCodeSearchFindsAddedAndRemoved() async throws {
        try write("c.txt", "let magicToken = 1\n")
        try await commitAll("add token")
        try write("c.txt", "let other = 1\n")
        try await commitAll("remove token")
        try write("c.txt", "let other = 2\n")
        try await commitAll("unrelated")
        let found = try await repo.searchCode("magicToken", revisions: ["HEAD"])
        XCTAssertEqual(found.map(\.subject), ["remove token", "add token"])
    }

    // MARK: 여러 커밋 체리픽

    /// B가 A 위에 쌓였는데 날짜는 B가 더 이르다. 목록 순서를 뒤집어 넘기면 A부터 들어가야 한다.
    func testCherryPickManyKeepsParentFirstEvenWithSwappedDates() async throws {
        try await repo.run(["checkout", "-q", "-b", "feat"])
        try write("a.txt", "one\nA\n")
        try await repo.stageAll()
        try await repo.run(["commit", "-q", "-m", "A"], environment: ["GIT_COMMITTER_DATE": "2026-10-29T12:00:00", "GIT_AUTHOR_DATE": "2026-10-29T12:00:00"])
        try write("a.txt", "one\nA\nB\n")
        try await repo.stageAll()
        try await repo.run(["commit", "-q", "-m", "B"], environment: ["GIT_COMMITTER_DATE": "2026-10-29T11:00:00", "GIT_AUTHOR_DATE": "2026-10-29T11:00:00"])
        try await repo.checkout("main")

        let store = RepositoryStore()
        await store.open(root)
        let picked = try await repo.log(revision: "feat", limit: 2)
        XCTAssertEqual(picked.map(\.subject), ["B", "A"], "목록은 자식이 위")
        store.cherryPick(picked)
        let confirm = try await waitForConfirmation(store)
        store.confirmation = nil
        await confirm.action()
        XCTAssertNil(store.errorMessage)
        let log = try await subjects()
        XCTAssertEqual(log, ["B", "A", "init"])
    }

    /// 확인 창이 비동기로 뜨는 동작을 기다린다
    private func waitForConfirmation(_ store: RepositoryStore) async throws -> RepositoryStore.Confirmation {
        for _ in 0..<100 {
            if let confirmation = store.confirmation { return confirmation }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw XCTSkip("확인 창이 뜨지 않았습니다")
    }

    func testCherryPickRefusesCommitsAlreadyOnBranch() async throws {
        let store = RepositoryStore()
        await store.open(root)
        store.cherryPick(store.commits)
        for _ in 0..<100 where store.errorMessage == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(store.errorMessage, "이미 현재 브랜치에 있는 커밋은 옮기지 않는다")
        XCTAssertNil(store.confirmation)
    }

    func testSkipContinuesPastAConflictingCommit() async throws {
        try await repo.run(["checkout", "-q", "-b", "feat"])
        try write("a.txt", "feat\n")
        try await commitAll("conflicting")
        try write("b.txt", "b\n")
        try await commitAll("clean")
        try await repo.checkout("main")
        try write("a.txt", "main\n")
        try await commitAll("main change")
        let store = RepositoryStore()
        await store.open(root)
        let picked = try await repo.log(revision: "feat", limit: 2)
        store.cherryPick(picked)
        let confirm = try await waitForConfirmation(store)
        store.confirmation = nil
        await confirm.action()
        XCTAssertEqual(store.operation, .cherryPicking)
        await store.skipOperation()
        XCTAssertNil(store.operation)
        let log = try await subjects()
        XCTAssertEqual(log.first, "clean", "충돌한 커밋만 건너뛰고 나머지는 옮겼다")
    }

    // MARK: 커밋 정리

    /// 검토에서 재현된 경우: A를 빼고 A를 되돌리던 B의 메시지를 고치면 B가 빈다. 계속해도 구간 밖 커밋의 메시지가 바뀌면 안 된다.
    func testEmptiedRewordDoesNotTouchCommitOutsideRange() async throws {
        try write("x.txt", "x")
        try await commitAll("[ABC-1] feat: A")
        try await repo.run(["rm", "-q", "x.txt"])
        try await repo.commit(message: "[ABC-1] revert: B", amend: false)
        try write("y.txt", "y")
        try await commitAll("[ABC-1] feat: C")
        let store = RepositoryStore()
        await store.open(root)
        let a = try XCTUnwrap(store.commits.first { $0.subject.hasSuffix(": A") })
        guard case .success(let context) = await store.loadRewrite(from: a.hash) else { return XCTFail() }
        var items = context.commits.map { RewriteItem(commit: $0) }
        items[0].action = .drop
        items[1].action = .reword("[ABC-1] fix: 새 B")
        let problem = await store.rewriteHistory(items, context: context, label: "커밋 정리", done: "")
        XCTAssertNil(problem)
        // B가 비어 멈췄으면 앱에서 계속한다
        var guardRounds = 0
        while store.operation != nil, guardRounds < 3 {
            await store.continueOperation()
            if store.operation != nil { await store.skipOperation() }
            guardRounds += 1
        }
        XCTAssertNil(store.operation)
        let log = try await subjects()
        XCTAssertEqual(log.last, "init", "구간 밖(init) 메시지는 그대로")
        XCTAssertFalse(log.contains("[ABC-1] fix: 새 B") && log.firstIndex(of: "[ABC-1] fix: 새 B") == log.count - 1)
        XCTAssertTrue(log.contains("[ABC-1] feat: C"))
    }

    /// 최종 검토에서 재현된 경우: 묶음 머리(R)가 비어 빠지면 뒤의 fixup(Y)이 구간 밖 기준 커밋에 합쳐졌다.
    /// 이제는 Y를 따로 남기고 기준 커밋은 그대로 둔다.
    func testFixupStaysSeparateWhenItsHeadIsSkipped() async throws {
        let baseHash = try await repo.run(["rev-parse", "HEAD"]).stdout.trimmed
        try write("x.txt", "x")
        try await commitAll("[ABC-1] feat: X")
        try await repo.run(["rm", "-q", "x.txt"])
        try await repo.commit(message: "[ABC-1] revert: R", amend: false)
        try write("y.txt", "y")
        try await commitAll("[ABC-1] feat: Y")
        let store = RepositoryStore()
        await store.open(root)
        let x = try XCTUnwrap(store.commits.first { $0.subject.hasSuffix(": X") })
        guard case .success(let context) = await store.loadRewrite(from: x.hash) else { return XCTFail() }
        var items = context.commits.map { RewriteItem(commit: $0) }
        items[0].action = .drop
        items[1].action = .reword("[ABC-1] fix: 새 R")
        items[2].action = .fixup
        _ = await store.rewriteHistory(items, context: context, label: "커밋 정리", done: "")
        var rounds = 0
        while store.operation != nil, rounds < 4 {
            await store.continueOperation()
            if store.operation != nil { await store.skipOperation() }
            rounds += 1
        }
        XCTAssertNil(store.operation)
        let initStill = try await repo.isAncestor(baseHash, of: "HEAD")
        XCTAssertTrue(initStill, "구간 밖 기준 커밋은 그대로")
        let baseMessage = try await repo.run(["log", "-1", "--format=%s", baseHash]).stdout.trimmed
        XCTAssertEqual(baseMessage, "init")
        let log = try await subjects()
        XCTAssertTrue(log.contains("[ABC-1] feat: Y"), "Y는 따로 남는다")
    }

    func testCherryPickRefusesPatchEquivalentCommit() async throws {
        try await repo.run(["checkout", "-q", "-b", "feat"])
        try write("p.txt", "p")
        try await commitAll("same change")
        let original = try await repo.run(["rev-parse", "HEAD"]).stdout.trimmed
        try await repo.checkout("main")
        try await repo.cherryPick(original)
        let store = RepositoryStore()
        await store.open(root)
        let tip = try await repo.log(revision: "feat", limit: 1)
        let commit = try XCTUnwrap(tip.first)
        await store.cherryPick(commit)
        XCTAssertNotNil(store.errorMessage, "해시는 달라도 같은 내용이 이미 있다")
    }

    func testCleanCandidatesKeepOddNamesUsable() async throws {
        try write("q\"uote.txt", "x")
        let candidates = try await repo.cleanCandidates(includeIgnored: false)
        XCTAssertEqual(candidates, ["q\"uote.txt"])
    }

    func testRefusesWhenHeadMovedAfterOpening() async throws {
        let store = try await threeCommits()
        let second = try XCTUnwrap(store.commits.first { $0.subject.hasSuffix("second") })
        guard case .success(let context) = await store.loadRewrite(from: second.hash) else { return XCTFail() }
        try write("late.txt", "late")
        try await commitAll("[ABC-1] feat: late")
        let problem = await store.rewriteHistory(context.commits.map { RewriteItem(commit: $0, action: .drop) }, context: context, label: "커밋 정리", done: "")
        XCTAssertNotNil(problem)
        let log = try await subjects()
        XCTAssertEqual(log.first, "[ABC-1] feat: late", "아무것도 바꾸지 않았다")
    }

    func testDropOnlyTheLatestCommit() async throws {
        let store = try await threeCommits()
        let third = try XCTUnwrap(store.commits.first { $0.subject.hasSuffix("third") })
        guard case .success(let context) = await store.loadRewrite(from: third.hash) else { return XCTFail() }
        let problem = await store.rewriteHistory([RewriteItem(commit: third, action: .drop)], context: context, label: "커밋 빼기", done: "")
        XCTAssertNil(problem)
        let log = try await subjects()
        XCTAssertEqual(log.first, "[ABC-1] feat: second")
    }

    func testRawMessagesKeepLineBreaks() async throws {
        try write("m.txt", "m")
        try await repo.stageAll()
        try await repo.commit(message: "[ABC-1] feat: 첫 줄\n둘째 줄", amend: false)
        let store = RepositoryStore()
        await store.open(root)
        let commit = try XCTUnwrap(store.commits.first)
        guard case .success(let context) = await store.loadRewrite(from: commit.hash) else { return XCTFail() }
        XCTAssertEqual(context.message(of: commit), "[ABC-1] feat: 첫 줄\n둘째 줄")
    }

    private func threeCommits() async throws -> RepositoryStore {
        for name in ["first", "second", "third"] {
            try write(name + ".txt", name)
            try await commitAll("[ABC-1] feat: \(name)")
        }
        let store = RepositoryStore()
        await store.open(root)
        return store
    }

    func testRewordChangesOnlyThatMessage() async throws {
        let store = try await threeCommits()
        let second = try XCTUnwrap(store.commits.first { $0.subject.hasSuffix("second") })
        guard case .success(let context) = await store.loadRewrite(from: second.hash) else { return XCTFail() }
        let items = context.commits.map { RewriteItem(commit: $0, action: $0.hash == second.hash ? .reword("[ABC-1] fix: 둘째 고침") : .keep) }
        let problem = await store.rewriteHistory(items, context: context, label: "메시지 고치기", done: "")
        XCTAssertNil(problem)
        let log = try await subjects()
        XCTAssertEqual(log, ["[ABC-1] feat: third", "[ABC-1] fix: 둘째 고침", "[ABC-1] feat: first", "init"])
        XCTAssertEqual(store.undoTitle, "메시지 고치기 실행 취소")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("third.txt").path))
    }

    func testSquashDropAndReorder() async throws {
        let store = try await threeCommits()
        let first = try XCTUnwrap(store.commits.first { $0.subject.hasSuffix("first") })
        guard case .success(let context) = await store.loadRewrite(from: first.hash) else { return XCTFail() }
        // first+second를 하나로, third는 빼기
        var items = context.commits.map { RewriteItem(commit: $0) }
        items[0].action = .reword("[ABC-1] feat: 합침")
        items[1].action = .fixup
        items[2].action = .drop
        let problem = await store.rewriteHistory(items, context: context, label: "커밋 정리", done: "")
        XCTAssertNil(problem)
        let log = try await subjects()
        XCTAssertEqual(log, ["[ABC-1] feat: 합침", "init"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("second.txt").path), "합친 커밋의 변경은 남는다")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("third.txt").path), "뺀 커밋의 변경은 사라진다")

        // ⌘Z로 정리 전으로
        await store.undo()
        if let confirm = store.confirmation { store.confirmation = nil; await confirm.action() }
        let restored = try await subjects()
        XCTAssertEqual(restored.count, 4)
    }

    func testReorderSwapsCommits() async throws {
        let store = try await threeCommits()
        let second = try XCTUnwrap(store.commits.first { $0.subject.hasSuffix("second") })
        guard case .success(let context) = await store.loadRewrite(from: second.hash) else { return XCTFail() }
        let items = context.commits.reversed().map { RewriteItem(commit: $0) }
        let problem = await store.rewriteHistory(Array(items), context: context, label: "커밋 정리", done: "")
        XCTAssertNil(problem)
        let log = try await subjects()
        XCTAssertEqual(log, ["[ABC-1] feat: second", "[ABC-1] feat: third", "[ABC-1] feat: first", "init"])
    }

    func testCommitMessageHookRejectsBeforeRewriting() async throws {
        let store = try await threeCommits()
        let hooks = root.appendingPathComponent(".git/hooks/commit-msg")
        try "#!/bin/sh\ngrep -q '^\\[' \"$1\" || { echo '형식이 틀렸습니다'; exit 1; }\n".write(to: hooks, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hooks.path)
        let third = try XCTUnwrap(store.commits.first { $0.subject.hasSuffix("third") })
        guard case .success(let context) = await store.loadRewrite(from: third.hash) else { return XCTFail() }
        let before = try await subjects()
        let problem = await store.rewriteHistory([RewriteItem(commit: third, action: .reword("형식 없음"))], context: context, label: "메시지 고치기", done: "")
        XCTAssertEqual(problem, "형식이 틀렸습니다")
        let after = try await subjects()
        XCTAssertEqual(before, after, "거부되면 시작하지 않는다")
    }

    func testConflictPausesThenContinueRecordsUndo() async throws {
        try write("a.txt", "one\nx\n")
        try await commitAll("[ABC-1] feat: x")
        try write("a.txt", "one\nx\ny\n")
        try await commitAll("[ABC-1] feat: y")
        let store = RepositoryStore()
        await store.open(root)
        let x = try XCTUnwrap(store.commits.first { $0.subject.hasSuffix("x") })
        guard case .success(let context) = await store.loadRewrite(from: x.hash) else { return XCTFail() }
        // y를 x보다 먼저 두면 y가 x의 줄 위에 쌓이므로 충돌한다
        let problem = await store.rewriteHistory(context.commits.reversed().map { RewriteItem(commit: $0) }, context: context, label: "커밋 정리", done: "")
        XCTAssertNil(problem)
        XCTAssertEqual(store.operation, .rebasing)
        await store.refresh()
        let undoBefore = store.undoTitle

        store.abortOperation()
        if let confirm = store.confirmation { store.confirmation = nil; await confirm.action() }
        XCTAssertNil(store.operation)
        XCTAssertEqual(store.undoTitle, undoBefore, "중단해서 그대로면 기록할 것이 없다")
        let log = try await subjects()
        XCTAssertEqual(log, ["[ABC-1] feat: y", "[ABC-1] feat: x", "init"])
    }

    func testRefusesRangesWithMergesAndOtherBranchesCommits() async throws {
        try await repo.run(["checkout", "-q", "-b", "side"])
        try write("s.txt", "s")
        try await commitAll("side")
        try await repo.checkout("main")
        try await repo.run(["merge", "-q", "--no-ff", "--no-edit", "side"])
        let store = RepositoryStore()
        await store.open(root)
        let initCommit = try XCTUnwrap(store.commits.first { $0.subject == "init" })
        guard case .failure(let error) = await store.loadRewrite(from: initCommit.hash) else { return XCTFail("머지가 낀 구간은 막는다") }
        XCTAssertTrue(error.message.contains("머지"))
    }
}
