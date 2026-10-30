import AppKit
import Foundation
import UniformTypeIdentifiers
import Observation

/// 화면이 구독하는 상태 전부와 git을 부르는 동작.
@Observable
@MainActor
final class RepositoryStore {
    enum Pane: String, CaseIterable, Identifiable {
        case changes
        case history
        case activity
        var id: String { rawValue }

        var title: String {
            switch self {
            case .changes: "변경 사항"
            case .history: "히스토리"
            case .activity: "활동"
            }
        }

        var symbol: String {
            switch self {
            case .changes: "pencil.and.list.clipboard"
            case .history: "point.3.connected.trianglepath.dotted"
            case .activity: "clock.arrow.circlepath"
            }
        }
    }

    /// 사이드바에서 고른 항목. nil이면 가운데 칸에 변경 사항/히스토리가 나온다.
    enum SidebarItem: Hashable {
        case branch(String)
        case tag(String)
        case stash(String)
    }

    enum Detail: Hashable, Identifiable {
        case change(FileChange)
        case commit(Commit)
        case stash(Stash)
        /// 브랜치 둘의 변경 (갈라진 지점부터 head까지)
        case compare(base: String, head: String)
        /// 한 파일의 커밋 역사
        case fileHistory(String)
        /// 한 파일의 줄별 작성자
        case blame(String)

        var id: String {
            switch self {
            case .change(let change): "change:" + change.id
            case .commit(let commit): "commit:" + commit.id
            case .stash(let stash): "stash:" + stash.id
            case .compare(let base, let head): "compare:" + base + "..." + head
            case .fileHistory(let path): "history:" + path
            case .blame(let path): "blame:" + path
            }
        }

        var title: String {
            switch self {
            case .change(let change): change.fileName
            case .commit(let commit): commit.subject
            case .stash(let stash): stash.title
            case .compare(let base, let head): "\(base) → \(head)"
            case .fileHistory(let path): (path as NSString).lastPathComponent + " 히스토리"
            case .blame(let path): (path as NSString).lastPathComponent + " 줄별 작성자"
            }
        }

        /// 지나온 길 줄에 쓰는 짧은 이름
        var crumbTitle: String {
            switch self {
            case .change(let change): change.fileName
            case .commit(let commit): "커밋 " + commit.shortHash
            case .stash(let stash): "스태시 " + stash.title
            case .compare(let base, let head): "\(base) → \(head)"
            case .fileHistory(let path): (path as NSString).lastPathComponent + " 히스토리"
            case .blame(let path): (path as NSString).lastPathComponent + " 줄별 작성자"
            }
        }

        var symbol: String {
            switch self {
            case .change: "doc.text"
            case .commit: "circle.fill"
            case .stash: "tray"
            case .compare: "arrow.left.arrow.right"
            case .fileHistory: "clock"
            case .blame: "person.text.rectangle"
            }
        }
    }

    enum Sheet: Identifiable {
        case newBranch
        case newWorktree
        case newStash
        case newTag(String)
        case newRemote
        case alias(key: String, title: String)
        case renameBranch(String)
        case clone
        case push
        case pull
        /// Git Flow 브랜치 시작. 종류를 정해 열 수도 있다.
        case gitFlowStart(GitFlowKind?)
        /// 커밋 정리. 메시지 고치기, 여러 커밋 합치기, 구간 전체 정리
        case rewordCommit(String)
        case squashCommits([String])
        case cleanupCommits(String)
        /// `gitFlowRun`의 단계를 보여 주고 실행한다
        case gitFlowFinish

        var id: String {
            switch self {
            case .newBranch: "newBranch"
            case .newWorktree: "newWorktree"
            case .newStash: "newStash"
            case .newTag(let hash): "newTag:" + hash
            case .newRemote: "newRemote"
            case .alias(let key, _): "alias:" + key
            case .renameBranch(let name): "rename:" + name
            case .clone: "clone"
            case .push: "push"
            case .pull: "pull"
            case .gitFlowStart: "gitFlowStart"
            case .rewordCommit(let hash): "reword:" + hash
            case .squashCommits(let hashes): "squash:" + hashes.joined(separator: ",")
            case .cleanupCommits(let hash): "cleanup:" + hash
            case .gitFlowFinish: "gitFlowFinish"
            }
        }
    }

    /// 확인 창. 칸을 나눠서 무엇을(대상), 어떻게 되는지(결과)를 한눈에 가르게 한다.
    /// - 제목: 동작만 짧게 묻는다. 이름 같은 긴 값은 넣지 않는다.
    /// - 대상: 브랜치·커밋·파일 이름. 고정폭 글꼴로 줄이지 않고 보여 준다.
    /// - 결과: 한 줄에 사실 하나. 남는 것과 사라지는 것을 아이콘으로 가른다.
    struct Confirmation: Identifiable {
        enum Tone { case normal, destructive }

        struct Fact: Hashable {
            enum Kind { case keeps, loses, warns, note, item }
            let kind: Kind
            let text: String
            /// 남는 것
            static func keeps(_ text: String) -> Fact { Fact(kind: .keeps, text: text) }
            /// 사라지는 것
            static func loses(_ text: String) -> Fact { Fact(kind: .loses, text: text) }
            /// 조심할 것. 충돌 미리보기 같은 경고
            static func warns(_ text: String) -> Fact { Fact(kind: .warns, text: text) }
            /// 알아 둘 것
            static func note(_ text: String) -> Fact { Fact(kind: .note, text: text) }
            /// 바로 위 줄에 딸린 목록 (커밋 제목 같은 것)
            static func item(_ text: String) -> Fact { Fact(kind: .item, text: text) }
        }

        let id = UUID()
        let title: String
        var target: String?
        /// 대상 아래 한 줄. 커밋 제목, 경로 같은 것
        var targetDetail: String?
        var facts: [Fact] = []
        let buttonTitle: String
        var tone: Tone = .destructive
        let action: @MainActor () async -> Void
        /// 켜면 하는 일이 달라지는 선택 하나. 기본은 꺼짐.
        var choice: Choice?

        /// "원격 브랜치도 삭제" 같은 선택. 켜면 결과 줄이 더해지고 버튼과 하는 일이 바뀐다.
        struct Choice {
            let title: String
            /// 스위치 아래 작은 글. 원격 저장소 이름 같은 것
            var detail: String?
            /// 켰을 때 보여 줄 결과 줄 전체. 꺼졌을 때의 줄을 대신한다("원격은 남습니다"가 "원격도 지웁니다"로 바뀌듯).
            var facts: [Fact] = []
            let buttonTitle: String
            let action: @MainActor () async -> Void
        }
    }

    /// 리셋 방식마다 남는 것과 사라지는 것
    private func resetFacts(_ mode: ResetMode) -> [Confirmation.Fact] {
        switch mode {
        case .soft: [.keeps("바뀐 내용은 스테이징된 채로 남습니다")]
        case .mixed: [.keeps("바뀐 내용은 작업 트리에 남습니다")]
        case .hard: [.loses("커밋하지 않은 변경 (⌘Z로 되돌릴 수 있습니다)")]
        }
    }

    // MARK: 저장소

    private(set) var mainRootPath: String?
    private(set) var activeWorktreePath: String?
    private(set) var worktrees: [Worktree] = []
    private(set) var branches: [Branch] = []
    private(set) var tags: [Tag] = []
    private(set) var stashes: [Stash] = []
    private(set) var remotes: [Remote] = []
    private(set) var status = StatusSnapshot()
    private(set) var workingStat = DiffStat.empty
    private(set) var stagedStat = DiffStat.empty
    private(set) var operation: RepositoryOperation?
    /// 분리된 HEAD일 때만 채운다
    private(set) var detachedPlace: DetachedPlace?
    /// 마지막 페치 시각. 원격과 같은지는 이 시각 기준이다.
    private(set) var lastFetchedAt: Date?
    /// reflog. 최근에 한 일.
    private(set) var activities: [ActivityEntry] = []
    var selectedActivityID: ActivityEntry.ID?
    /// 활동에서 고른 커밋. 목록에 없는 커밋일 수도 있어서 따로 읽는다.
    private(set) var activityCommit: Commit?
    private(set) var hasHead = false

    /// 히스토리 범위. 예전에는 "이 브랜치 작업"(기준 브랜치에 없는 것만)이 따로 있었는데, "이 브랜치 전체"와 차이가
    /// 이름만으로 드러나지 않아 하나로 합쳤다. 대신 기준 브랜치에 이미 있는 커밋을 흐리게 그리고 갈라진 곳을 표시한다.
    enum HistoryScope: String, CaseIterable, Identifiable {
        /// 이 브랜치(와 추적 브랜치)에서 닿는 커밋
        case current
        /// 브랜치·태그·원격을 전부
        case all
        var id: String { rawValue }
        var title: String {
            switch self {
            case .current: "이 브랜치"
            case .all: "모든 브랜치"
            }
        }
    }

    /// 브랜치 하나의 히스토리와, 기준 브랜치와 견준 결과
    struct BranchHistory {
        var commits: [Commit]
        /// 기준 브랜치에 이미 있는 커밋. 흐리게 그린다.
        var baseHashes: Set<String> = []
        /// 기준 브랜치에 없는, 이 브랜치에서 한 커밋 수
        var ownCount: Int?
        /// 추적 브랜치에서 받아 올 커밋 수
        var incomingCount = 0
        var base: String?
    }

    /// 히스토리 범위. 기본은 기준 브랜치에 없는 이 브랜치의 작업만 본다.
    /// 저장 속성이어야 화면이 바로 따라온다. 계산 속성이면 관찰이 안 된다.
    var historyScope = HistoryScope(rawValue: UserDefaults.standard.string(forKey: "historyScope.v2") ?? "") ?? .current {
        didSet {
            guard historyScope != oldValue else { return }
            UserDefaults.standard.set(historyScope.rawValue, forKey: "historyScope.v2")
            Task { await refresh() }
        }
    }
    /// 원격마다 HEAD가 가리키는 브랜치. `origin` → `origin/develop`
    private(set) var remoteHeads: [String: String] = [:]
    /// 이 브랜치의 작업을 가려낼 때 비교하는 브랜치. 현재 브랜치가 기준 브랜치 자체면 nil.
    private(set) var historyBase: String?
    /// 기준 브랜치에 모두 들어간 로컬 브랜치 이름
    private(set) var mergedBranchNames: Set<String> = []
    /// 기준 브랜치의 첫 부모 줄. 브랜치 끝이 여기 있으면 "머지됨"이 아니라 "작업 없음"이다.
    private var baseFirstParentHashes: Set<String> = []
    /// 정리 표시의 기준이 된 브랜치
    private(set) var cleanupBase: String?

    /// 사이드바에 붙는 정리 표시. 짧은 글자와 마우스를 올렸을 때 보이는 이유.
    struct BranchCleanup: Hashable {
        let label: String
        let reason: String
    }

    /// 오래 가는 브랜치 이름. 이것들은 다른 브랜치에 들어갔더라도 정리 대상이 아니다.
    private static let longLivedNames: Set<String> = ["main", "master", "develop", "trunk", "release", "staging", "production"]

    /// 정리해도 되는 브랜치면 표시. 지우지는 않는다.
    /// 조건은 둘뿐이다. 추적하던 원격 브랜치가 사라졌거나, 기준 브랜치에 커밋이 모두 들어갔거나.
    /// main·develop 같은 오래 가는 브랜치와 원격 HEAD가 가리키는 브랜치는 뺀다.
    func cleanup(for branch: Branch) -> BranchCleanup? {
        guard !branch.isRemote, !branch.isHead, branch.worktreePath == nil else { return nil }
        if branch.upstreamGone {
            return BranchCleanup(label: "원격 없음", reason: "추적하던 원격 브랜치가 사라졌습니다 (\(branch.upstream ?? "")). 보통 PR이 머지되어 지워진 경우입니다.")
        }
        guard let cleanupBase, branch.name != cleanupBase, mergedBranchNames.contains(branch.name) else { return nil }
        if Self.longLivedNames.contains(branch.name) { return nil }
        if remoteHeads.values.contains(where: { $0.split(separator: "/", maxSplits: 1).dropFirst().joined() == branch.name }) { return nil }
        // 끝이 기준 브랜치의 첫 부모 줄 위에 있으면 머지된 게 아니라 갈라진 뒤 커밋을 안 한 것이다.
        if baseFirstParentHashes.contains(branch.hash) {
            return BranchCleanup(label: "작업 없음", reason: "\(cleanupBase)에서 갈라진 뒤 커밋을 하나도 하지 않았습니다. 끝이 \(cleanupBase)의 옛 커밋을 그대로 가리킵니다. 지워도 잃는 것이 없습니다.")
        }
        return BranchCleanup(label: "머지됨", reason: "이 브랜치의 커밋이 머지 커밋을 거쳐 모두 \(cleanupBase)에 들어가 있습니다. 더 쓸 일이 없으면 지워도 됩니다.")
    }

    /// 기준 브랜치를 고른다. PR의 base → 원격 HEAD → develop/main/master 순으로, 있는 것 중 첫째.
    /// `exclude`는 보고 있는 브랜치 이름. 그 브랜치 자신은 기준이 될 수 없다.
    func resolveBase(excluding exclude: String?) -> String? {
        var candidates: [String] = []
        for remote in remoteNames {
            if let head = remoteHeads[remote] { candidates.append(head) }
        }
        candidates += ["develop", "main", "master", "trunk"]
        for name in candidates {
            // 로컬 브랜치를 먼저, 없으면 같은 이름의 원격 브랜치
            let local = branches.first { !$0.isRemote && $0.name == name }
            let short = name.split(separator: "/", maxSplits: 1).dropFirst().joined()
            let remote = branches.first { $0.isRemote && ($0.name == name || $0.nameWithoutRemote == name) }
            guard let found = local ?? remote else { continue }
            if let exclude, found.name == exclude || found.nameWithoutRemote == exclude || short == exclude { continue }
            return found.name
        }
        return nil
    }

    /// 그래프가 먼저 걷는 기준 브랜치 이름. 흔한 이름에 원격 HEAD가 가리키는 브랜치와 비교 기준을 더한다.
    private var graphBaseNames: Set<String> {
        var names = CommitGraph.defaultBaseNames
        for head in remoteHeads.values {
            names.insert(head.split(separator: "/", maxSplits: 1).dropFirst().joined())
        }
        if let cleanupBase { names.insert(cleanupBase) }
        return names
    }

    /// 브랜치(또는 HEAD)와 그 추적 브랜치. 추적 브랜치도 같이 넣어서 풀하면 들어올 커밋과 그 끝이 그래프에 보이게 한다.
    /// 원격에서 지워진 추적 브랜치를 넣으면 `git log`가 통째로 실패하니, 원격 브랜치 목록에 있을 때만 넣는다.
    private func tips(of name: String) -> (tips: [String], upstream: String?) {
        let branchName = name == "HEAD" ? status.branch : name
        let upstream = localBranches.first { $0.name == branchName }?.upstream
            .flatMap { up in branches.contains { $0.isRemote && $0.name == up } ? up : nil }
        return ([name] + (upstream.map { [$0] } ?? []), upstream)
    }

    private func headRevisions(scope: HistoryScope, base: String?) -> [String] { tips(of: "HEAD").tips }

    /// 히스토리 칸과 사이드바에서 고른 브랜치가 같은 규칙으로 쓴다.
    /// 브랜치와 추적 브랜치의 커밋을 읽고, 기준 브랜치에 이미 있는 커밋을 가려 낸다.
    private func loadHistory(of name: String, git: GitRepository) async throws -> BranchHistory {
        if historyScope == .all { return BranchHistory(commits: try await git.logAll()) }
        let (revisions, upstream) = tips(of: name)
        let commits = try await git.graphLog(revisions)
        guard let base = name == "HEAD" ? historyBase : resolveBase(excluding: name) else { return BranchHistory(commits: commits) }
        let own = try await git.revList(["\(base)..\(name)"])
        var incoming: Set<String> = []
        if let upstream { incoming = try await git.revList(["\(name)..\(upstream)"]) }
        let baseHashes = Set(commits.map(\.hash)).subtracting(own).subtracting(incoming)
        return BranchHistory(commits: commits, baseHashes: baseHashes, ownCount: own.count, incomingCount: incoming.count, base: base)
    }
    /// 히스토리 칸에 보이는 커밋
    private(set) var commits: [Commit] = []
    /// 히스토리 칸에서 기준 브랜치와 견준 결과(커밋 목록은 `commits`)
    private(set) var historyInfo = BranchHistory(commits: [])
    /// 사이드바에서 고른 브랜치에서 기준 브랜치와 견준 결과
    private(set) var refHistoryInfo = BranchHistory(commits: [])
    /// 목록이 이 커밋으로 스크롤해야 할 때 잠깐 값이 들어온다
    var scrollTargetHash: String?
    private(set) var graph = CommitGraphResult()
    /// 브랜치나 태그를 골랐을 때 그쪽 커밋
    private(set) var refCommits: [Commit] = []
    private(set) var refGraph = CommitGraphResult()
    /// `refCommits`가 어느 브랜치·태그의 것인지. 다른 것을 고른 직후 옛 목록을 잠깐 보여 주지 않게 한다.
    private(set) var refCommitsName: String?

    // MARK: 선택

    var sidebarSelection: SidebarItem?

    /// 사이드바에서 브랜치를 고른다. 지금 워크트리의 현재 브랜치는 "히스토리"와 같은 목록이라 히스토리로 보낸다.
    /// 따로 열면 같은 커밋을 두 곳에서 고른 커밋·스크롤·검색이 다른 채로 보게 된다.
    func selectBranch(_ branch: Branch) {
        if !branch.isRemote, branch.isHead, branch.worktreePath == nil || branch.worktreePath == activeWorktreePath {
            sidebarSelection = nil
            pane = .history
        } else {
            sidebarSelection = .branch(branch.id)
        }
    }
    var pane: Pane = .changes {
        didSet { UserDefaults.standard.set(pane.rawValue, forKey: "lastPane") }
    }
    /// 왼쪽 사이드바와 오른쪽 상세 패널을 접었는지. 기억해 둔다.
    var showsSidebar = UserDefaults.standard.object(forKey: "showsSidebar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showsSidebar, forKey: "showsSidebar") }
    }
    var showsDetail = UserDefaults.standard.object(forKey: "showsDetail") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showsDetail, forKey: "showsDetail")
            if !showsDetail { expandsDetail = false }
        }
    }
    /// 오른쪽 패널을 넓게 펼쳤는지. 가운데 칸을 잠시 접는다. 패널을 숨기거나 탭을 다 닫으면 돌아온다.
    var expandsDetail = false
    var selectedChangeID: FileChange.ID?
    var selectedCommitID: Commit.ID? {
        // 다른 길로 고른 커밋이 바뀌면 여러 개 고른 것은 풀린다
        didSet {
            guard let selectedCommitID else {
                selectedCommitIDs = []
                return
            }
            if !selectedCommitIDs.contains(selectedCommitID) { selectedCommitIDs = [] }
        }
    }
    /// 히스토리에서 ⌘·Shift 클릭으로 함께 고른 커밋. 하나만 골랐으면 비어 있거나 하나다.
    private(set) var selectedCommitIDs: Set<Commit.ID> = []
    private var commitSelectionAnchor: Commit.ID?

    /// 여러 개 골랐을 때 그 커밋들. 목록 순서(최근 것이 위)대로. 하나만 골랐으면 비어 있다.
    var selectedCommits: [Commit] {
        guard selectedCommitIDs.count > 1 else { return [] }
        return filteredCommits.filter { selectedCommitIDs.contains($0.id) }
    }
    var selectedRefCommitID: Commit.ID?
    private(set) var detail: Detail?
    /// 목록 선택과 다를 수 있는 상세. 패널 안에서 옮겨 갔거나 뒤로 간 화면이다. 새로고침이 와도 이것을 유지한다.
    private var pinnedDetail: Detail?
    /// `.fileHistory`의 커밋
    private(set) var fileHistoryCommits: [Commit] = []
    /// `.blame`의 줄
    private(set) var blameLines: [BlameLine] = []
    /// blame에서 다른 파일에서 옮겨 온 줄도 찾는지. blame 화면의 버튼으로 켠다.
    private(set) var blameAcrossFiles = false

    func toggleBlameAcrossFiles() {
        blameAcrossFiles.toggle()
        Task { await updateDetail(force: true) }
    }
    /// 사이드바에서 고른 브랜치를 어느 브랜치와 견줄지. nil이면 기준 브랜치.
    var compareBase: String? {
        didSet { Task { await loadComparison() } }
    }
    private(set) var comparison: BranchComparison?
    /// 오른쪽 패널이 지나온 화면. 가운데 목록에서 고르면 새로 시작하고, 패널 안의 링크는 뒤에 이어 붙는다.
    private(set) var trail: [Detail] = []
    /// `trail`에서 지금 보고 있는 칸
    private(set) var trailIndex = 0
    private static let maxTrail = 30
    private var diffCache: [String: [DiffFile]] = [:]
    /// 오래된 것부터 버리려고 넣은 순서를 둔다
    private var diffCacheOrder: [String] = []
    private static let maxDiffCache = 40
    private(set) var diffFiles: [DiffFile] = []
    /// 비교 화면의 커밋. `ahead`는 head에만, `behind`는 base에만 있는 커밋.
    struct CompareCommits: Equatable {
        var ahead: [Commit] = []
        var behind: [Commit] = []
        /// 읽어 오는 최대 개수. 이만큼 오면 "더 있음"으로 적는다.
        static let limit = 200
    }
    private(set) var compareCommits = CompareCommits()
    /// 비교 화면의 충돌 미리보기. head를 base에 합쳐 본 결과와, 충돌 파일을 base와 견준 diff.
    struct CompareConflicts: Equatable {
        var preview: MergePreview
        var files: [DiffFile]
    }
    private(set) var compareConflicts: CompareConflicts?
    private(set) var isLoadingDiff = false
    private var diffGeneration = 0
    /// 고른 커밋을 포함하는 브랜치·원격·태그
    private(set) var containingRefs = GitRepository.ContainingRefs()
    /// 커밋 해시 → 그 커밋을 담은 참조. 참조가 바뀌면(refsSignature) 비운다.
    private var containingRefsCache: [String: GitRepository.ContainingRefs] = [:]
    /// 고른 커밋의 조상. 히스토리에서 나머지를 흐리게 할 때 쓴다.
    private(set) var ancestorHashes: Set<String> = []
    var highlightsAncestors = true
    var commitFilter = "" {
        // 검색어를 고치면 코드 검색 결과는 맞지 않으니 메시지 검색으로 돌아간다
        didSet { if commitFilter.trimmed != codeSearchQuery, codeSearchResults != nil || isSearchingCode { clearCodeSearch() } }
    }
    /// 코드 검색 결과. nil이면 메시지·작성자·해시로 거른다.
    private(set) var codeSearchResults: [Commit]?
    private(set) var codeSearchQuery = ""
    private(set) var isSearchingCode = false
    private var codeSearchGeneration = 0

    // MARK: 입력

    var commitMessage = ""
    var amend = false
    /// "여기서 새 브랜치…"로 시트를 열 때 기본 base. 브랜치 이름이거나 커밋 해시.
    var newBranchBase: String?

    // MARK: 화면 상태

    private(set) var busyMessage: String?
    /// 동작이 잘 끝났을 때 잠깐 보여 주는 말
    private(set) var statusMessage: String?
    var errorMessage: String?
    var sheet: Sheet?
    var confirmation: Confirmation?
    private(set) var recentRepositoryPaths: [String]
    /// 사이드바 고정·별명·정렬. 저장소마다 따로.
    private(set) var sidebarPreferences = SidebarPreferences()

    /// 커밋에 쓰는 이름과 메일
    private(set) var gitUserName = ""
    private(set) var gitUserEmail = ""

    private static let recentKey = "recentRepositories"
    private var watcher: DirectoryWatcher?
    private var isRefreshing = false
    private var refreshRequestedAgain = false
    private var statusMessageTask: Task<Void, Never>?

    init() {
        recentRepositoryPaths = UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? []
    }

    enum CommitTab: String, CaseIterable, Identifiable {
        case changes, message, place
        var id: String { rawValue }
        var title: String {
            switch self {
            case .changes: "변경"
            case .message: "메시지"
            case .place: "위치"
            }
        }
    }
    /// 커밋 상세에서 고른 탭
    var commitTab: CommitTab = .changes

    // MARK: 계산값

    var isOpen: Bool { mainRootPath != nil }
    var isBusy: Bool { busyMessage != nil }
    var repositoryName: String { (mainRootPath as NSString?)?.lastPathComponent ?? "" }
    var activeWorktreeName: String { (activeWorktreePath as NSString?)?.lastPathComponent ?? "" }
    var git: GitRepository? { activeWorktreePath.map { GitRepository(path: $0) } }
    var localBranches: [Branch] { branches.filter { !$0.isRemote } }
    var remoteBranches: [Branch] { branches.filter(\.isRemote) }
    var currentBranch: Branch? { localBranches.first(where: \.isHead) }
    var selectedChange: FileChange? { status.changes.first { $0.id == selectedChangeID } }
    var conflicts: [FileChange] { status.changes.filter { $0.area == .conflicted } }
    var remoteNames: [String] { remotes.map(\.name) }
    var lastActivity: ActivityEntry? { activities.first }

    func remoteBranches(of remote: Remote) -> [Branch] {
        remoteBranches.filter { $0.name.hasPrefix(remote.name + "/") }
    }

    var selectedBranch: Branch? {
        if case .branch(let id) = sidebarSelection { return branches.first { $0.id == id } }
        return nil
    }

    var selectedTag: Tag? {
        if case .tag(let id) = sidebarSelection { return tags.first { $0.id == id } }
        return nil
    }

    var selectedStash: Stash? {
        if case .stash(let id) = sidebarSelection { return stashes.first { $0.id == id } }
        return nil
    }

    /// 브랜치나 태그를 골랐을 때 refCommits를 뽑는 기준 이름
    private var selectedRefName: String? {
        selectedBranch?.name ?? selectedTag?.name
    }

    /// 제목에 쓰는 이름. 리베이스 중에는 git이 HEAD를 떼어 두지만 원래 브랜치 이름을 보여 준다.
    var branchDisplayName: String {
        guard let branch = status.branch else { return "" }
        guard status.isDetached else { return branch }
        return detachedPlace?.rebasingBranch ?? "분리된 HEAD"
    }

    /// 제목 옆에 작게 붙이는 말. "리베이스 3/7", "v3.2.0 · a1b2c3d", "a1b2c3d"
    var headPlaceNote: String? {
        guard status.isDetached else { return nil }
        if let place = detachedPlace, place.rebasingBranch != nil || operation == .rebasing {
            return rebaseStepText.map { "리베이스 " + $0 } ?? "리베이스 중"
        }
        let hash = status.headOID.map { String($0.prefix(7)) }
        return [detachedPlace?.tag, hash].compactMap { $0 }.joined(separator: " ").nilIfEmpty
    }

    /// 리베이스 진행 정도. "4/7"
    var rebaseStepText: String? {
        guard let step = detachedPlace?.step, let total = detachedPlace?.total else { return nil }
        return "\(min(step, total))/\(total)"
    }

    /// 리베이스처럼 잠시 브랜치를 떠나 있는지. 아이콘을 주황으로 바꾼다.
    var isAwayFromBranch: Bool { status.isDetached }

    var filteredCommits: [Commit] {
        if let codeSearchResults { return codeSearchResults }
        let query = commitFilter.trimmed.lowercased()
        guard !query.isEmpty else { return commits }
        return commits.filter {
            $0.subject.lowercased().contains(query)
                || $0.authorName.lowercased().contains(query)
                || $0.hash.hasPrefix(query)
                || $0.body.lowercased().contains(query)
        }
    }

    var isFilteringCommits: Bool { !commitFilter.trimmed.isEmpty }

    /// 검색어가 코드에 생기거나 사라진 커밋을 지금 범위에서 찾는다. 큰 저장소에서는 몇 초 걸린다.
    func searchCode() async {
        let query = commitFilter.trimmed
        guard let git, !query.isEmpty else { return }
        codeSearchGeneration += 1
        let generation = codeSearchGeneration
        isSearchingCode = true
        defer { if generation == codeSearchGeneration { isSearchingCode = false } }
        // "모든 브랜치"는 히스토리와 같은 참조. `--all`은 스태시의 임시 커밋까지 넣는다.
        let revisions = historyScope == .all ? ["HEAD", "--branches", "--tags", "--remotes"] : headRevisions(scope: historyScope, base: historyBase)
        do {
            let found = try await git.searchCode(query, revisions: revisions)
            guard generation == codeSearchGeneration else { return }
            codeSearchQuery = query
            codeSearchResults = found
        } catch {
            guard generation == codeSearchGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    func clearCodeSearch() {
        codeSearchGeneration += 1
        codeSearchResults = nil
        codeSearchQuery = ""
        isSearchingCode = false
    }

    /// 히스토리 범위 탭 아래 한 줄. "develop에 없는 커밋 3개, 받아 올 커밋 2개, develop에 이미 있는 커밋은 흐리게"
    var historyScopeNote: String? { scopeNote(historyInfo) }

    /// 사이드바에서 고른 브랜치에 대해 같은 한 줄
    func refScopeNote(for name: String) -> String? { scopeNote(refHistoryInfo) }

    private func scopeNote(_ info: BranchHistory) -> String? {
        guard historyScope == .current, let base = info.base, let own = info.ownCount else { return nil }
        var parts = ["\(base)에 없는 커밋 \(own)개"]
        if info.incomingCount > 0 { parts.append("받아 올 커밋 \(info.incomingCount)개") }
        if !info.baseHashes.isEmpty { parts.append("\(base)에 이미 있는 커밋은 흐리게") }
        return parts.joined(separator: ", ")
    }

    /// 지금 HEAD가 가리키는 커밋
    var headCommit: Commit? {
        commits.first { $0.refs.contains { $0 == "HEAD" || $0.hasPrefix("HEAD -> ") } }
    }

    /// 히스토리에서 HEAD 커밋을 고르고 그 자리로 스크롤한다.
    func jumpToHead() {
        guard let head = headCommit else { return }
        sidebarSelection = nil
        pane = .history
        commitFilter = ""
        selectCommit(head.id)
        scrollTargetHash = head.hash
    }

    func isDimmed(_ commit: Commit) -> Bool {
        guard highlightsAncestors, !ancestorHashes.isEmpty else { return false }
        return !ancestorHashes.contains(commit.hash)
    }

    // MARK: 열기

    func openRepositoryPanel() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Git 저장소 폴더를 고르세요"
        panel.prompt = "열기"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in
                await self?.open(url)
            }
        }
    }

    func open(_ url: URL) async {
        do {
            let location = try await GitRepository.locate(url)
            // 저장소 설정에 실행 명령이 있으면 열기 전에 묻는다. 열면 상태 읽기·충돌 미리보기에서 바로 돌 수 있다.
            let settings = await RepositoryTrust.executableSettings(in: GitRepository(path: location.mainRoot))
            if !settings.isEmpty, !RepositoryTrust.isTrusted(root: location.mainRoot, settings: settings) {
                askTrust(root: location.mainRoot, settings: settings) { [weak self] in await self?.open(url) }
                return
            }
            mainRootPath = location.mainRoot
            addRecent(location.mainRoot)
            loadSidebarPreferences()
            loadDeletedBranches()
            await activateWorktree(location.worktree)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func askTrust(root: String, settings: [String], then reopen: @escaping @MainActor () async -> Void) {
        let shown = settings.prefix(8).map { Confirmation.Fact.item($0) }
        confirmation = Confirmation(
            title: "이 저장소를 신뢰할까요?",
            target: (root as NSString).abbreviatingWithTildeInPath,
            targetDetail: "저장소 설정에 git이 실행하는 명령이 있습니다",
            facts: [.warns("열거나 커밋, 체크아웃, 머지할 때 아래 명령이 이 Mac에서 실행됩니다")]
                + shown
                + (settings.count > 8 ? [.item("외 \(settings.count - 8)개")] : [])
                + [.note("직접 만들었거나 출처를 아는 저장소만 신뢰하세요. 설정이 바뀌면 다시 묻습니다")],
            buttonTitle: "신뢰하고 열기"
        ) {
            RepositoryTrust.trust(root: root, settings: settings)
            await reopen()
        }
    }

    func open(path: String) async {
        await open(URL(fileURLWithPath: path, isDirectory: true))
    }

    /// 지난번에 열어 둔 저장소·워크트리·칸을 다시 연다. 인자 없이 실행했을 때 쓴다.
    /// 마지막 저장소·칸·고른 커밋을 그대로 되살린다. 앱을 새로 설치해 다시 띄워도 보던 자리로 돌아온다.
    func restoreLastSession() async {
        guard let path = UserDefaults.standard.string(forKey: "lastWorktree") ?? UserDefaults.standard.string(forKey: "lastRepository"),
              FileManager.default.fileExists(atPath: path) else { return }
        await open(path: path)
        if let raw = UserDefaults.standard.string(forKey: "lastPane"), let saved = Pane(rawValue: raw) {
            pane = saved
        }
        if let raw = UserDefaults.standard.string(forKey: "lastSidebar"), !raw.isEmpty {
            if raw.hasPrefix("branch:"), let branch = branches.first(where: { $0.id == String(raw.dropFirst(7)) }) {
                selectBranch(branch)
                await handleSidebarSelection()
            } else if raw.hasPrefix("tag:"), let tag = tags.first(where: { $0.id == String(raw.dropFirst(4)) }) {
                sidebarSelection = .tag(tag.id)
                await handleSidebarSelection()
            }
        }
        if let hash = UserDefaults.standard.string(forKey: "lastCommit"), !hash.isEmpty {
            let list = sidebarSelection == nil ? commits : refCommits
            if list.contains(where: { $0.hash == hash }) {
                selectCommit(hash)
                scrollTargetHash = hash
            }
        }
    }

    /// 다음 실행 때 되살릴 선택을 적어 둔다.
    private func rememberSelection() {
        let sidebar: String
        switch sidebarSelection {
        case .branch(let id): sidebar = "branch:" + id
        case .tag(let id): sidebar = "tag:" + id
        default: sidebar = ""
        }
        UserDefaults.standard.set(sidebar, forKey: "lastSidebar")
        let commit = (sidebarSelection == nil ? selectedCommitID : selectedRefCommitID) ?? ""
        UserDefaults.standard.set(pane == .history || sidebarSelection != nil ? commit : "", forKey: "lastCommit")
    }

    /// 번들 없이 `swift run`으로 쓰던 때의 최근 목록을 한 번 가져온다. 설정 영역이 달라서 비어 보이기 때문이다.
    func importLegacyRecents() {
        guard recentRepositoryPaths.isEmpty, Bundle.main.bundleIdentifier != nil,
              let legacy = UserDefaults(suiteName: "Canopy")?.stringArray(forKey: Self.recentKey) ?? UserDefaults(suiteName: "Grove")?.stringArray(forKey: Self.recentKey) else { return }
        let existing = legacy.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return }
        recentRepositoryPaths = existing
        UserDefaults.standard.set(existing, forKey: Self.recentKey)
    }

    /// 받아 온 뒤 바로 연다.
    @discardableResult
    func clone(_ url: String, to destination: String) async -> Bool {
        guard busyMessage == nil else { return false }
        busyMessage = "클론 중…"
        defer { busyMessage = nil }
        do {
            try await GitRepository.clone(url, to: destination)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        await open(path: destination)
        return true
    }

    private func addRecent(_ path: String) {
        recentRepositoryPaths.removeAll { $0 == path }
        recentRepositoryPaths.insert(path, at: 0)
        recentRepositoryPaths = Array(recentRepositoryPaths.prefix(10))
        UserDefaults.standard.set(recentRepositoryPaths, forKey: Self.recentKey)
    }

    private func resetSelection() {
        sidebarSelection = nil
        selectedChangeID = nil
        selectedCommitID = nil
        selectedRefCommitID = nil
        selectedActivityID = nil
        activityCommit = nil
        detail = nil
        trail = []
        trailIndex = 0
        expandsDetail = false
        undoStack = []
        redoStack = []
        // 멈춘 Git Flow 마무리와 커밋 정리는 그 저장소의 것이다. 다른 저장소를 열면 버린다.
        // 같은 저장소 안에서 워크트리만 바꾸면 남겨 둔다(그 워크트리로 돌아오면 이어 간다).
        if gitFlowRun?.repository != mainRootPath { gitFlowRun = nil }
        if pendingRewrite?.repository != mainRootPath { pendingRewrite = nil }
        diffCache = [:]
        diffCacheOrder = []
        diffFiles = []
        refCommits = []
        refGraph = CommitGraphResult()
        containingRefs = GitRepository.ContainingRefs()
        ancestorHashes = []
        commitFilter = ""
        commitMessage = ""
        amend = false
    }

    // MARK: 사이드바 고정·별명·정렬

    private var preferencesKey: String? { mainRootPath.map { "sidebar:" + $0 } }

    private func loadSidebarPreferences() {
        guard let key = preferencesKey, let data = UserDefaults.standard.data(forKey: key),
              let loaded = try? JSONDecoder().decode(SidebarPreferences.self, from: data) else {
            sidebarPreferences = SidebarPreferences()
            return
        }
        sidebarPreferences = loaded
    }

    private func saveSidebarPreferences() {
        guard let key = preferencesKey, let data = try? JSONEncoder().encode(sidebarPreferences) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    func isPinned(_ key: String) -> Bool { sidebarPreferences.pinned.contains(key) }

    func togglePin(_ key: String) {
        if let index = sidebarPreferences.pinned.firstIndex(of: key) {
            sidebarPreferences.pinned.remove(at: index)
        } else {
            sidebarPreferences.pinned.append(key)
        }
        saveSidebarPreferences()
    }

    func alias(for key: String) -> String? {
        sidebarPreferences.aliases[key].flatMap { $0.isEmpty ? nil : $0 }
    }

    func setAlias(_ alias: String, for key: String) {
        let trimmed = alias.trimmed
        if trimmed.isEmpty {
            sidebarPreferences.aliases.removeValue(forKey: key)
        } else {
            sidebarPreferences.aliases[key] = trimmed
        }
        saveSidebarPreferences()
    }

    func sortOrder(for section: String, default fallback: SidebarSortOrder) -> SidebarSortOrder {
        sidebarPreferences.sorts[section].flatMap(SidebarSortOrder.init(rawValue:)) ?? fallback
    }

    func setSortOrder(_ order: SidebarSortOrder, for section: String) {
        sidebarPreferences.sorts[section] = order.rawValue
        saveSidebarPreferences()
    }

    // MARK: 워크트리 전환과 파일 감시

    func activateWorktree(_ path: String) async {
        guard path != activeWorktreePath else { return }
        activeWorktreePath = path
        UserDefaults.standard.set(path, forKey: "lastWorktree")
        UserDefaults.standard.set(mainRootPath, forKey: "lastRepository")
        resetSelection()
        watcher = DirectoryWatcher(path: path) { [weak self] paths in
            guard let self, !self.isBusy else { return }
            let inGit: (String) -> Bool = { $0.contains("/.git/") || $0.hasSuffix("/.git") }
            let gitOnly = !paths.isEmpty && paths.allSatisfy(inGit)
            if gitOnly, Date().timeIntervalSince(self.lastOwnChangeAt) < 2 {
                Timing.log("watcher: ignored own .git change")
                return
            }
            // .git이 조금이라도 바뀌었으면(터미널에서 체크아웃·풀·커밋 등) 참조까지 다시 읽는다.
            // 작업 트리 파일만 바뀌었을 때만 가볍게 읽는다.
            let touchesGit = paths.contains(where: inGit)
            Timing.log("watcher fired" + (touchesGit ? " (.git)" : " (worktree)"))
            Task { await self.refresh(light: !touchesGit) }
        }
        await refresh()
    }

    // MARK: 새로고침

    /// 바뀐 값만 넣는다. 같은 값을 다시 넣어도 화면이 그 값을 쓰는 곳을 모두 다시 그리기 때문이다.
    private func assign<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<RepositoryStore, T>, _ value: T) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    /// 브랜치·태그·스태시·HEAD를 한 줄로 요약한 값. 이것이 그대로면 히스토리·활동·그래프·정리 표시를 다시 계산하지 않는다.
    private var refsSignature = ""
    /// 마지막으로 앱이 스스로 git을 바꾸고 새로고침을 끝낸 때. 그 직후 파일 감시가 보내는 .git 변경은 같은 일의 메아리다.
    private var lastOwnChangeAt = Date.distantPast

    /// 상태를 다시 읽는다.
    /// `light`면 작업 트리와 스테이징만 읽는다. 스테이징·해제·버리기처럼 참조가 안 바뀌는 동작 뒤에 쓴다.
    /// 아니면 참조까지 읽되, 참조 요약이 그대로면 무거운 단계(로그·활동·머지 여부)를 건너뛴다.
    func refresh(light: Bool = false) async {
        guard let git else { return }
        if isRefreshing {
            refreshRequestedAgain = true
            return
        }
        isRefreshing = true
        defer {
            isRefreshing = false
            if refreshRequestedAgain {
                refreshRequestedAgain = false
                Task { await refresh() }
            }
        }
        let refreshStarted = Date()
        do {
            async let statusTask = git.status()
            async let operationTask = git.operationState()
            async let workingStatTask = git.diffStat(cached: false)
            async let stagedStatTask = git.diffStat(cached: true)
            async let fetchDateTask = git.lastFetchDate()
            if light {
                assign(\.status, try await statusTask)
                assign(\.operation, try await operationTask)
                if operation == nil, pendingRewrite != nil { await settlePendingRewrite() }
                assign(\.lastFetchedAt, try? await fetchDateTask)
                assign(\.detachedPlace, status.isDetached ? try? await git.detachedPlace() : nil)
                assign(\.workingStat, try await workingStatTask)
                assign(\.stagedStat, try await stagedStatTask)
                pruneChangeSelection()
                await updateDetail(force: true)
                Timing.log("refresh(light): done \(Int(Date().timeIntervalSince(refreshStarted) * 1000))ms")
                return
            }
            async let worktreesTask = git.worktrees()
            async let branchesTask = git.branches()
            async let tagsTask = git.tags()
            async let stashesTask = git.stashes()
            async let remotesTask = git.remotesDetailed()
            async let headTask = git.hasHead()
            async let identityTask = git.userIdentity()
            async let remoteHeadsTask = git.remoteHeads()
            assign(\.worktrees, try await worktreesTask)
            assign(\.branches, try await branchesTask)
            assign(\.tags, try await tagsTask)
            assign(\.stashes, try await stashesTask)
            assign(\.remotes, try await remotesTask)
            assign(\.status, try await statusTask)
            assign(\.hasHead, try await headTask)
            assign(\.operation, try await operationTask)
            // 멈췄던 커밋 정리가 끝났으면(앱 밖에서 끝냈어도) 바로 되돌리기 기록을 남긴다. 늦으면 그 사이 작업까지 덮는다.
            if operation == nil, pendingRewrite != nil { await settlePendingRewrite() }
            assign(\.lastFetchedAt, try? await fetchDateTask)
            assign(\.detachedPlace, status.isDetached ? try? await git.detachedPlace() : nil)
            assign(\.workingStat, try await workingStatTask)
            assign(\.stagedStat, try await stagedStatTask)
            let identity = try await identityTask
            assign(\.gitUserName, identity.name)
            assign(\.gitUserEmail, identity.email)
            assign(\.remoteHeads, (try? await remoteHeadsTask) ?? [:])
            Timing.log("refresh: status/refs \(Int(Date().timeIntervalSince(refreshStarted) * 1000))ms")

            let signature = [
                status.branch ?? "", status.headOID ?? "", status.upstream ?? "", historyScope.rawValue, selectedRefName ?? "",
                branches.map { $0.fullName + "=" + $0.hash }.joined(separator: ","),
                tags.map(\.name).joined(separator: ","),
                stashes.map(\.hash).joined(separator: ","),
                remoteHeads.sorted { $0.key < $1.key }.map { $0.key + $0.value }.joined(),
            ].joined(separator: "|")
            if signature != refsSignature {
                refsSignature = signature
                // 브랜치가 바뀌면 코드 검색 결과는 맞지 않는다. 메시지 검색으로 돌아간다.
                if codeSearchResults != nil { clearCodeSearch() }
                containingRefsCache = [:]
                mergePreviewCache = [:]
                assign(\.historyBase, resolveBase(excluding: status.branch))
                assign(\.cleanupBase, resolveBase(excluding: nil))
                assign(\.gitFlowConfig, GitFlowConfig(settings: (try? await git.gitFlowSettings()) ?? [:], branchNames: flowBranchNames))
                // 서로 기다릴 필요 없는 것들은 한꺼번에 돌린다.
                let base = cleanupBase
                let baseNames = Set((base.map { [$0] } ?? []) + graphBaseNames.filter { name in branches.contains { !$0.isRemote && $0.name == name } })
                async let mergedTask: Set<String> = {
                    guard let base else { return [] }
                    return (try? await git.mergedBranches(into: base)) ?? []
                }()
                async let firstParentTask: Set<String> = {
                    var lines: Set<String> = []
                    for name in baseNames { lines.formUnion((try? await git.firstParentHashes(of: name)) ?? []) }
                    return lines
                }()
                let head = hasHead
                async let activitiesTask: [ActivityEntry] = head ? try await git.activities() : []
                let history = head ? try await loadHistory(of: "HEAD", git: git) : BranchHistory(commits: [])
                var refHistory: BranchHistory?
                if let name = selectedRefName { refHistory = try await loadHistory(of: name, git: git) }
                let newCommits = history.commits
                historyInfo = BranchHistory(commits: [], baseHashes: history.baseHashes, ownCount: history.ownCount, incomingCount: history.incomingCount, base: history.base)
                if let refHistory {
                    refHistoryInfo = BranchHistory(commits: [], baseHashes: refHistory.baseHashes, ownCount: refHistory.ownCount, incomingCount: refHistory.incomingCount, base: refHistory.base)
                }
                let refLog = refHistory?.commits
                assign(\.activities, try await activitiesTask)
                assign(\.mergedBranchNames, await mergedTask)
                baseFirstParentHashes = await firstParentTask
                if newCommits != commits || graph.rows.count != newCommits.count {
                    commits = newCommits
                    graph = CommitGraph.build(commits, remoteNames: remoteNames, baseNames: graphBaseNames)
                }
                if let refLog, refLog != refCommits || refGraph.rows.count != refLog.count {
                    refCommits = refLog
                    refGraph = CommitGraph.build(refCommits, remoteNames: remoteNames, baseNames: graphBaseNames)
                    refCommitsName = selectedRefName
                }
                if selectedRefName != nil { Task { await loadComparison() } }
                Timing.log("refresh: refs changed, log/activity/merged \(Int(Date().timeIntervalSince(refreshStarted) * 1000))ms")
            }

            pruneChangeSelection()
            if let id = selectedCommitID, !commits.contains(where: { $0.id == id }), !(codeSearchResults?.contains { $0.id == id } ?? false) {
                selectedCommitID = nil
            }
            if let id = selectedRefCommitID, !refCommits.contains(where: { $0.id == id }) {
                selectedRefCommitID = nil
            }
            if case .stash(let id) = sidebarSelection, !stashes.contains(where: { $0.id == id }) {
                sidebarSelection = nil
            }
            if case .tag(let id) = sidebarSelection, !tags.contains(where: { $0.id == id }) {
                sidebarSelection = nil
            }
            if case .branch(let id) = sidebarSelection, !branches.contains(where: { $0.id == id }) {
                sidebarSelection = nil
            }
            await updateDetail(force: true)
            Timing.log("refresh: done \(Int(Date().timeIntervalSince(refreshStarted) * 1000))ms")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: 사이드바

    func handleSidebarSelection() async {
        commitFilter = ""
        rememberSelection()
        switch sidebarSelection {
        case .branch, .tag:
            await loadRefCommits()
        case .stash, nil:
            await updateDetail(force: true)
        }
    }

    private func loadRefCommits() async {
        guard let git, let name = selectedRefName else { return }
        let started = Date()
        defer { Timing.log("loadRefCommits \(name) \(Int(Date().timeIntervalSince(started) * 1000))ms") }
        selectedRefCommitID = nil
        comparison = nil
        compareBase = nil
        do {
            let history = try await loadHistory(of: name, git: git)
            // 읽는 동안 다른 것을 골랐으면 버린다
            guard selectedRefName == name else { return }
            refHistoryInfo = BranchHistory(commits: [], baseHashes: history.baseHashes, ownCount: history.ownCount, incomingCount: history.incomingCount, base: history.base)
            let loaded = history.commits
            refCommits = loaded
            refGraph = CommitGraph.build(refCommits, remoteNames: remoteNames, baseNames: graphBaseNames)
            refCommitsName = name
        } catch {
            refCommits = []
            refGraph = CommitGraphResult()
            refCommitsName = name
            errorMessage = error.localizedDescription
        }
        await updateDetail(force: true)
    }

    // MARK: 선택과 diff

    /// 여러 개 고른 변경. `selectedChangeID`는 그중 마지막에 고른 것이고 오른쪽에 diff로 보인다.
    private(set) var selectedChangeIDs: Set<FileChange.ID> = []
    /// Shift로 범위를 고를 때의 기준
    private var changeSelectionAnchor: FileChange.ID?

    /// 변경 목록의 화면 순서. 충돌 → 스테이징됨 → 변경 사항.
    var orderedChanges: [FileChange] {
        conflicts + status.staged + status.unstaged.filter { $0.area != .conflicted }
    }

    /// Fork처럼: 그냥 누르면 하나, Shift는 범위, ⌘는 하나씩 더하거나 뺀다.
    func selectChange(_ id: FileChange.ID?, extend: Bool = false, toggle: Bool = false) {
        guard let id else {
            selectedChangeID = nil
            selectedChangeIDs = []
            Task { await updateDetail() }
            return
        }
        let ordered = orderedChanges
        if extend, let anchor = changeSelectionAnchor,
           let from = ordered.firstIndex(where: { $0.id == anchor }), let to = ordered.firstIndex(where: { $0.id == id }) {
            selectedChangeIDs = Set(ordered[min(from, to)...max(from, to)].map(\.id))
        } else if toggle {
            if selectedChangeIDs.contains(id), selectedChangeIDs.count > 1 {
                selectedChangeIDs.remove(id)
                if selectedChangeID == id { selectedChangeID = ordered.first { selectedChangeIDs.contains($0.id) }?.id }
                Task { await updateDetail() }
                return
            }
            selectedChangeIDs.insert(id)
            changeSelectionAnchor = id
        } else {
            selectedChangeIDs = [id]
            changeSelectionAnchor = id
        }
        selectedChangeID = id
        showsDetail = true
        Task { await updateDetail() }
    }

    /// ⌘A. 지금 고른 것이 있는 묶음(스테이징됨 또는 변경 사항) 전체, 없으면 변경 사항 전체.
    func selectAllChanges() {
        let group: [FileChange]
        if let primary = selectedChange, primary.isStaged {
            group = status.staged
        } else {
            group = status.unstaged.filter { $0.area != .conflicted }
        }
        guard !group.isEmpty else { return }
        selectedChangeIDs = Set(group.map(\.id))
        if let id = selectedChangeID, selectedChangeIDs.contains(id) {
            // 보던 파일은 그대로
        } else {
            selectedChangeID = group[0].id
            changeSelectionAnchor = group[0].id
        }
        showsDetail = true
        Task { await updateDetail() }
    }

    /// 고른 것들 중 있는 것만 남긴다. 새로고침 뒤에 부른다.
    private func pruneChangeSelection() {
        let ids = Set(status.changes.map(\.id))
        selectedChangeIDs = selectedChangeIDs.intersection(ids)
        if let id = selectedChangeID, !ids.contains(id) {
            selectedChangeID = orderedChanges.first { selectedChangeIDs.contains($0.id) }?.id
        }
    }

    /// 지금 고른 변경들. 화면 순서대로.
    var selectedChanges: [FileChange] {
        orderedChanges.filter { selectedChangeIDs.contains($0.id) }
    }

    /// - Parameters:
    ///   - extend: Shift 클릭. 마지막으로 고른 커밋부터 여기까지
    ///   - toggle: ⌘ 클릭. 하나씩 더하거나 뺀다
    func selectCommit(_ id: Commit.ID?, extend: Bool = false, toggle: Bool = false) {
        if id != nil { showsDetail = true }
        if sidebarSelection == nil {
            let ordered = filteredCommits
            if let id, extend, let anchor = commitSelectionAnchor,
               let from = ordered.firstIndex(where: { $0.id == anchor }), let to = ordered.firstIndex(where: { $0.id == id }) {
                selectedCommitIDs = Set(ordered[min(from, to)...max(from, to)].map(\.id))
            } else if let id, toggle {
                if selectedCommitIDs.isEmpty, let current = selectedCommitID { selectedCommitIDs = [current] }
                if selectedCommitIDs.contains(id), selectedCommitIDs.count > 1 {
                    selectedCommitIDs.remove(id)
                    if selectedCommitID == id { selectedCommitID = ordered.first { selectedCommitIDs.contains($0.id) }?.id }
                    rememberSelection()
                    Task { await updateDetail() }
                    return
                }
                selectedCommitIDs.insert(id)
                commitSelectionAnchor = id
            } else {
                selectedCommitIDs = id.map { [$0] } ?? []
                commitSelectionAnchor = id
            }
            selectedCommitID = id
        } else {
            selectedRefCommitID = id
        }
        rememberSelection()
        Task { await updateDetail() }
    }

    func selectActivity(_ entry: ActivityEntry?) {
        selectedActivityID = entry?.id
        guard let entry else {
            activityCommit = nil
            Task { await updateDetail() }
            return
        }
        if let known = commits.first(where: { $0.hash == entry.hash }) {
            activityCommit = known
            Task { await updateDetail() }
            return
        }
        Task {
            // 리셋으로 버려진 커밋처럼 목록에 없는 커밋은 따로 읽는다.
            activityCommit = try? await git?.log(revision: entry.hash, limit: 1).first
            await updateDetail()
        }
    }

    func updateDetail(force: Bool = false) async {
        var next: Detail?
        switch sidebarSelection {
        case .stash:
            next = selectedStash.map(Detail.stash)
        case .branch, .tag:
            if let commit = refCommits.first(where: { $0.id == selectedRefCommitID }) {
                next = .commit(commit)
            } else {
                next = nil
            }
        case nil:
            switch pane {
            case .changes:
                next = selectedChange.map(Detail.change)
            case .history:
                // 코드 검색 결과는 불러온 히스토리(400개) 밖에 있을 수 있다
                next = (commits.first { $0.id == selectedCommitID } ?? codeSearchResults?.first { $0.id == selectedCommitID }).map(Detail.commit)
            case .activity:
                next = activityCommit.map(Detail.commit)
            }
        }
        // 사용자가 목록에서 무언가 고르면(force가 아니면) 고정 상세는 풀린다. 새로고침이면 유지한다.
        if let pinnedDetail {
            if force {
                next = pinnedDetail
            } else {
                self.pinnedDetail = nil
            }
        }
        if case .commit(let commit)? = next {
            let list = sidebarSelection == nil ? commits : refCommits
            ancestorHashes = CommitGraph.ancestors(of: commit.hash, in: list)
        } else {
            ancestorHashes = []
        }
        // 커밋 diff는 바뀌지 않으니 같은 커밋이면 다시 읽지 않는다.
        if !force || isCommitDetail(next), next == detail { return }
        detail = next
        if let next {
            // 같은 화면이 길에 두 번 있을 수 있어서 지금 칸부터 본다
            if force, let index = (trail.indices.contains(trailIndex) && trail[trailIndex].id == next.id) ? trailIndex : trail.lastIndex(where: { $0.id == next.id }) {
                // 새로고침: 지나온 길은 그대로 두고 그 칸의 값만 바꾼다
                trail[index] = next
                trailIndex = index
            } else {
                startTrail(next)
            }
        } else {
            clearTrail()
        }
        await loadDiff()
    }

    // MARK: 오른쪽 패널 이동 기록

    var canGoBack: Bool { trailIndex > 0 }
    var canGoForward: Bool { trailIndex + 1 < trail.count }

    /// 가운데 목록에서 골랐을 때. 지나온 길을 버리고 새로 시작한다.
    private func startTrail(_ item: Detail) {
        trail = [item]
        trailIndex = 0
    }

    private func clearTrail() {
        trail = []
        trailIndex = 0
        expandsDetail = false
    }

    /// 패널 안의 링크로 옮겨 갈 때. 지금 칸 뒤에 이어 붙이고, 앞으로 갈 칸은 버린다.
    private func pushTrail(_ item: Detail) {
        guard trail.indices.contains(trailIndex) else {
            startTrail(item)
            return
        }
        if trail[trailIndex].id == item.id {
            trail[trailIndex] = item
            return
        }
        trail = Array(trail.prefix(trailIndex + 1)) + [item]
        if trail.count > Self.maxTrail { trail.removeFirst(trail.count - Self.maxTrail) }
        trailIndex = trail.count - 1
    }

    /// ⌘[
    func goBack() {
        guard canGoBack else { return }
        showTrail(at: trailIndex - 1)
    }

    /// ⌘]
    func goForward() {
        guard canGoForward else { return }
        showTrail(at: trailIndex + 1)
    }

    /// 지나온 길의 한 칸을 다시 보여 준다. 가운데 목록의 선택은 건드리지 않는다.
    func showTrail(at index: Int) {
        guard trail.indices.contains(index) else { return }
        trailIndex = index
        let item = trail[index]
        pinnedDetail = item
        detail = item
        Task { await loadDiff() }
    }

    // MARK: 비교·파일 역사·blame

    /// 패널 안에서 다른 화면으로 옮겨 간다. 가운데 목록의 선택은 그대로 두고, 새로고침이 와도 유지된다.
    private func pin(_ item: Detail) async {
        pinnedDetail = item
        detail = item
        pushTrail(item)
        showsDetail = true
        await loadDiff()
    }

    /// 사이드바에서 고른 브랜치와 비교 기준의 차이를 읽는다.
    func loadComparison() async {
        let started = Date()
        defer { Timing.log("loadComparison \(Int(Date().timeIntervalSince(started) * 1000))ms") }
        guard let git, let branch = selectedBranch else {
            comparison = nil
            return
        }
        guard let base = compareBase ?? resolveBase(excluding: branch.name), base != branch.name else {
            comparison = nil
            return
        }
        do {
            async let countsTask = git.aheadBehind(base: base, head: branch.name)
            async let statTask = git.diffStat(base: base, head: branch.name)
            let counts = try await countsTask
            let stat = try await statTask
            // 합칠 커밋이 있을 때만 합쳐 본다. 고른 기준 브랜치가 어느 것이든 같은 계산이다.
            let preview = counts.ahead > 0 ? await previewMerge(ours: base, theirs: branch.name) : nil
            guard selectedBranch?.name == branch.name else { return }
            comparison = BranchComparison(base: base, head: branch.name, ahead: counts.ahead, behind: counts.behind, stat: stat, preview: preview)
        } catch {
            comparison = nil
        }
    }

    /// 비교 결과의 diff를 오른쪽에 연다.
    func showComparison() {
        guard let comparison else { return }
        Task { await pin(.compare(base: comparison.base, head: comparison.head)) }
    }

    func showFileHistory(_ path: String) {
        Task { await pin(.fileHistory(path)) }
    }

    func showBlame(_ path: String) {
        Task { await pin(.blame(path)) }
    }

    /// 패널 안의 링크(비교의 커밋, 부모 커밋, 파일 역사, 줄별 작성자)로 커밋을 연다.
    /// 지나온 길에 이어 붙이고 가운데 목록은 옮기지 않는다. 보던 자리를 잃지 않게 하려는 것이다.
    func showCommit(hash: String) {
        if let commit = commits.first(where: { $0.hash == hash }) ?? refCommits.first(where: { $0.hash == hash }) {
            Task { await pin(.commit(commit)) }
            return
        }
        Task {
            guard let commit = try? await git?.log(revision: hash, limit: 1).first else { return }
            await pin(.commit(commit))
        }
    }

    private func isCommitDetail(_ detail: Detail?) -> Bool {
        switch detail {
        case .commit: true
        default: false
        }
    }

    private func loadDiff() async {
        diffGeneration += 1
        let generation = diffGeneration
        guard let git, let detail else {
            diffFiles = []
            containingRefs = GitRepository.ContainingRefs()
            return
        }
        if isCommitDetail(detail), let cached = diffCache[detail.id] {
            diffFiles = cached
            if case .commit(let commit) = detail { containingRefs = containingRefsCache[commit.hash] ?? GitRepository.ContainingRefs() }
            return
        }
        isLoadingDiff = true
        let loadStarted = Date()
        defer {
            Timing.log("loadDiff \(detail.id) \(Int(Date().timeIntervalSince(loadStarted) * 1000))ms")
        }
        do {
            let files: [DiffFile]
            var refs = GitRepository.ContainingRefs()
            switch detail {
            case .change(let change):
                files = try await git.diff(for: change)
            case .commit(let commit):
                // 바뀐 파일을 먼저 보여 주고, 담은 브랜치(느릴 수 있다)는 뒤에서 채운다.
                files = try await git.diff(forCommit: commit.hash)
                if let cached = containingRefsCache[commit.hash] {
                    refs = cached
                } else {
                    let hash = commit.hash
                    Task { [weak self] in
                        guard let found = try? await git.refsContaining(hash) else { return }
                        guard let self else { return }
                        self.containingRefsCache[hash] = found
                        if case .commit(let shown)? = self.detail, shown.hash == hash { self.containingRefs = found }
                    }
                }
            case .stash(let stash):
                files = try await git.diff(forStash: stash.ref)
            case .compare(let base, let head):
                async let filesTask = git.diff(base: base, head: head)
                async let aheadTask = git.log(revision: "\(base)..\(head)", limit: CompareCommits.limit)
                async let behindTask = git.log(revision: "\(head)..\(base)", limit: CompareCommits.limit)
                files = try await filesTask
                let commits = CompareCommits(ahead: (try? await aheadTask) ?? [], behind: (try? await behindTask) ?? [])
                var conflicts: CompareConflicts?
                if !commits.ahead.isEmpty, let preview = await previewMerge(ours: base, theirs: head), !preview.isClean {
                    let conflictFiles = (try? await git.diff(from: base, toTree: preview.tree, paths: preview.conflicts)) ?? []
                    conflicts = CompareConflicts(preview: preview, files: conflictFiles)
                }
                guard generation == diffGeneration else { return }
                compareCommits = commits
                compareConflicts = conflicts
            case .fileHistory(let path):
                files = []
                let history = try await git.log(path: path)
                guard generation == diffGeneration else { return }
                fileHistoryCommits = history
            case .blame(let path):
                files = []
                let lines = try await git.blame(path: path, acrossFiles: blameAcrossFiles)
                guard generation == diffGeneration else { return }
                blameLines = lines
            }
            guard generation == diffGeneration else { return }
            diffFiles = files
            containingRefs = refs
            if isCommitDetail(detail) {
                if diffCache[detail.id] == nil { diffCacheOrder.append(detail.id) }
                diffCache[detail.id] = files
                if diffCacheOrder.count > Self.maxDiffCache {
                    diffCache.removeValue(forKey: diffCacheOrder.removeFirst())
                }
            }
        } catch {
            guard generation == diffGeneration else { return }
            diffFiles = []
            containingRefs = GitRepository.ContainingRefs()
            errorMessage = error.localizedDescription
        }
        if generation == diffGeneration {
            isLoadingDiff = false
        }
    }

    // MARK: 동작 공통

    @discardableResult
    /// - Parameter undoLabel: 주면 앞뒤 상태를 적어 두어 ⌘Z로 되돌릴 수 있다. "커밋", "브랜치 삭제" 같은 이름.
    private func perform(_ label: String, done: String? = nil, light: Bool = false, undo undoLabel: String? = nil, _ body: @escaping (GitRepository) async throws -> Void) async -> Bool {
        guard let git, busyMessage == nil else { return false }
        busyMessage = label
        let performStarted = Date()
        defer {
            busyMessage = nil
            Timing.log("perform \(label) total \(Int(Date().timeIntervalSince(performStarted) * 1000))ms")
        }
        // 진행 중인 머지·리베이스가 있으면 상태를 적을 수 없다(index에 충돌). 그때는 기록 없이 한다.
        let before = undoLabel != nil && operation == nil ? try? await git.snapshot() : nil
        var succeeded = true
        do {
            try await body(git)
        } catch {
            succeeded = false
            errorMessage = error.localizedDescription
        }
        // 뒤 상태는 새로고침과 같이 적는다. 둘 다 실제 index를 잠그지 않는다.
        let capturesAfter = succeeded && before != nil
        async let afterTask: RepositorySnapshot? = capturesAfter ? (try? await git.snapshot()) : nil
        await refresh(light: light)
        if let undoLabel, let before, let after = await afterTask, after != before {
            undoStack.append(UndoRecord(label: undoLabel, before: before, after: after))
            if undoStack.count > Self.maxUndo { undoStack.removeFirst() }
            redoStack = []
        }
        lastOwnChangeAt = Date()
        if succeeded, let done { showStatus(done) }
        return succeeded
    }

    // MARK: 되돌리기

    /// 앱에서 한 작업의 앞뒤 상태. 최근 것이 뒤. 저장소를 바꾸면 비운다.
    private(set) var undoStack: [UndoRecord] = []
    private(set) var redoStack: [UndoRecord] = []
    private static let maxUndo = 30

    var undoTitle: String? { undoStack.last.map { $0.label + " 실행 취소" } }
    var redoTitle: String? { redoStack.last.map { $0.label + " 실행 복귀" } }

    /// ⌘Z. 작업이 바꾼 것만 앞 상태로 돌리고, 그 뒤에 고친 파일은 그대로 둔다.
    func undo() async {
        guard let record = undoStack.last else { return }
        await step(record, from: record.after, to: record.before, isUndo: true) { [weak self] in
            self?.undoStack.removeLast()
            self?.redoStack.append(record)
        }
    }

    /// ⇧⌘Z
    func redo() async {
        guard let record = redoStack.last else { return }
        await step(record, from: record.before, to: record.after, isUndo: false) { [weak self] in
            self?.redoStack.removeLast()
            self?.undoStack.append(record)
        }
    }

    private func step(_ record: UndoRecord, from: RepositorySnapshot, to: RepositorySnapshot, isUndo: Bool, moved: @escaping () -> Void) async {
        guard let git, busyMessage == nil else { return }
        guard operation == nil, conflicts.isEmpty else {
            errorMessage = "진행 중인 \(operation?.title ?? "작업")을 먼저 끝내거나 중단하세요"
            return
        }
        guard let current = try? await git.snapshot() else {
            errorMessage = isUndo ? "지금 상태를 읽지 못해 되돌리지 못했습니다" : "지금 상태를 읽지 못해 다시 하지 못했습니다"
            return
        }
        let locked = Set(localBranches.compactMap { branch in
            branch.worktreePath.flatMap { $0 != activeWorktreePath ? branch.name : nil }
        })
        var upstreams: [String: String] = [:]
        for branch in localBranches {
            if let upstream = branch.upstream, let remote = branches.first(where: { $0.isRemote && $0.name == upstream }) {
                upstreams[branch.name] = remote.hash
            }
        }
        let check: UndoCheck
        do {
            check = try await git.checkUndo(from: from, to: to, current: current, lockedBranches: locked, upstreams: upstreams)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        switch check {
        case .blocked(let reason):
            // 앱 밖에서 저장소가 바뀌었다. 남은 기록도 믿을 수 없어서 비운다.
            undoStack = []
            redoStack = []
            errorMessage = reason
        case .ready(let plan):
            let run: () async -> Void = { [weak self] in
                guard let self else { return }
                let done = await self.perform(isUndo ? "되돌리는 중…" : "다시 하는 중…", done: record.label + (isUndo ? " 작업을 되돌렸습니다" : " 작업을 다시 했습니다")) { try await $0.apply(plan, to: to) }
                if done { moved() }
            }
            guard !plan.overwritten.isEmpty || !plan.dropsPushed.isEmpty else {
                await run()
                return
            }
            var facts: [Confirmation.Fact] = []
            if !plan.overwritten.isEmpty {
                facts.append(.loses("그 뒤에 고친 내용 (파일 \(plan.overwritten.count)개)"))
                facts += plan.overwritten.prefix(5).map { .item($0) }
            }
            for branch in plan.dropsPushed {
                facts.append(.warns("\(branch) 브랜치에서 이미 푸시한 커밋이 빠집니다. 다음 푸시는 강제 푸시가 필요합니다"))
            }
            confirmation = Confirmation(
                title: isUndo ? "되돌릴까요?" : "다시 할까요?",
                target: record.label,
                facts: facts,
                buttonTitle: isUndo ? "실행 취소" : "실행 복귀",
                tone: plan.overwritten.isEmpty ? .normal : .destructive
            ) { await run() }
        }
    }

    private func showStatus(_ text: String) {
        statusMessage = text
        statusMessageTask?.cancel()
        statusMessageTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { statusMessage = nil }
        }
    }

    // MARK: 스테이징과 커밋

    func toggleStaged(_ change: FileChange) async {
        showMoved([change], toStaged: !change.isStaged)
        if change.isStaged {
            await unstage(change)
        } else {
            await stage(change)
        }
    }

    /// 누르는 즉시 목록에서 옮겨 보인다. git이 끝나면 새로고침이 실제 상태로 맞춘다.
    /// 기다렸다가 옮기면 누를 때마다 0.2~0.4초 늦게 반응하는 것처럼 보인다.
    private func showMoved(_ changes: [FileChange], toStaged: Bool) {
        let moving = changes.filter { $0.area != .conflicted && $0.isStaged != toStaged }
        guard !moving.isEmpty else { return }
        var list = status.changes
        var renamed: [FileChange.ID: FileChange.ID] = [:]
        for change in moving {
            list.removeAll { $0.id == change.id }
            let kind: ChangeKind = change.area == .untracked ? .added : (!toStaged && change.kind == .added ? .untracked : change.kind)
            let area: ChangeArea = toStaged ? .staged : (kind == .untracked ? .untracked : .unstaged)
            let moved = FileChange(path: change.path, originalPath: change.originalPath, kind: kind, area: area)
            // 같은 파일이 반대쪽에도 있으면(일부만 스테이징된 경우) 하나로 합친다
            if !list.contains(where: { $0.id == moved.id }) {
                // git status와 같은 순서: 추적 안 되는 파일은 맨 뒤, 나머지는 그 앞에
                if moved.area == .untracked {
                    list.append(moved)
                } else if let index = list.firstIndex(where: { $0.area == .untracked }) {
                    list.insert(moved, at: index)
                } else {
                    list.append(moved)
                }
            }
            renamed[change.id] = moved.id
        }
        var next = status
        next.changes = list
        status = next
        selectedChangeIDs = Set(selectedChangeIDs.map { renamed[$0] ?? $0 })
        if let id = selectedChangeID, let new = renamed[id] { selectedChangeID = new }
    }

    func stage(_ change: FileChange) async {
        await perform("스테이징 중…", light: true) { try await $0.stage([change.path]) }
    }

    func unstage(_ change: FileChange) async {
        let hasHead = hasHead
        var paths = [change.path]
        if let original = change.originalPath { paths.append(original) }
        await perform("스테이징 해제 중…", light: true) { try await $0.unstage(paths, hasHead: hasHead) }
    }

    func stageAll() async {
        showMoved(status.unstaged, toStaged: true)
        await perform("스테이징 중…", light: true) { try await $0.stageAll() }
    }

    func unstageAll() async {
        showMoved(status.staged, toStaged: false)
        let hasHead = hasHead
        await perform("스테이징 해제 중…", light: true) { try await $0.unstageAll(hasHead: hasHead) }
    }

    /// 추적 중인 파일의 hunk 하나만 스테이징하거나 해제한다.
    func stageHunk(_ hunk: DiffHunk, of file: DiffFile, staged: Bool) async {
        let patch = file.patch(for: hunk)
        await perform(staged ? "스테이징 해제 중…" : "스테이징 중…", light: true) {
            try await $0.applyPatch(patch, cached: true, reverse: staged)
        }
    }

    /// 고른 줄만 스테이징하거나(작업 트리 변경), 해제한다(스테이징된 변경).
    func stageLines(_ ids: Set<Int>, in hunk: DiffHunk, of file: DiffFile, staged: Bool) async {
        guard let patch = file.patch(for: hunk, selecting: ids, reverse: staged) else { return }
        await perform(staged ? "줄 해제 중…" : "줄 스테이징 중…", done: staged ? "고른 줄을 해제했습니다" : "고른 줄을 스테이징했습니다", light: true) {
            try await $0.applyPatch(patch, cached: true, reverse: staged)
        }
    }

    /// 고른 줄만 원래대로 돌린다. ⌘Z로 되살릴 수 있지만 눈에 안 보이게 사라지므로 묻는다.
    func discardLines(_ ids: Set<Int>, in hunk: DiffHunk, of file: DiffFile) {
        guard let patch = file.patch(for: hunk, selecting: ids, reverse: true) else { return }
        let count = hunk.lines.filter { ids.contains($0.id) && ($0.kind == .addition || $0.kind == .deletion) }.count
        confirmation = Confirmation(
            title: "선택한 줄을 버릴까요?",
            target: file.displayPath,
            facts: [.loses("고른 줄 \(count)개의 변경"), .keeps("고르지 않은 줄의 변경")],
            buttonTitle: "버리기"
        ) { [weak self] in
            await self?.perform("버리는 중…", done: "고른 줄을 버렸습니다", light: true, undo: "버리기") { try await $0.applyPatch(patch, cached: false, reverse: true) }
        }
    }

    func discardHunk(_ hunk: DiffHunk, of file: DiffFile) {
        let patch = file.patch(for: hunk)
        confirmation = Confirmation(
            title: "이 부분을 버릴까요?",
            target: file.displayPath,
            targetDetail: hunk.newStart.map { "\($0)줄부터" + (hunk.context.map { " (\($0))" } ?? "") },
            facts: [.loses("이 부분의 변경"), .keeps("파일의 다른 변경")],
            buttonTitle: "버리기"
        ) { [weak self] in
            await self?.perform("버리는 중…", light: true, undo: "버리기") { try await $0.applyPatch(patch, cached: false, reverse: true) }
        }
    }

    /// 변경 목록에서 위아래로 움직인다. 스테이징됨 → 변경 사항 순서.
    /// 위아래 화살표. Shift를 누르고 있으면 범위를 늘린다.
    func moveChangeSelection(by delta: Int, extend: Bool = false) {
        let ordered = orderedChanges
        guard !ordered.isEmpty else { return }
        let current = ordered.firstIndex { $0.id == selectedChangeID } ?? (delta > 0 ? -1 : ordered.count)
        let next = min(max(current + delta, 0), ordered.count - 1)
        selectChange(ordered[next].id, extend: extend)
    }

    /// 엔터. 변경 사항 쪽을 골랐으면 스테이징, 스테이징된 쪽만 골랐으면 해제.
    func stageOrUnstageSelected() async {
        let changes = selectedChanges.filter { $0.area != .conflicted }
        guard !changes.isEmpty else { return }
        let unstaged = changes.filter { !$0.isStaged }
        showMoved(unstaged.isEmpty ? changes : unstaged, toStaged: !unstaged.isEmpty)
        if !unstaged.isEmpty {
            await perform("스테이징 중…", done: "파일 \(unstaged.count)개를 스테이징했습니다", light: true) { try await $0.stage(unstaged.map(\.path)) }
        } else {
            let hasHead = hasHead
            let paths = changes.flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) }
            await perform("스테이징 해제 중…", done: "파일 \(changes.count)개를 해제했습니다", light: true) { try await $0.unstage(paths, hasHead: hasHead) }
        }
    }

    /// 스페이스. 고른 것들을 각각 반대로 (스테이징된 것은 해제, 아닌 것은 스테이징).
    func toggleSelectedChange() async {
        let changes = selectedChanges.filter { $0.area != .conflicted }
        guard !changes.isEmpty else { return }
        let toStage = changes.filter { !$0.isStaged }.map(\.path)
        let toUnstage = changes.filter(\.isStaged)
        showMoved(changes.filter { !$0.isStaged }, toStaged: true)
        showMoved(toUnstage, toStaged: false)
        if !toStage.isEmpty {
            await perform("스테이징 중…", light: true) { try await $0.stage(toStage) }
        }
        if !toUnstage.isEmpty {
            let hasHead = hasHead
            let paths = toUnstage.flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) }
            await perform("스테이징 해제 중…", light: true) { try await $0.unstage(paths, hasHead: hasHead) }
        }
    }

    /// Delete. 고른 것 중 작업 트리 변경만 버린다. 하나면 파일 이름을, 여럿이면 개수를 묻는다.
    func discardSelectedChange() {
        let changes = selectedChanges.filter { !$0.isStaged && $0.area != .conflicted }
        guard !changes.isEmpty else { return }
        if changes.count == 1 {
            discard(changes[0])
            return
        }
        confirmation = Confirmation(
            title: "변경을 버릴까요?",
            target: "파일 \(changes.count)개",
            targetDetail: changes.prefix(3).map(\.fileName).joined(separator: ", ") + (changes.count > 3 ? " 외 \(changes.count - 3)개" : ""),
            facts: [.loses("작업 트리의 변경"), .note("새 파일은 휴지통으로 옮깁니다"), .keeps("스테이징한 변경")],
            buttonTitle: "버리기"
        ) { [weak self] in
            for change in changes { await self?.performDiscard(change) }
        }
    }

    var canCommit: Bool {
        !commitMessage.trimmed.isEmpty && (!status.staged.isEmpty || amend) && conflicts.isEmpty && !isBusy
    }

    func commit() async {
        let message = commitMessage.trimmed
        guard !message.isEmpty else { return }
        let amend = amend
        let succeeded = await perform("커밋 중…", done: "커밋했습니다", undo: amend ? "커밋 수정" : "커밋") { try await $0.commit(message: message, amend: amend) }
        if succeeded {
            commitMessage = ""
            self.amend = false
            // 메시지 칸의 글자 기록을 지운다. 남아 있으면 ⌘Z가 커밋을 되돌리지 않고 지운 메시지를 되살린다.
            NSApp.keyWindow?.firstResponder?.undoManager?.removeAllActions()
        }
    }

    /// Amend를 켤 때 메시지가 비어 있으면 HEAD의 메시지를 채워 준다.
    func amendToggled() {
        guard amend, commitMessage.trimmed.isEmpty, let head = commits.first(where: { $0.refs.contains { $0.hasPrefix("HEAD") } }) else { return }
        commitMessage = head.body.isEmpty ? head.subject : head.subject + "\n\n" + head.body
    }

    func undoLastCommit() {
        confirmation = Confirmation(
            title: "마지막 커밋을 되돌릴까요?",
            target: headCommit?.shortHash,
            targetDetail: headCommit?.subject,
            facts: [.loses("커밋 하나"), .keeps("바뀐 내용은 스테이징된 채로 남습니다"), .note("활동 칸에서 되찾을 수 있습니다")],
            buttonTitle: "되돌리기",
            tone: .normal
        ) { [weak self] in
            await self?.perform("커밋 되돌리는 중…", done: "마지막 커밋을 되돌렸습니다", undo: "마지막 커밋 되돌리기") { try await $0.undoLastCommit() }
        }
    }

    func discard(_ change: FileChange) {
        confirmation = Confirmation(
            title: change.area == .untracked ? "새 파일을 버릴까요?" : "변경을 버릴까요?",
            target: change.path,
            facts: change.area == .untracked
                ? [.loses("새 파일"), .note("휴지통으로 옮깁니다")]
                : [.loses("이 파일의 작업 트리 변경")] + (status.staged.contains { $0.path == change.path } ? [.keeps("스테이징한 변경")] : []),
            buttonTitle: "버리기"
        ) { [weak self] in
            await self?.performDiscard(change)
        }
    }

    private func performDiscard(_ change: FileChange) async {
        guard let activeWorktreePath else { return }
        if change.area == .untracked {
            let url = URL(fileURLWithPath: activeWorktreePath).appendingPathComponent(change.path)
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                errorMessage = error.localizedDescription
            }
            await refresh()
        } else {
            await perform("버리는 중…", light: true, undo: "버리기") { try await $0.discardWorkingTreeChanges([change.path]) }
        }
    }

    // MARK: 충돌과 진행 중인 작업

    func resolveConflict(_ change: FileChange, keepOurs: Bool) async {
        await perform("충돌 정리 중…") { try await $0.resolveConflict(change.path, keepOurs: keepOurs) }
    }

    func markResolved(_ change: FileChange) async {
        await perform("해결됨으로 표시 중…") { try await $0.stage([change.path]) }
    }

    func abortOperation() {
        guard let operation else { return }
        confirmation = Confirmation(
            title: "진행 중인 작업을 중단할까요?",
            target: operation.title,
            facts: [.loses("지금까지 정리한 충돌"), .keeps("시작하기 전 상태로 돌아갑니다")],
            buttonTitle: "중단"
        ) { [weak self] in
            await self?.perform("중단하는 중…", done: "작업을 중단했습니다") { try await $0.abort(operation) }
            await self?.settlePausedGitFlow()
            await self?.settlePendingRewrite()
        }
    }

    func continueOperation() async {
        guard let operation else { return }
        if operation == .rebasing, await refusesToPassMessageStep() { return }
        let continued = await perform("계속하는 중…", done: "계속 진행했습니다") { try await $0.continueOperation(operation) }
        await settlePausedGitFlow()
        await settlePendingRewrite()
        // Git Flow 마무리가 충돌로 멈춰 있었으면 흐름 창을 다시 띄워 이어 가게 한다
        if continued, self.operation == nil, hasPausedGitFlow { sheet = .gitFlowFinish }
    }

    // MARK: 커밋 정리

    /// 커밋 정리가 메시지 바꾸기 단계에서 실패해 멈췄으면 계속·건너뛰기를 막는다. 넘기면 새 메시지가 조용히 빠진다.
    private func refusesToPassMessageStep() async -> Bool {
        guard let git, await git.rebaseStoppedAtMessageStep() else { return false }
        errorMessage = "메시지를 바꾸는 단계가 실패해 멈췄습니다. 계속하면 새 메시지가 빠지니, 중단한 뒤 다시 정리하세요"
        return true
    }

    /// 충돌로 멈춘 커밋 정리. 계속하거나 중단해서 끝나면 그때 되돌리기 기록을 남긴다.
    private var pendingRewrite: (label: String, before: RepositorySnapshot, files: URL, worktree: String, repository: String?)?

    /// `hash`부터 HEAD까지를 정리할 수 있는지 보고 구간을 읽는다. 안 되면 이유를 돌려준다.
    func loadRewrite(from hash: String) async -> Result<RewriteContext, RewriteError> {
        guard let git else { return .failure(RewriteError("저장소가 열려 있지 않습니다")) }
        if operation != nil { return .failure(RewriteError("진행 중인 머지나 리베이스를 먼저 끝내세요")) }
        if status.isDetached { return .failure(RewriteError("브랜치에 있을 때만 정리할 수 있습니다")) }
        if status.changes.contains(where: { $0.area != .untracked }) {
            return .failure(RewriteError("커밋하지 않은 변경이 있습니다. 커밋하거나 스태시한 뒤 정리하세요"))
        }
        do {
            guard let range = try await git.rewriteRange(from: hash) else {
                return .failure(RewriteError("지금 브랜치(\(branchDisplayName))에 있는 커밋만 정리할 수 있습니다"))
            }
            if range.commits.contains(where: \.isMerge) {
                return .failure(RewriteError("머지 커밋이 낀 구간은 정리할 수 없습니다. 머지 커밋보다 최근 커밋만 고르세요"))
            }
            var pushed = 0
            if let upstream = currentBranch?.upstream, !(currentBranch?.upstreamGone ?? true) {
                // 푸시한 커밋은 오래된 쪽에 붙어 있으니 앞에서부터 센다
                for commit in range.commits {
                    guard try await git.isAncestor(commit.hash, of: upstream) else { break }
                    pushed += 1
                }
            }
            let hashes = Set(range.commits.map(\.hash))
            let others = localBranches.filter { !$0.isHead && hashes.contains($0.hash) }.map(\.name)
            return .success(RewriteContext(commits: range.commits, base: range.base, pushedCount: pushed, otherBranches: others, messages: range.messages))
        } catch {
            return .failure(RewriteError(error.localizedDescription))
        }
    }

    /// 할 일대로 커밋을 다시 쓴다. 새 메시지는 먼저 저장소의 commit-msg 훅으로 검사한다.
    /// - Returns: 시작하지 못한 이유. 시작했으면(충돌로 멈춰도) nil
    func rewriteHistory(_ items: [RewriteItem], context: RewriteContext, label: String, done: String) async -> String? {
        guard let git else { return "저장소가 열려 있지 않습니다" }
        if busyMessage != nil || operation != nil { return "다른 작업이 끝난 뒤 다시 하세요" }
        // 창을 연 뒤에 브랜치가 바뀌었으면(터미널에서 커밋 등) 목록이 맞지 않아 커밋을 잃거나 되살린다
        let head = try? await git.commitHash(of: "HEAD")
        guard head != nil, head == context.commits.last?.hash else {
            return "창을 연 뒤에 브랜치가 바뀌었습니다. 창을 닫고 다시 여세요"
        }
        for item in items {
            guard case .reword(let message) = item.action else { continue }
            if let rejection = try? await git.rejectionFromCommitMessageHook(message) { return rejection }
        }
        let folder: URL
        let todo: [String]
        do {
            folder = URL(fileURLWithPath: try await git.gitDirectory()).appendingPathComponent("canopy-rewrite")
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for item in items {
                guard case .reword(let message) = item.action else { continue }
                try message.write(to: folder.appendingPathComponent(item.commit.hash), atomically: true, encoding: .utf8)
            }
            todo = try HistoryRewrite.todo(
                items, hasBase: context.base != nil,
                messageFile: { folder.appendingPathComponent($0).path },
                markFile: { folder.appendingPathComponent($0 + ".head").path }
            )
        } catch {
            return error.localizedDescription
        }
        let before = try? await git.snapshot()
        let finished = await perform("커밋 정리 중…", done: done, undo: label) {
            try await $0.rewriteHistory(base: context.base, todo: todo, todoFile: folder.appendingPathComponent("todo"))
        }
        // 새로고침이 겹치면 operation이 옛 값일 수 있어 git에 직접 묻는다
        let stopped = (try? await git.operationState()) != nil
        if finished {
            try? FileManager.default.removeItem(at: folder)
        } else if stopped, let before, let worktree = activeWorktreePath {
            // 도중에 멈췄다. 메시지 파일은 이어서 할 때 쓰니 남긴다.
            pendingRewrite = (label, before, folder, worktree, mainRootPath)
            errorMessage = conflicts.isEmpty
                ? "정리가 중간에 멈췄습니다. 위 배너에서 계속하거나, 건너뛰거나, 중단하세요"
                : "충돌이 났습니다. 충돌을 풀고 계속하면 나머지 커밋을 이어서 정리합니다"
        } else {
            // 시작하지 못했다. 알림 창 대신 정리 창 안에 이유를 보여 준다.
            let reason = errorMessage ?? "정리하지 못했습니다"
            errorMessage = nil
            try? FileManager.default.removeItem(at: folder)
            return reason
        }
        return nil
    }

    private func settlePendingRewrite() async {
        guard operation == nil, let pending = pendingRewrite, pending.worktree == activeWorktreePath, let git else { return }
        pendingRewrite = nil
        try? FileManager.default.removeItem(at: pending.files)
        guard let after = try? await git.snapshot(), after != pending.before else { return }
        undoStack.append(UndoRecord(label: pending.label, before: pending.before, after: after))
        if undoStack.count > Self.maxUndo { undoStack.removeFirst() }
        redoStack = []
    }

    /// 커밋 하나를 뺀다. 확인 창을 거친다.
    func dropCommit(_ commit: Commit) {
        Task { [self] in
            switch await loadRewrite(from: commit.hash) {
            case .failure(let error):
                errorMessage = error.message
            case .success(let context):
                let items = context.commits.map { RewriteItem(commit: $0, action: $0.hash == commit.hash ? .drop : .keep) }
                confirmation = Confirmation(
                    title: "이 커밋을 삭제할까요?",
                    target: commit.shortHash,
                    targetDetail: commit.subject,
                    facts: [.loses("이 커밋의 변경"), .note("뒤의 커밋 \(context.commits.count - 1)개를 다시 씁니다"), .keeps("⌘Z로 되돌릴 수 있습니다")]
                        + context.notes.map { .warns($0) },
                    buttonTitle: "삭제"
                ) { [weak self] in
                    if let failure = await self?.rewriteHistory(items, context: context, label: "커밋 삭제", done: "커밋을 삭제했습니다") {
                        self?.errorMessage = failure
                    }
                }
            }
        }
    }

    // MARK: Git Flow

    /// `git flow init`이 적은 설정. 새로고침할 때 읽는다.
    private(set) var gitFlowConfig: GitFlowConfig?
    /// 준비했거나 진행 중인 마무리 흐름. 시트를 닫아도 남는다. 저장소를 바꾸면 비운다.
    var gitFlowRun: GitFlowRun?

    var flowConfig: GitFlowConfig {
        gitFlowConfig ?? GitFlowConfig(settings: [:], branchNames: flowBranchNames)
    }

    /// 로컬 브랜치와, 원격에만 있는 브랜치의 이름(원격 이름을 뗀 것)
    private var flowBranchNames: [String] {
        Array(Set(localBranches.map(\.name) + remoteBranches.map(\.nameWithoutRemote)))
    }

    /// 이름이 Git Flow 접두어로 시작하는 로컬 브랜치면 그 종류
    func gitFlowKind(of branch: String) -> GitFlowKind? { flowConfig.kind(of: branch) }

    /// 설정 › Git › Git Flow 마무리. 팀에서 main 머지를 PR로만 하면 끈다.
    var gitFlowFinishEnabled: Bool { UserDefaults.standard.object(forKey: "gitFlowFinish") as? Bool ?? true }

    /// 지금 브랜치를 마무리할 수 있으면 그 이름
    var finishableFlowBranch: String? {
        guard gitFlowFinishEnabled, let branch = status.branch, !status.isDetached, gitFlowKind(of: branch) != nil else { return nil }
        return branch
    }

    /// 이 워크트리에서 흐름을 시작했는데 아직 끝나지 않았는지. 상태 줄에 다시 여는 배너를 띄운다.
    var hasPausedGitFlow: Bool {
        guard let run = gitFlowRun, run.worktreePath == activeWorktreePath else { return false }
        return run.started && !run.isFinished && !run.isRunning
    }

    /// 기준 브랜치에서 `feature/이름` 같은 브랜치를 만들고 체크아웃한다.
    /// `git flow init`을 거친 저장소면 기준을 git-flow와 같은 키로 적어서, 마무리할 때(여기서든 터미널에서든) 그 기준으로 머지한다.
    func startGitFlow(kind: GitFlowKind, name: String, base chosenBase: String? = nil) async -> Bool {
        let config = flowConfig
        let branch = config.prefix(kind) + name
        let base = chosenBase ?? config.base(of: kind)
        let fromLocal = localBranches.contains { $0.name == base }
        // 원격에만 있으면 origin을 먼저 쓴다. 이름순으로 고르면 fork 원격이 먼저 잡힐 수 있다.
        let remoteCandidates = branches.filter { $0.isRemote && $0.nameWithoutRemote == base }
        let from = fromLocal ? base : (remoteCandidates.first { remoteName(of: $0.name) == "origin" } ?? remoteCandidates.first)?.name
        guard let from else {
            errorMessage = "\(base) 브랜치가 없습니다"
            return false
        }
        // git flow init을 했거나 기본과 다른 기준을 골랐으면 적는다. 적지 않으면 마무리가 기본 기준으로 머지한다.
        let records = config.isInitialized || base != config.base(of: kind)
        return await perform("\(branch) 만드는 중…", done: "\(branch) 브랜치를 시작했습니다", undo: "Git Flow 시작") {
            // 원격 브랜치에서 만들면 그 원격 브랜치를 추적하지 않게 한다. 추적하면 푸시가 공용 브랜치로 간다.
            try await $0.createBranch(branch, from: from, checkout: true, track: fromLocal)
            if records { try await $0.setGitFlowBase(base, for: branch) }
        }
    }

    /// 마무리 단계를 만들고, 시작 전에 막아야 할 것과 충돌을 미리 살핀 뒤 흐름 창을 띄운다.
    func prepareGitFlowFinish(branch: String, pushes: Bool = false) async {
        guard let git else { return }
        if hasPausedGitFlow || gitFlowRun?.isRunning == true {
            // 진행 중인 흐름이 있으면 그것을 보여 준다
            sheet = .gitFlowFinish
            return
        }
        let config = flowConfig
        guard let kind = config.kind(of: branch) else { return }
        let releasePrefix = config.prefix(.release)
        let releases = localBranches.map(\.name).filter { $0.hasPrefix(releasePrefix) && $0 != branch }
        let openRelease = kind == .hotfix && releases.count == 1 ? releases[0] : nil
        let pushRemote = localBranches.first { $0.name == config.development }?.upstream.flatMap(remoteName(of:)) ?? defaultRemote(for: config.development)
        let actions = GitFlowRun.finishSteps(kind: kind, branch: branch, config: config, openRelease: openRelease, pushRemote: pushRemote, pushTargets: pushes)
        var run = GitFlowRun(kind: kind, branch: branch, steps: actions.enumerated().map { GitFlowStep(id: $0.offset, action: $0.element) })
        run.pushes = pushes
        run.pushRemote = pushRemote
        run.worktreePath = activeWorktreePath
        run.repository = mainRootPath

        // 시작 전에 막을 것
        if operation != nil { run.blockers.append("진행 중인 머지나 리베이스를 먼저 끝내세요") }
        if status.changes.contains(where: { $0.area != .untracked }) {
            run.blockers.append("커밋하지 않은 변경이 있습니다. 커밋하거나 스태시한 뒤 마무리하세요")
        }
        for name in [branch] + run.mergeTargets {
            guard let local = localBranches.first(where: { $0.name == name }) else {
                run.blockers.append("로컬 브랜치 \(name)이(가) 없습니다")
                continue
            }
            if let path = local.worktreePath, path != activeWorktreePath {
                run.blockers.append("\(name)이(가) 다른 워크트리(\((path as NSString).abbreviatingWithTildeInPath))에 체크아웃되어 있습니다")
            }
            if name != branch, local.behind > 0 {
                run.notes.append("\(name)이(가) \(local.upstream ?? "원격")보다 \(local.behind)개 뒤처져 있습니다. 먼저 풀하면 최신 상태에 머지합니다")
            }
        }
        for step in run.steps {
            guard case .tag(let name, _) = step.action else { continue }
            if !(await git.isValidTagName(name)) {
                run.blockers.append("태그 이름 \(name)을(를) 쓸 수 없습니다. git flow 설정의 태그 접두어를 확인하세요")
            } else if tags.contains(where: { $0.name == name }) {
                // 지난번에 끊긴 마무리가 이미 단 태그면(이 릴리스를 담고 있으면) 그대로 쓰고 남은 단계만 한다
                if (try? await git.isAncestor(branch, of: "refs/tags/" + name)) == true {
                    run.notes.append("이미 있는 태그 \(name)을(를) 그대로 씁니다")
                } else {
                    run.blockers.append("태그 \(name)이(가) 이미 다른 커밋에 있습니다")
                }
            }
        }
        if kind == .hotfix, openRelease == nil, !releases.isEmpty {
            run.notes.append("릴리스 브랜치가 여러 개라 \(config.development)에 머지합니다")
        }
        // 머지 단계마다 충돌을 미리 본다
        for index in run.steps.indices {
            guard case .merge(let source, let target) = run.steps[index].action,
                  let preview = try? await git.previewMerge(ours: target, theirs: source), !preview.conflicts.isEmpty else { continue }
            run.steps[index].warning = "충돌 예상 \(preview.conflicts.count)개"
        }
        // 미리 보는 동안 실행을 눌렀으면 시작한 흐름을 덮어쓰지 않는다. 끝난 흐름은 새로 준비한 것으로 바꾼다.
        if let existing = gitFlowRun, existing.started, !existing.isFinished { return }
        gitFlowRun = run
        sheet = .gitFlowFinish
    }

    /// 남은 단계를 차례로 실행한다. 충돌이나 오류가 나면 그 단계에서 멈춘다.
    /// 단계마다 이미 되어 있는지 먼저 보므로, 충돌을 풀고 다시 부르면 남은 단계만 한다.
    func runGitFlow() async {
        guard let git, let current = gitFlowRun, !current.isRunning, current.blockers.isEmpty, busyMessage == nil,
              current.worktreePath == activeWorktreePath else { return }
        if operation != nil {
            errorMessage = "충돌을 풀고 머지를 마친 뒤 이어서 진행하세요"
            return
        }
        // 기다리기 전에 실행 중으로 표시한다. 버튼을 두 번 눌러도 한 번만 돈다.
        gitFlowRun?.isRunning = true
        busyMessage = "Git Flow 마무리 중…"
        // 멈춘 사이에 생긴 변경이 있으면 체크아웃이 그 변경을 끌고 다니므로 이어 가지 않는다
        if current.started, status.changes.contains(where: { $0.area != .untracked }) {
            gitFlowRun?.isRunning = false
            busyMessage = nil
            errorMessage = "커밋하지 않은 변경이 있습니다. 커밋하거나 스태시한 뒤 이어서 진행하세요"
            return
        }
        // 되돌리기 기록의 시작점. 멈출 때마다 거기까지를 기록하고 비우므로, 이어 갈 때 새로 찍는다.
        if gitFlowRun?.before == nil { gitFlowRun?.before = try? await git.snapshot() }
        gitFlowRun?.started = true
        for step in current.steps where step.state != .done && step.state != .skipped {
            update(step: step.id) { $0.state = .waiting }
        }
        for step in current.steps {
            guard let state = gitFlowRun?.steps.first(where: { $0.id == step.id })?.state, state != .done, state != .skipped else { continue }
            update(step: step.id) { $0.state = .running }
            do {
                let skipped = try await runGitFlowStep(step.action, git: git)
                update(step: step.id) { $0.state = skipped ? .skipped : .done }
            } catch {
                let message = error.localizedDescription.split(separator: "\n").first.map(String.init) ?? "실패했습니다"
                update(step: step.id) { $0.state = .failed(message) }
                break
            }
        }
        busyMessage = nil
        gitFlowRun?.isRunning = false
        await refresh()
        if operation != nil, let failed = gitFlowRun?.failedStep {
            // 머지 충돌로 멈췄으면 알아보기 쉬운 말로 바꾼다
            update(step: failed.id) { $0.state = .failed("충돌이 났습니다. 충돌을 풀고 계속하면 이어서 진행합니다") }
        } else {
            // 끝났거나 충돌 없이 멈췄으면 지금까지를 되돌리기 기록으로 남긴다
            await recordGitFlowUndo()
        }
        if gitFlowRun?.isFinished == true { showStatus("\(current.branch) 브랜치를 마무리했습니다") }
    }

    private func update(step id: Int, _ change: (inout GitFlowStep) -> Void) {
        guard let index = gitFlowRun?.steps.firstIndex(where: { $0.id == id }) else { return }
        change(&gitFlowRun!.steps[index])
    }

    /// 단계 하나. 이미 되어 있어 건너뛰었으면 true
    private func runGitFlowStep(_ action: GitFlowAction, git: GitRepository) async throws -> Bool {
        switch action {
        case .checkout(let branch):
            try await git.checkout(branch)
        case .merge(let source, let target):
            // 앞 단계 뒤에 다른 브랜치로 옮겨 갔을 수 있다. 머지는 늘 대상 브랜치에서 한다.
            try await git.checkout(target)
            if try await git.isAncestor(source, of: target) { return true }
            try await git.mergeNoFastForward(source)
        case .tag(let name, let target):
            if let existing = try await git.commitHash(of: "refs/tags/" + name) {
                // 같은 커밋에 있거나 이 릴리스를 담고 있으면 지난번 마무리가 단 것이다. 아니면 덮어쓰지 않는다.
                let source = gitFlowRun?.branch ?? target
                let sameCommit = try await existing == git.commitHash(of: target)
                let containsRelease = try await git.isAncestor(source, of: existing)
                guard sameCommit || containsRelease else {
                    throw GitError(arguments: ["tag", name], exitCode: 1, stderr: "태그 \(name)이(가) 이미 다른 커밋에 있습니다")
                }
                return true
            }
            try await git.createTag(name, at: target, message: name)
        case .deleteBranch(let branch):
            guard try await git.localBranchExists(branch) else { return true }
            // `branch -d`는 추적 중인 원격 브랜치를 기준으로 판단해서, 머지했는데도 거부하거나 머지 안 했는데도 지운다.
            // 머지 대상 모두에 들어갔는지 직접 보고 지운다.
            for target in gitFlowRun?.mergeTargets ?? [] where try await !git.isAncestor(branch, of: target) {
                throw GitError(arguments: ["branch", branch], exitCode: 1, stderr: "\(target)에 아직 들어가지 않아 지우지 않았습니다")
            }
            // 기준 설정(gitflow.branch.<이름>.base)은 남긴다. 되돌려서 브랜치가 돌아오면 그 기준을 다시 쓴다.
            try await git.deleteBranch(branch, force: true)
        case .push(let branch, let remote):
            try await git.push(branch: branch, remote: remote, target: branch, setUpstream: false, force: false, tags: false)
        case .pushTag(let name, let remote):
            try await git.pushTag(name, remote: remote)
        }
        return false
    }

    /// 지금까지 한 단계를 되돌리기 기록으로 남긴다. 머지가 진행 중이면 상태를 적을 수 없어 남기지 않는다.
    /// 남긴 뒤에는 시작점을 비워서, 멈춘 사이에 사용자가 한 다른 작업이 이 기록에 섞이지 않게 한다.
    private func recordGitFlowUndo() async {
        guard let git, operation == nil, let before = gitFlowRun?.before else { return }
        gitFlowRun?.before = nil
        guard let after = try? await git.snapshot(), after != before else { return }
        undoStack.append(UndoRecord(label: "Git Flow 마무리", before: before, after: after))
        if undoStack.count > Self.maxUndo { undoStack.removeFirst() }
        redoStack = []
    }

    /// 충돌을 계속하거나 중단해서 머지가 끝났을 때, 그때까지 한 단계를 기록한다.
    private func settlePausedGitFlow() async {
        guard operation == nil, let run = gitFlowRun, run.started, !run.isFinished, run.worktreePath == activeWorktreePath else { return }
        await recordGitFlowUndo()
    }

    /// 흐름을 그만둔다. 몇 단계라도 했으면 거기까지를 되돌리기 기록으로 남긴다.
    func cancelGitFlow() async {
        if operation != nil {
            errorMessage = "진행 중인 머지를 먼저 중단하거나 마치세요"
            return
        }
        if gitFlowRun?.started == true { await recordGitFlowUndo() }
        gitFlowRun = nil
        sheet = nil
    }

    // MARK: 브랜치

    func checkout(_ branch: Branch) async {
        let localName = branch.nameWithoutRemote
        let localExists = localBranches.contains { $0.name == localName }
        await perform("\(branch.name) 체크아웃 중…", done: "\(localName) 브랜치로 전환했습니다", undo: "체크아웃") { git in
            if branch.isRemote, !localExists {
                try await git.checkoutTracking(branch.name)
            } else {
                try await git.checkout(localName)
            }
        }
    }

    func checkoutCommit(_ commit: Commit) {
        confirmation = Confirmation(
            title: "커밋을 체크아웃할까요?",
            target: commit.shortHash,
            targetDetail: commit.subject,
            facts: [.note("어느 브랜치에도 있지 않은 상태(분리된 HEAD)가 됩니다"), .note("여기서 작업하려면 새 브랜치를 만드세요")],
            buttonTitle: "체크아웃",
            tone: .normal
        ) { [weak self] in
            await self?.perform("체크아웃 중…", undo: "체크아웃") { try await $0.checkoutDetached(commit.hash) }
        }
    }

    @discardableResult
    func createBranch(name: String, from base: String?, checkout: Bool) async -> Bool {
        await perform("브랜치 만드는 중…", done: "\(name) 브랜치를 만들었습니다", undo: "브랜치 만들기") { try await $0.createBranch(name, from: base, checkout: checkout) }
    }

    /// 지우기 전에 무엇을 잃는지 세어서 한 번만 묻는다. 버튼은 "삭제" 하나.
    /// 기준 브랜치에 없는 커밋이 있으면 그 수와 제목을 보여 주고, 없으면 잃는 것이 없다고 적는다.
    func deleteBranch(_ branch: Branch) {
        Task { [self] in
            var facts: [Confirmation.Fact] = []
            // 원격은 건드리지 않는다는 것을 먼저 분명히 적는다
            if let upstream = branch.upstream, !branch.upstreamGone {
                facts.append(.keeps("원격 브랜치(\(upstream))는 그대로 남습니다"))
            } else {
                facts.append(.note("이 컴퓨터의 브랜치만 지웁니다"))
            }
            // 정말 잃는 것은 어디에도 없는 커밋이다. 원격이 있으면 원격 어디에도 없는 커밋, 없으면 기준 브랜치에 없는 커밋.
            let base = resolveBase(excluding: branch.name)
            var unique: [Commit] = []
            let describesRemotes = !remotes.isEmpty
            if let git {
                if describesRemotes {
                    unique = (try? await git.log(revisions: [branch.name, "--not", "--remotes"], limit: 50)) ?? []
                } else if let base {
                    unique = (try? await git.log(revision: "\(base)..\(branch.name)", limit: 50)) ?? []
                }
            }
            let more = unique.count >= 50 ? "+" : ""
            if unique.isEmpty {
                if describesRemotes {
                    facts.append(.keeps("커밋은 모두 원격에 있습니다"))
                } else if let base {
                    facts.append(.keeps("사라지는 커밋이 없습니다. 모두 \(base)에 있습니다"))
                }
            } else {
                facts.append(.loses(describesRemotes ? "푸시하지 않은 커밋 \(unique.count)개\(more) (이 컴퓨터에만 있음)" : "\(base ?? "기준 브랜치")에 없는 커밋 \(unique.count)개\(more)"))
                for commit in unique.prefix(3) { facts.append(.item("\(commit.shortHash)  \(commit.subject)")) }
                if unique.count > 3 { facts.append(.item("외 \(unique.count - 3)개")) }
            }
            facts.append(.note("⌘Z나 활동 칸에서 복구할 수 있습니다"))
            confirmation = Confirmation(
                title: "브랜치를 삭제할까요?",
                target: branch.name,
                facts: facts,
                buttonTitle: unique.isEmpty ? "삭제" : "커밋 \(unique.count)개와 함께 삭제",
                action: { [weak self] in
                    guard let self else { return }
                    if await perform("브랜치 삭제 중…", done: "\(branch.name) 브랜치를 지웠습니다", undo: "브랜치 삭제", { try await $0.deleteBranch(branch.name, force: true) }) {
                        remember(deleted: branch)
                    }
                },
                choice: await deleteUpstreamChoice(for: branch)
            )
        }
    }

    /// 브랜치 삭제 창의 "원격 브랜치도 삭제". 추적 중인 원격 브랜치가 있고 기준 브랜치가 아닐 때만.
    /// 원격을 먼저 지우고, 성공하면 이 컴퓨터의 브랜치를 지운다. 원격 삭제가 막히면 로컬도 그대로 둔다.
    private func deleteUpstreamChoice(for branch: Branch) async -> Confirmation.Choice? {
        guard let git, let upstream = branch.upstream, !branch.upstreamGone,
              let remoteBranch = branches.first(where: { $0.isRemote && $0.name == upstream }),
              !isProtectedRemoteBranch(remoteBranch),
              let remote = remoteName(of: upstream) else { return nil }
        let remoteBranchName = String(upstream.dropFirst(remote.count + 1))
        let repository = remotes.first { $0.name == remote }?.repositoryPath
        // 둘 다 지우면 잃는 커밋: 이 두 브랜치 말고는 어디에도 없는 커밋
        let lost = (try? await git.log(revisions: [branch.name, remoteBranch.fullName, "--not", "--exclude=\(branch.name)", "--branches", "--tags", "--exclude=\(upstream)", "--remotes"], limit: 50)) ?? []
        var facts: [Confirmation.Fact] = [
            .loses("원격 브랜치(\(upstream))도 지웁니다"),
            .warns(repository.map { "같은 원격 저장소(\($0))를 쓰는 모든 사람에게서 사라집니다" } ?? "같은 원격 저장소를 쓰는 모든 사람에게서 사라집니다"),
        ]
        if lost.isEmpty {
            facts.append(.keeps("커밋은 다른 브랜치에 모두 남습니다"))
        } else {
            facts.append(.loses("어디에도 남지 않는 커밋 \(lost.count)개\(lost.count >= 50 ? "+" : "")"))
            for commit in lost.prefix(3) { facts.append(.item("\(commit.shortHash)  \(commit.subject)")) }
            if lost.count > 3 { facts.append(.item("외 \(lost.count - 3)개")) }
        }
        facts.append(.note("이 컴퓨터의 브랜치는 ⌘Z로, 원격 브랜치는 활동 칸의 \"최근 지운 브랜치\"에서 복구할 수 있습니다"))
        return Confirmation.Choice(
            title: "원격 브랜치도 삭제",
            detail: upstream + (repository.map { " (\($0))" } ?? ""),
            facts: facts,
            buttonTitle: "로컬과 원격에서 삭제",
            action: { [weak self] in
                guard let self else { return }
                let remoteDeleted = await perform("원격 브랜치 삭제 중…") { try await $0.deleteRemoteBranch(remote: remote, branch: remoteBranchName) }
                guard remoteDeleted else { return }
                remember(deleted: DeletedBranch(name: remoteBranchName, hash: remoteBranch.hash, date: Date(), remote: remote))
                if await perform("브랜치 삭제 중…", done: "\(branch.name) 브랜치를 로컬과 원격에서 지웠습니다", undo: "브랜치 삭제", { try await $0.deleteBranch(branch.name, force: true) }) {
                    remember(deleted: branch)
                }
            }
        )
    }

    // MARK: 안전망

    /// 이 앱에서 지운 브랜치. 최근 것이 앞. 저장소마다 따로 기억한다.
    private(set) var deletedBranches: [DeletedBranch] = []

    private var deletedBranchesKey: String? { mainRootPath.map { "deletedBranches:" + $0 } }

    func loadDeletedBranches() {
        guard let key = deletedBranchesKey, let data = UserDefaults.standard.data(forKey: key) else {
            deletedBranches = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        deletedBranches = (try? decoder.decode([DeletedBranch].self, from: data)) ?? []
    }

    private func saveDeletedBranches() {
        guard let key = deletedBranchesKey else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        UserDefaults.standard.set(try? encoder.encode(deletedBranches), forKey: key)
    }

    private func remember(deleted branch: Branch) {
        remember(deleted: DeletedBranch(name: branch.name, hash: branch.shortHash, date: Date()))
    }

    private func remember(deleted: DeletedBranch) {
        deletedBranches.removeAll { $0.name == deleted.name && $0.remote == deleted.remote }
        deletedBranches.insert(deleted, at: 0)
        deletedBranches = Array(deletedBranches.prefix(20))
        saveDeletedBranches()
    }

    /// 지운 브랜치를 같은 이름, 같은 커밋으로 다시 만든다.
    func restoreBranch(_ deleted: DeletedBranch) async {
        if let remote = deleted.remote {
            // 원격에서 지운 브랜치는 같은 커밋으로 그 원격에 다시 올린다
            if branches.contains(where: { $0.isRemote && $0.name == deleted.displayName }) {
                errorMessage = "원격에 \(deleted.displayName) 브랜치가 이미 있습니다"
                return
            }
            if await perform("원격에 다시 올리는 중…", done: "\(deleted.displayName) 브랜치를 원격에 다시 올렸습니다", { try await $0.pushBranch(remote: remote, name: deleted.name, commit: deleted.hash) }) {
                forgetDeletedBranch(deleted)
            }
            return
        }
        if branches.contains(where: { !$0.isRemote && $0.name == deleted.name }) {
            errorMessage = "\(deleted.name) 브랜치가 이미 있습니다."
            return
        }
        if await perform("브랜치 복구 중…", done: "\(deleted.name) 브랜치를 복구했습니다", undo: "브랜치 복구", { try await $0.createBranch(deleted.name, from: deleted.hash, checkout: false) }) {
            forgetDeletedBranch(deleted)
        }
    }

    func forgetDeletedBranch(_ deleted: DeletedBranch) {
        deletedBranches.removeAll { $0.id == deleted.id }
        saveDeletedBranches()
    }

    /// 활동 기록의 한 시점으로 현재 브랜치를 되돌린다. 하드 리셋은 따로 경고한다.
    func reset(toActivity entry: ActivityEntry, mode: ResetMode) {
        confirmation = Confirmation(
            title: "현재 브랜치를 이 시점으로 되돌릴까요?",
            target: entry.shortHash,
            targetDetail: entry.title,
            facts: resetFacts(mode) + [.note("활동 칸에서 지금 위치로 다시 돌아올 수 있습니다")],
            buttonTitle: "되돌리기",
            tone: mode == .hard ? .destructive : .normal
        ) { [weak self] in
            await self?.perform("되돌리는 중…", done: "\(entry.shortHash) 시점으로 되돌렸습니다", undo: "그 시점으로 되돌리기") { try await $0.reset(to: entry.hash, mode: mode) }
        }
    }

    func merge(_ branch: Branch) {
        let current = branchDisplayName
        Task { [self] in
            // 확인 창을 띄우기 전에 합쳐 본다. 커밋 수만 개짜리 저장소에서도 0.1초가 안 걸린다.
            let preview = await previewMerge(ours: headRevision, theirs: branch.name)
            confirmation = Confirmation(
                title: "머지할까요?",
                target: "\(branch.name) → \(current)",
                facts: [.note("머지 커밋이 하나 생깁니다")] + conflictFacts(preview),
                buttonTitle: "머지",
                tone: .normal
            ) { [weak self] in
                await self?.perform("머지 중…", done: "머지했습니다", undo: "머지") { try await $0.merge(branch.name) }
            }
        }
    }

    func rebase(onto branch: Branch) {
        let current = branchDisplayName
        Task { [self] in
            // 리베이스는 커밋을 하나씩 옮기며 충돌하므로, 한 번에 합쳐 본 결과는 어림값이다
            let preview = await previewMerge(ours: branch.name, theirs: headRevision)
            confirmation = Confirmation(
                title: "리베이스할까요?",
                target: current,
                targetDetail: "\(branch.name) 위로 다시 쌓습니다",
                facts: [.note("커밋이 새로 만들어져 해시가 바뀝니다"), .note("이미 푸시한 브랜치면 강제 푸시가 필요합니다")] + conflictFacts(preview, approximate: true),
                buttonTitle: "리베이스",
                tone: .normal
            ) { [weak self] in
                await self?.perform("리베이스 중…", done: "리베이스했습니다", undo: "리베이스") { try await $0.rebase(onto: branch.name) }
            }
        }
    }

    // MARK: 충돌 미리보기

    /// 미리 합쳐 본 결과. 참조가 바뀌면(refsSignature) 비운다.
    private var mergePreviewCache: [String: MergePreview] = [:]

    /// 지금 HEAD 커밋. "HEAD"라는 이름으로 캐시하면 체크아웃 뒤에도 옛 결과가 남는다.
    var headRevision: String { status.headOID ?? "HEAD" }

    /// `theirs`를 `ours`에 합쳐 본다. 작업 트리와 브랜치는 건드리지 않는다.
    func previewMerge(ours: String, theirs: String, mergeBase: String? = nil) async -> MergePreview? {
        let key = [ours, theirs, mergeBase ?? ""].joined(separator: "|")
        if let cached = mergePreviewCache[key] { return cached }
        guard let git, let preview = try? await git.previewMerge(ours: ours, theirs: theirs, mergeBase: mergeBase) else { return nil }
        mergePreviewCache[key] = preview
        return preview
    }

    /// 확인 창에 넣는 충돌 미리보기 줄
    private func conflictFacts(_ preview: MergePreview?, approximate: Bool = false) -> [Confirmation.Fact] {
        guard let preview else { return [] }
        if preview.isClean {
            return [.keeps(approximate ? "충돌 없이 합쳐질 것으로 보입니다" : "충돌 없이 합쳐집니다")]
        }
        var facts: [Confirmation.Fact] = [.warns("충돌 파일 \(preview.conflicts.count)개" + (approximate ? " (어림값)" : ""))]
        facts += preview.conflicts.prefix(5).map { .item($0) }
        if preview.conflicts.count > 5 { facts.append(.item("외 \(preview.conflicts.count - 5)개")) }
        facts.append(.note("충돌이 나면 멈추고, 변경 사항 칸에서 정리한 뒤 계속합니다"))
        return facts
    }

    // MARK: 커밋 동작

    /// 충돌이 없으면 묻지 않고 바로, 충돌이 나면 어느 파일인지 보여 주고 묻는다.
    /// 고른 커밋 여러 개를 오래된 것부터 차례로 현재 브랜치에 옮긴다.
    func cherryPick(_ commits: [Commit]) {
        guard !commits.isEmpty, let git else { return }
        if commits.contains(where: \.isMerge) {
            errorMessage = "머지 커밋은 체리픽할 수 없습니다. 머지 커밋을 제외하고 선택하세요"
            return
        }
        Task {
            // 이미 현재 브랜치에 있는 커밋(같은 내용 포함)은 옮기면 비어서 멈춘다. 미리 뺀다.
            var already: [Commit] = []
            for commit in commits where (try? await git.isAlreadyApplied(commit.hash)) == true { already.append(commit) }
            let picking = commits.filter { commit in !already.contains { $0.id == commit.id } }
            guard !picking.isEmpty else {
                errorMessage = "고른 커밋은 모두 이미 \(branchDisplayName)에 있습니다"
                return
            }
            confirmCherryPick(picking, skipped: already.count)
        }
    }

    private func confirmCherryPick(_ commits: [Commit], skipped: Int) {
        // 목록은 최근 것이 위라, 뒤집으면 오래된 것부터
        let ordered = Array(commits.reversed())
        let shown = ordered.prefix(8).map { Confirmation.Fact.item($0.shortHash + "  " + $0.subject) }
        confirmation = Confirmation(
            title: "커밋 \(commits.count)개를 체리픽할까요?",
            target: branchDisplayName,
            targetDetail: "오래된 커밋부터 차례로 옮깁니다",
            facts: shown + (ordered.count > 8 ? [.item("외 \(ordered.count - 8)개")] : [])
                + (skipped > 0 ? [.note("이미 \(branchDisplayName)에 있는 커밋 \(skipped)개는 제외했습니다")] : [])
                + [.note("충돌이 나면 그 커밋에서 멈춥니다. 풀고 계속하거나, 그 커밋만 건너뛸 수 있습니다")],
            buttonTitle: "체리픽",
            tone: .normal
        ) { [weak self] in
            await self?.perform("체리픽 중…", done: "커밋 \(commits.count)개를 체리픽했습니다", undo: "체리픽") { try await $0.cherryPick(ordered.map(\.hash)) }
        }
    }

    /// 멈춘 커밋 하나를 건너뛰고 나머지를 이어 간다
    func skipOperation() async {
        guard let operation, operation != .merging else { return }
        if operation == .rebasing, await refusesToPassMessageStep() { return }
        await perform("건너뛰는 중…", done: "건너뛰었습니다") { try await $0.skip(operation) }
        await settlePausedGitFlow()
    }

    func cherryPick(_ commit: Commit) async {
        if let git, (try? await git.isAlreadyApplied(commit.hash)) == true {
            errorMessage = "이 커밋은 이미 \(branchDisplayName)에 있습니다"
            return
        }
        let run: () async -> Void = { [weak self] in
            await self?.perform("체리픽 중…", done: "\(commit.shortHash) 커밋을 체리픽했습니다", undo: "체리픽") { try await $0.cherryPick(commit.hash) }
        }
        // 커밋 하나의 변경만 옮기는 것은 그 부모를 기준으로 합치는 것과 같다
        guard let parent = commit.parents.first,
              let preview = await previewMerge(ours: headRevision, theirs: commit.hash, mergeBase: parent),
              !preview.isClean else {
            await run()
            return
        }
        confirmation = Confirmation(
            title: "체리픽할까요?",
            target: commit.shortHash,
            targetDetail: commit.subject,
            facts: conflictFacts(preview),
            buttonTitle: "체리픽",
            tone: .normal
        ) { await run() }
    }

    func revert(_ commit: Commit) {
        Task { [self] in
            // 되돌리기는 커밋을 기준으로 그 부모 쪽으로 합치는 것과 같다
            var preview: MergePreview?
            if let parent = commit.parents.first {
                preview = await previewMerge(ours: headRevision, theirs: parent, mergeBase: commit.hash)
            }
            confirmation = Confirmation(
                title: "리버트할까요?",
                target: commit.shortHash,
                targetDetail: commit.subject,
                facts: [.note("이 커밋을 반대로 적용한 새 커밋이 생깁니다"), .keeps("원래 커밋은 그대로 남습니다")] + conflictFacts(preview),
                buttonTitle: "리버트",
                tone: .normal
            ) { [weak self] in
                await self?.perform("리버트 중…", done: "리버트 커밋을 만들었습니다", undo: "리버트") { try await $0.revert(commit.hash) }
            }
        }
    }

    func reset(to commit: Commit, mode: ResetMode) {
        confirmation = Confirmation(
            title: "현재 브랜치를 리셋할까요?",
            target: commit.shortHash,
            targetDetail: commit.subject,
            facts: resetFacts(mode) + [.note("활동 칸에서 지금 위치로 다시 돌아올 수 있습니다")],
            buttonTitle: "리셋",
            tone: mode == .hard ? .destructive : .normal
        ) { [weak self] in
            await self?.perform("리셋 중…", done: "리셋했습니다", undo: "리셋") { try await $0.reset(to: commit.hash, mode: mode) }
        }
    }

    /// 커밋을 패치로 복사한다. 메신저나 이슈에 붙이면 받는 쪽이 `git am`으로 적용한다.
    func copyPatch(_ commits: [Commit]) async {
        guard let git, !commits.isEmpty else { return }
        // 머지 커밋은 패치로 만들 수 없다(format-patch가 빼 버린다)
        let plain = commits.filter { !$0.isMerge }
        guard !plain.isEmpty else {
            errorMessage = "머지 커밋은 패치로 복사할 수 없습니다"
            return
        }
        // 히스토리는 최근 것이 위라(부모가 아래) 뒤집으면 오래된 것부터
        let ordered = plain.reversed().map(\.hash)
        do {
            let patch = try await git.formatPatch(ordered)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(patch, forType: .string)
            let skipped = commits.count - plain.count
            showStatus((plain.count == 1 ? "패치를 복사했습니다" : "커밋 \(plain.count)개를 패치로 복사했습니다") + (skipped > 0 ? ". 머지 커밋 \(skipped)개는 제외했습니다" : ""))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 커밋하지 않은 변경을 패치로 복사한다. 추적 안 된 새 파일은 git이 아직 모르는 파일이라 빠진다.
    func copyPatch(for changes: [FileChange]) async {
        guard let git else { return }
        let paths = changes.filter { $0.area != .untracked }.map(\.path)
        guard !paths.isEmpty else {
            errorMessage = "추적 안 된 새 파일은 패치로 만들 수 없습니다. 스테이징한 뒤 복사하세요"
            return
        }
        do {
            let patch = try await git.workingPatch(paths: paths, hasHead: hasHead)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(patch, forType: .string)
            showStatus(paths.count == 1 ? "패치를 복사했습니다" : "파일 \(paths.count)개를 패치로 복사했습니다")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 추적 안 된 파일을 정리한다. 지울 목록을 먼저 보여 주고, 지우지 않고 휴지통으로 옮긴다.
    /// 무시된 파일(빌드 결과물 등)은 기본으로 빼고, 확인 창의 스위치로 넣을 수 있다.
    func cleanUntracked() {
        guard let git, let root = activeWorktreePath else { return }
        Task { [self] in
            do {
                let untracked = try await git.cleanCandidates(includeIgnored: false)
                let all = try await git.cleanCandidates(includeIgnored: true)
                let ignored = all.filter { !untracked.contains($0) }
                guard !all.isEmpty else {
                    showStatus("정리할 파일이 없습니다")
                    return
                }
                func list(_ paths: [String]) -> [Confirmation.Fact] {
                    let shown = paths.prefix(8).map { Confirmation.Fact.item($0) }
                    return shown + (paths.count > 8 ? [.item("외 \(paths.count - 8)개")] : [])
                }
                let trash: ([String]) -> @MainActor () async -> Void = { paths in
                    { [weak self] in await self?.moveToTrash(paths, root: root) }
                }
                let ignoredWarning = Confirmation.Fact.warns(".env 같은 개인 설정 파일도 들어갈 수 있습니다. 목록을 확인하세요")
                let restorable = Confirmation.Fact.keeps("휴지통으로 옮깁니다. Finder에서 복구할 수 있습니다")
                // 무시된 파일만 있으면 고를 것이 없으니 바로 그 목록을 보여 준다
                if untracked.isEmpty {
                    confirmation = Confirmation(
                        title: "무시된 파일을 정리할까요?",
                        target: "\(ignored.count)개 항목",
                        targetDetail: "빌드 결과물처럼 .gitignore에 적힌 파일",
                        facts: list(ignored) + [ignoredWarning, restorable],
                        buttonTitle: "휴지통으로 이동",
                        tone: .normal,
                        action: trash(ignored)
                    )
                    return
                }
                confirmation = Confirmation(
                    title: "추적 안 된 파일을 정리할까요?",
                    target: "\(untracked.count)개 항목",
                    facts: list(untracked) + [restorable],
                    buttonTitle: "휴지통으로 이동",
                    tone: .normal,
                    action: trash(untracked),
                    choice: ignored.isEmpty ? nil : Confirmation.Choice(
                        title: "무시된 파일도 넣기",
                        detail: "빌드 결과물처럼 .gitignore에 적힌 \(ignored.count)개 항목. 폴더는 안의 파일까지 옮깁니다",
                        facts: list(all) + [ignoredWarning, restorable],
                        buttonTitle: "모두 휴지통으로 이동",
                        action: trash(all)
                    )
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func moveToTrash(_ paths: [String], root: String) async {
        var failed: [String] = []
        for path in paths {
            let url = URL(fileURLWithPath: root).appendingPathComponent(path)
            do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) } catch { failed.append(path) }
        }
        await refresh()
        if failed.isEmpty {
            showStatus("\(paths.count)개를 휴지통으로 옮겼습니다")
        } else {
            errorMessage = "옮기지 못한 파일 \(failed.count)개: " + failed.prefix(3).joined(separator: ", ")
        }
    }

    func copyHash(_ commit: Commit) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commit.hash, forType: .string)
        showStatus("커밋 해시를 복사했습니다")
    }

    // MARK: 스태시

    @discardableResult
    func createStash(message: String, includeUntracked: Bool) async -> Bool {
        await perform("스태시 만드는 중…", done: "스태시에 넣었습니다", undo: "스태시 만들기") {
            try await $0.stashPush(message: message.trimmed, includeUntracked: includeUntracked)
        }
    }

    func applyStash(_ stash: Stash, pop: Bool) async {
        if pop, sidebarSelection == .stash(stash.id) { sidebarSelection = nil }
        await perform("스태시 적용 중…", done: pop ? "스태시를 적용하고 지웠습니다" : "스태시를 적용했습니다", undo: "스태시 적용") {
            try await $0.stashApply(stash.ref, pop: pop)
        }
    }

    func dropStash(_ stash: Stash) {
        confirmation = Confirmation(
            title: "스태시를 삭제할까요?",
            target: stash.title,
            targetDetail: stash.branch,
            facts: [.loses("치워 둔 변경 (⌘Z로 되돌릴 수 있습니다)")],
            buttonTitle: "삭제"
        ) { [weak self] in
            guard let self else { return }
            if sidebarSelection == .stash(stash.id) { sidebarSelection = nil }
            await perform("스태시 지우는 중…", undo: "스태시 삭제") { try await $0.stashDrop(stash.ref) }
        }
    }

    // MARK: 태그

    @discardableResult
    func createTag(name: String, at hash: String, message: String) async -> Bool {
        await perform("태그 만드는 중…", done: "\(name) 태그를 만들었습니다", undo: "태그 만들기") {
            try await $0.createTag(name, at: hash, message: message.trimmed.isEmpty ? nil : message.trimmed)
        }
    }

    func deleteTag(_ tag: Tag) {
        confirmation = Confirmation(
            title: "태그를 삭제할까요?",
            target: tag.name,
            facts: [.loses("이 컴퓨터의 태그"), .keeps("원격에 올린 태그")],
            buttonTitle: "삭제"
        ) { [weak self] in
            guard let self else { return }
            if sidebarSelection == .tag(tag.id) { sidebarSelection = nil }
            await perform("태그 삭제 중…", undo: "태그 삭제") { try await $0.deleteTag(tag.name) }
        }
    }

    // MARK: 워크트리

    func suggestedWorktreePath(for branch: String) -> String {
        guard let mainRootPath else { return "" }
        let parent = (mainRootPath as NSString).deletingLastPathComponent
        let name = (mainRootPath as NSString).lastPathComponent
        let safe = branch.replacingOccurrences(of: "/", with: "-")
        return (parent as NSString).appendingPathComponent("\(name)-\(safe)")
    }

    @discardableResult
    func addWorktree(path: String, branch: String, createBranch: Bool, from base: String?) async -> Bool {
        let succeeded = await perform("워크트리 추가 중…", done: "워크트리를 만들었습니다") {
            try await $0.addWorktree(at: path, branch: branch, createBranch: createBranch, from: base)
        }
        if succeeded {
            let target = canonicalPath(path)
            if let added = worktrees.first(where: { canonicalPath($0.path) == target }) {
                await activateWorktree(added.path)
            }
        }
        return succeeded
    }

    /// 커밋하지 않은 변경을 먼저 세어서 한 번만 묻는다. 버튼은 하나.
    func removeWorktree(_ worktree: Worktree) {
        Task { [self] in
            let dirty = (try? await GitRepository(path: worktree.path).status().changes.count) ?? 0
            var facts: [Confirmation.Fact] = [.loses("워크트리 폴더")]
            if dirty > 0 { facts.append(.loses("커밋하지 않은 변경 \(dirty)개")) }
            facts.append(.keeps("브랜치와 커밋은 그대로 남습니다"))
            confirmation = Confirmation(
                title: "워크트리를 제거할까요?",
                target: worktree.name,
                targetDetail: (worktree.path as NSString).abbreviatingWithTildeInPath,
                facts: facts,
                buttonTitle: dirty > 0 ? "변경 \(dirty)개와 함께 제거" : "제거"
            ) { [weak self] in
                await self?.performRemoveWorktree(worktree, force: dirty > 0)
            }
        }
    }

    private func performRemoveWorktree(_ worktree: Worktree, force: Bool) async {
        if worktree.path == activeWorktreePath, let mainRootPath {
            await activateWorktree(mainRootPath)
        }
        await perform("워크트리 제거 중…") { try await $0.removeWorktree(worktree.path, force: force) }
    }

    // MARK: 원격

    /// 지금 진행 중인 페치·풀·푸시. 그 버튼이 자기 자리에 진행 표시를 그린다.
    enum SyncActivity { case fetch, pull, push }
    private(set) var syncActivity: SyncActivity?

    func fetch() async {
        syncActivity = .fetch
        defer { syncActivity = nil }
        await perform("페치 중…", done: "페치했습니다") { try await $0.fetch() }
    }

    func fetch(_ remote: Remote) async {
        syncActivity = .fetch
        defer { syncActivity = nil }
        await perform("\(remote.name) 페치 중…", done: "\(remote.name)에서 가져왔습니다") { try await $0.fetch(remote: remote.name) }
    }

    /// 풀 방식. 풀 창에서 마지막으로 고른 것을 기억하고, 설정에서도 바꿀 수 있다.
    static var pullRebases: Bool { UserDefaults.standard.bool(forKey: "pullRebase") }
    static var pullAutostash: Bool { UserDefaults.standard.object(forKey: "pullAutostash") as? Bool ?? true }

    // MARK: 푸시·풀 창

    /// 푸시 창을 열 때 강제 푸시를 켜 둘지. 더 보기 메뉴의 "강제 푸시…"에서 켠다.
    var pushPresetForce = false

    /// 푸시 창. 어느 원격의 어느 브랜치로 가는지 보고 ⏎로 보낸다.
    func showPush(force: Bool = false) {
        guard isOpen else { return }
        guard !localBranches.isEmpty else {
            errorMessage = "푸시할 브랜치가 없습니다"
            return
        }
        guard !remotes.isEmpty else {
            errorMessage = "원격이 없습니다. 사이드바의 원격에서 먼저 추가하세요"
            return
        }
        pushPresetForce = force
        sheet = .push
    }

    /// 풀 창. 현재 브랜치로 받으므로 브랜치를 체크아웃한 상태여야 한다.
    func showPull() {
        guard isOpen else { return }
        guard currentBranch != nil else {
            errorMessage = "브랜치를 체크아웃한 상태에서만 풀할 수 있습니다"
            return
        }
        guard !remotes.isEmpty else {
            errorMessage = "원격이 없습니다. 사이드바의 원격에서 먼저 추가하세요"
            return
        }
        sheet = .pull
    }

    /// 이 저장소에서 마지막으로 푸시한 원격
    private var lastPushRemote: String? {
        get { mainRootPath.flatMap { UserDefaults.standard.string(forKey: "pushRemote:" + $0) } }
        set { if let root = mainRootPath { UserDefaults.standard.set(newValue, forKey: "pushRemote:" + root) } }
    }

    /// `Upstream/feature/x` → `Upstream`. 원격 이름에 `/`가 들어갈 수 있어 긴 이름부터 맞춰 본다.
    func remoteName(of ref: String) -> String? {
        remotes.map(\.name).sorted { $0.count > $1.count }.first { ref.hasPrefix($0 + "/") }
    }

    /// 창을 열 때 미리 고를 원격. 추적 중인 원격 → 이 저장소에서 마지막으로 고른 원격 → 원격이 하나뿐이면 그것.
    /// 셋 다 아니면 고르지 않고 사용자에게 맡긴다. 목록의 첫 번째로 정하면 엉뚱한 저장소로 갈 수 있다.
    func defaultRemote(for branch: String) -> String? {
        if let upstream = localBranches.first(where: { $0.name == branch })?.upstream, let remote = remoteName(of: upstream) {
            return remote
        }
        if let last = lastPushRemote, remotes.contains(where: { $0.name == last }) { return last }
        return remotes.count == 1 ? remotes[0].name : nil
    }

    /// 원격에서 짝이 되는 브랜치 이름. 그 원격을 추적 중이면 추적 브랜치, 아니면 같은 이름.
    func counterpart(of branch: String, on remote: String) -> String {
        if let upstream = localBranches.first(where: { $0.name == branch })?.upstream, remoteName(of: upstream) == remote {
            return String(upstream.dropFirst(remote.count + 1))
        }
        return branch
    }

    /// 그 원격에 있는 브랜치 이름들. `HEAD`는 뺀다.
    func branchNames(on remote: String) -> [String] {
        remoteBranches
            .filter { remoteName(of: $0.name) == remote }
            .map { String($0.name.dropFirst(remote.count + 1)) }
            .filter { $0 != "HEAD" }
    }

    struct SyncCounts: Equatable {
        /// 보낼 커밋 (푸시) / 내 쪽에만 있는 커밋 (풀)
        let ahead: Int
        /// 원격에만 있는 커밋
        let behind: Int
        /// 원격에 그 브랜치가 있는지
        let targetExists: Bool
    }

    /// 마지막 페치 기준으로 `branch`와 `remote/target` 사이의 커밋 수. 원격에 없는 브랜치면 그 원격 어디에도 없는 커밋만 센다.
    func syncCounts(branch: String, remote: String, target: String) async -> SyncCounts? {
        guard let git else { return nil }
        let local = branch == "HEAD" ? "HEAD" : "refs/heads/\(branch)"
        if branchNames(on: remote).contains(target) {
            guard let counts = try? await git.aheadBehind(base: "refs/remotes/\(remote)/\(target)", head: local) else { return nil }
            return SyncCounts(ahead: counts.ahead, behind: counts.behind, targetExists: true)
        }
        guard let ahead = try? await git.countCommits([local, "--not", "--remotes=\(remote)"]) else { return nil }
        return SyncCounts(ahead: ahead, behind: 0, targetExists: false)
    }

    @discardableResult
    func push(branch: String, remote: String, target: String, force: Bool, tags: Bool) async -> Bool {
        // 추적 브랜치가 없을 때만 이번 대상을 추적하게 한다. 이미 있으면 다른 곳으로 보내도 추적은 그대로 둔다.
        let setUpstream = localBranches.first(where: { $0.name == branch })?.upstream == nil
        lastPushRemote = remote
        syncActivity = .push
        defer { syncActivity = nil }
        return await perform(force ? "강제 푸시 중…" : "푸시 중…", done: "\(remote)/\(target)에 푸시했습니다") {
            try await $0.push(branch: branch, remote: remote, target: target, setUpstream: setUpstream, force: force, tags: tags)
        }
    }

    @discardableResult
    func pull(remote: String, branch: String, rebase: Bool, autostash: Bool) async -> Bool {
        UserDefaults.standard.set(rebase, forKey: "pullRebase")
        UserDefaults.standard.set(autostash, forKey: "pullAutostash")
        syncActivity = .pull
        defer { syncActivity = nil }
        return await perform(rebase ? "풀(리베이스) 중…" : "풀 중…", done: "\(remote)/\(branch)에서 풀했습니다", undo: "풀") {
            try await $0.pull(remote: remote, branch: branch, rebase: rebase, autostash: autostash)
        }
    }

    func renameBranch(_ branch: Branch, to newName: String) async -> Bool {
        let name = newName.trimmed
        guard !name.isEmpty, name != branch.name else { return false }
        return await perform("이름 바꾸는 중…", done: "브랜치 이름을 \(name)(으)로 바꿨습니다", undo: "브랜치 이름 바꾸기") { try await $0.renameBranch(branch.name, to: name) }
    }

    /// 원격 브랜치 삭제. 되살리기 어려워서 꼭 묻는다.
    /// 원격의 기본 브랜치와 기준 브랜치(main, develop 같은 것). 앱에서는 원격에서 지우지 못하게 막는다.
    func isProtectedRemoteBranch(_ branch: Branch) -> Bool {
        guard branch.isRemote, let remote = remoteName(of: branch.name) else { return false }
        return remoteHeads[remote] == branch.name || CommitGraph.defaultBaseNames.contains(String(branch.name.dropFirst(remote.count + 1)))
    }

    /// 원격 브랜치 삭제. 같은 저장소를 쓰는 모두에게서 사라지고 ⌘Z로 되돌릴 수 없어서 가장 조심한다.
    func deleteRemoteBranch(_ branch: Branch) {
        guard let remote = remoteName(of: branch.name), !isProtectedRemoteBranch(branch) else { return }
        let name = String(branch.name.dropFirst(remote.count + 1))
        let repository = remotes.first { $0.name == remote }?.repositoryPath
        Task { [self] in
            // 이 원격 브랜치에만 있는 커밋. 다른 브랜치·태그·원격 어디에도 없으면 지운 뒤 찾기 어렵다.
            var onlyHere: [Commit] = []
            if let git {
                // --remotes와 쓰는 --exclude는 refs/remotes/를 뺀 이름을 받는다
                onlyHere = (try? await git.log(revisions: [branch.fullName, "--not", "--branches", "--tags", "--exclude=\(branch.name)", "--remotes"], limit: 50)) ?? []
            }
            var facts: [Confirmation.Fact] = [
                .loses("이 원격 저장소를 쓰는 모든 사람에게서 사라집니다"),
            ]
            if !onlyHere.isEmpty {
                facts.append(.loses("다른 브랜치에 없는 커밋 \(onlyHere.count)개\(onlyHere.count >= 50 ? "+" : "")"))
                for commit in onlyHere.prefix(3) { facts.append(.item("\(commit.shortHash)  \(commit.subject)")) }
                if onlyHere.count > 3 { facts.append(.item("외 \(onlyHere.count - 3)개")) }
            }
            if localBranches.contains(where: { $0.name == name }) {
                facts.append(.keeps("이 컴퓨터의 \(name) 브랜치는 남습니다"))
            }
            facts.append(.note("⌘Z로는 되돌릴 수 없습니다. 지운 뒤 활동 칸의 \"최근 지운 브랜치\"에서 다시 올릴 수 있습니다"))
            confirmation = Confirmation(
                title: "원격 브랜치를 삭제할까요?",
                target: branch.name,
                targetDetail: repository.map { "원격 저장소 " + $0 },
                facts: facts,
                buttonTitle: "원격에서 삭제"
            ) { [weak self] in
                guard let self else { return }
                if await perform("원격 브랜치 삭제 중…", done: "\(branch.name) 브랜치를 원격에서 지웠습니다", { try await $0.deleteRemoteBranch(remote: remote, branch: name) }) {
                    remember(deleted: DeletedBranch(name: name, hash: branch.hash, date: Date(), remote: remote))
                }
            }
        }
    }

    func setUpstream(_ branch: Branch, to upstream: String?) async {
        await perform("추적 브랜치 바꾸는 중…", done: upstream.map { "\($0) 추적을 시작했습니다" } ?? "추적을 해제했습니다") {
            try await $0.setUpstream(branch.name, to: upstream)
        }
    }

    func copyBranchName(_ branch: Branch) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(branch.nameWithoutRemote, forType: .string)
        showStatus("브랜치 이름을 복사했습니다")
    }

    func pushTags() async {
        await perform("태그 푸시 중…", done: "태그를 푸시했습니다") { try await $0.pushTags() }
    }

    @discardableResult
    func addRemote(name: String, url: String) async -> Bool {
        await perform("원격 추가 중…", done: "\(name) 원격을 추가했습니다") { try await $0.addRemote(name, url: url) }
    }

    func removeRemote(_ remote: Remote) {
        confirmation = Confirmation(
            title: "원격을 제거할까요?",
            target: remote.name,
            targetDetail: remote.url,
            facts: [.loses("이 원격의 추적 브랜치 목록"), .keeps("원격 서버의 저장소는 그대로입니다")],
            buttonTitle: "제거"
        ) { [weak self] in
            await self?.perform("원격 제거 중…") { try await $0.removeRemote(remote.name) }
        }
    }

    /// 브라우저로 연다. http·https만. `file:`이나 다른 앱의 주소는 열지 않는다(커밋 본문·Claude 답에서 온 주소라서).
    /// PR(GitLab은 MR) 작성 페이지 주소. GitHub와 GitLab만 만든다. 다른 호스트는 주소 모양을 짐작하지 않는다.
    /// 브랜치를 fork 원격에 푸시했으면, 기준 브랜치가 있는 원격(원본 저장소)으로 보내는 PR을 연다.
    func pullRequestURL(for branch: String) -> URL? {
        guard let local = localBranches.first(where: { $0.name == branch }),
              let upstream = local.upstream, !local.upstreamGone,
              let headRemoteName = remoteName(of: upstream),
              let headRemote = remotes.first(where: { $0.name == headRemoteName }),
              let host = headRemote.host
        else { return nil }
        let headBranch = String(upstream.dropFirst(headRemoteName.count + 1))
        // 기준: Git Flow 브랜치면 그 기준, 아니면 히스토리 기준 브랜치. 기준 브랜치가 추적하는 원격이 PR을 받는 저장소다.
        let baseName: String
        if let kind = gitFlowKind(of: branch) {
            // 릴리스·핫픽스는 배포 브랜치로, 기능·버그 수정은 시작할 때 적어 둔 기준으로
            baseName = kind.releases ? flowConfig.production : flowConfig.finishBase(of: branch, kind: kind)
        } else if let base = resolveBase(excluding: branch) {
            // `origin/develop`처럼 원격 브랜치가 기준이면 원격 이름을 뗀다
            baseName = remoteName(of: base).map { String(base.dropFirst($0.count + 1)) } ?? base
        } else {
            return nil
        }
        let baseUpstream = localBranches.first { $0.name == baseName }?.upstream
        let baseRemote = baseUpstream.flatMap(remoteName(of:)).flatMap { name in remotes.first { $0.name == name } } ?? headRemote
        let baseBranch = baseUpstream.flatMap { up in remoteName(of: up).map { String(up.dropFirst($0.count + 1)) } } ?? baseName
        guard baseRemote.host == host, let basePath = baseRemote.webPath, let headPath = headRemote.webPath, let web = baseRemote.webHost else { return nil }
        let sameRepository = basePath == headPath
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#?")
        func encode(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text }

        if host == "github.com" || host.hasPrefix("github.") {
            let headOwner = headPath.split(separator: "/").first.map(String.init) ?? ""
            let head = sameRepository ? headBranch : "\(headOwner):\(headBranch)"
            return URL(string: "https://\(web)/\(basePath)/compare/\(encode(baseBranch))...\(encode(head))?expand=1")
        }
        if host.contains("gitlab"), sameRepository {
            // 다른 프로젝트로 보내는 MR은 프로젝트 번호가 있어야 해서 만들지 않는다
            return URL(string: "https://\(web)/\(basePath)/-/merge_requests/new?merge_request%5Bsource_branch%5D=\(encode(headBranch))&merge_request%5Btarget_branch%5D=\(encode(baseBranch))")
        }
        return nil
    }

    /// PR 작성 페이지를 연다. 아직 푸시하지 않은 커밋이 있으면 PR에 빠지니 알린다.
    func openPullRequest(for branch: String) {
        guard let url = pullRequestURL(for: branch) else {
            errorMessage = "PR 주소를 만들 수 없습니다. 원격에 푸시한 브랜치이고 GitHub나 GitLab 저장소인지 확인하세요"
            return
        }
        NSWorkspace.shared.open(url)
        if let ahead = localBranches.first(where: { $0.name == branch })?.ahead, ahead > 0 {
            showStatus("푸시하지 않은 커밋 \(ahead)개는 PR에 들어가지 않습니다")
        }
    }

    func openURL(_ string: String) {
        guard let url = URL(string: string), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            errorMessage = "웹 주소(http, https)만 열 수 있습니다"
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: Claude

    struct AssistantMessage: Identifiable, Hashable {
        enum Role { case user, assistant }
        let id = UUID()
        let role: Role
        var text: String
        var isStreaming = false
        var error: String?
        /// 빠른 동작으로 만든 답이면 무엇이었는지. 커밋 메시지 제안은 "넣기" 버튼이 붙는다.
        var action: AssistantAction?
        /// 이 질문에 붙여 보낸 문맥의 이름들
        var attached: [String] = []
        /// 답을 만드는 동안 거친 과정. 생각, 도구 호출.
        var steps: [AssistantStep] = []
    }

    /// 답이 오기 전에 Claude가 한 일 하나.
    struct AssistantStep: Identifiable, Hashable {
        enum Kind: Hashable { case thinking, tool(String) }
        let id = UUID()
        let kind: Kind
        var summary: String
        var startedAt = Date()
        var finishedAt: Date?
        /// 도구 결과 요약 ("120줄")
        var result: String?
    }

    /// 머리말의 빠른 동작. 지금 보고 있는 것에 맞는 질문을 대신 적어 준다.
    enum AssistantAction: String, CaseIterable, Identifiable {
        case explain, review, commitMessage
        var id: String { rawValue }

        var title: String {
            switch self {
            case .explain: "설명"
            case .review: "리뷰"
            case .commitMessage: "커밋 메시지 제안"
            }
        }

        var prompt: String {
            switch self {
            case .explain:
                "아래 변경을 읽고 무엇을 왜 바꿨는지 설명해 주세요. 바뀐 동작과 영향받는 곳을 먼저, 세부는 그다음에. 한국어로, 짧은 문장으로."
            case .review:
                "아래 변경을 리뷰해 주세요. 버그 가능성, 빠진 경우, 이름·구조에서 걸리는 점을 중요한 순서로 적고, 각 지적에 파일과 줄을 붙여 주세요. 괜찮은 부분은 길게 칭찬하지 말고 한 줄로. 한국어로."
            case .commitMessage:
                "아래 diff에 맞는 커밋 메시지를 제안해 주세요. 첫 줄은 50자 안쪽의 제목, 빈 줄, 그다음 무엇을 왜 바꿨는지 두세 문장. 설명이나 인사 없이 커밋 메시지 본문만 출력하세요. 한국어로."
            }
        }
    }

    /// 질문에 같이 붙는 것 하나. 창 위에 칩으로 보이고, 끌 수 있다.
    struct AssistantContextItem: Identifiable, Hashable {
        enum Kind: Hashable { case commit(String), change(FileChange), compare(base: String, head: String), staged, workingTree, repository }
        let kind: Kind
        let symbol: String
        /// 칩에 적는 짧은 이름
        let title: String
        /// 칩 아래 작은 글. "파일 5개 · +45 −31"
        let detail: String
        /// 처음부터 켜져 있는지. 사용자가 누르면 반대가 된다.
        var defaultOn = true

        var id: String {
            switch kind {
            case .commit(let hash): "commit:" + hash
            case .change(let change): "change:" + change.id
            case .compare(let base, let head): "compare:\(base)...\(head)"
            case .staged: "staged"
            case .workingTree: "workingTree"
            case .repository: "repository"
            }
        }
    }

    private(set) var assistantMessages: [AssistantMessage] = []
    private(set) var isAssistantRunning = false
    private var assistantTask: Task<Void, Never>?
    /// claude CLI 위치. 앱으로 돌아올 때마다 다시 찾는다(`ClaudeAccount.relocate`).
    private var claudeExecutable: URL? { ClaudeAccount.shared.executable }
    var assistantAvailable: Bool { claudeExecutable != nil }
    /// 메인 창 위에 떠 있는 Claude 카드가 열려 있는지. 오른쪽 패널과 무관하다.
    var showsAssistant = false
    /// 설정 모달이 열려 있는지
    var showsSettings = false
    /// 빠른 실행 (⌘P)이 열려 있는지
    var showsPalette = false
    /// 머리글의 브랜치 바꾸기 창 (⌘B)
    var showsBranchSwitcher = false
    /// 단축키로 입력 칸에 커서를 보내 달라는 요청. 값이 바뀌면 그 칸이 포커스를 가져간다.
    var commitSearchFocusRequest = 0
    var commitMessageFocusRequest = 0

    // MARK: Fork와 같은 단축키가 부르는 동작

    /// ⌘0: 히스토리에서 HEAD 커밋으로
    func revealHead() {
        sidebarSelection = nil
        pane = .history
        jumpToHead()
    }

    /// ⌘F: 히스토리의 커밋 검색 칸으로
    func focusCommitSearch() {
        sidebarSelection = nil
        pane = .history
        commitSearchFocusRequest += 1
    }

    /// ⇧⌘C: 변경 사항의 커밋 메시지 칸으로
    func focusCommitMessage() {
        sidebarSelection = nil
        pane = .changes
        commitMessageFocusRequest += 1
    }

    /// ⇧⌘A: 현재 브랜치만 보기와 모든 브랜치 보기를 오간다
    func toggleCurrentBranchFilter() {
        sidebarSelection = nil
        pane = .history
        historyScope = historyScope == .all ? .current : .all
    }

    /// ⇧⌘↩: 커밋하고 푸시 창을 연다
    func commitAndPush() async {
        let before = status.headOID
        await commit()
        guard status.headOID != before else { return }
        // 커밋은 바로, 푸시는 어디로 가는지 창에서 확인한 뒤에
        showPush()
    }

    /// ⌥⇧⌘H: 묻지 않고 바로 스태시 (추적하지 않는 파일 포함)
    func quickStash() async {
        guard !status.changes.isEmpty else { return }
        _ = await createStash(message: "", includeUntracked: true)
    }

    /// ⇧⌘G: HEAD에 새 태그
    func newTagAtHead() {
        guard let head = status.headOID ?? headCommit?.hash else { return }
        sheet = .newTag(head)
    }
    /// `/`로 부를 수 있는 스킬. 카드를 열 때 뒤에서 읽어 둔다.
    private(set) var skills: [ClaudeSkill] = []

    /// 스킬 목록을 다시 읽는다. 디스크만 읽으니 가볍지만 메인에서 하지 않는다.
    func loadSkills() {
        let root = mainRootPath
        Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) { SkillCatalog.load(projectRoot: root) }.value
            self?.skills = loaded
        }
    }
    /// 사용자가 칩을 눌러 기본값과 반대로 바꾼 문맥
    var toggledAssistantContext: Set<String> = []

    func isAssistantContextIncluded(_ item: AssistantContextItem) -> Bool {
        item.defaultOn != toggledAssistantContext.contains(item.id)
    }

    /// 지금 붙일 수 있는 문맥. 메인 창에서 보고 있는 것이 바뀌면 같이 바뀐다.
    var assistantContextItems: [AssistantContextItem] {
        var items: [AssistantContextItem] = []
        switch detail {
        case .commit(let commit):
            let files = diffFiles
            let detail = files.isEmpty ? commit.subject : "파일 \(files.count)개, +\(files.reduce(0) { $0 + $1.additions }) −\(files.reduce(0) { $0 + $1.deletions })"
            items.append(AssistantContextItem(kind: .commit(commit.hash), symbol: "circle.fill", title: "커밋 \(commit.shortHash)", detail: detail))
        case .change(let change):
            items.append(AssistantContextItem(kind: .change(change), symbol: "doc.text", title: change.fileName, detail: change.kind.label + ", " + (change.isStaged ? "스테이징됨" : "작업 트리")))
        case .compare(let base, let head):
            items.append(AssistantContextItem(kind: .compare(base: base, head: head), symbol: "arrow.left.arrow.right", title: "\(base) → \(head)", detail: comparison.map { "커밋 \($0.ahead)개, 파일 \($0.stat.files)개" } ?? "갈라진 뒤의 변경"))
        default:
            if !status.staged.isEmpty {
                // 아래에서 공통으로 붙인다
            } else if !status.changes.isEmpty {
                items.append(AssistantContextItem(kind: .workingTree, symbol: "pencil.and.list.clipboard", title: "작업 트리 변경", detail: "파일 \(status.changes.count)개, +\(workingStat.additions) −\(workingStat.deletions)"))
            } else if let head = headCommit ?? commits.first {
                // 아무것도 고르지 않았고 작업 트리도 깨끗하면 최근 커밋이 대상이다. 그래야 "설명"이 빈손으로 가지 않는다.
                items.append(AssistantContextItem(kind: .commit(head.hash), symbol: "circle.fill", title: "최근 커밋 \(head.shortHash)", detail: head.subject))
            }
        }
        // 스테이징한 변경은 무엇을 보고 있든 칩으로 둔다. 다른 것을 보고 있으면 처음엔 꺼 둔다.
        if !status.staged.isEmpty {
            let viewingSomething = !items.isEmpty
            items.append(AssistantContextItem(kind: .staged, symbol: "tray.and.arrow.down", title: "스테이징한 변경", detail: "파일 \(status.staged.count)개, +\(stagedStat.additions) −\(stagedStat.deletions)", defaultOn: !viewingSomething))
        }
        items.append(AssistantContextItem(kind: .repository, symbol: "arrow.triangle.branch", title: repositoryName, detail: branchDisplayName + "의 최근 커밋 20개"))
        return items
    }

    private var includedAssistantContext: [AssistantContextItem] {
        assistantContextItems.filter(isAssistantContextIncluded)
    }

    func toggleAssistantContext(_ item: AssistantContextItem) {
        if toggledAssistantContext.contains(item.id) {
            toggledAssistantContext.remove(item.id)
        } else {
            toggledAssistantContext.insert(item.id)
        }
    }

    /// 커밋을 만드는 요청(커밋 메시지 제안, 커밋 스킬)에 맞는 문맥.
    /// 보고 있는 파일 하나가 아니라 스테이징한 변경 전체, 없으면 작업 트리 변경 전체를 붙인다.
    var commitContext: [AssistantContextItem] {
        var items: [AssistantContextItem] = []
        if !status.staged.isEmpty {
            items.append(AssistantContextItem(kind: .staged, symbol: "tray.and.arrow.down", title: "스테이징한 변경", detail: "파일 \(status.staged.count)개, +\(stagedStat.additions) −\(stagedStat.deletions)"))
        } else if !status.changes.isEmpty {
            items.append(AssistantContextItem(kind: .workingTree, symbol: "pencil.and.list.clipboard", title: "작업 트리 변경", detail: "파일 \(status.changes.count)개"))
        }
        items.append(AssistantContextItem(kind: .repository, symbol: "arrow.triangle.branch", title: repositoryName, detail: branchDisplayName))
        return items
    }

    /// 프롬프트가 `/스킬`로 시작하면 그 스킬
    private func skill(in prompt: String) -> ClaudeSkill? {
        guard prompt.hasPrefix("/") else { return nil }
        let name = prompt.dropFirst().split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        if let found = skills.first(where: { $0.name == name }) { return found }
        // 목록을 아직 못 읽었거나 방금 만든 스킬이면 지금 읽는다. `/`로 보낼 때만이라 한 번이다.
        skills = SkillCatalog.load(projectRoot: mainRootPath)
        return skills.first { $0.name == name }
    }

    /// 문맥 하나를 실제로 보낼 글로. 미리보기와 전송이 같은 글을 쓴다. diff는 40,000자에서 자른다.
    func assistantText(for item: AssistantContextItem) async -> String {
        guard let git else { return "" }
        let limit = 40_000
        func clipped(_ text: String) -> String {
            text.count > limit ? String(text.prefix(limit)) + "\n\n[… 너무 길어 여기서 잘랐습니다]" : text
        }
        switch item.kind {
        case .commit(let hash):
            let show = (try? await git.run(["show", "--format=fuller", "-M", "--patch", hash]).stdout) ?? ""
            return "## 커밋 \(hash)\n\n" + clipped(show)
        case .change(let change):
            let arguments: [String]
            switch change.area {
            case .staged: arguments = ["diff", "--cached", "-M", "--", change.path]
            case .untracked: arguments = ["diff", "--no-index", "--", "/dev/null", change.path]
            default: arguments = ["diff", "-M", "--", change.path]
            }
            let diff = (try? await git.run(arguments, allowedExitCodes: [0, 1]).stdout) ?? ""
            return "## 파일 \(change.path) (\(change.kind.label))\n\n" + clipped(diff)
        case .compare(let base, let head):
            let diff = (try? await git.run(["diff", "-M", "\(base)...\(head)"]).stdout) ?? ""
            let log = (try? await git.run(["log", "--oneline", "\(base)..\(head)"]).stdout) ?? ""
            return "## \(base)에서 갈라진 뒤 \(head)의 변경\n\n커밋:\n\(log)\n\n" + clipped(diff)
        case .staged:
            let diff = (try? await git.run(["diff", "--cached", "-M"]).stdout) ?? ""
            return "## 스테이징한 변경\n\n" + clipped(diff)
        case .workingTree:
            let diff = (try? await git.run(["diff", "-M"]).stdout) ?? ""
            let untracked = status.changes.filter { $0.area == .untracked }.map(\.path)
            var text = "## 작업 트리 변경\n"
            if !untracked.isEmpty { text += "추적 안 되는 파일: " + untracked.joined(separator: ", ") + "\n" }
            return text + "\n" + clipped(diff)
        case .repository:
            let log = (try? await git.run(["log", "--oneline", "-n", "20"]).stdout) ?? ""
            return "## 저장소 \(repositoryName)\n브랜치: \(branchDisplayName)\n\n최근 커밋:\n\(log)"
        }
    }

    private func assistantContext(_ items: [AssistantContextItem]) async -> String {
        var parts: [String] = []
        for item in items { parts.append(await assistantText(for: item)) }
        return parts.joined(separator: "\n\n")
    }

    func showAssistant() {
        showsAssistant = true
        loadSkills()
    }

    func toggleAssistant() {
        showsAssistant.toggle()
        if showsAssistant { loadSkills() }
    }

    func askAssistant(action: AssistantAction) {
        if action == .commitMessage {
            if status.changes.isEmpty {
                showAssistant()
                assistantMessages.append(AssistantMessage(role: .user, text: action.prompt, attached: commitContext.map(\.title)))
                assistantMessages.append(AssistantMessage(role: .assistant, text: "", error: "커밋할 변경이 없습니다. 파일을 스테이징하거나 고친 뒤 다시 눌러 주세요.", action: action))
                return
            }
        }
        askAssistant(action.prompt, action: action)
    }

    /// 질문을 보내고 답을 조각마다 마지막 말풍선에 이어 붙인다. 문맥은 보내는 순간 켜져 있던 칩이다.
    /// 이번 실행 동안 "설정 없이 보내기"를 고른 저장소. 같은 저장소에서 매번 묻지 않는다.
    private var declinedClaudeTrust: Set<String> = []

    /// 저장소에 Claude 설정이 있고 아직 신뢰하지 않았으면 먼저 묻는다. 기본은 저장소 설정 없이 보내기.
    func askAssistant(_ prompt: String, action: AssistantAction? = nil) {
        guard !isAssistantRunning else { return }
        guard claudeExecutable != nil, let root = activeWorktreePath else {
            errorMessage = ClaudeError.notInstalled.localizedDescription
            return
        }
        // 스킬 목록을 아직 안 읽었으면 지금 읽는다. 목록이 달라지면 신뢰 기록과 엇갈려 다시 묻게 된다.
        if skills.isEmpty { skills = SkillCatalog.load(projectRoot: mainRootPath) }
        let config = ClaudeProjectConfig.scan(root: root, skills: skills)
        if config.isEmpty || config.isTrusted(root: root) {
            sendAssistant(prompt, action: action, projectSettings: !config.isEmpty)
            return
        }
        if declinedClaudeTrust.contains(root) {
            sendAssistant(prompt, action: action, projectSettings: false)
            return
        }
        let invokesProjectSkill = skill(in: prompt)?.source == "프로젝트"
        confirmation = Confirmation(
            title: "이 저장소의 Claude 설정을 쓸까요?",
            target: (root as NSString).abbreviatingWithTildeInPath,
            targetDetail: "저장소에 Claude 설정이 들어 있습니다",
            facts: [.warns("신뢰하면 그 안의 훅, MCP 서버, 스킬이 허용한 명령이 이 Mac에서 실행될 수 있습니다")]
                + config.items.prefix(8).map { .item($0) }
                + [.note(invokesProjectSkill ? "이 스킬은 저장소에 든 것이라 신뢰해야 쓸 수 있습니다" : "신뢰하지 않으면 내 Claude 설정만으로 보냅니다")],
            buttonTitle: "설정 없이 보내기",
            tone: .normal,
            action: { [weak self] in
                self?.declinedClaudeTrust.insert(root)
                self?.sendAssistant(prompt, action: action, projectSettings: false)
            },
            choice: Confirmation.Choice(
                title: "이 저장소의 Claude 설정 신뢰",
                detail: "설정이나 스킬이 바뀌면 다시 묻습니다",
                facts: [.keeps("저장소의 Claude 설정과 스킬을 씁니다")] + config.items.prefix(8).map { .item($0) },
                buttonTitle: "신뢰하고 보내기",
                action: { [weak self] in
                    config.trust(root: root)
                    self?.sendAssistant(prompt, action: action, projectSettings: true)
                }
            )
        )
    }

    private func sendAssistant(_ prompt: String, action: AssistantAction?, projectSettings: Bool) {
        guard let executable = claudeExecutable, let root = activeWorktreePath else { return }
        var invokedSkill = skill(in: prompt)
        // 저장소 스킬은 신뢰하지 않으면 불리지 않으니 도구도 더하지 않는다
        if !projectSettings, invokedSkill?.source == "프로젝트" { invokedSkill = nil }
        // 커밋을 만드는 요청이면 보고 있는 파일 하나가 아니라 스테이징한 변경 전체를 붙인다.
        let aboutCommit = action == .commitMessage || invokedSkill?.isAboutCommit == true
        let items = aboutCommit ? commitContext : includedAssistantContext
        // 스킬이 머리말에 적은 도구(Bash, Jira 조회 등)는 그 스킬을 부를 때만 허용한다. 스킬은 단계가 많아 턴도 넉넉히.
        let extraTools = invokedSkill?.allowedTools ?? []
        let maxTurns = invokedSkill == nil ? 6 : 40
        showAssistant()
        var attached = items.map(\.title)
        if !extraTools.isEmpty { attached.append("허용: " + extraTools.joined(separator: ", ")) }
        assistantMessages.append(AssistantMessage(role: .user, text: prompt, attached: attached))
        assistantMessages.append(AssistantMessage(role: .assistant, text: "", isStreaming: true, action: action))
        let index = assistantMessages.count - 1
        isAssistantRunning = true
        let service = ClaudeService(executable: executable)
        assistantTask = Task { [weak self] in
            guard let self else { return }
            let context = await assistantContext(items)
            let fullPrompt = prompt + (items.isEmpty ? "" : "\n\n(아래 stdin으로 붙인 내용이 대상입니다. 저장소 파일을 더 봐야 하면 읽어도 됩니다.)")
            do {
                for try await event in service.stream(prompt: fullPrompt, context: context.isEmpty ? nil : context, directory: URL(fileURLWithPath: root, isDirectory: true), extraTools: extraTools, projectSettings: projectSettings, maxTurns: maxTurns) {
                    guard !Task.isCancelled else { break }
                    switch event {
                    case .text(let piece):
                        assistantMessages[index].text += piece
                    case .thinkingStarted:
                        assistantMessages[index].steps.append(AssistantStep(kind: .thinking, summary: "생각하는 중"))
                    case .thinkingStopped:
                        if let last = assistantMessages[index].steps.lastIndex(where: { $0.kind == .thinking && $0.finishedAt == nil }) {
                            assistantMessages[index].steps[last].finishedAt = Date()
                            let seconds = Int(Date().timeIntervalSince(assistantMessages[index].steps[last].startedAt).rounded())
                            assistantMessages[index].steps[last].summary = seconds > 0 ? "\(seconds)초 생각" : "생각"
                        }
                    case .toolUse(let name, let summary):
                        assistantMessages[index].steps.append(AssistantStep(kind: .tool(name), summary: summary))
                    case .toolResult(let summary):
                        if let last = assistantMessages[index].steps.lastIndex(where: { if case .tool = $0.kind { return $0.finishedAt == nil } else { return false } }) {
                            assistantMessages[index].steps[last].finishedAt = Date()
                            assistantMessages[index].steps[last].result = summary
                        }
                    }
                }
            } catch {
                if assistantMessages[index].text.isEmpty {
                    assistantMessages[index].error = error.localizedDescription
                }
            }
            assistantMessages[index].isStreaming = false
            isAssistantRunning = false
        }
    }

    func cancelAssistant() {
        assistantTask?.cancel()
        assistantTask = nil
        if let last = assistantMessages.indices.last, assistantMessages[last].isStreaming {
            assistantMessages[last].isStreaming = false
            if assistantMessages[last].text.isEmpty { assistantMessages[last].error = "중단했습니다" }
        }
        isAssistantRunning = false
    }

    func clearAssistant() {
        cancelAssistant()
        assistantMessages = []
    }

    /// 제안받은 글을 커밋 메시지 칸에 넣고 변경 칸으로 간다.
    func useAsCommitMessage(_ text: String) {
        commitMessage = text.trimmingCharacters(in: .whitespacesAndNewlines)
        sidebarSelection = nil
        pane = .changes
        showStatus("커밋 메시지에 넣었습니다")
    }

    // MARK: 바깥 앱

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// 설정에서 고른 터미널로 연다
    func openInTerminal(_ path: String) {
        TerminalApp.preferred.open(folder: path)
    }

    /// 기본 앱으로 연다. 앱·스크립트·실행 파일은 열면 바로 실행되므로 한 번 묻는다.
    func openWithDefaultApp(_ change: FileChange) {
        guard let path = absolutePath(of: change) else { return }
        let url = URL(fileURLWithPath: path)
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        let runs = FileManager.default.isExecutableFile(atPath: path)
            || [UTType.application, .executable, .script, .shellScript, .applicationBundle].contains { type?.conforms(to: $0) == true }
            || ["command", "tool", "terminal", "workflow", "pkg", "mpkg"].contains(url.pathExtension.lowercased())
        guard runs else {
            NSWorkspace.shared.open(url)
            return
        }
        confirmation = Confirmation(
            title: "실행 파일을 열까요?",
            target: change.path,
            facts: [.warns("열면 이 파일이 실행됩니다"), .note("내용만 보려면 오른쪽 패널의 diff나 Finder의 훑어보기를 쓰세요")],
            buttonTitle: "열기"
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    func absolutePath(of change: FileChange) -> String? {
        guard let activeWorktreePath else { return nil }
        return (activeWorktreePath as NSString).appendingPathComponent(change.path)
    }
}
