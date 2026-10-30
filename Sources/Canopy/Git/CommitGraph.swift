import Foundation

/// 그래프에서 선 하나를 차지하는 브랜치.
struct GraphOwner: Identifiable, Hashable {
    let id: String
    /// 화면에 적는 이름
    let name: String
    let colorIndex: Int
    let isHead: Bool
    /// 머지된 뒤 참조가 사라져서 이름을 커밋 메시지에서 추측한 브랜치
    let isMerged: Bool
}

/// 커밋 목록 한 줄에 그릴 그래프 정보.
struct GraphRow: Hashable {
    /// 이 커밋의 점이 놓이는 열
    let lane: Int
    /// 이 줄에서 쓰는 열 수
    let laneCount: Int
    /// 위에서 아래로 그냥 지나가는 열
    let through: [Int]
    /// 위에서 점으로 들어오는 선이 있는지 (같은 브랜치의 자식 커밋이 위에 있음)
    let hasIncoming: Bool
    /// 다른 열에서 위로부터 점으로 들어오는 선. 다른 브랜치가 이 커밋에서 갈라져 나갔다.
    var incomingFrom: [Int] = []
    /// 점에서 아래로 나가는 열. 첫 번째가 첫 부모.
    let outgoing: [Int]
    /// 열마다 그 열을 쓰는 브랜치의 색 번호. 안 쓰는 열은 -1
    let laneColors: [Int]
    /// 열마다 그 열을 쓰는 브랜치. 선 이름표와 강조에 쓴다.
    let laneOwners: [String?]
    let ownerID: String
}

struct CommitGraphResult {
    var rows: [GraphRow] = []
    var ownerByHash: [String: String] = [:]
    var owners: [String: GraphOwner] = [:]
    /// 처음 등장한 순서대로. 범례에 쓴다.
    var legend: [GraphOwner] = []
    var maxLaneCount = 0
    /// 머지 커밋 설명. "feature/login → main 머지"
    var mergeDescriptions: [String: String] = [:]

    func owner(of hash: String) -> GraphOwner? {
        ownerByHash[hash].flatMap { owners[$0] }
    }
}

/// 커밋마다 "어느 브랜치 소속인지"를 먼저 정하고, 브랜치 하나에 열 하나를 준다.
///
/// 소속은 각 브랜치 끝에서 첫 번째 부모만 따라 내려가며 정한다. 먼저 걷는 브랜치가 커밋을 가져가므로
/// 걷는 순서가 곧 소속이다. 기준 브랜치(develop, main 같은 오래 가는 것)를 먼저 걷고, 그다음은
/// 끝이 더 깊은(오래된) 브랜치부터 걷는다. 그래야 feature 브랜치가 develop에서 갈라진 뒤 자기가
/// 담고 있는 develop의 옛 커밋까지 가져가지 않는다. 같은 끝을 여러 참조가 가리키면
/// 현재 브랜치 → 로컬 → 원격 → 태그 순서로 이름을 쓴다. 머지되어 사라진 브랜치는
/// 머지 커밋의 두 번째 부모부터 따로 묶는다.
enum CommitGraph {
    /// 선 색의 수. `Theme.graphPalette`의 개수와 같아야 한다.
    static let colorCount = 10

    /// 따로 알려 주지 않아도 기준 브랜치로 보는 이름
    static let defaultBaseNames: Set<String> = ["main", "master", "develop", "trunk"]

    static func build(_ commits: [Commit], remoteNames: [String], baseNames: Set<String> = CommitGraph.defaultBaseNames) -> CommitGraphResult {
        var result = CommitGraphResult()
        guard !commits.isEmpty else { return result }

        var byHash: [String: Commit] = [:]
        for commit in commits { byHash[commit.hash] = commit }

        // 1. 브랜치 끝(tip)을 우선순위대로 모은다.
        enum Kind: Int { case head, local, remote, tag }
        var tips: [(kind: Kind, name: String, hash: String)] = []
        for commit in commits {
            for ref in commit.refs {
                if ref.hasPrefix("HEAD -> ") {
                    tips.append((.head, String(ref.dropFirst(8)), commit.hash))
                } else if ref == "HEAD" {
                    tips.append((.head, "HEAD", commit.hash))
                } else if ref.hasPrefix("tag: ") {
                    tips.append((.tag, String(ref.dropFirst(5)), commit.hash))
                } else if remoteNames.contains(where: { ref.hasPrefix($0 + "/") }) {
                    tips.append((.remote, ref, commit.hash))
                } else {
                    tips.append((.local, ref, commit.hash))
                }
            }
        }
        var indexByHash: [String: Int] = [:]
        for (index, commit) in commits.enumerated() { indexByHash[commit.hash] = index }
        func isBase(_ name: String) -> Bool {
            if baseNames.contains(name) { return true }
            let withoutRemote = name.split(separator: "/", maxSplits: 1).dropFirst().joined()
            return remoteNames.contains(where: { name.hasPrefix($0 + "/") }) && baseNames.contains(withoutRemote)
        }
        // 기준 브랜치 먼저, 그다음 끝이 깊은 순, 같은 끝이면 현재 → 로컬 → 원격 → 태그.
        tips.sort { a, b in
            let aBase = isBase(a.name), bBase = isBase(b.name)
            if aBase != bBase { return aBase }
            let aIndex = indexByHash[a.hash] ?? 0, bIndex = indexByHash[b.hash] ?? 0
            if aIndex != bIndex { return aIndex > bIndex }
            return a.kind.rawValue < b.kind.rawValue
        }

        var nextColor = 0
        func register(id: String, name: String, isHead: Bool, isMerged: Bool) {
            guard result.owners[id] == nil else { return }
            let owner = GraphOwner(id: id, name: name, colorIndex: nextColor, isHead: isHead, isMerged: isMerged)
            nextColor += 1
            result.owners[id] = owner
            result.legend.append(owner)
        }
        func walk(from start: String, ownerID: String) {
            var hash = start
            while let commit = byHash[hash], result.ownerByHash[hash] == nil {
                result.ownerByHash[hash] = ownerID
                guard let parent = commit.parents.first else { break }
                hash = parent
            }
        }

        // 2. 끝에서 첫 부모를 따라 내려가며 소속을 정한다.
        var headOwnerID: String?
        for tip in tips where result.ownerByHash[tip.hash] == nil {
            let id = "ref:" + tip.name
            register(id: id, name: tip.name, isHead: tip.kind == .head, isMerged: false)
            if tip.kind == .head { headOwnerID = id }
            walk(from: tip.hash, ownerID: id)
        }

        // 3. 머지된 뒤 사라진 브랜치는 머지 커밋의 두 번째 부모부터 묶는다.
        for commit in commits where commit.parents.count > 1 {
            for (position, parent) in commit.parents.enumerated() where position > 0 && result.ownerByHash[parent] == nil {
                let id = "merged:\(commit.hash):\(position)"
                register(id: id, name: mergedBranchName(from: commit.subject), isHead: false, isMerged: true)
                walk(from: parent, ownerID: id)
            }
        }

        // 4. 그래도 남은 커밋
        for commit in commits where result.ownerByHash[commit.hash] == nil {
            register(id: "other", name: "기타", isHead: false, isMerged: false)
            walk(from: commit.hash, ownerID: "other")
        }

        // 5. 머지 설명
        for commit in commits where commit.parents.count > 1 {
            let into = result.owner(of: commit.parents[0])?.name ?? "?"
            let from = commit.parents.dropFirst().compactMap { result.owner(of: $0)?.name }.joined(separator: ", ")
            result.mergeDescriptions[commit.hash] = "\(from) → \(into) 머지"
        }

        // 6. 브랜치마다 열을 준다. 현재 브랜치는 0번 열을 예약해 둔다.
        var lanes: [String?] = []
        var headPlaced = false
        // 색은 열을 처음 받을 때 정한다. 지금 그려지고 있는 다른 선과 겹치지 않는 색을 고른다.
        // 브랜치 순서대로 돌려 쓰면 같은 색 선이 나란히 놓여 어느 선이 어느 브랜치인지 헷갈린다.
        var colorOf: [String: Int] = [:]
        var lastColor = 0
        func assignColor(_ ownerID: String) {
            guard colorOf[ownerID] == nil else { return }
            if ownerID == headOwnerID {
                colorOf[ownerID] = 0
                return
            }
            let busy = Set(lanes.compactMap { $0 }.compactMap { colorOf[$0] })
            // 현재 브랜치 색(0)은 남겨 두고, 바로 전에 쓴 색 다음부터 찾는다
            let order = (0..<(Self.colorCount - 1)).map { 1 + (lastColor + $0) % (Self.colorCount - 1) }
            let color = order.first { !busy.contains($0) } ?? order[0]
            colorOf[ownerID] = color
            lastColor = color
        }
        /// 연결선. 부모 브랜치의 열이 아직 시작되지 않았을 때 부모 커밋 줄까지 따로 내려가는 선이다.
        /// 부모 브랜치의 열을 바로 열면 그 브랜치 끝 커밋 위로 선이 이어져 그 커밋의 자식처럼 보인다.
        var edgeTarget: [String: String] = [:]
        /// 연결선을 낸 브랜치. 강조와 선 이름표에 쓴다.
        var edgeOwner: [String: String] = [:]
        /// 이 줄에서 들어온 연결선이 비운 열. 이 줄의 다른 선이 그 열을 가져가지 않게 잠깐 막는다.
        let blocked = "\u{0}blocked"

        func allocate(_ ownerID: String) -> Int {
            assignColor(ownerID)
            if ownerID == headOwnerID {
                headPlaced = true
                if lanes.isEmpty { lanes.append(ownerID) } else { lanes[0] = ownerID }
                return 0
            }
            let start = (headOwnerID != nil && !headPlaced) ? 1 : 0
            while lanes.count < start { lanes.append(nil) }
            if let free = lanes.indices.first(where: { $0 >= start && lanes[$0] == nil }) {
                lanes[free] = ownerID
                return free
            }
            lanes.append(ownerID)
            return lanes.count - 1
        }

        // 브랜치마다 그 브랜치 커밋이 나오는 줄 번호. 열에 다음으로 올 커밋이 정말 부모인지 볼 때 쓴다.
        var ownerRows: [String: [Int]] = [:]
        for (row, commit) in commits.enumerated() {
            ownerRows[result.ownerByHash[commit.hash] ?? "other", default: []].append(row)
        }
        func nextRow(of owner: String, after row: Int) -> Int? {
            ownerRows[owner]?.first { $0 > row }
        }

        for (row, commit) in commits.enumerated() {
            let before = lanes
            let ownerID = result.ownerByHash[commit.hash] ?? "other"
            // 위에서 이 커밋으로 오는 연결선. 열을 비워서 이 커밋이 그 열을 이어받을 수 있게 한다.
            let arriving = lanes.indices.filter { lanes[$0].flatMap { edgeTarget[$0] } == commit.hash }
            for index in arriving { lanes[index] = nil }
            let lane = lanes.firstIndex(of: ownerID) ?? allocate(ownerID)
            let hasIncoming = before.indices.contains(lane) && (before[lane] == ownerID || arriving.contains(lane))
            let incomingFrom = arriving.filter { $0 != lane }
            for index in incomingFrom { lanes[index] = blocked }

            let continues = commit.parents.first.map { result.ownerByHash[$0] == ownerID } ?? false
            if !continues {
                lanes[lane] = nil
            }
            var outgoing: [Int] = []
            for (position, parent) in commit.parents.enumerated() {
                let parentOwner = result.ownerByHash[parent] ?? "other"
                // 부모 브랜치의 열이 열려 있어도, 그 열에 다음으로 올 커밋이 부모가 아니면 바로 합류하지 않는다.
                // 합류하면 그 사이 커밋(부모보다 최근)에서 갈라진 것처럼 보인다.
                if let active = lanes.firstIndex(of: parentOwner), nextRow(of: parentOwner, after: row) == indexByHash[parent] {
                    outgoing.append(active)
                } else if byHash[parent] != nil {
                    let id = "edge:\(commit.hash):\(position)"
                    edgeTarget[id] = parent
                    edgeOwner[id] = ownerID
                    colorOf[id] = colorOf[ownerID]
                    // 첫 부모로 가는 선은 자기 열을 그대로 쓴다
                    if position == 0, lanes[lane] == nil {
                        lanes[lane] = id
                        outgoing.append(lane)
                    } else {
                        outgoing.append(allocate(id))
                    }
                } else {
                    // 부모가 목록 밖이면(개수 제한, 범위 밖) 예전처럼 그 브랜치 열로 보낸다
                    outgoing.append(allocate(parentOwner))
                }
            }
            for index in incomingFrom where lanes[index] == blocked { lanes[index] = nil }

            var through: [Int] = []
            for index in before.indices where index != lane {
                if let id = before[index], index < lanes.count, lanes[index] == id {
                    through.append(index)
                }
            }
            let laneCount = max(before.count, lanes.count, lane + 1)
            var colors = Array(repeating: -1, count: laneCount)
            var laneOwners: [String?] = Array(repeating: nil, count: laneCount)
            for index in 0..<laneCount {
                let id = (index < lanes.count ? lanes[index] : nil) ?? (index < before.count ? before[index] : nil)
                if index == lane {
                    colors[index] = colorOf[ownerID] ?? -1
                    laneOwners[index] = ownerID
                } else if let id {
                    colors[index] = colorOf[id] ?? -1
                    laneOwners[index] = edgeOwner[id] ?? id
                }
            }
            result.rows.append(GraphRow(
                lane: lane,
                laneCount: laneCount,
                through: through,
                hasIncoming: hasIncoming,
                incomingFrom: incomingFrom,
                outgoing: outgoing,
                laneColors: colors,
                laneOwners: laneOwners,
                ownerID: ownerID
            ))
            result.maxLaneCount = max(result.maxLaneCount, laneCount)
            while let last = lanes.last, last == nil, lanes.count > 1 {
                lanes.removeLast()
            }
        }
        // 이름 옆 색점도 선과 같은 색이어야 한다
        for (id, owner) in result.owners {
            guard let color = colorOf[id] else { continue }
            result.owners[id] = GraphOwner(id: owner.id, name: owner.name, colorIndex: color, isHead: owner.isHead, isMerged: owner.isMerged)
        }
        result.legend = result.legend.compactMap { result.owners[$0.id] }
        return result
    }

    /// "Merge branch 'feature/x' into main" 같은 메시지에서 브랜치 이름을 꺼낸다.
    static func mergedBranchName(from subject: String) -> String {
        if let open = subject.firstIndex(of: "'"),
           let close = subject[subject.index(after: open)...].firstIndex(of: "'") {
            let name = subject[subject.index(after: open)..<close]
            if !name.isEmpty { return String(name) + " (머지됨)" }
        }
        if let range = subject.range(of: "from ") {
            let rest = subject[range.upperBound...].split(separator: " ").first.map(String.init) ?? ""
            if let slash = rest.firstIndex(of: "/") {
                return String(rest[rest.index(after: slash)...]) + " (머지됨)"
            }
            if !rest.isEmpty { return rest + " (머지됨)" }
        }
        return "머지된 브랜치"
    }

    /// 주어진 커밋에 포함된 조상 집합 (목록 안에서만 찾는다).
    static func ancestors(of hash: String, in commits: [Commit]) -> Set<String> {
        var byHash: [String: Commit] = [:]
        for commit in commits { byHash[commit.hash] = commit }
        var seen: Set<String> = [hash]
        var queue = [hash]
        while let current = queue.popLast() {
            guard let commit = byHash[current] else { continue }
            for parent in commit.parents where !seen.contains(parent) {
                seen.insert(parent)
                queue.append(parent)
            }
        }
        return seen
    }
}
