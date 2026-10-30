import Foundation

/// Git Flow의 브랜치 종류
enum GitFlowKind: String, CaseIterable, Identifiable {
    case feature, bugfix, release, hotfix

    var id: String { rawValue }

    var title: String {
        switch self {
        case .feature: "기능"
        case .bugfix: "버그 수정"
        case .release: "릴리스"
        case .hotfix: "핫픽스"
        }
    }

    /// 마무리하면 배포 브랜치에 머지하고 태그를 다는지. 기능·버그 수정은 기준 브랜치에만 머지한다.
    var releases: Bool { self == .release || self == .hotfix }
}

/// Git Flow 브랜치 이름과 접두어. `git flow init`이 적은 설정을 따르고, 없으면 흔한 이름을 쓴다.
struct GitFlowConfig: Equatable {
    /// 배포된 것만 들어가는 브랜치. `main` 또는 `master`
    var production: String
    var development: String
    var prefixes: [GitFlowKind: String]
    /// 태그 이름 앞에 붙는 것. 비어 있으면 버전 그대로
    var tagPrefix: String
    /// 브랜치마다 적힌 기준 브랜치. `gitflow.branch.feature/x.base develop`
    /// git-flow(AVH판)는 시작할 때 이것을 적고, 마무리할 때 여기로 머지한다.
    var recordedBases: [String: String]

    /// - Parameters:
    ///   - settings: `git config --get-regexp ^gitflow\.`의 결과
    ///   - branchNames: 설정이 없을 때 main과 master 중 있는 것을 고르려고 쓴다. 원격에만 있는 브랜치도 원격 이름을 떼고 넣는다.
    init(settings: [String: String], branchNames: [String]) {
        let production = settings["gitflow.branch.master"] ?? settings["gitflow.branch.main"]
        self.production = production ?? (branchNames.contains("main") || !branchNames.contains("master") ? "main" : "master")
        development = settings["gitflow.branch.develop"] ?? "develop"
        var prefixes: [GitFlowKind: String] = [:]
        for kind in GitFlowKind.allCases {
            prefixes[kind] = settings["gitflow.prefix.\(kind.rawValue)"] ?? kind.rawValue + "/"
        }
        self.prefixes = prefixes
        tagPrefix = settings["gitflow.prefix.versiontag"] ?? ""
        var bases: [String: String] = [:]
        for (key, value) in settings where key.hasPrefix("gitflow.branch.") && key.hasSuffix(".base") {
            let branch = key.dropFirst("gitflow.branch.".count).dropLast(".base".count)
            if !branch.isEmpty, !value.isEmpty { bases[String(branch)] = value }
        }
        recordedBases = bases
        isInitialized = settings["gitflow.branch.develop"] != nil || settings["gitflow.branch.master"] != nil
    }

    /// 저장소가 `git flow init`을 거쳤는지. 그러면 시작할 때 기준을 git-flow와 같은 키로 적는다.
    var isInitialized: Bool

    /// 마무리할 때 머지할 기준. 적어 둔 것이 있으면 그것, 없으면 종류의 기본 기준.
    func finishBase(of branch: String, kind: GitFlowKind) -> String {
        recordedBases[branch] ?? (kind == .hotfix || kind == .release ? development : base(of: kind))
    }

    func prefix(_ kind: GitFlowKind) -> String { prefixes[kind] ?? kind.rawValue + "/" }

    /// 새 브랜치를 어디서 갈라낼지. 기능·릴리스는 개발 브랜치, 핫픽스는 배포 브랜치에서.
    func base(of kind: GitFlowKind) -> String { kind == .hotfix ? production : development }

    /// 이름으로 종류를 알아낸다. 접두어가 겹치지 않으니 처음 맞는 것.
    func kind(of branch: String) -> GitFlowKind? {
        GitFlowKind.allCases.first { kind in
            let prefix = self.prefix(kind)
            return !prefix.isEmpty && branch.hasPrefix(prefix) && branch.count > prefix.count
        }
    }

    /// `release/26.45.01` → `26.45.01`
    func version(of branch: String, kind: GitFlowKind) -> String { String(branch.dropFirst(prefix(kind).count)) }
}

/// 마무리 흐름의 한 단계
struct GitFlowStep: Identifiable, Equatable {
    enum Action: Equatable {
        case checkout(String)
        /// `source`를 지금 체크아웃한 `target`에 머지
        case merge(source: String, target: String)
        case tag(name: String, target: String)
        case deleteBranch(String)
        case push(branch: String, remote: String)
        case pushTag(name: String, remote: String)
    }

    enum State: Equatable {
        case waiting
        case running
        case done
        /// 이미 되어 있어서 건너뛰었다
        case skipped
        case failed(String)
    }

    let id: Int
    let action: Action
    var state: State = .waiting
    /// 실행 전 미리 본 문제. "충돌 2개" 같은 것
    var warning: String?

    var title: String {
        switch action {
        case .checkout(let branch): "\(branch) 체크아웃"
        case .merge(let source, let target): "\(source) → \(target) 머지"
        case .tag(let name, _): "태그 \(name)"
        case .deleteBranch(let branch): "\(branch) 삭제"
        case .push(let branch, let remote): "\(branch) → \(remote) 푸시"
        case .pushTag(let name, let remote): "태그 \(name) → \(remote) 푸시"
        }
    }
}

/// 마무리 흐름 하나. 시트를 닫아도 store에 남아서, 충돌을 풀고 돌아와 이어 갈 수 있다.
struct GitFlowRun: Equatable {
    let kind: GitFlowKind
    let branch: String
    var steps: [GitFlowStep]
    /// 시작 전에 막아야 하는 문제. 하나라도 있으면 실행하지 않는다.
    var blockers: [String] = []
    /// 막지는 않지만 알려야 하는 것
    var notes: [String] = []
    var isRunning = false
    /// 흐름을 준비한 워크트리. 다른 워크트리에서는 이어 가지 않는다.
    var worktreePath: String?
    /// 흐름을 준비한 저장소. 다른 저장소를 열면 흐름을 버린다.
    var repository: String?
    /// 끝나면 원격에 푸시하는지
    var pushes = false
    var pushRemote: String?
    /// 실행을 한 번이라도 시작했는지. 시작한 뒤에는 단계 구성을 바꾸지 않는다.
    var started = false
    /// 흐름을 시작하기 전 상태. 끝나면 이것과 끝난 상태로 되돌리기 기록 하나를 만든다.
    var before: RepositorySnapshot?

    /// 머지 단계의 대상 브랜치. 순서대로, 겹치지 않게
    var mergeTargets: [String] {
        var targets: [String] = []
        for step in steps {
            if case .merge(_, let target) = step.action, !targets.contains(target) { targets.append(target) }
        }
        return targets
    }

    var isFinished: Bool { steps.allSatisfy { $0.state == .done || $0.state == .skipped } }
    var failedStep: GitFlowStep? {
        steps.first { if case .failed = $0.state { return true } else { return false } }
    }

    /// 마무리 단계. 릴리스·핫픽스는 배포 브랜치에 머지하고 태그를 단 뒤 개발 브랜치에도 머지한다.
    /// 핫픽스는 진행 중인 릴리스 브랜치가 있으면 개발 브랜치 대신 그 릴리스에 머지한다(그 릴리스가 끝날 때 개발 브랜치로 간다).
    static func finishSteps(
        kind: GitFlowKind, branch: String, config: GitFlowConfig, openRelease: String?,
        pushRemote: String?, pushTargets: Bool
    ) -> [GitFlowAction] {
        var actions: [GitFlowStep.Action] = []
        var tagName: String?
        switch kind {
        case .feature, .bugfix:
            let base = config.finishBase(of: branch, kind: kind)
            actions += [.checkout(base), .merge(source: branch, target: base)]
        case .release, .hotfix:
            let tag = config.tagPrefix + config.version(of: branch, kind: kind)
            tagName = tag
            let back = backMergeTarget(kind: kind, branch: branch, config: config, openRelease: openRelease)
            actions += [
                .checkout(config.production), .merge(source: branch, target: config.production),
                .tag(name: tag, target: config.production),
                .checkout(back), .merge(source: branch, target: back),
            ]
        }
        actions.append(.deleteBranch(branch))
        if pushTargets, let remote = pushRemote {
            if kind.releases {
                actions.append(.push(branch: config.production, remote: remote))
                actions.append(.push(branch: backMergeTarget(kind: kind, branch: branch, config: config, openRelease: openRelease), remote: remote))
            } else {
                actions.append(.push(branch: config.finishBase(of: branch, kind: kind), remote: remote))
            }
            if let tagName { actions.append(.pushTag(name: tagName, remote: remote)) }
        }
        return actions
    }

    /// 릴리스·핫픽스를 배포 브랜치에 머지한 뒤 다시 머지할 곳.
    /// 핫픽스는 진행 중인 릴리스가 있으면 그 릴리스, 아니면 개발 브랜치. 릴리스는 적어 둔 기준(보통 개발 브랜치).
    private static func backMergeTarget(kind: GitFlowKind, branch: String, config: GitFlowConfig, openRelease: String?) -> String {
        kind == .hotfix ? (openRelease ?? config.development) : config.finishBase(of: branch, kind: kind)
    }
}

typealias GitFlowAction = GitFlowStep.Action
