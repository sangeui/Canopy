import Foundation

/// 한 워크트리를 대상으로 git 명령을 보내는 타입. 상태는 들고 있지 않다.
struct GitRepository {
    let directory: URL
    var runner = GitRunner()

    init(directory: URL) {
        self.directory = directory
    }

    init(path: String) {
        self.directory = URL(fileURLWithPath: path, isDirectory: true)
    }

    /// 모든 호출에 붙인다. `core.fsmonitor`는 저장소 설정에 적힌 명령을 `git status`마다 실행해서 끈다.
    /// 저장소를 열기만 해도 남이 넣어 둔 명령이 돌 수 있었다.
    private static let fixedArguments = ["-c", "core.quotePath=false", "-c", "color.ui=never", "-c", "core.fsmonitor=false"]

    /// 설정 › Git › 충돌 해결 기억을 켰을 때만 `rerere`를 쓴다. 한 번 쓰면 `.git/rr-cache`가 생기고,
    /// git은 그 폴더가 있으면 설정 없이도 rerere를 쓰므로 터미널 git까지 바뀐다. 그래서 기본은 끈다.
    /// 채운 파일은 충돌로 남겨 두어(autoUpdate 끔) 사용자가 보고 "해결됨"으로 넘긴다.
    static var remembersResolutions: Bool { UserDefaults.standard.bool(forKey: "rerere") }

    private static var baseArguments: [String] {
        fixedArguments + (remembersResolutions ? ["-c", "rerere.enabled=true"] : [])
    }

    /// diff를 그리는 호출에 붙인다. 저장소 설정의 외부 diff 프로그램(`diff.external`)과 변환 명령(`textconv`)을 쓰지 않는다.
    static let noExternalDiff = ["--no-ext-diff", "--no-textconv"]

    @discardableResult
    func run(_ arguments: [String], allowedExitCodes: Set<Int32> = [0], input: String? = nil, environment: [String: String] = [:]) async throws -> GitOutput {
        let output = try await runner.run(Self.baseArguments + arguments, in: directory, input: input, extraEnvironment: environment)
        guard allowedExitCodes.contains(output.exitCode) else {
            throw GitError(arguments: arguments, exitCode: output.exitCode, stderr: output.stderr)
        }
        return output
    }

    // MARK: 저장소 찾기

    struct Location {
        /// 사용자가 고른 폴더가 속한 워크트리의 최상위
        let worktree: String
        /// 메인 워크트리의 최상위
        let mainRoot: String
    }

    static func locate(_ url: URL) async throws -> Location {
        let repo = GitRepository(directory: url)
        let top = try await repo.run(["rev-parse", "--show-toplevel"]).stdout.trimmed
        let common = try await repo.run(["rev-parse", "--path-format=absolute", "--git-common-dir"]).stdout.trimmed
        var mainRoot = common
        if (mainRoot as NSString).lastPathComponent == ".git" {
            mainRoot = (mainRoot as NSString).deletingLastPathComponent
        }
        return Location(worktree: top, mainRoot: mainRoot)
    }

    /// 저장소를 받아 온다. `destination`은 새로 만들 폴더.
    static func clone(_ url: String, to destination: String) async throws {
        let parent = (destination as NSString).deletingLastPathComponent
        let repo = GitRepository(path: parent)
        try await repo.run(["clone", "--", url, destination])
    }

    // MARK: 읽기

    func status() async throws -> StatusSnapshot {
        let output = try await run(["status", "--porcelain=v2", "--branch", "--untracked-files=all", "-z"])
        return StatusParser.parse(output.stdout)
    }

    func hasHead() async throws -> Bool {
        try await run(["rev-parse", "--verify", "--quiet", "HEAD"], allowedExitCodes: [0, 1]).exitCode == 0
    }

    func log(revision: String = "HEAD", limit: Int = 400) async throws -> [Commit] {
        try await graphLog([revision], limit: limit)
    }

    /// `text`가 코드에 생기거나 사라진 커밋(`git log -S`). 메시지가 아니라 바뀐 내용에서 찾는다.
    func searchCode(_ text: String, revisions: [String], limit: Int = 200) async throws -> [Commit] {
        let output = try await run(["log", "--format=\(LogParser.format)", "-n", "\(limit)", "--date-order", "-S" + text] + revisions + ["--"])
        return LogParser.parse(output.stdout)
    }

    /// `git rev-list`가 내놓는 커밋 해시. 범위 계산에 쓴다.
    func revList(_ arguments: [String], limit: Int = 5000) async throws -> Set<String> {
        let output = try await run(["rev-list", "-n", "\(limit)"] + arguments + ["--"]).stdout
        return Set(output.split(separator: "\n").map(String.init))
    }

    /// 여러 끝에서 시작하는 히스토리를 그래프 하나로. `["^develop", "HEAD", "origin/feature"]`
    func graphLog(_ revisions: [String], limit: Int = 400) async throws -> [Commit] {
        let output = try await run(["log", "--format=\(LogParser.format)", "-n", "\(limit)", "--date-order"] + revisions + ["--"])
        return LogParser.parse(output.stdout)
    }

    /// 원격마다 HEAD가 가리키는 브랜치. `origin` → `origin/develop`. 기준 브랜치를 고를 때 쓴다.
    func remoteHeads() async throws -> [String: String] {
        let output = try await run(["for-each-ref", "--format=%(refname:short)%1f%(symref:short)", "refs/remotes"]).stdout
        var heads: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 2, fields[0].hasSuffix("/HEAD"), !fields[1].isEmpty else { continue }
            heads[String(fields[0].dropLast(5))] = fields[1]
        }
        return heads
    }

    /// 한 파일의 역사. 이름이 바뀐 것도 따라간다.
    /// 여러 범위를 함께 준다. `["feature/x", "--not", "--remotes"]`처럼 쓴다.
    func log(revisions: [String], limit: Int) async throws -> [Commit] {
        let output = try await run(["log", "--format=\(LogParser.format)", "-n", "\(limit)"] + revisions + ["--"])
        return LogParser.parse(output.stdout)
    }

    func log(path: String, limit: Int = 300) async throws -> [Commit] {
        let output = try await run(["log", "--format=\(LogParser.format)", "-n", "\(limit)", "--follow", "--", path])
        return LogParser.parse(output.stdout)
    }

    /// 줄마다 마지막으로 바꾼 커밋. 추적되지 않는 파일이면 실패한다.
    /// 줄마다 마지막으로 바꾼 커밋. 들여쓰기만 바꾼 커밋과 같은 파일 안에서 옮긴 줄은 넘어가서 처음 쓴 커밋을 찾는다(`-w -M`).
    /// - Parameter acrossFiles: 다른 파일에서 옮겨 오거나 복사한 줄도 찾는다(`-C`). 큰 파일에서 몇 초 걸려서 필요할 때만 켠다.
    func blame(path: String, acrossFiles: Bool = false) async throws -> [BlameLine] {
        let output = try await run(["blame", "--line-porcelain", "--no-textconv", "-w", "-M"] + (acrossFiles ? ["-C"] : []) + ["--", path])
        return BlameParser.parse(output.stdout)
    }

    /// `head`가 `base`보다 몇 커밋 앞서고 뒤처졌는지.
    func aheadBehind(base: String, head: String) async throws -> (ahead: Int, behind: Int) {
        let output = try await run(["rev-list", "--left-right", "--count", "\(base)...\(head)"]).stdout.trimmed
        let parts = output.split(whereSeparator: { $0 == "\t" || $0 == " " })
        guard parts.count == 2 else { return (0, 0) }
        return (Int(parts[1]) ?? 0, Int(parts[0]) ?? 0)
    }

    /// 갈라진 지점부터 `head`까지 바뀐 양.
    func diffStat(base: String, head: String) async throws -> DiffStat {
        NumstatParser.parse(try await run(["diff", "--numstat"] + Self.noExternalDiff + ["\(base)...\(head)"]).stdout)
    }

    /// 갈라진 지점부터 `head`까지의 diff.
    func diff(base: String, head: String) async throws -> [DiffFile] {
        DiffParser.parse(try await run(["diff", "-M", "--patch"] + Self.noExternalDiff + ["\(base)...\(head)"]).stdout)
    }

    /// 모든 브랜치·태그·원격 브랜치의 커밋. 그래프를 그릴 때 쓴다.
    func logAll(limit: Int = 400) async throws -> [Commit] {
        let output = try await run([
            "log", "--format=\(LogParser.format)", "-n", "\(limit)", "--date-order",
            "HEAD", "--branches", "--tags", "--remotes", "--",
        ])
        return LogParser.parse(output.stdout)
    }

    func stashes() async throws -> [Stash] {
        let output = try await run(["stash", "list", "--format=\(StashParser.format)"])
        return StashParser.parse(output.stdout)
    }

    func tags() async throws -> [Tag] {
        let output = try await run(["for-each-ref", "--sort=-creatordate", "--format=\(TagParser.format)", "refs/tags"])
        return TagParser.parse(output.stdout)
    }

    func remotesDetailed() async throws -> [Remote] {
        RemoteParser.parse(try await run(["remote", "-v"]).stdout)
    }

    /// `.git` 안의 표시 파일을 보고 진행 중인 작업을 알아낸다.
    func operationState() async throws -> RepositoryOperation? {
        let output = try await run([
            "rev-parse", "--git-path", "MERGE_HEAD", "--git-path", "rebase-merge", "--git-path", "rebase-apply",
            "--git-path", "CHERRY_PICK_HEAD", "--git-path", "REVERT_HEAD",
        ]).stdout
        let paths = output.split(separator: "\n").map { String($0) }
        guard paths.count == 5 else { return nil }
        func exists(_ relative: String) -> Bool {
            let url = relative.hasPrefix("/") ? URL(fileURLWithPath: relative) : directory.appendingPathComponent(relative)
            return FileManager.default.fileExists(atPath: url.path)
        }
        if exists(paths[1]) || exists(paths[2]) { return .rebasing }
        if exists(paths[0]) { return .merging }
        if exists(paths[3]) { return .cherryPicking }
        if exists(paths[4]) { return .reverting }
        return nil
    }

    /// HEAD가 브랜치에 붙어 있지 않을 때 어디인지. 리베이스 중이면 원래 브랜치와 진행 정도, 아니면 HEAD를 가리키는 태그.
    func detachedPlace() async throws -> DetachedPlace {
        let paths = try await run(["rev-parse", "--git-path", "rebase-merge", "--git-path", "rebase-apply"]).stdout
            .split(separator: "\n").map(String.init)
        func read(_ folder: String, _ name: String) -> String? {
            let base = folder.hasPrefix("/") ? URL(fileURLWithPath: folder) : directory.appendingPathComponent(folder)
            return (try? String(contentsOf: base.appendingPathComponent(name), encoding: .utf8))?.trimmed
        }
        var place = DetachedPlace()
        // rebase-merge는 msgnum/end, 옛 방식 rebase-apply는 next/last에 진행 정도를 적는다
        for (folder, files) in zip(paths, [("msgnum", "end"), ("next", "last")]) {
            guard let head = read(folder, "head-name") else { continue }
            if head.hasPrefix("refs/heads/") { place.rebasingBranch = String(head.dropFirst("refs/heads/".count)) }
            place.step = read(folder, files.0).flatMap { Int($0) }
            place.total = read(folder, files.1).flatMap { Int($0) }
            return place
        }
        place.tag = try await run(["tag", "--points-at", "HEAD", "--sort=-creatordate"]).stdout
            .split(separator: "\n").first.map { String($0).trimmed }
        return place
    }

    /// 마지막으로 페치한 시각. 워크트리마다 `FETCH_HEAD`가 따로 있어서 모두 보고 가장 최근 것을 쓴다.
    func lastFetchDate() async throws -> Date? {
        let common = try await run(["rev-parse", "--git-common-dir"]).stdout.trimmed
        let root = common.hasPrefix("/") ? URL(fileURLWithPath: common) : directory.appendingPathComponent(common)
        var files = [root.appendingPathComponent("FETCH_HEAD")]
        let worktrees = root.appendingPathComponent("worktrees")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: worktrees.path)) ?? [] {
            files.append(worktrees.appendingPathComponent(name).appendingPathComponent("FETCH_HEAD"))
        }
        return files.compactMap { (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date }.max()
    }

    struct ContainingRefs: Hashable {
        var branches: [String] = []
        var remotes: [String] = []
        var tags: [String] = []
        var isEmpty: Bool { branches.isEmpty && remotes.isEmpty && tags.isEmpty }
    }

    /// 이 커밋을 포함하는 브랜치, 원격 브랜치, 태그
    func refsContaining(_ hash: String) async throws -> ContainingRefs {
        async let locals = run(["branch", "--contains", hash, "--format=%(refname:short)"]).stdout
        async let remotes = run(["branch", "-r", "--contains", hash, "--format=%(refname:short)"]).stdout
        async let tags = run(["tag", "--contains", hash]).stdout
        func lines(_ text: String) -> [String] { text.split(separator: "\n").map { $0.trimmed }.filter { !$0.isEmpty && !$0.hasSuffix("/HEAD") } }
        return ContainingRefs(branches: lines(try await locals), remotes: lines(try await remotes), tags: lines(try await tags))
    }

    /// HEAD의 reflog. 최근에 무슨 일을 했는지 보여 줄 때 쓴다.
    func activities(limit: Int = 100) async throws -> [ActivityEntry] {
        let output = try await run(["reflog", "show", "--date=unix", "--format=\(ActivityParser.format)", "-n", "\(limit)"])
        return ActivityParser.parse(output.stdout)
    }

    /// 작업 트리(또는 인덱스) 변경의 파일 수와 줄 수.
    func diffStat(cached: Bool) async throws -> DiffStat {
        var arguments = ["diff", "--numstat"] + Self.noExternalDiff
        if cached { arguments.append("--cached") }
        return NumstatParser.parse(try await run(arguments).stdout)
    }

    /// 이 저장소에서 커밋할 때 쓰는 이름과 메일.
    func userIdentity() async throws -> (name: String, email: String) {
        let name = try await run(["config", "user.name"], allowedExitCodes: [0, 1]).stdout.trimmed
        let email = try await run(["config", "user.email"], allowedExitCodes: [0, 1]).stdout.trimmed
        return (name, email)
    }

    func diff(forStash ref: String) async throws -> [DiffFile] {
        let output = try await run(["stash", "show", "-p", "--include-untracked"] + Self.noExternalDiff + [ref])
        return DiffParser.parse(output.stdout)
    }

    func branches() async throws -> [Branch] {
        let output = try await run(["for-each-ref", "--format=\(BranchParser.format)", "refs/heads", "refs/remotes"])
        return BranchParser.parse(output.stdout)
    }

    func worktrees() async throws -> [Worktree] {
        let output = try await run(["worktree", "list", "--porcelain"])
        return WorktreeParser.parse(output.stdout)
    }

    func remotes() async throws -> [String] {
        try await run(["remote"]).stdout.split(separator: "\n").map { $0.trimmed }.filter { !$0.isEmpty }
    }

    func diff(for change: FileChange) async throws -> [DiffFile] {
        let output: GitOutput
        switch change.area {
        case .staged:
            var paths = [change.path]
            if let original = change.originalPath { paths.insert(original, at: 0) }
            output = try await run(["diff", "--cached", "-M"] + Self.noExternalDiff + ["--"] + paths)
        case .untracked:
            // --no-index는 차이가 있으면 1로 끝난다.
            output = try await run(["diff", "--no-index"] + Self.noExternalDiff + ["--", "/dev/null", change.path], allowedExitCodes: [0, 1])
        case .unstaged:
            output = try await run(["diff", "-M"] + Self.noExternalDiff + ["--", change.path])
        case .conflicted:
            // 그냥 `git diff`는 두 쪽을 함께 비교하는 combined diff(`diff --cc`, `@@@`)를 내서 읽을 수 없다.
            // HEAD와 비교하면 충돌 표시(<<<<<<< ======= >>>>>>>)가 더한 줄로 보이는 보통 diff가 나온다.
            if let againstHead = try? await run(["diff", "HEAD", "-M"] + Self.noExternalDiff + ["--", change.path]) {
                output = againstHead
            } else {
                output = try await run(["diff", "--no-index"] + Self.noExternalDiff + ["--", "/dev/null", change.path], allowedExitCodes: [0, 1])
            }
        }
        let started = Date()
        let files = DiffParser.parse(output.stdout)
        Timing.log("diff parse \(Int(Date().timeIntervalSince(started) * 1000))ms, \(output.stdout.count) chars")
        return files
    }

    func diff(forCommit hash: String) async throws -> [DiffFile] {
        // 머지 커밋은 첫 번째 부모와만 비교해서 combined diff가 나오지 않게 한다.
        let output = try await run(["show", "--format=", "-m", "--first-parent", "-M", "--patch"] + Self.noExternalDiff + [hash])
        return DiffParser.parse(output.stdout)
    }

    // MARK: 스테이징과 커밋

    func stage(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        try await run(["add", "-A", "--"] + paths)
    }

    func stageAll() async throws {
        try await run(["add", "-A"])
    }

    func unstage(_ paths: [String], hasHead: Bool) async throws {
        guard !paths.isEmpty else { return }
        if hasHead {
            try await run(["reset", "-q", "HEAD", "--"] + paths)
        } else {
            try await run(["rm", "--cached", "-r", "-q", "--"] + paths)
        }
    }

    func unstageAll(hasHead: Bool) async throws {
        if hasHead {
            try await run(["reset", "-q", "HEAD"])
        } else {
            try await run(["rm", "--cached", "-r", "-q", "--", "."])
        }
    }

    func discardWorkingTreeChanges(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        try await run(["checkout", "--", ] + paths)
    }

    /// hunk 하나를 담은 패치를 인덱스나 작업 트리에 적용한다.
    func applyPatch(_ patch: String, cached: Bool, reverse: Bool) async throws {
        // 줄 단위로 고른 패치는 머리말의 줄 수가 원래 hunk와 다르다. git이 다시 세게 한다.
        var arguments = ["apply", "--whitespace=nowarn", "--recount"]
        if cached { arguments.append("--cached") }
        if reverse { arguments.append("--reverse") }
        arguments.append("-")
        try await run(arguments, input: patch)
    }

    func resolveConflict(_ path: String, keepOurs: Bool) async throws {
        try await run(["checkout", keepOurs ? "--ours" : "--theirs", "--", path])
        try await run(["add", "--", path])
    }

    func undoLastCommit() async throws {
        try await run(["reset", "-q", "--soft", "HEAD~1"])
    }

    func commit(message: String, amend: Bool) async throws {
        var arguments = ["commit", "-q"]
        if amend { arguments.append("--amend") }
        arguments += ["-m", message]
        try await run(arguments)
    }

    // MARK: 브랜치

    func checkout(_ ref: String) async throws {
        try await run(["checkout", "-q", "--end-of-options", ref])
    }

    /// `origin/feature`를 받아 같은 이름의 로컬 브랜치를 만들고 추적하게 한다.
    func checkoutTracking(_ remoteBranch: String) async throws {
        try await run(["checkout", "-q", "--track", remoteBranch])
    }

    /// - Parameter track: false면 원격 브랜치에서 만들어도 그 원격 브랜치를 추적하지 않는다.
    ///   `origin/develop`에서 만든 기능 브랜치가 origin/develop을 추적하면 푸시가 공용 develop으로 간다.
    func createBranch(_ name: String, from base: String?, checkout: Bool, track: Bool = true) async throws {
        var arguments = checkout ? ["checkout", "-q"] : ["branch"]
        if !track { arguments.append("--no-track") }
        arguments += checkout ? ["-b", name] : [name]
        if let base { arguments.append(base) }
        try await run(arguments)
    }

    /// 커밋들을 `git am`으로 적용할 수 있는 패치 글로. 작성자와 메시지가 들어 있다. 오래된 커밋부터.
    func formatPatch(_ hashes: [String]) async throws -> String {
        var text = ""
        for hash in hashes {
            text += try await run(["format-patch", "-1", "--stdout", "--no-signature", "--end-of-options", hash]).stdout
        }
        return text
    }

    /// 커밋하지 않은 변경(스테이징한 것과 안 한 것 모두)을 마지막 커밋 대비 패치로. `git apply`로 적용한다.
    func workingPatch(paths: [String], hasHead: Bool) async throws -> String {
        let base = hasHead ? ["HEAD"] : ["--cached"]
        return try await run(["diff", "--binary"] + Self.noExternalDiff + base + ["--"] + paths).stdout
    }

    /// `git clean`이 지울 경로. 실제로 지우지는 않는다(`-n`). 폴더는 `/`로 끝난다.
    /// - Parameter includeIgnored: `.gitignore`로 무시한 파일(빌드 결과물 등)도 넣는다(`-x`)
    /// `git clean -n`은 따옴표·탭이 든 이름을 C 형식으로 감싸 내놓아서 경로로 쓸 수 없다.
    /// `ls-files -z`로 이름을 그대로 받는다. 추적 안 된 폴더는 `폴더/` 하나로 나온다(clean -d와 같다).
    /// 안에 `.git`이 있는 폴더(다른 저장소)는 `git clean -d`처럼 건드리지 않는다.
    func cleanCandidates(includeIgnored: Bool) async throws -> [String] {
        let base = ["ls-files", "-z", "--others", "--directory", "--exclude-standard"]
        var paths = Self.nulSeparated(try await run(base).stdout)
        if includeIgnored {
            paths += Self.nulSeparated(try await run(base + ["--ignored"]).stdout)
        }
        return paths.filter { path in
            !(path.hasSuffix("/") && FileManager.default.fileExists(atPath: directory.appendingPathComponent(path).appendingPathComponent(".git").path))
        }
    }

    private static func nulSeparated(_ text: String) -> [String] {
        text.split(separator: "\u{0}").map(String.init).filter { !$0.isEmpty }
    }

    // MARK: 커밋 정리

    /// `oldest`부터 HEAD까지 이어지는 커밋, 오래된 것부터. `base`는 `oldest`의 부모(맨 처음 커밋이면 nil).
    /// `oldest`가 HEAD에 들어 있지 않으면 nil
    func rewriteRange(from oldest: String) async throws -> (commits: [Commit], base: String?, messages: [String: String])? {
        guard try await isAncestor(oldest, of: "HEAD") else { return nil }
        let base = try await commitHash(of: oldest + "^")
        let range = base.map { "\($0)..HEAD" } ?? "HEAD"
        let output = try await run(["log", "--format=\(LogParser.format)", "--reverse", "--topo-order", range, "--"])
        // 메시지는 줄바꿈까지 그대로(%B). 해시와 메시지를 0x00으로, 커밋끼리는 0x1e로 나눈다.
        let raw = try await run(["log", "--format=%H%x00%B%x1e", range, "--"]).stdout
        var messages: [String: String] = [:]
        for record in raw.split(separator: "\u{1e}") {
            let parts = record.split(separator: "\u{0}", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            messages[parts[0].trimmingCharacters(in: .whitespacesAndNewlines)] = String(parts[1])
        }
        return (LogParser.parse(output.stdout), base, messages)
    }

    /// `.git` 폴더의 절대 경로. 워크트리면 그 워크트리의 것
    func gitDirectory() async throws -> String {
        try await run(["rev-parse", "--absolute-git-dir"]).stdout.trimmed
    }

    /// 할 일 목록을 그대로 넣어 `git rebase -i`를 돌린다. 편집기 대신 미리 적어 둔 파일을 복사한다.
    /// 빠진 커밋이 있으면 멈추게 하고(missingCommitsCheck), 다른 브랜치는 옮기지 않는다(--no-update-refs).
    func rewriteHistory(base: String?, todo: [String], todoFile: URL) async throws {
        try (todo.joined(separator: "\n") + "\n").write(to: todoFile, atomically: true, encoding: .utf8)
        try await run(
            ["-c", "rebase.missingCommitsCheck=error", "-c", "rebase.abbreviateCommands=false",
             "rebase", "-i", "--no-autosquash", "--no-update-refs"] + (base.map { [$0] } ?? ["--root"]),
            environment: ["GIT_SEQUENCE_EDITOR": "cp " + HistoryRewrite.shellQuote(todoFile.path)]
        )
    }

    /// 저장소의 `commit-msg` 훅으로 메시지를 미리 검사한다. 통과하거나 훅이 없으면 nil, 거부하면 훅이 남긴 말.
    /// 커밋 정리 도중에는 훅을 건너뛰므로(리베이스가 반쯤 멈추지 않게) 시작하기 전에 여기서 검사한다.
    func rejectionFromCommitMessageHook(_ message: String) async throws -> String? {
        var hook = try await run(["rev-parse", "--git-path", "hooks/commit-msg"]).stdout.trimmed
        if !hook.hasPrefix("/") { hook = directory.appendingPathComponent(hook).path }
        guard FileManager.default.isExecutableFile(atPath: hook) else { return nil }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("canopy-commit-msg-\(UUID().uuidString)")
        try message.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: hook)
                process.arguments = [file.path]
                process.currentDirectoryURL = directory
                // git이 훅을 부를 때와 같은 PATH. GUI 앱의 PATH에는 Homebrew가 없어서 commitlint 같은 도구를 못 찾는다.
                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
                process.environment = environment
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: process.terminationStatus == 0 ? nil : (text.isEmpty ? "commit-msg 훅이 메시지를 거부했습니다" : text))
            }
        }
    }

    /// 참조가 가리키는 커밋의 전체 해시. 없으면 nil
    func commitHash(of ref: String) async throws -> String? {
        let output = try await run(["rev-parse", "--verify", "--quiet", ref + "^{commit}"], allowedExitCodes: [0, 1])
        return output.exitCode == 0 ? output.stdout.trimmed : nil
    }

    /// `base`에 모두 들어간 로컬 브랜치 이름. 정리해도 되는 브랜치를 표시할 때 쓴다.
    func mergedBranches(into base: String) async throws -> Set<String> {
        let output = try await run(["branch", "--merged", base, "--format=%(refname:short)"]).stdout
        return Set(output.split(separator: "\n").map { $0.trimmed }.filter { !$0.isEmpty })
    }

    /// `base`의 첫 부모 줄에 있는 커밋 해시. 브랜치 끝이 여기 있으면 그 브랜치는 기준 브랜치의 옛 자리를 가리킬 뿐이다.
    func firstParentHashes(of base: String, limit: Int = 5000) async throws -> Set<String> {
        let output = try await run(["rev-list", "--first-parent", "-n", "\(limit)", base]).stdout
        return Set(output.split(separator: "\n").map { $0.trimmed }.filter { !$0.isEmpty })
    }

    func deleteBranch(_ name: String, force: Bool) async throws {
        try await run(["branch", force ? "-D" : "-d", name])
    }

    func merge(_ branch: String) async throws {
        try await run(["merge", "--no-edit", "--end-of-options", branch])
    }

    /// 언제나 머지 커밋을 만든다. Git Flow 마무리는 브랜치가 있었다는 흔적을 남기려고 fast-forward를 하지 않는다.
    func mergeNoFastForward(_ branch: String) async throws {
        try await run(["merge", "--no-ff", "--no-edit", "--end-of-options", branch])
    }

    /// `ancestor`가 `descendant`에 이미 들어 있는지. 머지 단계를 끝냈는지 볼 때 쓴다.
    func isAncestor(_ ancestor: String, of descendant: String) async throws -> Bool {
        try await run(["merge-base", "--is-ancestor", ancestor, descendant], allowedExitCodes: [0, 1]).exitCode == 0
    }

    func localBranchExists(_ name: String) async throws -> Bool {
        try await run(["rev-parse", "--verify", "--quiet", "refs/heads/" + name], allowedExitCodes: [0, 1]).exitCode == 0
    }

    /// 태그 이름으로 쓸 수 있는지(`git check-ref-format`). 접두어에 공백이나 점이 있으면 안 된다.
    func isValidTagName(_ name: String) async -> Bool {
        (try? await run(["check-ref-format", "refs/tags/" + name], allowedExitCodes: [0, 1]).exitCode) == 0
    }

    func tagExists(_ name: String) async throws -> Bool {
        try await run(["rev-parse", "--verify", "--quiet", "refs/tags/" + name], allowedExitCodes: [0, 1]).exitCode == 0
    }

    /// git-flow가 브랜치마다 적는 기준 브랜치. 시작할 때 적고, 브랜치를 지우면 같이 지운다.
    func setGitFlowBase(_ base: String?, for branch: String) async throws {
        let key = "gitflow.branch.\(branch).base"
        if let base {
            try await run(["config", "--local", key, base])
        } else {
            // 키가 없으면 끝 코드 5. 지울 것이 없을 뿐이다.
            try await run(["config", "--local", "--unset", key], allowedExitCodes: [0, 5])
        }
    }

    /// `git flow init`이 적은 설정. `gitflow.branch.develop` → `develop`. 없으면 빈 사전.
    func gitFlowSettings() async throws -> [String: String] {
        let output = try await run(["config", "--get-regexp", "^gitflow\\."], allowedExitCodes: [0, 1]).stdout
        var settings: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            settings[String(parts[0])] = parts.count > 1 ? String(parts[1]) : ""
        }
        return settings
    }

    /// 합쳐 보기만 한다. 작업 트리·index·브랜치는 건드리지 않고 결과 트리와 충돌 파일만 얻는다.
    /// 끝 코드 0은 깨끗하게 합쳐짐, 1은 충돌. 체리픽·리버트는 `mergeBase`로 기준을 바꿔 같은 계산을 한다.
    func previewMerge(ours: String, theirs: String, mergeBase: String? = nil) async throws -> MergePreview {
        var arguments = ["merge-tree", "--write-tree", "--name-only", "--no-messages"]
        if let mergeBase { arguments.append("--merge-base=\(mergeBase)") }
        let output = try await run(arguments + [ours, theirs], allowedExitCodes: [0, 1])
        let lines = output.stdout.split(separator: "\n").map { String($0) }.filter { !$0.isEmpty }
        guard let tree = lines.first else { throw GitError(arguments: arguments, exitCode: output.exitCode, stderr: output.stderr) }
        var seen: Set<String> = []
        let conflicts = output.exitCode == 0 ? [] : lines.dropFirst().filter { seen.insert($0).inserted }
        return MergePreview(tree: tree, conflicts: conflicts)
    }

    /// 미리 합친 결과에서 충돌 파일만 `from`과 비교한다. 충돌 표시가 더한 줄로 보인다.
    func diff(from revision: String, toTree tree: String, paths: [String]) async throws -> [DiffFile] {
        guard !paths.isEmpty else { return [] }
        return DiffParser.parse(try await run(["diff"] + Self.noExternalDiff + [revision, tree, "--"] + paths).stdout)
    }

    func rebase(onto branch: String) async throws {
        try await run(["rebase", "--end-of-options", branch])
    }

    func abort(_ operation: RepositoryOperation) async throws {
        try await run([operation.command, "--abort"])
    }

    func continueOperation(_ operation: RepositoryOperation) async throws {
        // 리베이스를 계속할 때도 빠진 커밋이 있으면 멈추게 한다. 시작할 때만 검사하면 계속하면서 커밋을 잃을 수 있다.
        let check = operation == .rebasing ? ["-c", "rebase.missingCommitsCheck=error"] : []
        try await run(check + [operation.command, "--continue"])
    }

    /// 리베이스가 Canopy의 메시지 바꾸기 단계(exec)에서 실패해 멈췄는지. 이때 계속하거나 건너뛰면 새 메시지가 빠진다.
    func rebaseStoppedAtMessageStep() async -> Bool {
        guard let path = try? await run(["rev-parse", "--git-path", "rebase-merge/done"]).stdout.trimmed else { return false }
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path)
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let last = text.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return false }
        return last.hasPrefix("exec") && last.contains("canopy-rewrite") && last.contains("commit --amend")
    }

    /// 같은 내용이 이미 HEAD에 들어 있는지. 해시가 달라도(다른 브랜치에서 체리픽했거나 리베이스했으면) 찾는다.
    func isAlreadyApplied(_ hash: String) async throws -> Bool {
        if try await isAncestor(hash, of: "HEAD") { return true }
        guard try await commitHash(of: hash + "^") != nil else { return false }
        // `git cherry HEAD <커밋> <커밋>^`: 같은 패치가 HEAD 쪽에 있으면 "-"로 시작한다
        let output = try await run(["cherry", "HEAD", hash, hash + "^"]).stdout
        return output.split(separator: "\n").contains { $0.hasPrefix("- ") }
    }

    /// 지금 멈춘 커밋 하나를 건너뛰고 나머지를 이어 간다. 체리픽·리베이스·리버트에만 있다.
    func skip(_ operation: RepositoryOperation) async throws {
        try await run([operation.command, "--skip"])
    }

    func cherryPick(_ hash: String) async throws {
        try await run(["cherry-pick", "--end-of-options", hash])
    }

    /// 여러 커밋을 차례로 옮긴다. 충돌이 나면 그 커밋에서 멈추고, 계속하면 나머지를 이어 간다.
    func cherryPick(_ hashes: [String]) async throws {
        try await run(["cherry-pick", "--end-of-options"] + hashes)
    }

    func revert(_ hash: String) async throws {
        try await run(["revert", "--no-edit", "--end-of-options", hash])
    }

    func reset(to hash: String, mode: ResetMode) async throws {
        try await run(["reset", "-q", "--\(mode.rawValue)", hash])
    }

    func checkoutDetached(_ hash: String) async throws {
        try await run(["checkout", "-q", "--detach", hash])
    }

    // MARK: 스태시와 태그

    func stashPush(message: String?, includeUntracked: Bool) async throws {
        var arguments = ["stash", "push"]
        if includeUntracked { arguments.append("--include-untracked") }
        if let message, !message.isEmpty { arguments += ["-m", message] }
        try await run(arguments)
    }

    func stashApply(_ ref: String, pop: Bool) async throws {
        try await run(["stash", pop ? "pop" : "apply", ref])
    }

    func stashDrop(_ ref: String) async throws {
        try await run(["stash", "drop", ref])
    }

    func createTag(_ name: String, at target: String, message: String?) async throws {
        if let message, !message.isEmpty {
            try await run(["tag", "-a", "-m", message, "--end-of-options", name, target])
        } else {
            try await run(["tag", "--end-of-options", name, target])
        }
    }

    func deleteTag(_ name: String) async throws {
        try await run(["tag", "-d", "--end-of-options", name])
    }

    // MARK: 워크트리

    func addWorktree(at path: String, branch: String, createBranch: Bool, from base: String?) async throws {
        var arguments = ["worktree", "add"]
        if createBranch {
            arguments += ["-b", branch, path]
            if let base { arguments.append(base) }
        } else {
            arguments += [path, branch]
        }
        try await run(arguments)
    }

    func removeWorktree(_ path: String, force: Bool) async throws {
        var arguments = ["worktree", "remove"]
        if force { arguments.append("--force") }
        arguments.append(path)
        try await run(arguments)
    }

    // MARK: 원격

    func fetch() async throws {
        try await run(["fetch", "--all", "--prune"])
    }

    /// 고른 원격의 고른 브랜치를 현재 브랜치로 풀한다. `git pull --rebase|--no-rebase [--autostash] <원격> <브랜치>`
    func pull(remote: String, branch: String, rebase: Bool, autostash: Bool) async throws {
        var arguments = ["pull", rebase ? "--rebase" : "--no-rebase"]
        if autostash { arguments.append("--autostash") }
        try await run(arguments + ["--end-of-options", remote, branch])
    }

    func renameBranch(_ name: String, to newName: String) async throws {
        try await run(["branch", "-m", "--end-of-options", name, newName])
    }

    /// 원격 브랜치를 지운다. `origin/feature/x` → `git push origin --delete feature/x`
    func deleteRemoteBranch(remote: String, branch: String) async throws {
        try await run(["push", "--delete", "--end-of-options", remote, branch])
    }

    /// 원격에서 지운 브랜치를 같은 커밋으로 다시 올린다. 커밋은 지운 뒤에도 이 컴퓨터에 남아 있다.
    func pushBranch(remote: String, name: String, commit: String) async throws {
        try await run(["push", "--end-of-options", remote, "\(commit):refs/heads/\(name)"])
    }

    func setUpstream(_ branch: String, to upstream: String?) async throws {
        if let upstream {
            try await run(["branch", "--set-upstream-to=\(upstream)", branch])
        } else {
            try await run(["branch", "--unset-upstream", branch])
        }
    }

    /// 로컬 브랜치를 고른 원격의 고른 브랜치로 푸시한다. 원격과 대상을 늘 적어서 git 설정에 따라 엉뚱한 곳으로 가지 않게 한다.
    /// `git push [-u] [--force-with-lease] <원격> refs/heads/<로컬>:refs/heads/<대상>`
    func push(branch: String, remote: String, target: String, setUpstream: Bool, force: Bool, tags: Bool) async throws {
        var arguments = ["push"]
        if setUpstream { arguments.append("-u") }
        if force { arguments.append("--force-with-lease") }
        try await run(arguments + ["--end-of-options", remote, "refs/heads/\(branch):refs/heads/\(target)"])
        if tags { try await run(["push", "--tags", "--end-of-options", remote]) }
    }

    /// `git rev-list --count <인자>`
    func countCommits(_ arguments: [String]) async throws -> Int {
        Int(try await run(["rev-list", "--count"] + arguments).stdout.trimmed) ?? 0
    }

    func pushTag(_ name: String, remote: String) async throws {
        try await run(["push", "--end-of-options", remote, "refs/tags/" + name])
    }

    func pushTags() async throws {
        try await run(["push", "--tags"])
    }

    func fetch(remote: String) async throws {
        try await run(["fetch", "--prune", "--end-of-options", remote])
    }

    func addRemote(_ name: String, url: String) async throws {
        try await run(["remote", "add", "--", name, url])
    }

    func removeRemote(_ name: String) async throws {
        try await run(["remote", "remove", name])
    }
}
