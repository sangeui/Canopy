import SwiftUI

/// 빠른 실행 (⌘P). Fork의 Quick Launch처럼 이름 몇 글자로 동작·브랜치·저장소를 찾아 바로 실행한다.
struct CommandPalette: View {
    @Environment(RepositoryStore.self) private var store
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool
    /// 입력 칸이 화살표와 esc를 먼저 가져가므로 창 단위로 받는다
    @State private var keyMonitor: Any?

    struct Item: Identifiable {
        let id: String
        let symbol: String
        let title: String
        /// 오른쪽에 흐리게. 단축키나 종류
        let hint: String
        let run: @MainActor () -> Void
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Color.black.opacity(0.12)
                    .ignoresSafeArea()
                    .onTapGesture { close() }
                panel
                    .frame(width: min(560, geometry.size.width - 48))
                    .padding(.top, 72)
            }
        }
        .onAppear {
            focused = true
            #if CANOPY_DEV
            // 화면 확인용 검색어. 배포 빌드는 읽지 않는다(번들 ID가 같아 개발 빌드가 남긴 값이 보일 수 있다).
            if let seed = UserDefaults.standard.string(forKey: "debugPaletteQuery") { query = seed }
            #endif
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                switch event.keyCode {
                case 126: _ = move(-1, count: filtered.count); return nil   // ↑
                case 125: _ = move(1, count: filtered.count); return nil    // ↓
                case 53: close(); return nil                                 // esc
                default: return event
                }
            }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }

    private var panel: some View {
        let results = filtered
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.secondary)
                TextField("동작, 브랜치, 저장소 찾기", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit { runHighlighted(results) }
                    .onKeyPress(.upArrow) { move(-1, count: results.count) }
                    .onKeyPress(.downArrow) { move(1, count: results.count) }
                    .onKeyPress(.escape) { close(); return .handled }
                    .onChange(of: query) { highlighted = 0 }
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            if !results.isEmpty {
                HairlineDivider()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(results.prefix(60).enumerated()), id: \.element.id) { index, item in
                                row(item, isHighlighted: index == highlighted)
                                    .id(index)
                                    .onTapGesture { run(item) }
                            }
                        }
                        .padding(6)
                    }
                    // 결과가 적으면 그만큼만. 빈 칸이 길게 남지 않게 한다.
                    .frame(height: min(CGFloat(min(results.count, 60)) * 34 + 12, 360))
                    .onChange(of: highlighted) { proxy.scrollTo(highlighted) }
                }
            }
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.2), radius: 24, y: 8)
    }

    private func row(_ item: Item, isHighlighted: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .frame(width: 18)
            Text(item.title)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            Text(item.hint)
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(isHighlighted ? Theme.raised : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: 항목

    private var items: [Item] {
        var list: [Item] = []
        func action(_ id: String, _ symbol: String, _ title: String, _ hint: String, enabled: Bool = true, _ run: @escaping @MainActor () -> Void) {
            guard enabled else { return }
            list.append(Item(id: "action:" + id, symbol: symbol, title: title, hint: hint, run: run))
        }
        let open = store.isOpen
        if open {
            action("fetch", "arrow.triangle.2.circlepath", "페치", "⇧⌘F") { Task { await store.fetch() } }
            action("pull", "arrow.down", "풀…", "⇧⌘L") { store.showPull() }
            action("push", "arrow.up", "푸시…", "⇧⌘P") { store.showPush() }
            action("forcePush", "arrow.up", "강제 푸시…", "") { store.showPush(force: true) }
            action("commit", "checkmark.circle", "커밋", "⌘⏎", enabled: store.canCommit) { Task { await store.commit() } }
            action("stageAll", "tray.and.arrow.down", "모두 스테이징", "⌥⌘S", enabled: !store.status.unstaged.isEmpty) { Task { await store.stageAll() } }
            action("newBranch", "plus", "새 브랜치…", "⇧⌘B") { store.sheet = .newBranch }
            action("stash", "tray", "스태시 저장…", "⇧⌘H", enabled: !store.status.changes.isEmpty) { store.sheet = .newStash }
            action("worktree", "square.on.square", "새 워크트리…", "") { store.sheet = .newWorktree }
            action("checkout", "arrow.triangle.branch", "브랜치 체크아웃…", "⌘B") { store.showsBranchSwitcher = true }
            action("tag", "tag", "새 태그…", "⇧⌘G", enabled: store.hasHead) { store.newTagAtHead() }
            action("head", "location", "HEAD 보기", "⌘0", enabled: store.hasHead) { store.revealHead() }
            action("search", "magnifyingglass", "커밋 찾기", "⌘F") { store.focusCommitSearch() }
            action("commitPush", "arrow.up.circle", "커밋하고 푸시", "⇧⌘⏎", enabled: store.canCommit) { Task { await store.commitAndPush() } }
            action("refresh", "arrow.clockwise", "새로고침", "⌘R") { Task { await store.refresh() } }
            action("changes", "pencil.and.list.clipboard", "변경 사항 보기", "⌘1") { store.sidebarSelection = nil; store.pane = .changes }
            action("history", "point.3.connected.trianglepath.dotted", "히스토리 보기", "⌘2") { store.sidebarSelection = nil; store.pane = .history }
            action("activity", "clock.arrow.circlepath", "활동 보기", "⌘3") { store.sidebarSelection = nil; store.pane = .activity }
            action("claude", "asterisk", store.showsAssistant ? "\(store.assistantTitle) 닫기" : store.assistantTitle, "⌘I") { store.toggleAssistant() }
            action("mini", "pip.enter", "미니 모드", "⌥⌘M") { MiniMode.enter() }
            for kind in GitFlowKind.allCases {
                action("flow-" + kind.rawValue, "arrow.triangle.branch", "Git Flow \(kind.title) 시작", "") { store.sheet = .gitFlowStart(kind) }
            }
            if let branch = store.finishableFlowBranch {
                action("flow-finish", "flag.checkered", "\(branch) Git Flow 마무리", "") { Task { await store.prepareGitFlowFinish(branch: branch) } }
            }
            if let branch = store.status.branch, store.pullRequestURL(for: branch) != nil {
                action("pull-request", "arrow.up.forward.square", "PR 만들기", "") { store.openPullRequest(for: branch) }
            }
            action("sidebar", "sidebar.left", store.showsSidebar ? "사이드바 숨기기" : "사이드바 보기", "⌃⌘S") { store.showsSidebar.toggle() }
            action("detail", "sidebar.right", store.showsDetail ? "오른쪽 패널 숨기기" : "오른쪽 패널 보기", "⇧⌘D") { store.showsDetail.toggle() }
            action("terminal", "terminal", "터미널에서 열기", "⌃⌘T") { if let path = store.activeWorktreePath { store.openInTerminal(path) } }
            action("finder", "folder", "Finder에서 보기", "⌃⌘O") { if let path = store.activeWorktreePath { store.revealInFinder(path) } }
        }
        action("settings", "gearshape", "설정", "⌘,") { store.showsSettings = true }
        action("openRepo", "folder.badge.plus", "저장소 열기…", "⌘O") { store.openRepositoryPanel() }

        if open {
            for branch in store.localBranches where !branch.isHead {
                list.append(Item(id: "branch:" + branch.id, symbol: "arrow.triangle.branch", title: branch.name, hint: "체크아웃") {
                    Task { await store.checkout(branch) }
                })
            }
            let localNames = Set(store.localBranches.map(\.name))
            for branch in store.remoteBranches where !localNames.contains(branch.nameWithoutRemote) {
                list.append(Item(id: "branch:" + branch.id, symbol: "cloud", title: branch.name, hint: "가져와서 체크아웃") {
                    Task { await store.checkout(branch) }
                })
            }
            for tag in store.tags.prefix(50) {
                list.append(Item(id: "tag:" + tag.id, symbol: "tag", title: tag.name, hint: "태그 보기") {
                    store.sidebarSelection = .tag(tag.id)
                })
            }
        }
        for path in store.recentRepositoryPaths where path != store.mainRootPath {
            let name = (path as NSString).lastPathComponent
            list.append(Item(id: "repo:" + path, symbol: "folder", title: name, hint: "저장소 열기") {
                Task { await store.open(path: path) }
            })
        }
        return list
    }

    /// 글자가 순서대로 들어 있으면 맞는 것으로 본다. 앞에서 맞을수록, 붙어서 맞을수록 위로.
    private var filtered: [Item] {
        let needle = query.trimmed.lowercased()
        let all = items
        guard !needle.isEmpty else { return all.filter { $0.id.hasPrefix("action:") } }
        let scored: [(Item, Int)] = all.compactMap { item in
            Self.score(item.title.lowercased(), needle).map { (item, $0) }
        }
        return scored.sorted { $0.1 < $1.1 }.map(\.0)
    }

    static func score(_ text: String, _ needle: String) -> Int? {
        if let range = text.range(of: needle) {
            return text.distance(from: text.startIndex, to: range.lowerBound)
        }
        var index = text.startIndex
        var gaps = 0
        var last: String.Index?
        for character in needle {
            guard let found = text[index...].firstIndex(of: character) else { return nil }
            if let last, text.index(after: last) != found { gaps += 1 }
            last = found
            index = text.index(after: found)
        }
        return 100 + gaps * 10 + text.count
    }

    // MARK: 동작

    private func move(_ delta: Int, count: Int) -> KeyPress.Result {
        guard count > 0 else { return .ignored }
        highlighted = (highlighted + delta + min(count, 60)) % min(count, 60)
        return .handled
    }

    private func runHighlighted(_ results: [Item]) {
        guard !results.isEmpty else { return }
        run(results[min(highlighted, results.count - 1)])
    }

    private func run(_ item: Item) {
        close()
        // 팔레트가 닫히는 것을 먼저 보이고, 그다음에 동작한다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { item.run() }
    }

    private func close() {
        store.showsPalette = false
    }
}
