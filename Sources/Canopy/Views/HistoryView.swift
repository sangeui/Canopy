import SwiftUI

/// 모든 브랜치의 커밋을 그래프와 함께 보여 준다.
struct HistoryView: View {
    @Environment(RepositoryStore.self) private var store
    @AppStorage("historyCompact") private var compact = false
    @State private var expandedGroups: Set<String> = []

    var body: some View {
        @Bindable var store = store
        if !store.hasHead {
            EmptyState(
                title: "아직 커밋이 없습니다",
                message: "파일을 스테이징하고 첫 커밋을 만들어 보세요.",
                systemImage: "point.3.connected.trianglepath.dotted"
            )
        } else {
            VStack(spacing: 0) {
                // 폭이 모자라면 아이콘 버튼 넷을 메뉴 하나로 접는다. 검색 상자가 아이콘만 남을 만큼 줄어들면 안 된다.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        SearchField(text: $store.commitFilter, placeholder: "메시지, 작성자, 해시로 찾기", focusRequest: store.commitSearchFocusRequest)
                            .frame(minWidth: 180)
                        scopeTabs
                        toolButtons
                    }
                    HStack(spacing: 8) {
                        SearchField(text: $store.commitFilter, placeholder: "찾기", focusRequest: store.commitSearchFocusRequest)
                            .frame(minWidth: 120)
                        scopeTabs
                        Menu {
                            Button("HEAD 커밋으로 이동") { store.jumpToHead() }
                                .disabled(store.headCommit == nil)
                            Toggle("구조만 보기", isOn: $compact)
                            Toggle("선택한 커밋에 포함된 커밋만 강조", isOn: $store.highlightsAncestors)
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.text)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        GraphHelpButton()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
                .onChange(of: compact) { expandedGroups = [] }
                if store.isFilteringCommits {
                    CodeSearchBar()
                        .padding(.horizontal, 14)
                        .padding(.bottom, 6)
                } else if let note = store.historyScopeNote {
                    HStack {
                        Text(note)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
                }
                CommitList(
                    commits: store.filteredCommits,
                    graph: store.isFilteringCommits ? nil : store.graph,
                    selectedID: store.selectedCommitID,
                    selectedIDs: store.selectedCommitIDs,
                    baseHashes: store.isFilteringCommits ? [] : store.historyInfo.baseHashes,
                    baseName: store.historyInfo.base,
                    compact: compact && !store.isFilteringCommits,
                    expandedGroups: $expandedGroups,
                    select: { id in
                        // 변경 목록과 같이 Shift는 범위, ⌘는 하나씩
                        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
                        store.selectCommit(id, extend: flags.contains(.shift), toggle: flags.contains(.command))
                    }
                )
                .overlay(alignment: .bottom) {
                    if store.selectedCommits.count > 1 {
                        CommitSelectionBar(commits: store.selectedCommits)
                            .padding(12)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.15), value: store.selectedCommits.count > 1)
            }
        }
    }

    private var scopeTabs: some View {
        @Bindable var store = store
        return UnderlineTabs(
            tabs: RepositoryStore.HistoryScope.allCases,
            selection: $store.historyScope,
            title: { $0.title }
        )
        .help(scopeHelp)
    }

    /// 범위 탭 설명. 기준 브랜치 이름을 넣어 무엇이 보이는지 구체적으로 적는다.
    private var scopeHelp: String {
        let base = store.historyBase ?? "기준 브랜치"
        return "이 브랜치: 이 브랜치와 추적 브랜치의 커밋. \(base)에 이미 있는 커밋은 흐리게, 갈라진 곳에 줄을 긋습니다\n모든 브랜치: 브랜치, 태그, 원격을 전부 날짜순으로"
    }

    private var toolButtons: some View {
        @Bindable var store = store
        return HStack(spacing: 8) {
            Button { store.jumpToHead() } label: {
                Image(systemName: "location")
            }
            .buttonStyle(IconButtonStyle(size: 28))
            .help("HEAD 커밋으로 이동")
            .disabled(store.headCommit == nil)
            Toggle(isOn: $compact) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
            }
            .toggleStyle(.button)
            .buttonStyle(IconButtonStyle(size: 28))
            .help("구조만 보기: 갈라지고 합쳐진 곳만 남기고 평범한 연속 커밋은 접습니다")
            Toggle(isOn: $store.highlightsAncestors) {
                Image(systemName: "scope")
            }
            .toggleStyle(.button)
            .buttonStyle(IconButtonStyle(size: 28))
            .help("선택한 커밋에 포함된 커밋만 강조합니다")
            GraphHelpButton()
        }
    }
}

struct BranchHistoryView: View {
    @Environment(RepositoryStore.self) private var store
    let branch: Branch

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: branch.isRemote ? "cloud" : "arrow.triangle.branch")
                        .foregroundStyle(Theme.secondary)
                    Text(branch.name)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // 현재 브랜치인지는 상단 바 제목과 사이드바 체크가 이미 말한다
                    if let alias = store.alias(for: PreferenceKey.branch(branch)) {
                        AliasChip(alias: alias)
                    }
                    Spacer()
                    if let path = branch.worktreePath, path != store.activeWorktreePath {
                        Button("워크트리로 전환") {
                            store.sidebarSelection = nil
                            Task { await store.activateWorktree(path) }
                        }
                        .buttonStyle(PillButtonStyle(compact: true))
                    } else if !branch.isHead {
                        Button("체크아웃") { Task { await store.checkout(branch) } }
                            .buttonStyle(PillButtonStyle(prominent: true, compact: true))
                            .disabled(store.isBusy)
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    // 현재 브랜치의 추적 상태는 머리글 아래 상태 줄이 이미 보여 준다.
                    if let upstream = branch.upstream {
                        row("추적") {
                            HStack(spacing: 6) {
                                Text(upstream).lineLimit(1).truncationMode(.middle)
                                if branch.ahead > 0 { Text("올릴 커밋 \(branch.ahead)개") }
                                if branch.behind > 0 { Text("받아 올 커밋 \(branch.behind)개") }
                                if branch.ahead == 0, branch.behind == 0 { Text("같음").foregroundStyle(Theme.secondary) }
                            }
                        }
                    }
                    // 다른 워크트리에 체크아웃된 브랜치일 때만 어디인지 적는다. 마지막 커밋과 커밋 수는 바로 아래 목록이 보여 준다.
                    if let path = branch.worktreePath, path != store.activeWorktreePath {
                        row("체크아웃") {
                            Text((path as NSString).lastPathComponent)
                        }
                    }
                    if !branch.isRemote {
                        // 무엇과 견주는지 이름표를 붙인다. 없으면 위 "추적" 줄과 섞여 추적 브랜치로 읽힌다.
                        row("비교") { ComparisonLine(branch: branch) }
                    }
                }
                .font(.system(size: 12))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            HairlineDivider()
            RefCommitList()
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .frame(minWidth: 64, alignment: .leading)
                .fixedSize()
            content()
        }
    }
}

/// 브랜치 머리말의 비교 줄. 기준을 고르면 앞섬·뒤처짐과 바뀐 양을 적고, 변경 전체를 열 수 있다.
private struct ComparisonLine: View {
    @Environment(RepositoryStore.self) private var store
    let branch: Branch

    private var candidates: [Branch] {
        store.branches.filter { !$0.isRemote && $0.name != branch.name }
    }

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(candidates) { candidate in
                    Button(candidate.name) { store.compareBase = candidate.name }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(store.comparison?.base ?? store.compareBase ?? "기준 선택")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Theme.raised, in: Capsule())
                .contentShape(Capsule())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("어느 브랜치와 견줄지 고릅니다")
            if let comparison = store.comparison {
                // 폭이 모자라면 줄 수 → 파일 수 순으로 통째로 뺀다. 줄바꿈은 하지 않는다.
                ViewThatFits(in: .horizontal) {
                    comparisonFacts(comparison, files: true, lines: true)
                    comparisonFacts(comparison, files: true, lines: false)
                    comparisonFacts(comparison, files: false, lines: false)
                }
            } else if candidates.isEmpty {
                Text("견줄 브랜치가 없습니다").foregroundStyle(Theme.secondary)
            }
        }
        .monospacedDigit()
    }

    /// "커밋 2개 · 파일 5개 +79 −9 · 기준에 새 커밋 3개   변경 보기". 0인 것은 적지 않는다.
    private func comparisonFacts(_ comparison: BranchComparison, files: Bool, lines: Bool) -> some View {
        HStack(spacing: 6) {
            if comparison.ahead == 0, comparison.stat.files == 0 {
                Text(comparison.behind > 0 ? "\(comparison.head)에만 있는 커밋 없음" : "차이 없음").foregroundStyle(Theme.secondary)
            } else {
                if comparison.ahead > 0 {
                    Text(verbatim: "\(comparison.head)에만 있는 커밋 \(comparison.ahead)개").help("\(comparison.base)에 없는 \(comparison.head)의 커밋")
                }
                if files, comparison.stat.files > 0 {
                    dot
                    Text(verbatim: "파일 \(comparison.stat.files)개")
                }
                if lines { DiffCountLabel(additions: comparison.stat.additions, deletions: comparison.stat.deletions) }
            }
            if let preview = comparison.preview {
                dot
                if preview.isClean {
                    Text("충돌 없음")
                        .foregroundStyle(Theme.secondary)
                        .help("합쳐 보니 충돌이 없습니다\n\(comparison.head) → \(comparison.base)")
                } else {
                    Text(verbatim: "충돌 \(preview.conflicts.count)개")
                        .foregroundStyle(Theme.orange)
                        .help("\(comparison.base)에 합치면 충돌하는 파일\n" + preview.conflicts.joined(separator: "\n"))
                }
            }
            if comparison.behind > 0 {
                dot
                Text(verbatim: "\(comparison.base)에만 있는 커밋 \(comparison.behind)개")
                    .foregroundStyle(Theme.secondary)
                    .help("\(comparison.head)에 아직 들어오지 않은 \(comparison.base)의 커밋")
            }
            if comparison.stat.files > 0 {
                Button("변경 보기") { store.showComparison() }
                    .buttonStyle(TextButtonStyle())
                    .padding(.leading, 4)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    /// 사실 사이의 틈. 점을 찍지 않고 간격으로만 나눈다.
    private var dot: some View {
        Color.clear.frame(width: 4, height: 1)
    }
}

struct TagHistoryView: View {
    @Environment(RepositoryStore.self) private var store
    let tag: Tag

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "tag")
                    .foregroundStyle(Theme.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tag.name)
                        .font(.system(size: 14, weight: .semibold))
                    (tag.isAnnotated ? Text("주석 태그  ").foregroundStyle(Theme.tertiary) + Text(tag.subject) : Text(tag.subject))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("삭제…") { store.deleteTag(tag) }
                    .buttonStyle(PillButtonStyle(compact: true))
                    .disabled(store.isBusy)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            HairlineDivider()
            RefCommitList()
        }
    }
}

/// 그래프 읽는 법을 알려 주는 작은 도움말.
private struct GraphHelpButton: View {
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: "questionmark.circle")
        }
        .buttonStyle(IconButtonStyle(size: 28))
        .help("그래프 읽는 법")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("그래프 읽는 법")
                    .font(.system(size: 13, weight: .semibold))
                helpRow("circle.fill", "점 하나가 커밋 하나입니다. 위가 최신입니다.")
                helpRow("line.diagonal", "세로선 하나가 브랜치 하나입니다. 목록 위 줄에 지금 보이는 선의 이름이 왼쪽부터 순서대로 나옵니다.")
                helpRow("hand.point.up.left", "선이나 그 이름에 마우스를 올리면 그 브랜치만 밝게 남고 나머지는 흐려집니다.")
                helpRow("arrow.triangle.branch", "선이 옆으로 갈라져 나오면 그 자리에서 새 브랜치를 만든 것입니다.")
                helpRow("arrow.triangle.merge", "선이 다른 선으로 들어가면 머지입니다. 머지 커밋은 테두리만 있는 점으로 그리고, 무엇을 어디에 합쳤는지 적어 둡니다.")
                helpRow("scope", "커밋을 고르면 그 커밋이 담은 커밋만 밝게 남습니다. 흐려진 커밋은 아직 그 브랜치에 없는 것입니다.")
                helpRow("tag", "이름표는 브랜치와 태그가 지금 가리키는 커밋입니다.")
            }
            .padding(16)
            .frame(width: 360)
        }
    }

    private func helpRow(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 12))
        }
    }
}

struct CommitList: View {
    @Environment(RepositoryStore.self) private var store
    let commits: [Commit]
    /// nil이면 그래프를 그리지 않는다 (검색 중)
    let graph: CommitGraphResult?
    let selectedID: Commit.ID?
    /// 여러 개 고른 커밋. 고른 것처럼 칠한다.
    var selectedIDs: Set<Commit.ID> = []
    /// 기준 브랜치에 이미 있는 커밋. 글자를 흐리게 하고, 처음 나오는 줄 위에 갈라진 곳을 표시한다.
    var baseHashes: Set<String> = []
    var baseName: String?
    /// 평범한 연속 커밋을 접을지
    var compact = false
    var expandedGroups: Binding<Set<String>>?
    let select: (Commit.ID?) -> Void

    static let rowHeight: CGFloat = 48
    static let dayHeight: CGFloat = 26

    /// 소속 브랜치 이름을 적을 커밋. 바로 위 줄과 소속이 같으면 이름을 다시 적지 않는다.
    /// 같은 브랜치의 커밋이 줄줄이 이어질 때 같은 이름이 모든 줄에 반복되지 않게 한다. 날짜가 바뀌어도 다시 적는다.
    static func ownerStarts(_ items: [HistoryItem], graph: CommitGraphResult?) -> Set<String> {
        guard let graph else { return [] }
        var starts: Set<String> = []
        var previous: String?
        for item in items {
            switch item {
            case .commit(let commit, _, let day):
                let owner = graph.ownerByHash[commit.hash]
                if owner != previous || day != nil { starts.insert(commit.hash) }
                previous = owner
            case .group(let commits, _, _):
                previous = commits.last.flatMap { graph.ownerByHash[$0.hash] }
            }
        }
        return starts
    }
    static let laneWidth: CGFloat = 16

    /// 목록 맨 위에 보이는 줄. 선 이름 줄이 이 줄의 선을 보여 준다.
    @State private var topItemID: String?
    @State private var focus = GraphFocus()

    var body: some View {
        if commits.isEmpty {
            EmptyState(title: "커밋이 없습니다", message: "검색어와 맞는 커밋이 없거나 아직 커밋이 없습니다.")
        } else {
            let layout = HistoryLayout(commits: commits, graph: graph, compact: compact, expanded: expandedGroups?.wrappedValue ?? [], selectedID: selectedID)
            let graphWidth = CGFloat(min(graph?.maxLaneCount ?? 0, 12)) * Self.laneWidth
            let ownerStarts = Self.ownerStarts(layout.items, graph: graph)
            // 목록에서 기준 브랜치 커밋이 처음 나오는 줄. 그 위에 "갈라진 곳"을 적는다.
            let forkHash: String? = baseHashes.isEmpty ? nil : layout.items.lazy.compactMap { item -> String? in
                if case .commit(let commit, _, _) = item, baseHashes.contains(commit.hash) { return commit.hash }
                return nil
            }.first
            VStack(spacing: 0) {
                if let graph, graph.maxLaneCount > 1 {
                    LaneLegend(graph: graph, rows: focus.row.map { [$0] } ?? visibleRows(in: layout))
                }
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(layout.items) { item in
                            switch item {
                            case .commit(let commit, let row, let day):
                                CommitRow(
                                    commit: commit,
                                    graphRow: row,
                                    graphWidth: graphWidth,
                                    owner: graph?.owner(of: commit.hash),
                                    showsOwner: ownerStarts.contains(commit.hash),
                                    mergeDescription: graph?.mergeDescriptions[commit.hash],
                                    day: day,
                                    // 무엇이 흐린지는 위 안내 줄이 말하니, 여기는 잘리지 않게 짧게
                                    marker: commit.hash == forkHash ? baseName.map { "\($0)에서 갈라진 곳" } : nil,
                                    inBase: baseHashes.contains(commit.hash),
                                    isSelected: selectedID == commit.id || selectedIDs.contains(commit.id),
                                    isDimmed: store.isDimmed(commit),
                                    select: { select(commit.id) }
                                )
                                .contextMenu { CommitMenu(commit: commit) }
                            case .group(let commits, let row, let day):
                                GroupRow(
                                    commits: commits,
                                    graphRow: row,
                                    graphWidth: graphWidth,
                                    owner: graph?.owner(of: commits[0].hash),
                                    day: day,
                                    isDimmed: !commits.contains { !store.isDimmed($0) }
                                ) {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        _ = expandedGroups?.wrappedValue.insert(commits[0].hash)
                                    }
                                }
                            }
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .scrollPosition(id: $topItemID, anchor: .top)
                .onChange(of: store.scrollTargetHash) {
                    guard let hash = store.scrollTargetHash else { return }
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo("c:" + hash, anchor: .center)
                    }
                    store.scrollTargetHash = nil
                }
                }
            }
            .environment(focus)
        }
    }

    /// 화면에 보이는 줄들의 그래프. 맨 위 줄부터 한 화면 남짓을 본다. 아직 스크롤하지 않았으면 첫 줄부터.
    private func visibleRows(in layout: HistoryLayout) -> [GraphRow] {
        let start = topItemID.flatMap { id in layout.items.firstIndex { $0.id == id } } ?? 0
        return layout.items.dropFirst(start).prefix(18).compactMap { item in
            switch item {
            case .commit(_, let row, _): row
            case .group(_, let row, _): row
            }
        }
    }
}

/// 그래프에서 마우스를 올린 선. 그 브랜치만 밝게 남기고, 선 이름 줄은 마우스가 있는 줄을 기준으로 바뀐다.
@Observable
final class GraphFocus {
    var owner: String?
    var row: GraphRow?
}

/// 목록 위 한 줄. 지금 보이는 그래프 선이 각각 어느 브랜치인지 왼쪽부터 순서대로 적는다.
/// 선은 이름이 끝(가장 위 커밋)에만 붙어 있어서, 스크롤하면 어느 선이 무엇인지 알 수 없었다.
private struct LaneLegend: View {
    @Environment(GraphFocus.self) private var focus
    let graph: CommitGraphResult
    let rows: [GraphRow]

    /// 왼쪽 열부터, 같은 열이면 위에 나오는 것부터. 그래프에서 선이 놓인 순서와 같다.
    private var owners: [GraphOwner] {
        var seen: Set<String> = []
        var found: [(column: Int, row: Int, id: String)] = []
        for (rowIndex, row) in rows.enumerated() {
            for (column, id) in row.laneOwners.enumerated() {
                guard let id, seen.insert(id).inserted else { continue }
                found.append((column, rowIndex, id))
            }
        }
        return found
            .sorted { ($0.column, $0.row) < ($1.column, $1.row) }
            .compactMap { graph.owners[$0.id] }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(owners) { owner in
                    let isFocused = focus.owner == owner.id
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Theme.graphColor(owner.colorIndex))
                            .frame(width: 3, height: 12)
                        Text(owner.name)
                            .font(.system(size: 11, weight: isFocused ? .semibold : .regular))
                            .foregroundStyle(isFocused ? Theme.text : Theme.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .opacity(focus.owner == nil || isFocused ? 1 : 0.4)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        focus.owner = inside ? owner.id : nil
                    }
                    .help(owner.isMerged ? "\(owner.name)\n머지된 뒤 지워진 브랜치라 머지 메시지에서 이름을 읽었습니다" : owner.name)
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 24)
        .animation(.easeInOut(duration: 0.12), value: focus.owner)
        .help("그래프의 선을 왼쪽부터 순서대로 적었습니다. 올리면 그 브랜치만 밝게 남습니다")
    }
}

/// 커밋 줄 위에 얹는 날짜. 캔버스는 커밋 줄이 그리므로 선이 끊기지 않는다.
private struct DayLabel: View {
    let date: Date?
    var marker: String?

    var body: some View {
        HStack(spacing: 8) {
            if let date {
                Text(date, format: .dateTime.year().month().day().weekday(.abbreviated))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondary)
            }
            if let marker {
                Label(marker, systemImage: "arrow.triangle.branch")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
            }
            Rectangle().fill(marker == nil ? Theme.border : Theme.accent.opacity(0.5)).frame(height: 1)
        }
        .frame(height: CommitList.dayHeight)
        .padding(.trailing, 10)
    }
}

/// 접힌 커밋 묶음.
private struct GroupRow: View {
    let commits: [Commit]
    let graphRow: GraphRow?
    let graphWidth: CGFloat
    let owner: GraphOwner?
    var day: Date?
    let isDimmed: Bool
    let expand: () -> Void
    @State private var hovering = false

    private var height: CGFloat { CommitList.rowHeight + (day == nil ? 0 : CommitList.dayHeight) }

    var body: some View {
        HStack(spacing: 0) {
            if let graphRow, graphWidth > 0 {
                GraphCanvas(row: graphRow, isMerge: false, isGroup: true, topInset: day == nil ? 0 : CommitList.dayHeight)
                    .frame(width: graphWidth, height: height)
                    .padding(.trailing, 6)
            }
            VStack(alignment: .leading, spacing: 0) {
            if let day { DayLabel(date: day) }
            HStack(spacing: 6) {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(owner.map { Theme.graphColor($0.colorIndex) } ?? Theme.secondary)
                Text("커밋 \(commits.count)개")
                    .font(.system(size: 12, weight: .medium))
                if let owner {
                    Text(owner.name)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                }
                Text(commits.last!.date, format: .dateTime.month(.defaultDigits).day())
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                Text("~")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                Text(commits.first!.date, format: .dateTime.month(.defaultDigits).day())
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                Spacer()
                Text("펼치기")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .opacity(hovering ? 1 : 0)
            }
            .frame(height: CommitList.rowHeight)
            .opacity(isDimmed ? 0.35 : 1)
            .padding(.trailing, 10)
            }
        }
        .padding(.leading, 8)
        // 스크롤할 때마다 LazyVStack이 줄 크기를 묻는다. 높이가 정해져 있으니 안쪽을 재지 않고 바로 답한다.
        .fixedRow(height: height)
        .background(hovering ? Theme.hover : Color.clear, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
        .contentShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
        .onTapGesture(perform: expand)
        .onHover { hovering = $0 }
        .help("같은 브랜치의 평범한 커밋 \(commits.count)개를 접었습니다. 누르면 펼칩니다.")
    }
}

/// 커밋을 여러 개 골랐을 때 목록 아래에 뜨는 막대. 우클릭을 몰라도 할 수 있는 일이 보인다.
private struct CommitSelectionBar: View {
    @Environment(RepositoryStore.self) private var store
    let commits: [Commit]

    var body: some View {
        // 가운데 칸이 좁으면(오른쪽 패널을 연 작은 창) 글자 버튼이 잘린다. 그때는 아이콘 버튼으로 줄인다.
        SmoothFit(options: [false, true]) { compact in
            bar(compact: compact)
        }
        .disabled(store.isBusy)
    }

    private func bar(compact: Bool) -> some View {
        HStack(spacing: compact ? 2 : 8) {
            Text("커밋 \(commits.count)개")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .padding(.leading, 6)
            Spacer(minLength: compact ? 4 : 12)
            action("하나로 합치기", symbol: "arrow.triangle.merge", compact: compact, help: "붙어 있는 커밋을 하나로 합칩니다") {
                store.sheet = .squashCommits(commits.map(\.hash))
            }
            action("체리픽", symbol: "arrow.uturn.right", compact: compact, help: "현재 브랜치에 오래된 커밋부터 차례로 옮깁니다") {
                store.cherryPick(commits)
            }
            action("패치로 복사", symbol: "doc.on.doc", compact: compact, help: "패치로 복사합니다") {
                Task { await store.copyPatch(commits) }
            }
            action("선택 해제", symbol: "xmark", compact: compact, help: "여러 개 선택한 것을 해제합니다") {
                store.selectCommit(store.selectedCommitID)
            }
        }
        .padding(compact ? 6 : 8)
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        .fixedSize()
    }

    @ViewBuilder
    private func action(_ title: String, symbol: String, compact: Bool, help: String, _ run: @escaping () -> Void) -> some View {
        if compact {
            Button(action: run) { Image(systemName: symbol) }
                .buttonStyle(IconButtonStyle(size: 28))
                .help(title + "\n" + help)
        } else {
            Button(title, action: run)
                .buttonStyle(PillButtonStyle(compact: true))
                .help(help)
        }
    }
}

/// 검색 중일 때 결과 수와 함께 "코드에서 찾기"를 둔다. 메시지 검색과 코드 검색을 그 자리에서 오간다.
private struct CodeSearchBar: View {
    @Environment(RepositoryStore.self) private var store

    var body: some View {
        HStack(spacing: 8) {
            if let results = store.codeSearchResults {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondary)
                Text("코드에 \"\(store.codeSearchQuery)\"가 생기거나 사라진 커밋 \(results.count)개")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("메시지에서 찾기") { store.clearCodeSearch() }
                    .buttonStyle(PillButtonStyle(compact: true))
            } else if store.isSearchingCode {
                ProgressView().controlSize(.small)
                Text("코드에서 찾는 중… 큰 저장소는 몇 초 걸립니다")
                    .lineLimit(1)
                Spacer()
                Button("취소") { store.clearCodeSearch() }
                    .buttonStyle(PillButtonStyle(compact: true))
            } else {
                Text("메시지, 작성자, 해시에서 \(store.filteredCommits.count)개")
                    .lineLimit(1)
                Spacer()
                Button("코드에서 찾기") { Task { await store.searchCode() } }
                    .buttonStyle(PillButtonStyle(compact: true))
                    .help("이 글자가 코드에 생기거나 사라진 커밋을 지금 범위에서 찾습니다")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.secondary)
    }
}

struct CommitMenu: View {
    @Environment(RepositoryStore.self) private var store
    let commit: Commit

    var body: some View {
        // 여러 개 고른 커밋 위에서 눌렀으면 고른 것 모두에 대한 메뉴를 먼저
        let selection = store.selectedCommits
        if selection.count > 1, selection.contains(where: { $0.id == commit.id }) {
            Button("커밋 \(selection.count)개 하나로 합치기…") { store.sheet = .squashCommits(selection.map(\.hash)) }
            Button("커밋 \(selection.count)개 체리픽…") { store.cherryPick(selection) }
            Button("커밋 \(selection.count)개 패치로 복사") { Task { await store.copyPatch(selection) } }
            Divider()
        }
        Button("여기서 새 브랜치…") {
            store.newBranchBase = commit.hash
            store.sheet = .newBranch
        }
        Button("태그 만들기…") { store.sheet = .newTag(commit.hash) }
        Button("이 커밋 체크아웃…") { store.checkoutCommit(commit) }
        Divider()
        // 커밋 정리: 지금 브랜치의 커밋이어야 한다. 아니면 누를 때 이유를 알린다.
        Button("메시지 수정…") { store.sheet = .rewordCommit(commit.hash) }
        Button("이 커밋 삭제…") { store.dropCommit(commit) }
        Button("여기부터 커밋 정리…") { store.sheet = .cleanupCommits(commit.hash) }
        Divider()
        Button("현재 브랜치에 체리픽") { Task { await store.cherryPick(commit) } }
        Button("리버트…") { store.revert(commit) }
        Menu("현재 브랜치를 여기로 리셋") {
            ForEach(ResetMode.allCases) { mode in
                Button(mode.title) { store.reset(to: commit, mode: mode) }
            }
        }
        Divider()
        Button("해시 복사") { store.copyHash(commit) }
        Button("패치로 복사") { Task { await store.copyPatch([commit]) } }
    }
}

struct CommitRow: View {
    @Environment(GraphFocus.self) private var focus: GraphFocus?
    let commit: Commit
    let graphRow: GraphRow?
    let graphWidth: CGFloat
    let owner: GraphOwner?
    /// 위 줄과 소속이 다를 때만 이름을 적는다. 같으면 색점만 둔다.
    var showsOwner = true
    let mergeDescription: String?
    var day: Date?
    /// 날짜 줄 자리에 같이 적는 표시. "develop에서 갈라진 곳"
    var marker: String?
    /// 기준 브랜치에 이미 있는 커밋. 글자만 흐리게(그래프는 그대로)
    var inBase = false
    let isSelected: Bool
    let isDimmed: Bool
    let select: () -> Void
    @State private var hovering = false

    private var hasHeader: Bool { day != nil || marker != nil }
    private var height: CGFloat { CommitList.rowHeight + (hasHeader ? CommitList.dayHeight : 0) }

    /// 그래프에서 다른 브랜치를 강조하고 있으면 이 줄은 흐리게
    private var isOutOfFocus: Bool {
        guard let highlighted = focus?.owner else { return false }
        return graphRow?.ownerID != highlighted
    }

    var body: some View {
        HStack(spacing: 0) {
            if let graphRow, graphWidth > 0 {
                GraphCanvas(row: graphRow, isMerge: commit.isMerge, topInset: hasHeader ? CommitList.dayHeight : 0)
                    .frame(width: graphWidth, height: height)
                    .padding(.trailing, 6)
            }
            VStack(alignment: .leading, spacing: 0) {
            if hasHeader { DayLabel(date: day, marker: marker) }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    ForEach(commit.refs, id: \.self) { ref in
                        RefBadge(ref: ref)
                    }
                    Text(commit.subject)
                        .font(.system(size: 13))
                        .foregroundStyle(inBase ? Theme.secondary : Theme.text)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    if let owner, showsOwner {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Theme.graphColor(owner.colorIndex))
                                .frame(width: 6, height: 6)
                            Text(owner.name)
                                .lineLimit(1)
                        }
                    }
                    if let mergeDescription {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.triangle.merge")
                                .font(.system(size: 9))
                            Text(mergeDescription)
                                .lineLimit(1)
                        }
                        .foregroundStyle(Theme.purple)
                    }
                    Text(commit.authorName)
                        .lineLimit(1)
                    Text(commit.date, format: .relative(presentation: .named))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(commit.shortHash)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .fixedSize()
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
            }
            .frame(height: CommitList.rowHeight)
            .opacity(isDimmed ? 0.35 : (isOutOfFocus ? 0.45 : 1))
            .padding(.trailing, 10)
            }
        }
        .padding(.leading, 8)
        // 스크롤할 때마다 LazyVStack이 줄 크기를 묻는다. 높이가 정해져 있으니 안쪽을 재지 않고 바로 답한다.
        .fixedRow(height: height)
        .background(alignment: .bottom) {
            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                .fill(isSelected ? Theme.raised : (hovering ? Theme.hover : Color.clear))
                .frame(height: CommitList.rowHeight)
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: isDimmed)
    }
}

/// 한 줄의 그래프. 열마다 세로선, 점, 갈라지고 합쳐지는 곡선을 그린다.
struct GraphCanvas: View {
    @Environment(GraphFocus.self) private var focus: GraphFocus?
    let row: GraphRow
    let isMerge: Bool
    var isGroup = false
    /// 위에 날짜가 얹힌 줄이면 그만큼 점을 아래로 내린다. 선은 맨 위부터 이어 그린다.
    var topInset: CGFloat = 0

    var body: some View {
        // 바깥에서 읽어야 강조가 바뀔 때 다시 그린다
        let highlighted = focus?.owner
        Canvas { context, size in
            let lane = CommitList.laneWidth
            func x(_ index: Int) -> CGFloat { CGFloat(index) * lane + lane / 2 }
            func color(_ index: Int) -> Color {
                let base = index < row.laneColors.count ? Theme.graphColor(row.laneColors[index]) : Theme.tertiary
                guard let highlighted else { return base }
                let owner = index < row.laneOwners.count ? row.laneOwners[index] : nil
                return owner == highlighted ? base : base.opacity(0.15)
            }
            let height = size.height
            let center = topInset + (height - topInset) / 2
            let dotX = x(max(row.lane, 0))
            let width: CGFloat = 2

            for index in row.through where x(index) < size.width {
                var path = Path()
                path.move(to: CGPoint(x: x(index), y: 0))
                path.addLine(to: CGPoint(x: x(index), y: height))
                context.stroke(path, with: .color(color(index)), lineWidth: width)
            }
            if row.hasIncoming {
                var path = Path()
                path.move(to: CGPoint(x: dotX, y: 0))
                path.addLine(to: CGPoint(x: dotX, y: center))
                context.stroke(path, with: .color(color(row.lane)), lineWidth: width)
            }
            // 옆 열에서 내려와 이 커밋으로 합쳐지는 선. 그 브랜치가 여기서 갈라져 나갔다.
            for source in row.incomingFrom where x(source) < size.width + lane {
                var path = Path()
                path.move(to: CGPoint(x: x(source), y: 0))
                path.addCurve(
                    to: CGPoint(x: dotX, y: center),
                    control1: CGPoint(x: x(source), y: center),
                    control2: CGPoint(x: dotX, y: 0)
                )
                context.stroke(path, with: .color(color(source)), lineWidth: width)
            }
            for target in row.outgoing where x(target) < size.width + lane {
                var path = Path()
                path.move(to: CGPoint(x: dotX, y: center))
                if target == row.lane {
                    path.addLine(to: CGPoint(x: dotX, y: height))
                } else {
                    path.addCurve(
                        to: CGPoint(x: x(target), y: height),
                        control1: CGPoint(x: dotX, y: height),
                        control2: CGPoint(x: x(target), y: center)
                    )
                }
                context.stroke(path, with: .color(color(target)), lineWidth: width)
            }

            guard row.lane >= 0 else { return }
            if isGroup {
                // 접힌 묶음은 점 대신 짧은 막대 세 개
                for offset in [-7.0, 0.0, 7.0] {
                    let dot = Path(ellipseIn: CGRect(x: dotX - 2, y: center + offset - 2, width: 4, height: 4))
                    context.fill(dot, with: .color(color(row.lane)))
                }
                return
            }
            let radius: CGFloat = isMerge ? 4.5 : 4
            let dot = Path(ellipseIn: CGRect(x: dotX - radius, y: center - radius, width: radius * 2, height: radius * 2))
            if isMerge {
                context.fill(dot, with: .color(Theme.surface))
                context.stroke(dot, with: .color(color(row.lane)), lineWidth: 2)
            } else {
                context.fill(dot, with: .color(color(row.lane)))
            }
        }
        // 마우스가 있는 열의 브랜치를 강조한다. 점이 아니라 지나가는 선 위에 올려도 그 선의 브랜치가 된다.
        .onContinuousHover { phase in
            guard let focus else { return }
            switch phase {
            case .active(let point):
                let index = Int(point.x / CommitList.laneWidth)
                let owner = row.laneOwners.indices.contains(index) ? row.laneOwners[index] : nil
                if focus.owner != owner { focus.owner = owner }
                if focus.row != row { focus.row = row }
            case .ended:
                focus.owner = nil
                focus.row = nil
            }
        }
    }
}

struct RefBadge: View {
    @Environment(RepositoryStore.self) private var store
    let ref: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 9))
            Text(label)
                .font(.system(size: 11, weight: isHead ? .semibold : .medium))
        }
        .foregroundStyle(color)
        .lineLimit(1)
    }

    private var symbol: String {
        if isTag { return "tag" }
        if isRemote { return "cloud" }
        return "arrow.triangle.branch"
    }

    private var isHead: Bool { ref.hasPrefix("HEAD -> ") || ref == "HEAD" }
    private var isTag: Bool { ref.hasPrefix("tag: ") }
    /// `origin/develop`처럼 원격 이름으로 시작하는지. `feature/a` 같은 로컬 브랜치도 `/`가 들어 있어서 이름만으로는 모른다.
    private var isRemote: Bool { !isHead && !isTag && store.remoteNames.contains { ref.hasPrefix($0 + "/") } }

    private var label: String {
        if ref.hasPrefix("HEAD -> ") { return String(ref.dropFirst(8)) }
        if ref.hasPrefix("tag: ") { return String(ref.dropFirst(5)) }
        return ref
    }

    private var color: Color {
        if isHead { return Theme.green }
        if isTag { return Theme.orange }
        if isRemote { return Theme.purple }
        return Theme.blue
    }
}


/// 사이드바에서 고른 브랜치·태그의 커밋 목록. 화면은 바로 바뀌고, 목록은 읽어 오는 대로 채운다.
private struct RefCommitList: View {
    @Environment(RepositoryStore.self) private var store

    var body: some View {
        if store.refCommitsName == (store.selectedBranch?.name ?? store.selectedTag?.name) {
            VStack(spacing: 0) {
                if let name = store.refCommitsName, let note = store.refScopeNote(for: name) {
                    HStack {
                        Text(note).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                }
                CommitList(
                    commits: store.refCommits,
                    graph: store.refGraph,
                    selectedID: store.selectedRefCommitID,
                    baseHashes: store.refHistoryInfo.baseHashes,
                    baseName: store.refHistoryInfo.base,
                    select: { store.selectCommit($0) }
                )
            }
            .transition(.opacity)
        } else {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("커밋을 읽는 중…").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// 높이가 정해진 줄. 받은 폭과 정한 높이를 바로 답해서, 바깥이 크기를 물을 때 안쪽 글자·배지 배치까지 재지 않게 한다.
/// `.frame(maxWidth: .infinity)`는 크기를 답하려고 안쪽을 끝까지 재서, 긴 목록을 스크롤할 때 프레임이 밀렸다.
struct FixedRowLayout: Layout {
    let height: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
        }
    }
}

extension View {
    func fixedRow(height: CGFloat) -> some View {
        FixedRowLayout(height: height) { self.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading) }
    }
}
