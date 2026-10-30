import XCTest
@testable import Canopy

/// Git Flow 시작·마무리와 PR 주소. 임시 저장소에서 store를 그대로 돌린다.
@MainActor
final class GitFlowTests: XCTestCase {
    private var root: URL!
    private var repo: GitRepository!

    override func setUp() async throws {
        setenv("GIT_CONFIG_GLOBAL", "/dev/null", 1)
        setenv("GIT_CONFIG_NOSYSTEM", "1", 1)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grove-flow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        repo = GitRepository(directory: root)
        try await repo.run(["init", "-q", "-b", "main"])
        try await repo.run(["config", "user.name", "Grove Test"])
        try await repo.run(["config", "user.email", "grove@example.com"])
        try write("a.txt", "one\n")
        try await repo.stageAll()
        try await repo.commit(message: "init", amend: false)
        try await repo.run(["branch", "develop"])
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: root.appendingPathExtension("wt"))
    }

    private func write(_ name: String, _ text: String) throws {
        try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func commitAll(_ message: String) async throws {
        try await repo.stageAll()
        try await repo.commit(message: message, amend: false)
    }

    private func parents(of ref: String) async throws -> [String] {
        try await repo.run(["rev-list", "--parents", "-n", "1", ref]).stdout.split(separator: " ").dropFirst().map(String.init)
    }

    // MARK: 설정과 단계

    func testConfigReadsGitFlowSettingsAndFallsBack() {
        let fallback = GitFlowConfig(settings: [:], branchNames: ["master", "develop"])
        XCTAssertEqual(fallback.production, "master", "main이 없고 master만 있으면 master")
        XCTAssertEqual(fallback.prefix(.feature), "feature/")
        XCTAssertEqual(fallback.kind(of: "release/1.0"), .release)
        XCTAssertNil(fallback.kind(of: "release/"), "접두어만 있는 이름은 아니다")
        XCTAssertNil(fallback.kind(of: "develop"))

        let custom = GitFlowConfig(settings: [
            "gitflow.branch.master": "prod", "gitflow.branch.develop": "dev",
            "gitflow.prefix.feature": "feat-", "gitflow.prefix.versiontag": "v",
        ], branchNames: [])
        XCTAssertEqual(custom.production, "prod")
        XCTAssertEqual(custom.base(of: .feature), "dev")
        XCTAssertEqual(custom.base(of: .hotfix), "prod")
        XCTAssertEqual(custom.kind(of: "feat-login"), .feature)
        let steps = GitFlowRun.finishSteps(kind: .release, branch: "release/2.0", config: custom, openRelease: nil, pushRemote: nil, pushTargets: false)
        XCTAssertTrue(steps.contains(.tag(name: "v2.0", target: "prod")))
    }

    func testHotfixMergesIntoOpenReleaseInsteadOfDevelop() {
        let config = GitFlowConfig(settings: [:], branchNames: ["main", "develop"])
        let steps = GitFlowRun.finishSteps(kind: .hotfix, branch: "hotfix/1.0.1", config: config, openRelease: "release/1.1", pushRemote: "origin", pushTargets: true)
        XCTAssertEqual(steps, [
            .checkout("main"), .merge(source: "hotfix/1.0.1", target: "main"), .tag(name: "1.0.1", target: "main"),
            .checkout("release/1.1"), .merge(source: "hotfix/1.0.1", target: "release/1.1"),
            .deleteBranch("hotfix/1.0.1"),
            .push(branch: "main", remote: "origin"), .push(branch: "release/1.1", remote: "origin"), .pushTag(name: "1.0.1", remote: "origin"),
        ])
    }

    // MARK: 실행

    func testStartAndFinishRelease() async throws {
        let store = RepositoryStore()
        await store.open(root)
        let started = await store.startGitFlow(kind: .release, name: "1.0.0")
        XCTAssertTrue(started)
        XCTAssertEqual(store.status.branch, "release/1.0.0")
        try write("a.txt", "one\nrelease\n")
        try await commitAll("release fix")
        await store.refresh()

        await store.prepareGitFlowFinish(branch: "release/1.0.0")
        let run = try XCTUnwrap(store.gitFlowRun)
        XCTAssertEqual(run.blockers, [])
        await store.runGitFlow()

        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.gitFlowRun?.isFinished, true)
        let mainParents = try await parents(of: "main")
        let developParents = try await parents(of: "develop")
        XCTAssertEqual(mainParents.count, 2, "fast-forward가 아니라 머지 커밋")
        XCTAssertEqual(developParents.count, 2)
        let tagExists = try await repo.tagExists("1.0.0")
        XCTAssertTrue(tagExists)
        let branchExists = try await repo.localBranchExists("release/1.0.0")
        XCTAssertFalse(branchExists)
        XCTAssertEqual(store.status.branch, "develop")
        XCTAssertEqual(store.undoTitle, "Git Flow 마무리 실행 취소")
    }

    /// git-flow(AVH판)는 feature마다 기준을 적어 두고 거기로 머지한다. 다른 feature 위에서 시작한 feature가 develop으로 가면 안 된다.
    func testFeatureFinishesIntoRecordedBase() async throws {
        try await repo.run(["config", "gitflow.branch.master", "main"])
        try await repo.run(["config", "gitflow.branch.develop", "develop"])
        try await repo.run(["branch", "feature/dialog", "develop"])
        let store = RepositoryStore()
        await store.open(root)
        let started = await store.startGitFlow(kind: .feature, name: "child", base: "feature/dialog")
        XCTAssertTrue(started)
        let recorded = try await repo.run(["config", "gitflow.branch.feature/child.base"]).stdout.trimmed
        XCTAssertEqual(recorded, "feature/dialog")
        try write("b.txt", "child\n")
        try await commitAll("child work")
        await store.refresh()

        await store.prepareGitFlowFinish(branch: "feature/child")
        XCTAssertEqual(store.gitFlowRun?.steps.map(\.action), [
            .checkout("feature/dialog"), .merge(source: "feature/child", target: "feature/dialog"), .deleteBranch("feature/child"),
        ])
        await store.runGitFlow()
        XCTAssertEqual(store.gitFlowRun?.isFinished, true)
        let dialogParents = try await parents(of: "feature/dialog")
        XCTAssertEqual(dialogParents.count, 2)
        let developHasChild = try await repo.isAncestor("HEAD", of: "develop")
        XCTAssertFalse(developHasChild, "develop에는 머지하지 않는다")
        let left = try await repo.run(["config", "gitflow.branch.feature/child.base"], allowedExitCodes: [0, 1]).stdout.trimmed
        XCTAssertEqual(left, "feature/dialog", "되돌려서 브랜치가 돌아오면 다시 쓰도록 기준 설정은 남긴다")
    }

    func testConflictPausesAndResumes() async throws {
        let store = RepositoryStore()
        await store.open(root)
        _ = await store.startGitFlow(kind: .release, name: "2.0")
        try write("a.txt", "release\n")
        try await commitAll("release change")
        // release를 만든 뒤 develop에서 같은 줄을 바꿔 develop 머지에서 충돌이 나게 한다
        try await repo.checkout("develop")
        try write("a.txt", "develop\n")
        try await commitAll("develop change")
        try await repo.checkout("release/2.0")
        await store.refresh()

        await store.prepareGitFlowFinish(branch: "release/2.0")
        let warned = store.gitFlowRun?.steps.contains { $0.action == .merge(source: "release/2.0", target: "develop") && $0.warning != nil }
        XCTAssertEqual(warned, true, "실행 전에 충돌을 미리 알린다")
        await store.runGitFlow()

        XCTAssertEqual(store.operation, .merging)
        XCTAssertEqual(store.gitFlowRun?.failedStep?.action, .merge(source: "release/2.0", target: "develop"))
        XCTAssertTrue(store.hasPausedGitFlow)
        let tagExists = try await repo.tagExists("2.0")
        XCTAssertTrue(tagExists, "충돌 전 단계는 끝났다")

        // 충돌을 풀고 계속하면 흐름 창이 다시 뜨고, 이어서 하면 남은 단계만 한다
        try write("a.txt", "develop\nrelease\n")
        try await repo.stageAll()
        await store.refresh()
        await store.continueOperation()
        XCTAssertNil(store.operation)
        XCTAssertEqual(store.sheet?.id, "gitFlowFinish")
        await store.runGitFlow()
        XCTAssertEqual(store.gitFlowRun?.isFinished, true)
        let branchExists = try await repo.localBranchExists("release/2.0")
        XCTAssertFalse(branchExists)
        let skipped = store.gitFlowRun?.steps.first { $0.action == .merge(source: "release/2.0", target: "develop") }?.state
        XCTAssertEqual(skipped, .skipped, "충돌을 풀며 이미 머지했으니 건너뛴다")
    }

    /// 검토에서 재현된 경우: main 머지에서 충돌 → 중단 → release에서 main을 받아 직접 해결 → 이어서.
    /// 이어서 할 때 HEAD가 release라도 머지는 main에 들어가야 한다.
    func testResumeMergesIntoTargetAfterManualResolution() async throws {
        try await repo.run(["checkout", "-q", "main"])
        try write("a.txt", "main hotfix\n")
        try await commitAll("main change")
        let store = RepositoryStore()
        await store.open(root)
        _ = await store.startGitFlow(kind: .release, name: "3.0")
        try write("a.txt", "release\n")
        try await commitAll("release change")
        await store.refresh()
        await store.prepareGitFlowFinish(branch: "release/3.0")
        await store.runGitFlow()
        XCTAssertEqual(store.operation, .merging)

        try await repo.run(["merge", "--abort"])
        try await repo.checkout("release/3.0")
        _ = try? await repo.run(["merge", "--no-edit", "main"])
        try write("a.txt", "release\nmain hotfix\n")
        try await commitAll("resolve on release")
        let releaseTip = try await repo.commitHash(of: "release/3.0")
        await store.refresh()
        await store.runGitFlow()

        XCTAssertEqual(store.gitFlowRun?.isFinished, true)
        let mainHasRelease = try await repo.isAncestor(XCTUnwrap(releaseTip), of: "main")
        XCTAssertTrue(mainHasRelease, "release가 main에 들어갔다")
        let tagCommit = try await repo.commitHash(of: "refs/tags/3.0")
        let mainCommit = try await repo.commitHash(of: "main")
        XCTAssertEqual(tagCommit, mainCommit)
    }

    func testStartFromRemoteBaseDoesNotTrackIt() async throws {
        try await repo.run(["remote", "add", "origin", "git@github.com:team/app.git"])
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout.trimmed
        try await repo.run(["update-ref", "refs/remotes/origin/shared", head])
        let store = RepositoryStore()
        await store.open(root)
        let started = await store.startGitFlow(kind: .feature, name: "r", base: "shared")
        XCTAssertTrue(started)
        let upstream = try await repo.run(["rev-parse", "--abbrev-ref", "feature/r@{upstream}"], allowedExitCodes: [0, 128])
        XCTAssertEqual(upstream.exitCode, 128, "origin/shared를 추적하면 푸시가 공용 브랜치로 간다")
    }

    /// 푸시한 뒤 커밋을 더 한 feature. `branch -d`는 원격 브랜치 기준으로 거부했지만 develop에 들어갔으니 지워야 한다.
    func testDeletesFeatureAheadOfItsUpstream() async throws {
        try await repo.run(["remote", "add", "origin", "git@github.com:team/app.git"])
        let store = RepositoryStore()
        await store.open(root)
        _ = await store.startGitFlow(kind: .feature, name: "z")
        let pushed = try await repo.run(["rev-parse", "HEAD"]).stdout.trimmed
        try await repo.run(["update-ref", "refs/remotes/origin/feature/z", pushed])
        try await repo.setUpstream("feature/z", to: "origin/feature/z")
        try write("z.txt", "more\n")
        try await commitAll("after push")
        await store.refresh()
        await store.prepareGitFlowFinish(branch: "feature/z")
        await store.runGitFlow()
        XCTAssertEqual(store.gitFlowRun?.isFinished, true, "\(String(describing: store.gitFlowRun?.failedStep))")
        let exists = try await repo.localBranchExists("feature/z")
        XCTAssertFalse(exists)
    }

    func testCancelIsRefusedWhileMergeIsInProgress() async throws {
        let store = RepositoryStore()
        await store.open(root)
        _ = await store.startGitFlow(kind: .feature, name: "c")
        try write("a.txt", "feature\n")
        try await commitAll("feature change")
        try await repo.checkout("develop")
        try write("a.txt", "develop\n")
        try await commitAll("develop change")
        try await repo.checkout("feature/c")
        await store.refresh()
        await store.prepareGitFlowFinish(branch: "feature/c")
        await store.runGitFlow()
        XCTAssertEqual(store.operation, .merging)
        store.errorMessage = nil
        await store.cancelGitFlow()
        XCTAssertNotNil(store.gitFlowRun, "머지 중에는 흐름을 버리지 않는다")
        XCTAssertNotNil(store.errorMessage)
    }

    /// 끊긴 릴리스(태그까지 달았는데 develop 머지에서 멈춤)를 앱을 다시 켠 뒤 다시 마무리할 수 있어야 한다
    func testInterruptedReleaseCanBeFinishedAgain() async throws {
        let store = RepositoryStore()
        await store.open(root)
        _ = await store.startGitFlow(kind: .release, name: "4.0")
        try write("a.txt", "release\n")
        try await commitAll("release change")
        try await repo.checkout("develop")
        try write("a.txt", "develop\n")
        try await commitAll("develop change")
        try await repo.checkout("release/4.0")
        await store.refresh()
        await store.prepareGitFlowFinish(branch: "release/4.0")
        await store.runGitFlow()
        XCTAssertEqual(store.operation, .merging)
        // 앱을 다시 켠 것처럼: 머지를 중단하고 흐름을 잊는다
        try await repo.run(["merge", "--abort"])
        store.gitFlowRun = nil
        await store.refresh()

        await store.prepareGitFlowFinish(branch: "release/4.0")
        XCTAssertEqual(store.gitFlowRun?.blockers, [], "이미 단 태그가 이 릴리스를 담고 있으면 막지 않는다")
        XCTAssertTrue(store.gitFlowRun?.notes.contains { $0.contains("태그") } ?? false)
    }

    func testRemoteAliasesAndPorts() {
        XCTAssertEqual(Remote(name: "o", url: "git@github.com-work:me/app.git").host, "github.com")
        XCTAssertEqual(Remote(name: "o", url: "https://git.example.com:8443/team/app.git").webHost, "git.example.com:8443")
        XCTAssertEqual(Remote(name: "o", url: "ssh://git@git.example.com:2222/team/app.git").webHost, "git.example.com")
    }

    func testBlocksWhenWorkingTreeIsDirty() async throws {
        let store = RepositoryStore()
        await store.open(root)
        _ = await store.startGitFlow(kind: .feature, name: "x")
        try write("a.txt", "changed\n")
        await store.refresh()
        await store.prepareGitFlowFinish(branch: "feature/x")
        XCTAssertFalse(store.gitFlowRun?.blockers.isEmpty ?? true)
        await store.runGitFlow()
        XCTAssertEqual(store.gitFlowRun?.started, false, "막힌 흐름은 실행하지 않는다")
        XCTAssertEqual(store.status.branch, "feature/x")
    }

    func testBlocksWhenTargetIsCheckedOutInAnotherWorktree() async throws {
        let store = RepositoryStore()
        await store.open(root)
        _ = await store.startGitFlow(kind: .feature, name: "y")
        try await repo.run(["worktree", "add", "-q", root.appendingPathExtension("wt").path, "develop"])
        await store.refresh()
        await store.prepareGitFlowFinish(branch: "feature/y")
        XCTAssertTrue(store.gitFlowRun?.blockers.contains { $0.contains("다른 워크트리") } ?? false)
    }

    // MARK: PR

    func testRemoteHost() {
        XCTAssertEqual(Remote(name: "o", url: "git@github.com:me/app.git").host, "github.com")
        XCTAssertEqual(Remote(name: "o", url: "https://gitlab.example.com/team/app").host, "gitlab.example.com")
        XCTAssertEqual(Remote(name: "o", url: "ssh://git@github.com/me/app.git").host, "github.com")
        XCTAssertNil(Remote(name: "o", url: "/Users/me/app.git").host)
    }

    func testRemoteWebPathKeepsSubgroups() {
        XCTAssertEqual(Remote(name: "o", url: "git@gitlab.com:group/sub/app.git").webPath, "group/sub/app")
        XCTAssertEqual(Remote(name: "o", url: "https://gitlab.com/group/sub/app.git/").webPath, "group/sub/app")
        XCTAssertEqual(Remote(name: "o", url: "ssh://git@ssh.github.com:443/me/app.git").host, "github.com")
    }

    func testGitLabMergeRequestURLForSubgroup() async throws {
        try await repo.run(["remote", "add", "gl", "git@gitlab.com:group/sub/app.git"])
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout.trimmed
        for ref in ["refs/remotes/gl/develop", "refs/remotes/gl/feature/a"] { try await repo.run(["update-ref", ref, head]) }
        try await repo.run(["branch", "feature/a"])
        try await repo.setUpstream("develop", to: "gl/develop")
        try await repo.setUpstream("feature/a", to: "gl/feature/a")
        let store = RepositoryStore()
        await store.open(root)
        XCTAssertEqual(store.pullRequestURL(for: "feature/a")?.absoluteString,
                       "https://gitlab.com/group/sub/app/-/merge_requests/new?merge_request%5Bsource_branch%5D=feature/a&merge_request%5Btarget_branch%5D=develop")
    }

    func testPullRequestURLForSameRepositoryAndFork() async throws {
        try await repo.run(["remote", "add", "origin", "git@github.com:team/app.git"])
        try await repo.run(["remote", "add", "Forked", "https://github.com/me/app.git"])
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout.trimmed
        for ref in ["refs/remotes/origin/develop", "refs/remotes/origin/feature/a", "refs/remotes/Forked/feature/b"] {
            try await repo.run(["update-ref", ref, head])
        }
        try await repo.run(["branch", "feature/a"])
        try await repo.run(["branch", "feature/b"])
        try await repo.setUpstream("develop", to: "origin/develop")
        try await repo.setUpstream("feature/a", to: "origin/feature/a")
        try await repo.setUpstream("feature/b", to: "Forked/feature/b")

        let store = RepositoryStore()
        await store.open(root)
        XCTAssertEqual(store.pullRequestURL(for: "feature/a")?.absoluteString,
                       "https://github.com/team/app/compare/develop...feature/a?expand=1")
        XCTAssertEqual(store.pullRequestURL(for: "feature/b")?.absoluteString,
                       "https://github.com/team/app/compare/develop...me:feature/b?expand=1", "fork에서 원본 저장소로")
        XCTAssertNil(store.pullRequestURL(for: "main"), "추적 브랜치가 없으면 만들지 않는다")
    }
}
