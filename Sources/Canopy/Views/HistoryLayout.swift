import Foundation

/// 히스토리 목록 한 줄.
enum HistoryItem: Identifiable {
    /// 날짜가 바뀌는 첫 줄이면 `day`에 그 날짜가 들어간다. 줄 위에 날짜를 얹어 그린다.
    case commit(Commit, GraphRow?, day: Date?)
    /// 같은 브랜치의 평범한 커밋을 접은 것. 그래프 줄은 첫 커밋의 것을 쓴다.
    case group([Commit], GraphRow?, day: Date?)

    var id: String {
        switch self {
        case .commit(let commit, _, _): "c:" + commit.hash
        case .group(let commits, _, _): "g:" + commits[0].hash
        }
    }
}

/// 커밋 목록을 날짜 구분선과 접힌 묶음이 섞인 줄로 바꾼다.
struct HistoryLayout {
    let items: [HistoryItem]

    init(commits: [Commit], graph: CommitGraphResult?, compact: Bool, expanded: Set<String>, selectedID: Commit.ID?) {
        let rows = graph?.rows ?? []
        let structural = compact ? Self.structuralHashes(commits: commits, graph: graph, selectedID: selectedID) : []
        let calendar = Calendar.current

        var items: [HistoryItem] = []
        var pending: [(Commit, GraphRow?, Date?)] = []
        var lastDay: Date?

        func flush() {
            guard !pending.isEmpty else { return }
            if pending.count == 1 || expanded.contains(pending[0].0.hash) {
                items += pending.map { HistoryItem.commit($0.0, $0.1, day: $0.2) }
            } else {
                items.append(.group(pending.map(\.0), pending[0].1, day: pending[0].2))
            }
            pending = []
        }

        for (index, commit) in commits.enumerated() {
            let row = index < rows.count ? rows[index] : nil
            let day = calendar.startOfDay(for: commit.date)
            var dayLabel: Date?
            if day != lastDay {
                dayLabel = day
                lastDay = day
            }
            guard compact else {
                items.append(.commit(commit, row, day: dayLabel))
                continue
            }
            if structural.contains(commit.hash) {
                flush()
                items.append(.commit(commit, row, day: dayLabel))
            } else if dayLabel != nil || (pending.last.map { graph?.ownerByHash[$0.0.hash] != graph?.ownerByHash[commit.hash] } ?? false) {
                // 날짜가 바뀌거나 브랜치가 바뀌면 묶음을 끊는다.
                flush()
                pending = [(commit, row, dayLabel)]
            } else {
                pending.append((commit, row, nil))
            }
        }
        flush()

        self.items = items
    }

    /// 접지 않을 커밋. 브랜치 끝과 시작, 머지와 그 출처, 분기점, 이름표가 있는 것, 고른 것.
    static func structuralHashes(commits: [Commit], graph: CommitGraphResult?, selectedID: Commit.ID?) -> Set<String> {
        var result: Set<String> = []
        var seenOwner: Set<String> = []
        func owner(_ hash: String) -> String { graph?.ownerByHash[hash] ?? "" }
        for commit in commits {
            let id = owner(commit.hash)
            if !commit.refs.isEmpty || commit.isMerge || commit.parents.isEmpty || commit.id == selectedID {
                result.insert(commit.hash)
            }
            for parent in commit.parents.dropFirst() { result.insert(parent) }
            if let first = commit.parents.first, owner(first) != id {
                result.insert(commit.hash)
                result.insert(first)
            }
            if !seenOwner.contains(id) {
                seenOwner.insert(id)
                result.insert(commit.hash)
            }
        }
        if let last = commits.last { result.insert(last.hash) }
        return result
    }

}
