import SwiftUI
import UniformTypeIdentifiers

/// 사이드바 섹션. 순서를 바꿀 수 있어서 저장한다.
enum SidebarSection: String, CaseIterable, Identifiable {
    case workspace, pinned, worktrees, branches, stashes, tags, remotes
    var id: String { rawValue }

    var title: String {
        switch self {
        case .workspace: "작업"
        case .pinned: "고정"
        case .worktrees: "워크트리"
        case .branches: "로컬"
        case .stashes: "스태시"
        case .tags: "태그"
        case .remotes: "원격"
        }
    }
}

struct SidebarView: View {
    @Environment(RepositoryStore.self) private var store
    @AppStorage("sidebarOrder") private var orderRaw = ""
    @AppStorage("sidebarCollapsed") private var collapsedRaw = ""
    @State private var collapsedFolders: Set<String> = []
    @State private var showsAllTags = false
    @State private var dropTarget: SidebarSection?
    @State private var filter = ""

    private var query: String { filter.trimmed.lowercased() }
    private var isFiltering: Bool { !query.isEmpty }

    private static let tagLimit = 6

    private var order: [SidebarSection] {
        var result = orderRaw.split(separator: ",").compactMap { SidebarSection(rawValue: String($0)) }
        // 고정은 나중에 생긴 섹션이라 저장된 순서에 없다. 없으면 작업 바로 아래에 둔다.
        if !result.contains(.pinned) { result.insert(.pinned, at: min(1, result.count)) }
        for section in SidebarSection.allCases where !result.contains(section) { result.append(section) }
        // 고정한 것이 없으면 섹션을 보이지 않는다
        if pinnedItems.isEmpty { result.removeAll { $0 == .pinned } }
        // 워크트리가 메인 하나뿐이면 섹션을 보여 줄 이유가 없다. 아래 저장소 카드가 그 역할을 한다.
        if store.worktrees.count < 2 { result.removeAll { $0 == .worktrees } }
        // "작업" 칸은 왼쪽 아이콘 줄(SidebarRail)로 옮겼다. 저장된 순서에 남아 있어도 그리지 않는다.
        result.removeAll { $0 == .workspace }
        return result
    }

    private var collapsedSections: Set<SidebarSection> {
        Set(collapsedRaw.split(separator: ",").compactMap { SidebarSection(rawValue: String($0)) })
    }

    var body: some View {
        content
            // 현재 브랜치가 든 폴더는 펼친다. 체크아웃하면 접혀 있던 폴더 안으로 들어가 안 보이는 일이 없게.
            .onAppear { expandFolders(of: store.currentBranch?.name) }
            .onChange(of: store.currentBranch?.name) { expandFolders(of: store.currentBranch?.name) }
    }

    /// `release/26.45.01` → `release` 폴더를, `a/b/c` → `a`, `a/b`를 펼친다
    private func expandFolders(of name: String?) {
        guard let name else { return }
        var path = ""
        for part in name.split(separator: "/").dropLast() {
            path = path.isEmpty ? String(part) : path + "/" + part
            collapsedFolders.remove(path)
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            // 상단 바 첫 줄. 신호등 버튼은 이 줄 위의 제목 표시줄에 있다.
            // 사이드바 버튼은 제목 표시줄의 신호등 버튼 옆에 고정돼 있다(WindowChrome.keepSidebarToggle)
            SearchField(text: $filter, placeholder: "찾기")
                .frame(height: StatusBand.height)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // 지금 브랜치는 로컬 섹션 안에서 찾게 두지 않고 맨 위에 따로 둔다
                    if !isFiltering, store.hasHead {
                        CurrentBranchCard()
                            .contextMenu { if let branch = store.currentBranch { branchMenu(branch) } }
                    }
                    if isFiltering {
                        FilteredRows(query: query, branchRow: { branchRow($0, displayName: $0.name) }, tagRow: { tagRow($0, displayName: $0.name) })
                    }
                    ForEach(isFiltering ? [] : order) { section in
                        sectionView(section)
                            .overlay(alignment: .top) {
                                if dropTarget == section {
                                    Capsule().fill(Theme.accent).frame(height: 2).padding(.horizontal, 8)
                                }
                            }
                            .dropDestination(for: String.self) { items, _ in
                                guard let raw = items.first, let moved = SidebarSection(rawValue: raw) else { return false }
                                move(moved, before: section)
                                return true
                            } isTargeted: { targeted in
                                dropTarget = targeted ? section : (dropTarget == section ? nil : dropTarget)
                            }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
                .animation(.easeInOut(duration: 0.2), value: orderRaw)
                .environment(\.rowVerticalPadding, 7)
            }
            HairlineDivider()
            OpenRepositoryMenu()
                .padding(10)
        }
        .background(Theme.sidebar)
    }

    // MARK: 섹션

    @ViewBuilder
    private func sectionView(_ section: SidebarSection) -> some View {
        let collapsed = collapsedSections.contains(section)
        VStack(alignment: .leading, spacing: 2) {
            SidebarSectionHeader(
                title: section.title,
                isCollapsed: collapsed,
                toggle: { toggleCollapsed(section) },
                plusHelp: plusHelp(for: section),
                plusAction: plusAction(for: section),
                sortOrder: sortable(section) ? sortOrder(of: section) : nil,
                setSortOrder: { store.setSortOrder($0, for: section.rawValue) },
                moveUp: order.first == section ? nil : { shift(section, by: -1) },
                moveDown: order.last == section ? nil : { shift(section, by: 1) }
            )
            .modifier(SectionDrag(section: section))
            if !collapsed {
                // Group에 건 수식어는 안의 행 하나하나에 붙는다. 행은 클릭을 받으려고 제스처를 갖고 있어서
                // 바깥 섹션에만 끌기를 걸면 행 위에서는 끌기가 시작되지 않는다.
                Group {
                switch section {
                case .workspace: EmptyView()
                case .pinned: pinnedRows
                case .worktrees: worktreeRows
                case .branches: branchRows
                case .stashes: stashRows
                case .tags: tagRows
                case .remotes: remoteRows
                }
                }
                .modifier(SectionDrag(section: section))
            }
        }
    }

    private func sortable(_ section: SidebarSection) -> Bool {
        section != .worktrees && section != .remotes && section != .workspace && section != .pinned
    }

    private func sortOrder(of section: SidebarSection) -> SidebarSortOrder {
        store.sortOrder(for: section.rawValue, default: section == .branches ? .name : .date)
    }

    private func plusHelp(for section: SidebarSection) -> String? {
        switch section {
        case .workspace, .pinned: nil
        case .worktrees: "새 워크트리… (⇧⌘W)"
        case .branches: "새 브랜치… (⇧⌘B)"
        case .stashes: "스태시 저장 (⇧⌘H)"
        case .tags: nil
        case .remotes: "원격 추가…"
        }
    }

    private func plusAction(for section: SidebarSection) -> (() -> Void)? {
        switch section {
        case .workspace, .pinned: nil
        case .worktrees: { store.sheet = .newWorktree }
        case .branches: { store.sheet = .newBranch }
        case .stashes: { store.sheet = .newStash }
        case .tags: nil
        case .remotes: { store.sheet = .newRemote }
        }
    }

    private func toggleCollapsed(_ section: SidebarSection) {
        var set = collapsedSections
        if set.contains(section) { set.remove(section) } else { set.insert(section) }
        withAnimation(.easeInOut(duration: 0.2)) {
            collapsedRaw = set.map(\.rawValue).sorted().joined(separator: ",")
        }
    }

    private func move(_ section: SidebarSection, before target: SidebarSection) {
        guard section != target else { return }
        var list = order
        list.removeAll { $0 == section }
        let index = list.firstIndex(of: target) ?? list.count
        list.insert(section, at: index)
        orderRaw = list.map(\.rawValue).joined(separator: ",")
    }

    private func shift(_ section: SidebarSection, by delta: Int) {
        var list = order
        guard let index = list.firstIndex(of: section) else { return }
        let target = index + delta
        guard list.indices.contains(target) else { return }
        list.swapAt(index, target)
        orderRaw = list.map(\.rawValue).joined(separator: ",")
    }

    // MARK: 워크트리

    private var worktreeRows: some View {
        ForEach(store.worktrees) { worktree in worktreeRow(worktree) }
    }

    /// - Parameter inPinned: 고정 섹션 안이면 핀 표시를 다시 달지 않는다
    private func worktreeRow(_ worktree: Worktree, inPinned: Bool = false) -> some View {
        SelectableRow(
            isSelected: store.sidebarSelection == nil && worktree.path == store.activeWorktreePath,
            action: {
                store.sidebarSelection = nil
                Task { await store.activateWorktree(worktree.path) }
            }
        ) {
            WorktreeRow(worktree: worktree, isActive: worktree.path == store.activeWorktreePath, alias: store.alias(for: PreferenceKey.worktree(worktree)), isPinned: !inPinned && store.isPinned(PreferenceKey.worktree(worktree)))
        }
        .contextMenu { LazyMenu { worktreeMenu(worktree) } }
    }

    // MARK: 고정

    /// 고정한 것. 종류와 상관없이 고정한 순서대로. 지금 저장소에 없는 것(지운 브랜치 등)은 건너뛴다.
    private enum PinnedItem: Identifiable {
        case branch(Branch), tag(Tag), worktree(Worktree), stash(Stash)

        var id: String {
            switch self {
            case .branch(let branch): PreferenceKey.branch(branch)
            case .tag(let tag): PreferenceKey.tag(tag)
            case .worktree(let worktree): PreferenceKey.worktree(worktree)
            case .stash(let stash): PreferenceKey.stash(stash)
            }
        }
    }

    private var pinnedItems: [PinnedItem] {
        store.sidebarPreferences.pinned.compactMap { key -> PinnedItem? in
            if let branch = store.branches.first(where: { PreferenceKey.branch($0) == key }) { return .branch(branch) }
            if let tag = store.tags.first(where: { PreferenceKey.tag($0) == key }) { return .tag(tag) }
            if let worktree = store.worktrees.first(where: { PreferenceKey.worktree($0) == key }) { return .worktree(worktree) }
            if let stash = store.stashes.first(where: { PreferenceKey.stash($0) == key }) { return .stash(stash) }
            return nil
        }
    }

    /// 고정한 것을 한곳에. 원래 자리에서도 빠지지 않는다. 폴더 밖이라 이름은 전체로, 앞에 종류 아이콘을 둔다.
    private var pinnedRows: some View {
        ForEach(pinnedItems) { item in
            switch item {
            case .branch(let branch):
                branchRow(branch, displayName: branch.name, symbol: branch.isRemote ? "cloud" : "arrow.triangle.branch", inPinned: true)
            case .tag(let tag):
                tagRow(tag, displayName: tag.name, inPinned: true)
            case .worktree(let worktree):
                worktreeRow(worktree, inPinned: true)
            case .stash(let stash):
                stashRow(stash, inPinned: true)
            }
        }
    }

    // MARK: 브랜치

    /// 브랜치를 폴더로 묶는다. 현재 브랜치도 제 폴더 자리에 두고 굵은 이름과 체크로 표시한다.
    /// 맨 위에 따로 빼 두면 `release/`처럼 그 브랜치 하나뿐인 폴더가 사라져 브랜치가 없는 것처럼 보였다.
    /// 현재 브랜치가 무엇인지는 상단 바 제목이 크게 보여 준다.
    @ViewBuilder
    private var branchRows: some View {
        if sortOrder(of: .branches) == .name {
            PathTreeView(nodes: PathTree.build(store.localBranches.map { (name: $0.name, leaf: $0) }), collapsedFolders: $collapsedFolders) { node in
                if let branch = node.leaf {
                    branchRow(branch, displayName: node.name)
                }
            }
        } else {
            ForEach(store.localBranches.sorted { $0.date > $1.date }) { branch in
                branchRow(branch, displayName: branch.name)
            }
        }
        if store.localBranches.isEmpty {
            EmptyNote("브랜치가 없습니다")
        }
    }

    /// - Parameters:
    ///   - symbol: 고정 섹션처럼 여러 종류가 섞이는 곳에서 앞에 두는 아이콘
    ///   - inPinned: 고정 섹션 안이면 핀 표시를 다시 달지 않는다
    private func branchRow(_ branch: Branch, displayName: String, symbol: String? = nil, inPinned: Bool = false) -> some View {
        SelectableRow(
            isSelected: store.sidebarSelection == .branch(branch.id),
            action: { store.selectBranch(branch) },
            doubleTap: {
                if let path = branch.worktreePath, path != store.activeWorktreePath {
                    store.sidebarSelection = nil
                    Task { await store.activateWorktree(path) }
                } else if !branch.isHead {
                    Task { await store.checkout(branch) }
                }
            }
        ) {
            BranchRow(branch: branch, displayName: displayName, symbol: symbol, alias: store.alias(for: PreferenceKey.branch(branch)), isPinned: !inPinned && store.isPinned(PreferenceKey.branch(branch)), cleanup: store.cleanup(for: branch))
        }
        .contextMenu { LazyMenu { branchMenu(branch) } }
    }

    // MARK: 스태시

    /// 최신순 한 줄 목록. 브랜치는 각 줄 아래에 작게 적는다.
    @ViewBuilder
    private var stashRows: some View {
        if store.stashes.isEmpty {
            EmptyNote("치워 둔 변경이 없습니다")
        } else {
            let sorted = sortOrder(of: .stashes) == .name ? store.stashes.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } : store.stashes
            ForEach(sorted) { stash in stashRow(stash) }
        }
    }

    private func stashRow(_ stash: Stash, inPinned: Bool = false) -> some View {
        SelectableRow(
            isSelected: store.sidebarSelection == .stash(stash.id),
            action: { store.sidebarSelection = .stash(stash.id) }
        ) {
            StashRow(stash: stash, alias: store.alias(for: PreferenceKey.stash(stash)), isPinned: !inPinned && store.isPinned(PreferenceKey.stash(stash)))
        }
        .contextMenu { LazyMenu { stashMenu(stash) } }
    }

    // MARK: 태그

    /// 최신순. 많으면 일부만 보이고 "더 보기"로 펼친다. 슬래시가 있으면 폴더로 묶는다.
    @ViewBuilder
    private var tagRows: some View {
        if store.tags.isEmpty {
            EmptyNote("태그가 없습니다")
        } else {
            let sorted = sortOrder(of: .tags) == .name ? store.tags.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } : store.tags
            let hasFolders = sortOrder(of: .tags) == .name && sorted.contains { $0.name.contains("/") }
            let shown = showsAllTags || hasFolders ? sorted : Array(sorted.prefix(Self.tagLimit))
            if hasFolders {
                PathTreeView(nodes: PathTree.build(shown.map { (name: $0.name, leaf: $0) }), collapsedFolders: $collapsedFolders) { node in
                    if let tag = node.leaf { tagRow(tag, displayName: node.name) }
                }
            } else {
                ForEach(shown) { tag in tagRow(tag, displayName: tag.name) }
                if sorted.count > Self.tagLimit {
                    Button(showsAllTags ? "접기" : "\(sorted.count - Self.tagLimit)개 더 보기") {
                        withAnimation(.easeInOut(duration: 0.2)) { showsAllTags.toggle() }
                    }
                    .buttonStyle(TextButtonStyle())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func tagRow(_ tag: Tag, displayName: String, inPinned: Bool = false) -> some View {
        SelectableRow(
            isSelected: store.sidebarSelection == .tag(tag.id),
            action: { store.sidebarSelection = .tag(tag.id) }
        ) {
            TagRow(tag: tag, displayName: displayName, alias: store.alias(for: PreferenceKey.tag(tag)), isPinned: !inPinned && store.isPinned(PreferenceKey.tag(tag)))
        }
        .contextMenu { LazyMenu { tagMenu(tag) } }
    }

    // MARK: 원격

    @ViewBuilder
    private var remoteRows: some View {
        if store.remotes.isEmpty {
            EmptyNote("원격이 없습니다")
        }
        ForEach(store.remotes) { remote in
            RemoteGroup(remote: remote, collapsedFolders: $collapsedFolders) { branch, displayName in
                branchRow(branch, displayName: displayName)
            }
            .contextMenu { LazyMenu { remoteMenu(remote) } }
        }
    }

    // MARK: 메뉴

    @ViewBuilder
    private func pinAndAlias(key: String, title: String) -> some View {
        Button(store.isPinned(key) ? "고정 해제" : "고정") { store.togglePin(key) }
        Button(store.alias(for: key) == nil ? "별명 지정…" : "별명 바꾸기…") { store.sheet = .alias(key: key, title: title) }
        Divider()
    }

    @ViewBuilder
    private func worktreeMenu(_ worktree: Worktree) -> some View {
        pinAndAlias(key: PreferenceKey.worktree(worktree), title: worktree.name)
        Button("Finder에서 보기") { store.revealInFinder(worktree.path) }
        Button("터미널에서 열기") { store.openInTerminal(worktree.path) }
        if !worktree.isMain {
            Divider()
            Button("워크트리 제거…", role: .destructive) { store.removeWorktree(worktree) }
        }
    }

    @ViewBuilder
    private func branchMenu(_ branch: Branch) -> some View {
        pinAndAlias(key: PreferenceKey.branch(branch), title: branch.name)
        if let path = branch.worktreePath, path != store.activeWorktreePath {
            Button("그 워크트리로 전환") {
                store.sidebarSelection = nil
                Task { await store.activateWorktree(path) }
            }
        } else if !branch.isHead {
            Button("체크아웃") { Task { await store.checkout(branch) } }
        }
        if !branch.isHead, !store.status.isDetached {
            Button("\(store.branchDisplayName)에 머지…") { store.merge(branch) }
            Button("현재 브랜치를 여기 위로 리베이스…") { store.rebase(onto: branch) }
        }
        Divider()
        Button("여기서 새 브랜치…") {
            store.newBranchBase = branch.name
            store.sheet = .newBranch
        }
        Button("이름 복사") { store.copyBranchName(branch) }
        if !branch.isRemote, store.gitFlowFinishEnabled, store.gitFlowKind(of: branch.name) != nil {
            Button("Git Flow 마무리…") { Task { await store.prepareGitFlowFinish(branch: branch.name) } }
                .disabled(store.isBusy || (branch.worktreePath != nil && branch.worktreePath != store.activeWorktreePath))
        }
        if !branch.isRemote, store.pullRequestURL(for: branch.name) != nil {
            Button("PR 만들기") { store.openPullRequest(for: branch.name) }
        }
        if !branch.isRemote {
            Button("이름 바꾸기…") { store.sheet = .renameBranch(branch.name) }
            Menu("추적 브랜치") {
                let candidates = store.remoteBranches.filter { $0.nameWithoutRemote == branch.name }
                ForEach(candidates) { remote in
                    Button((branch.upstream == remote.name ? "✓ " : "") + remote.name) { Task { await store.setUpstream(branch, to: remote.name) } }
                }
                if !candidates.isEmpty { Divider() }
                Menu("다른 원격 브랜치") {
                    ForEach(store.remoteBranches.filter { $0.nameWithoutRemote != branch.name }) { remote in
                        Button(remote.name) { Task { await store.setUpstream(branch, to: remote.name) } }
                    }
                }
                if branch.upstream != nil {
                    Divider()
                    Button("추적 해제") { Task { await store.setUpstream(branch, to: nil) } }
                }
            }
        }
        if branch.isRemote {
            Divider()
            if store.isProtectedRemoteBranch(branch) {
                // 메뉴에서 이유를 바로 보이게 한다. 눌러 본 뒤에 막히는 것보다 낫다.
                Button("원격에서 삭제 (보호된 기준 브랜치)") {}
                    .disabled(true)
            } else {
                Button("원격에서 삭제…", role: .destructive) { store.deleteRemoteBranch(branch) }
            }
        } else if !branch.isHead, branch.worktreePath == nil {
            Divider()
            Button("브랜치 삭제…", role: .destructive) { store.deleteBranch(branch) }
        }
    }

    @ViewBuilder
    private func stashMenu(_ stash: Stash) -> some View {
        pinAndAlias(key: PreferenceKey.stash(stash), title: stash.title)
        Button("적용") { Task { await store.applyStash(stash, pop: false) } }
        Button("적용 후 삭제") { Task { await store.applyStash(stash, pop: true) } }
        Divider()
        Button("삭제…", role: .destructive) { store.dropStash(stash) }
    }

    @ViewBuilder
    private func tagMenu(_ tag: Tag) -> some View {
        pinAndAlias(key: PreferenceKey.tag(tag), title: tag.name)
        Button("여기서 새 브랜치…") {
            store.newBranchBase = tag.name
            store.sheet = .newBranch
        }
        Divider()
        Button("태그 삭제…", role: .destructive) { store.deleteTag(tag) }
    }

    @ViewBuilder
    private func remoteMenu(_ remote: Remote) -> some View {
        Button("\(remote.name) 페치") { Task { await store.fetch(remote) } }
        Divider()
        Button("원격 제거…", role: .destructive) { store.removeRemote(remote) }
    }
}

/// 섹션 머리말. 접기 화살표, 제목, 개수, 추가 버튼.
/// 섹션 어디를 잡아도(머리줄이든 행이든) 그 섹션을 끌어 순서를 바꾼다. 클릭은 움직여야 끌기가 되므로 그대로 동작한다.
/// 섹션이 길면 끄는 모습이 화면을 덮어서, 끄는 동안에는 섹션 이름만 보여 준다.
private struct SectionDrag: ViewModifier {
    let section: SidebarSection

    func body(content: Content) -> some View {
        content.draggable(section.rawValue) {
            Text(section.title)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.surface, in: Capsule())
        }
    }
}

private struct SidebarSectionHeader: View {
    let title: String
    let isCollapsed: Bool
    let toggle: () -> Void
    let plusHelp: String?
    let plusAction: (() -> Void)?
    var sortOrder: SidebarSortOrder?
    var setSortOrder: (SidebarSortOrder) -> Void = { _ in }
    var moveUp: (() -> Void)?
    var moveDown: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            // 버튼으로 두면 마우스를 잡고 끄는 동작까지 버튼이 가져가 섹션을 끌 수 없다. 누르는 영역으로 둔다.
            // 평소에는 이름만 보인다. 화살표는 마우스를 올렸거나 접혀 있을 때만 그린다.
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 12))
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .opacity(hovering || isCollapsed ? 1 : 0)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.secondary)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            // 정렬과 추가 버튼도 마우스를 올렸을 때만
            HStack(spacing: 2) {
                Menu {
                    if let sortOrder {
                        Picker("정렬", selection: Binding(get: { sortOrder }, set: setSortOrder)) {
                            ForEach(SidebarSortOrder.allCases) { order in Text(order.title).tag(order) }
                        }
                        Divider()
                    }
                    if let moveUp { Button("섹션 위로", action: moveUp) }
                    if let moveDown { Button("섹션 아래로", action: moveDown) }
                    Button(isCollapsed ? "펼치기" : "접기", action: toggle)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Circle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("정렬과 섹션 순서")
                if let plusAction {
                    Button(action: plusAction) { Image(systemName: "plus") }
                        .buttonStyle(IconButtonStyle(size: 22))
                        .help(plusHelp ?? "")
                }
            }
            .opacity(hovering ? 1 : 0)
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { self.hovering = hovering } }
        .help("끌어서 순서를 바꿀 수 있습니다")
    }
}

/// 목록 칸 맨 위의 현재 브랜치. 이름, 추적 브랜치, 올릴·받을 커밋 수. 누르면 이 브랜치의 히스토리를 연다.
private struct CurrentBranchCard: View {
    @Environment(RepositoryStore.self) private var store


    var body: some View {
        let branch = store.currentBranch
        SelectableRow(
            isSelected: store.sidebarSelection == nil && store.pane == .history,
            action: {
                if let branch {
                    store.selectBranch(branch)
                } else {
                    store.sidebarSelection = nil
                    store.pane = .history
                }
            }
        ) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: store.isAwayFromBranch ? "circle.dotted" : "arrow.triangle.branch")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(store.isAwayFromBranch ? Theme.orange : Theme.green)
                    .frame(width: 16)
                // 줄마다 한 가지만: 무엇인지, 이름, 추적 브랜치. 이름은 줄이지 않고 길면 다음 줄로 넘긴다.
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.isAwayFromBranch ? "분리된 HEAD" : "현재 브랜치")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                    Text(store.branchDisplayName)
                        .font(.system(size: 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if !store.isAwayFromBranch {
                        Label {
                            Text(branch?.upstream ?? "추적 브랜치 없음")
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "cloud").font(.system(size: 9))
                        }
                        .labelStyle(CompactLabelStyle())
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                        .help("추적 브랜치")
                    }
                }
                Spacer(minLength: 4)
                if let branch {
                    HStack(spacing: 6) {
                        if branch.ahead > 0 { Text("↑\(branch.ahead)") }
                        if branch.behind > 0 { Text("↓\(branch.behind)") }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .monospacedDigit()
                }
            }
        }
        .help("현재 브랜치의 히스토리 보기")
    }
}

/// 아이콘과 글자 사이를 좁게 두는 라벨
private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}

private struct EmptyNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.tertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
    }
}

/// 원격 하나와 그 브랜치를 접었다 펼 수 있는 묶음. 브랜치는 폴더로 묶는다.
private struct RemoteGroup<Row: View>: View {
    let remote: Remote
    @Binding var collapsedFolders: Set<String>
    @ViewBuilder let row: (Branch, String) -> Row
    @Environment(RepositoryStore.self) private var store
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 10)
                    Image(systemName: "cloud")
                        .font(.system(size: 12))
                    Text(remote.name)
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text("\(store.remoteBranches(of: remote).count)")
                        .font(.system(size: 11))
                }
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(remote.url)
            if expanded {
                let items = store.remoteBranches(of: remote).map { (name: $0.nameWithoutRemote, leaf: $0) }
                PathTreeView(nodes: PathTree.build(items), depth: 1, collapsedFolders: $collapsedFolders) { node in
                    if let branch = node.leaf { row(branch, node.name) }
                }
            }
        }
    }
}

/// 사이드바 아래 저장소 전환 칸. 지금 열린 저장소를 보여 주고, 누르면 최근 저장소 목록이 뜬다.
/// macOS의 Menu는 라벨을 글자 하나로 뭉개 버려서 팝오버로 만든다.
private struct OpenRepositoryMenu: View {
    @Environment(RepositoryStore.self) private var store
    @State private var showing = false
    @State private var hovering = false

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(Theme.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.repositoryName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(userLine)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(hovering || showing ? Theme.panelHover : Theme.panelRaised, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).stroke(Theme.panelBorder, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(store.mainRootPath ?? "")
        .popover(isPresented: $showing, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 2) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("커밋 작성자")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                    Text(store.gitUserName.isEmpty ? "user.name이 비어 있습니다" : store.gitUserName)
                        .font(.system(size: 13, weight: .medium))
                    Text(store.gitUserEmail.isEmpty ? "user.email이 비어 있습니다" : store.gitUserEmail)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                    Text(store.mainRootPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
                HairlineDivider().padding(.bottom, 6)
                Text("저장소")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
                ForEach(store.recentRepositoryPaths, id: \.self) { path in
                    SelectableRow(isSelected: path == store.mainRootPath, action: {
                        showing = false
                        if path != store.mainRootPath { Task { await store.open(path: path) } }
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                                .foregroundStyle(Theme.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text((path as NSString).lastPathComponent)
                                    .font(.system(size: 13, weight: path == store.mainRootPath ? .semibold : .regular))
                                Text((path as NSString).abbreviatingWithTildeInPath)
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 0)
                            if path == store.mainRootPath {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Theme.green)
                            }
                        }
                    }
                }
                HairlineDivider().padding(.vertical, 4)
                Button {
                    showing = false
                    store.openRepositoryPanel()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                        Text("다른 저장소 열기…")
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(8)
            .frame(width: 320)
        }
    }

    /// 카드 아랫줄은 폭이 좁아 하나만 적는다. 커밋 작성자, 없으면 경로. 나머지는 카드를 눌렀을 때 나오는 창에 있다.
    private var userLine: String {
        if !store.gitUserName.isEmpty { return store.gitUserName }
        return store.mainRootPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? ""
    }
}

/// 필터 글자가 있을 때 폴더 없이 맞는 항목만 늘어놓는다.
private struct FilteredRows<BranchRowView: View, TagRowView: View>: View {
    @Environment(RepositoryStore.self) private var store
    let query: String
    @ViewBuilder let branchRow: (Branch) -> BranchRowView
    @ViewBuilder let tagRow: (Tag) -> TagRowView

    var body: some View {
        let branches = store.localBranches.filter { $0.name.lowercased().contains(query) || (store.alias(for: PreferenceKey.branch($0))?.lowercased().contains(query) ?? false) }
        let remotes = store.remoteBranches.filter { $0.name.lowercased().contains(query) }
        let tags = store.tags.filter { $0.name.lowercased().contains(query) }
        let stashes = store.stashes.filter { $0.title.lowercased().contains(query) || ($0.branch?.lowercased().contains(query) ?? false) }
        VStack(alignment: .leading, spacing: 2) {
            if branches.isEmpty, remotes.isEmpty, tags.isEmpty, stashes.isEmpty {
                Text("맞는 항목이 없습니다")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiary)
                    .padding(10)
            }
            if !branches.isEmpty {
                SectionTitle("로컬 브랜치 \(branches.count)")
                ForEach(branches) { branchRow($0) }
            }
            if !remotes.isEmpty {
                SectionTitle("원격 브랜치 \(remotes.count)").padding(.top, 8)
                ForEach(remotes) { branchRow($0) }
            }
            if !tags.isEmpty {
                SectionTitle("태그 \(tags.count)").padding(.top, 8)
                ForEach(tags) { tagRow($0) }
            }
            if !stashes.isEmpty {
                SectionTitle("스태시 \(stashes.count)").padding(.top, 8)
                ForEach(stashes) { stash in
                    SelectableRow(isSelected: store.sidebarSelection == .stash(stash.id), action: { store.sidebarSelection = .stash(stash.id) }) {
                        HStack(spacing: 8) {
                            Image(systemName: "tray").font(.system(size: 12)).foregroundStyle(Theme.secondary).frame(width: 16)
                            Text(stash.title).font(.system(size: 13)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }
}

/// 별명을 원래 이름 옆에 작은 칩으로 같이 적는다.
struct AliasChip: View {
    let alias: String

    var body: some View {
        Text(alias)
            .font(.system(size: 12))
            .foregroundStyle(Theme.blue)
            .lineLimit(1)
    }
}

private struct PinMark: View {
    var body: some View {
        Image(systemName: "pin.fill")
            .font(.system(size: 9))
            .foregroundStyle(Theme.tertiary)
            .help("고정됨")
    }
}

/// 워크트리 = 폴더. 폴더 이름과 그 안에 체크아웃된 브랜치를 적고, 지금 보고 있는 것은 체크로 표시한다.
private struct WorktreeRow: View {
    let worktree: Worktree
    let isActive: Bool
    var alias: String?
    var isPinned = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: worktree.isMain ? "folder.fill" : "folder")
                .font(.system(size: 13))
                .foregroundStyle(isActive ? Theme.green : Theme.secondary)
                .frame(width: 16)
                .help(worktree.path)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(worktree.name)
                        .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                        .lineLimit(1)
                    if worktree.isMain {
                        Text("메인")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.tertiary)
                    }
                    if let alias { AliasChip(alias: alias) }
                }
                HStack(spacing: 4) {
                    Image(systemName: worktree.isDetached ? "circle.dotted" : "arrow.triangle.branch")
                        .font(.system(size: 9))
                    Text(worktree.branchDisplay)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 0)
            if isPinned { PinMark() }
            if worktree.isLocked {
                Image(systemName: "lock")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
            }
            if isActive {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.green)
                    .help("지금 보고 있는 워크트리")
            }
        }
    }
}

private struct BranchRow: View {
    let branch: Branch
    let displayName: String
    /// 고정 섹션처럼 여러 종류가 섞이는 곳에서만 앞에 두는 아이콘. 로컬·원격 섹션 안에서는 모두 브랜치라 달지 않는다.
    var symbol: String?
    var alias: String?
    /// 고정했으면 다른 종류의 줄과 같이 작은 핀을 단다
    var isPinned = false
    /// 정리해도 되는 브랜치면 표시. 이름을 흐리게 하고 "머지됨"/"원격 없음"을 적는다.
    var cleanup: RepositoryStore.BranchCleanup?

    var body: some View {
        // 폭이 모자라면 정리 라벨부터 뺀다(이름이 이미 흐려서 뜻은 남는다). 이름을 줄이는 건 마지막.
        ViewThatFits(in: .horizontal) {
            row(nameFits: true, showsLabel: true)
            row(nameFits: true, showsLabel: false)
            row(nameFits: false, showsLabel: false)
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.secondary)
        .monospacedDigit()
        .help(tooltip)
    }

    private var tooltip: String {
        var parts = [branch.name]
        if !branch.authorName.isEmpty { parts.append("마지막 커밋: \(branch.authorName)") }
        if let cleanup { parts.append(cleanup.reason) }
        return parts.joined(separator: "\n")
    }

    private func row(nameFits: Bool, showsLabel: Bool) -> some View {
        HStack(spacing: 8) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 16)
            }
            Group {
                if nameFits {
                    Text(displayName).fixedSize()
                } else {
                    Text(displayName).lineLimit(1).truncationMode(.middle)
                }
            }
            .font(.system(size: 13, weight: branch.isHead ? .semibold : .regular))
            .foregroundStyle(cleanup == nil ? Theme.text : Theme.secondary)
            if let alias { AliasChip(alias: alias).fixedSize() }
            Spacer(minLength: 0)
            if showsLabel, let cleanup {
                Text(cleanup.label)
                    .foregroundStyle(Theme.tertiary)
                    .fixedSize()
            }
            trailing
        }
    }

    @ViewBuilder
    private var trailing: some View {
            if isPinned { PinMark() }
            if branch.ahead > 0 {
                Text("↑\(branch.ahead)")
            }
            if branch.behind > 0 {
                Text("↓\(branch.behind)")
            }
            if branch.isHead {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.green)
                    .help("현재 브랜치")
            } else if let path = branch.worktreePath {
                Image(systemName: "tree")
                    .font(.system(size: 11))
                    .help("다른 워크트리에 체크아웃됨\n\(path)")
            }
    }
}

private struct StashRow: View {
    let stash: Stash
    var alias: String?
    var isPinned = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(stash.title)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    if let alias { AliasChip(alias: alias) }
                }
                HStack(spacing: 8) {
                    if let branch = stash.branch {
                        Text(branch).lineLimit(1).truncationMode(.middle)
                    }
                    Text(stash.date, format: .relative(presentation: .named))
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            if isPinned { PinMark() }
        }
    }
}

private struct TagRow: View {
    let tag: Tag
    let displayName: String
    var alias: String?
    var isPinned = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "tag")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .frame(width: 16)
            Text(displayName)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            if let alias { AliasChip(alias: alias) }
            Spacer(minLength: 0)
            if isPinned { PinMark() }
            Text(tag.date, format: .relative(presentation: .named))
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
        }
    }
}


/// 우클릭 메뉴를 메뉴가 열릴 때만 만든다. 그냥 넘기면 목록을 그릴 때마다 줄마다 메뉴 전체를 새로 만든다.
/// 브랜치 메뉴는 원격 브랜치 수백 개를 훑는 하위 메뉴가 있어서, 창 크기를 바꿀 때 특히 무거웠다.
struct LazyMenu<Content: View>: View {
    let content: () -> Content
    init(@ViewBuilder _ content: @escaping () -> Content) { self.content = content }
    var body: some View { content() }
}
