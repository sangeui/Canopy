import Foundation

/// `git status --porcelain=v2`의 X/Y 한 글자에 대응한다.
enum ChangeKind: Character, Hashable {
    case modified = "M"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"
    case typeChanged = "T"
    case untracked = "?"
    case unmerged = "U"

    var label: String {
        switch self {
        case .modified: "수정됨"
        case .added: "추가됨"
        case .deleted: "삭제됨"
        case .renamed: "이름 바뀜"
        case .copied: "복사됨"
        case .typeChanged: "종류 바뀜"
        case .untracked: "추적 안 됨"
        case .unmerged: "충돌"
        }
    }
}

enum ChangeArea: String, Hashable {
    case staged
    case unstaged
    case untracked
    case conflicted
}

/// 작업 트리 또는 인덱스에서 바뀐 파일 하나.
/// 한 파일이 스테이징과 작업 트리 양쪽에서 바뀌면 `area`만 다른 값이 두 개 나온다.
struct FileChange: Identifiable, Hashable {
    let path: String
    let originalPath: String?
    let kind: ChangeKind
    let area: ChangeArea

    var id: String { area.rawValue + ":" + path }
    var fileName: String { (path as NSString).lastPathComponent }
    var directory: String { (path as NSString).deletingLastPathComponent }
    var isStaged: Bool { area == .staged }
}

struct StatusSnapshot: Hashable {
    var branch: String?
    var headOID: String?
    var upstream: String?
    var ahead = 0
    var behind = 0
    var changes: [FileChange] = []

    var isDetached: Bool { branch == "(detached)" }
    var staged: [FileChange] { changes.filter { $0.area == .staged } }
    var unstaged: [FileChange] { changes.filter { $0.area != .staged } }
}

struct Commit: Identifiable, Hashable {
    let hash: String
    let shortHash: String
    let authorName: String
    let authorEmail: String
    let date: Date
    let parents: [String]
    let refs: [String]
    let subject: String
    let body: String

    var id: String { hash }
    var isMerge: Bool { parents.count > 1 }
}

struct Branch: Identifiable, Hashable {
    /// `refs/heads/main`, `refs/remotes/origin/main`
    let fullName: String
    /// `main`, `origin/main`
    let name: String
    let isRemote: Bool
    /// 지금 보고 있는 워크트리의 HEAD인지
    let isHead: Bool
    let upstream: String?
    let ahead: Int
    let behind: Int
    /// 어떤 워크트리에든 체크아웃되어 있으면 그 경로
    let worktreePath: String?
    let shortHash: String
    /// 마지막 커밋 시각. 최근순 정렬에 쓴다.
    var date = Date.distantPast
    /// 마지막 커밋의 작성자. git은 브랜치를 만든 사람을 따로 기록하지 않는다.
    var authorName = ""
    /// 추적하던 원격 브랜치가 지워졌는지. `[gone]`
    var upstreamGone = false
    /// 끝 커밋의 전체 해시
    var hash = ""

    var id: String { fullName }

    /// `origin/feature/x` → `feature/x`
    var nameWithoutRemote: String {
        guard isRemote else { return name }
        return name.split(separator: "/", maxSplits: 1).dropFirst().joined()
    }
}

struct Worktree: Identifiable, Hashable {
    let path: String
    let head: String?
    /// `refs/heads/`를 뗀 브랜치 이름. detached면 nil.
    let branch: String?
    let isBare: Bool
    let isDetached: Bool
    /// `git worktree list`의 첫 항목
    let isMain: Bool
    let isLocked: Bool
    let isPrunable: Bool

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }

    var branchDisplay: String {
        if let branch { return branch }
        if isBare { return "bare 저장소" }
        if isDetached { return "HEAD 분리됨 (\(head?.prefix(7) ?? "?"))" }
        return ""
    }
}

struct DiffLine: Identifiable, Hashable {
    enum Kind { case context, addition, deletion, meta }

    let id: Int
    let kind: Kind
    let text: String
    let oldNumber: Int?
    let newNumber: Int?
    /// 짝이 되는 줄과 견줘 실제로 바뀐 글자 구간. 문자 오프셋.
    var marks: [Range<Int>] = []
}

struct DiffHunk: Identifiable, Hashable {
    let id: Int
    /// `@@ -33,9 +33,7 @@ class Foo` 원문
    let header: String
    var lines: [DiffLine]
    /// 내용 요약값. 읽을 때 한 번 계산해 두고 그린 글을 기억하는 열쇠로 쓴다. 0이면 아직 없다.
    var signature = 0

    /// 머리말 뒤에 git이 붙여 주는 문맥 (보통 둘러싼 선언)
    var context: String? {
        guard let close = header.range(of: "@@", options: .backwards), close.upperBound < header.endIndex else { return nil }
        let text = header[close.upperBound...].trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// 새 파일 기준 시작 줄
    var newStart: Int? {
        guard let plus = header.range(of: "+") else { return nil }
        let digits = header[plus.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }
}

struct DiffFile: Identifiable, Hashable {
    let id: Int
    var oldPath: String?
    var newPath: String?
    var hunks: [DiffHunk]
    var isBinary: Bool
    /// `index`, `new file mode`처럼 hunk 앞에 오는 줄
    var headerLines: [String]

    var displayPath: String { newPath ?? oldPath ?? "?" }
    var isRename: Bool {
        if let oldPath, let newPath { return oldPath != newPath }
        return false
    }
}

struct Stash: Identifiable, Hashable {
    /// `stash@{index}`의 index
    let index: Int
    let hash: String
    let date: Date
    /// "WIP on main: abc1234 subject" 또는 "On main: message"
    let message: String

    var id: String { hash }
    var ref: String { "stash@{\(index)}" }

    /// "On main: " 같은 머리말을 뗀 메시지
    var title: String {
        guard let range = message.range(of: ": ") else { return message }
        let rest = String(message[range.upperBound...])
        // "WIP on main: 1234567 Subject"는 git이 자동으로 붙인 것이라 앞의 해시를 뗀다.
        if message.hasPrefix("WIP on "), let space = rest.firstIndex(of: " "), rest[..<space].allSatisfy(\.isHexDigit) {
            return String(rest[rest.index(after: space)...])
        }
        return rest
    }

    var branch: String? {
        let prefix = message.hasPrefix("WIP on ") ? "WIP on " : (message.hasPrefix("On ") ? "On " : nil)
        guard let prefix, let colon = message.firstIndex(of: ":") else { return nil }
        return String(message[message.index(message.startIndex, offsetBy: prefix.count)..<colon])
    }
}

struct Tag: Identifiable, Hashable {
    let name: String
    /// 태그가 가리키는 커밋
    let targetHash: String
    let date: Date
    let subject: String
    let isAnnotated: Bool

    var id: String { "refs/tags/" + name }
}

struct Remote: Identifiable, Hashable {
    let name: String
    let url: String

    var id: String { name }

    /// 주소에서 `owner/repo`만. 원격 이름은 사용자가 붙인 것이라 실제로 어디인지 같이 보여 준다.
    /// `git@github.com:owner/repo.git`, `https://github.com/owner/repo`, `ssh://git@host/owner/repo.git` → `owner/repo`
    var repositoryPath: String {
        var text = url.trimmed
        if text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix(".git") { text.removeLast(4) }
        if let scheme = text.range(of: "://") {
            text = String(text[scheme.upperBound...])
            if let slash = text.firstIndex(of: "/") { text = String(text[text.index(after: slash)...]) }
        } else if !text.hasPrefix("/"), !text.hasPrefix("."), let colon = text.firstIndex(of: ":") {
            text = String(text[text.index(after: colon)...])
        } else {
            return (url as NSString).abbreviatingWithTildeInPath
        }
        let parts = text.split(separator: "/")
        return parts.suffix(2).joined(separator: "/")
    }

    /// 호스트 뒤의 전체 경로. GitLab 하위 그룹(`group/sub/project`)까지 남긴다. 웹 주소를 만들 때 쓴다.
    var webPath: String? {
        var text = url.trimmed
        if text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix(".git") { text.removeLast(4) }
        if text.contains("://") {
            guard let path = URL(string: text)?.path, path.count > 1 else { return nil }
            return String(path.dropFirst())
        }
        guard !text.hasPrefix("/"), !text.hasPrefix("."), let colon = text.firstIndex(of: ":") else { return nil }
        let path = text[text.index(after: colon)...]
        return path.isEmpty ? nil : String(path.hasPrefix("/") ? path.dropFirst() : path)
    }

    /// 주소의 호스트. `git@github.com:owner/repo.git`, `https://github.com/owner/repo`, `ssh://git@github.com/owner/repo` → `github.com`
    var host: String? {
        let text = url.trimmed
        let host: String
        if text.contains("://") {
            guard let found = URL(string: text)?.host?.lowercased() else { return nil }
            host = found
        } else {
            guard !text.hasPrefix("/"), !text.hasPrefix("."), let colon = text.firstIndex(of: ":") else { return nil }
            let userHost = text[..<colon]
            host = String(userHost.split(separator: "@").last ?? Substring(userHost)).lowercased()
        }
        // 443번 포트로 SSH를 쓰는 GitHub 주소, 계정을 여럿 쓸 때 흔한 SSH 별칭(`github.com-work`)
        if host == "ssh.github.com" || host.hasPrefix("github.com-") { return "github.com" }
        if host.hasPrefix("gitlab.com-") { return "gitlab.com" }
        return host
    }

    /// 웹 주소에 쓸 호스트. https 주소에 포트가 있으면 붙인다(사내 GitLab 등). SSH 포트는 웹과 상관없어서 뺀다.
    var webHost: String? {
        guard let host else { return nil }
        if url.trimmed.lowercased().hasPrefix("https://"), let port = URL(string: url.trimmed)?.port { return "\(host):\(port)" }
        return host
    }
}

/// 진행 중인 머지/리베이스 같은 작업. `.git` 안의 표시 파일로 알아낸다.
/// 브랜치에 붙어 있지 않을 때 지금 어디인지. 상단 바 제목에 쓴다.
struct DetachedPlace: Hashable {
    /// 리베이스 중인 브랜치. git은 리베이스하는 동안 HEAD를 떼어 두고 원래 이름을 `head-name`에 남긴다.
    var rebasingBranch: String?
    /// 리베이스에서 지금 몇 번째 커밋인지와 전체 수
    var step: Int?
    var total: Int?
    /// HEAD를 가리키는 태그
    var tag: String?
}

enum RepositoryOperation: Hashable {
    case merging
    case rebasing
    case cherryPicking
    case reverting

    var title: String {
        switch self {
        case .merging: "머지 진행 중"
        case .rebasing: "리베이스 진행 중"
        case .cherryPicking: "체리픽 진행 중"
        case .reverting: "리버트 진행 중"
        }
    }

    var command: String {
        switch self {
        case .merging: "merge"
        case .rebasing: "rebase"
        case .cherryPicking: "cherry-pick"
        case .reverting: "revert"
        }
    }
}

enum ResetMode: String, CaseIterable, Identifiable {
    case soft, mixed, hard
    var id: String { rawValue }

    var title: String {
        switch self {
        case .soft: "소프트 (변경을 스테이징에 남김)"
        case .mixed: "믹스드 (변경을 작업 트리에 남김)"
        case .hard: "하드 (변경을 모두 버림)"
        }
    }
}

extension DiffHunk {
    var additions: Int { lines.filter { $0.kind == .addition }.count }
    var deletions: Int { lines.filter { $0.kind == .deletion }.count }

    /// `git apply`에 넘길 수 있는 모양으로 hunk를 다시 쓴다.
    var patchBody: String {
        var text = header + "\n"
        for line in lines {
            switch line.kind {
            case .context: text += " " + line.text + "\n"
            case .addition: text += "+" + line.text + "\n"
            case .deletion: text += "-" + line.text + "\n"
            case .meta: text += "\\ " + line.text + "\n"
            }
        }
        return text
    }
}

extension DiffFile {
    var additions: Int { hunks.reduce(0) { $0 + $1.additions } }
    var deletions: Int { hunks.reduce(0) { $0 + $1.deletions } }

    /// hunk 하나만 담은 패치. 추적 중인 파일에만 쓴다.
    /// 고른 줄만 담은 패치. `reverse`는 이 패치를 `--reverse`로 적용할 때(스테이징 해제, 버리기).
    /// 앞으로 적용(스테이징): 고르지 않은 `-` 줄은 그대로 두니 문맥이 되고, 고르지 않은 `+` 줄은 아직 없으니 뺀다.
    /// 거꾸로 적용: 고르지 않은 `+` 줄은 남아 있으니 문맥이 되고, 고르지 않은 `-` 줄은 이미 없으니 뺀다.
    /// 고른 줄 중에 바뀐 줄이 없으면 nil. 줄 수는 `git apply --recount`가 다시 센다.
    func patch(for hunk: DiffHunk, selecting ids: Set<Int>, reverse: Bool) -> String? {
        guard hunk.lines.contains(where: { ids.contains($0.id) && ($0.kind == .addition || $0.kind == .deletion) }) else { return nil }
        var body = ""
        var oldCount = 0, newCount = 0
        var lastKept = true
        for line in hunk.lines {
            let selected = ids.contains(line.id)
            switch line.kind {
            case .context:
                body += " " + line.text + "\n"; oldCount += 1; newCount += 1; lastKept = true
            case .addition:
                if selected {
                    body += "+" + line.text + "\n"; newCount += 1; lastKept = true
                } else if reverse {
                    body += " " + line.text + "\n"; oldCount += 1; newCount += 1; lastKept = true
                } else {
                    lastKept = false
                }
            case .deletion:
                if selected {
                    body += "-" + line.text + "\n"; oldCount += 1; lastKept = true
                } else if reverse {
                    lastKept = false
                } else {
                    body += " " + line.text + "\n"; oldCount += 1; newCount += 1; lastKept = true
                }
            case .meta:
                // "\ No newline at end of file"은 바로 앞 줄에 붙는다. 앞 줄을 뺐으면 같이 뺀다.
                if lastKept { body += "\\ " + line.text + "\n" }
            }
        }
        let start = DiffParser.hunkStart(hunk.header)
        let header = "@@ -\(start.old),\(oldCount) +\(start.new),\(newCount) @@\n"
        let old = oldPath.map { "a/" + $0 } ?? "/dev/null"
        // 지운 파일에서 일부 줄만 고르면 파일은 남는다. 그때는 /dev/null 대신 원래 경로.
        let new = newPath.map { "b/" + $0 } ?? oldPath.map { "b/" + $0 } ?? "/dev/null"
        let gitLine = "diff --git \(oldPath.map { "a/" + $0 } ?? new) \(newPath.map { "b/" + $0 } ?? new)\n"
        return gitLine + "--- \(old)\n+++ \(new)\n" + header + body
    }

    func patch(for hunk: DiffHunk) -> String {
        let old = oldPath.map { "a/" + $0 } ?? "/dev/null"
        let new = newPath.map { "b/" + $0 } ?? "/dev/null"
        let gitLine = "diff --git \(oldPath.map { "a/" + $0 } ?? new) \(newPath.map { "b/" + $0 } ?? old)\n"
        return gitLine + "--- \(old)\n+++ \(new)\n" + hunk.patchBody
    }
}

/// reflog 한 줄. "무슨 일이 있었나"를 보여 줄 때 쓴다.
struct ActivityEntry: Identifiable, Hashable {
    enum Kind: Hashable {
        case checkout, commit, amend, merge, pull, push, reset, rebase, cherryPick, revert, clone, other

        var symbol: String {
            switch self {
            case .checkout: "arrow.triangle.swap"
            case .commit: "circle.fill"
            case .amend: "pencil.circle"
            case .merge: "arrow.triangle.merge"
            case .pull: "arrow.down.to.line"
            case .push: "arrow.up.to.line"
            case .reset: "arrow.uturn.backward"
            case .rebase: "arrow.triangle.branch"
            case .cherryPick: "leaf"
            case .revert: "arrow.counterclockwise"
            case .clone: "square.and.arrow.down"
            case .other: "circle"
            }
        }
    }

    /// `HEAD@{n}`의 n
    let index: Int
    let hash: String
    let shortHash: String
    let date: Date
    let kind: Kind
    /// 우리말로 풀어 쓴 한 줄
    let title: String
    /// git이 남긴 원문
    let raw: String

    var id: String { "\(index):\(hash)" }
}

/// 이 앱에서 지운 브랜치. 되살릴 수 있게 이름과 가리키던 커밋을 남긴다.
struct DeletedBranch: Codable, Identifiable, Hashable {
    let name: String
    let hash: String
    let date: Date
    /// 원격에서 지운 브랜치면 그 원격. 되살리면 이 원격에 다시 올린다.
    var remote: String?

    var id: String { (remote.map { $0 + "/" } ?? "") + name + "@" + hash }
    var displayName: String { (remote.map { $0 + "/" } ?? "") + name }
}

/// 브랜치 둘을 견준 결과. `head`가 `base`보다 얼마나 앞서고 뒤처졌는지와 바뀐 양.
struct BranchComparison: Hashable {
    let base: String
    let head: String
    let ahead: Int
    let behind: Int
    let stat: DiffStat
    /// head를 base에 합쳐 본 결과. 합칠 커밋이 없으면 nil.
    var preview: MergePreview?
}

/// 실제로 합치지 않고 계산만 해 본 머지 결과. `git merge-tree --write-tree`
struct MergePreview: Hashable {
    /// 합친 결과 트리. 충돌 파일에는 충돌 표시가 들어 있다.
    let tree: String
    /// 충돌하는 파일 경로
    let conflicts: [String]

    var isClean: Bool { conflicts.isEmpty }

    /// "BannerView.swift, HomeViewController.swift 외 2개"
    var conflictSummary: String {
        let names = conflicts.prefix(2).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        return conflicts.count > 2 ? names + " 외 \(conflicts.count - 2)개" : names
    }
}

/// `git blame` 한 줄. 어느 커밋이 이 줄을 마지막으로 바꿨는지.
struct BlameLine: Identifiable, Hashable {
    let number: Int
    let hash: String
    let author: String
    let date: Date
    let summary: String
    let text: String

    var id: Int { number }
    var shortHash: String { String(hash.prefix(7)) }
}

/// `git diff --numstat`를 합친 값.
struct DiffStat: Hashable {
    var files = 0
    var additions = 0
    var deletions = 0

    static let empty = DiffStat()
}


/// 사이드바 고정·별명·정렬을 저장소별로 저장한다.
struct SidebarPreferences: Codable, Hashable {
    var pinned: [String] = []
    var aliases: [String: String] = [:]
    var sorts: [String: String] = [:]
}

enum SidebarSortOrder: String, CaseIterable, Identifiable {
    case name, date
    var id: String { rawValue }
    var title: String { self == .name ? "이름순" : "최근순" }
}

/// 고정과 별명의 열쇠. 같은 종류 안에서 이름이 같으면 같은 항목으로 본다.
enum PreferenceKey {
    static func branch(_ branch: Branch) -> String { "branch:" + branch.name }
    static func tag(_ tag: Tag) -> String { "tag:" + tag.name }
    static func worktree(_ worktree: Worktree) -> String { "worktree:" + worktree.path }
    static func stash(_ stash: Stash) -> String { "stash:" + stash.hash }
}
