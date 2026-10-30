import SwiftUI

/// 머리글. 지금 어느 브랜치에 있고, 무엇이 바뀌었고, 최근에 무슨 일을 했는지를 한눈에 보여 준다.
struct StatusBand: View {
    @Environment(RepositoryStore.self) private var store

    var body: some View {
        // 줄 전체를 통째로 견줘 고른다. 먼저 버튼이 아이콘만 남고, 그래도 모자라면 브랜치 이름의 앞 폴더를 뺀다.
        // 줄이는 건 정말 마지막 경우뿐이다.
        // 제목 옆의 "리베이스 3/7" 같은 말은 브랜치 이름을 줄이기 전에 먼저 뺀다.
        // 창 폭을 바꿀 때 버튼 글자가 뚝 끊겨 사라지지 않게 SmoothFit으로 고르고 애니메이션으로 바꾼다.
        // 왼쪽(브랜치 이름)에 붙인다. 오른쪽에 붙이면 패널을 열 때 잠깐 넘치는 동안 이름이 좌우로 흔들렸다.
        SmoothFit(options: Self.layouts, alignment: .leading) { layout in
            row(name: layout.name, level: layout.level, showsNote: layout.showsNote)
        }
        .padding(.horizontal, 20)
        .frame(height: StatusBand.height)
        .titleBarDoubleClick()
        .animation(.easeInOut(duration: 0.2), value: store.statusMessage)
    }

    private struct Layout: Hashable {
        var name: BranchNameStyle
        var level: Int
        var showsNote = false
    }

    private static let layouts: [Layout] = [
        Layout(name: .full, level: 0, showsNote: true),
        Layout(name: .full, level: 1, showsNote: true),
        Layout(name: .full, level: 0),
        Layout(name: .full, level: 1),
        Layout(name: .lastComponent, level: 1),
        Layout(name: .full, level: 2),
        Layout(name: .lastComponent, level: 2),
        Layout(name: .truncated, level: 2),
    ]

    private func row(name: BranchNameStyle, level: Int, showsNote: Bool = false) -> some View {
        HStack(alignment: .center, spacing: 12) {
            BranchHero(nameStyle: name, showsNote: showsNote)
            Spacer(minLength: 8)
            controls(level: level).fixedSize()
        }
    }

    /// 상단 띠 높이. 오른쪽 패널의 탭 줄도 같은 높이라 띠가 한 줄로 이어진다.
    static let height: CGFloat = 48

    /// 버튼 줄. 0 = 글자 있는 동기화와 Finder·터미널 버튼, 1 = 동기화 아이콘만, 2 = 미니 모드 버튼도 더 보기 메뉴로(오른쪽 패널 버튼은 늘 남는다).
    private func controls(level: Int) -> some View {
        HStack(spacing: 8) {
            if let busy = store.busyMessage, store.syncActivity == nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    if level < 2 { Text(busy).lineLimit(1).fixedSize(horizontal: true, vertical: false) }
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .help(busy)
            } else if let done = store.statusMessage, level < 2 {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
                    Text(done).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .transition(.opacity)
            }
            SyncControl(compact: level > 0)
            // 넣고 빼면 그 자리에서 나타났다 사라지는 동안 옆 버튼만 미끄러져 겹쳐 보인다. 폭을 줄였다 늘린다.
            // 줄 간격(8)도 감춘 폭 안에 넣어야 다 줄었을 때 빈 틈이 남지 않는다.
            OpenInButtons()
                .padding(.trailing, 8)
                .revealed(level == 0)
                .padding(.trailing, -8)
            MoreMenu(includesOpenIn: level > 0, includesPanels: level >= 2)
            // Claude는 폭이 좁아도 더 보기 메뉴로 넣지 않는다. 자주 여닫고, 지금 열려 있는지도 이 표시로 본다.
            // claude CLI가 없으면 숨긴다. 설치 안내는 설정의 Claude 페이지에 있다.
            if store.assistantAvailable {
                Button { store.toggleAssistant() } label: {
                    AssistantMark(size: 14, color: store.showsAssistant ? AssistantMark.accent : Theme.secondary)
                }
                .buttonStyle(IconButtonStyle())
                .help(store.showsAssistant ? "\(store.assistantTitle) 닫기 (⌘I)" : "\(store.assistantTitle) (⌘I)")
            }
            // 미니 모드와 오른쪽 패널은 창 배치를 바꾸는 버튼이라 맨 오른쪽에 같이 둔다.
            // 미니 창의 돌아가기 버튼(pip.exit)과 짝을 맞춘다.
            // 미니 모드는 좁으면 더 보기 메뉴로 옮기지만, 오른쪽 패널 버튼은 늘 둔다. 패널을 닫은 뒤 다시 열 곳이 보여야 한다.
            PanelToggle(symbol: "pip.enter", help: "미니 모드 (⌥⌘M)") { MiniMode.enter() }
                .padding(.leading, 8)
                .revealed(level < 2)
                .padding(.leading, -8)
            PanelToggle(symbol: "rectangle.righthalf.inset.filled", help: store.showsDetail ? "오른쪽 패널 숨기기 (⇧⌘D)" : "오른쪽 패널 보기 (⇧⌘D)", active: store.showsDetail) {
                store.showsDetail.toggle()
            }
        }
    }
}

/// 상단 띠 아래 한 줄. 변경 · 원격과의 관계. 분리된 HEAD나 진행 중인 작업 배너도 여기 붙는다.
struct StatusLine: View {
    @Environment(RepositoryStore.self) private var store

    /// 띄울 배너가 있는지. 없으면 이 줄은 높이가 없다.
    private var hasBanner: Bool {
        AppUpdater.shared.bannerRelease != nil || (store.status.isDetached && store.operation == nil) || (store.hasPausedGitFlow && store.operation == nil) || store.operation != nil
    }

    var body: some View {
        // 예전에는 "변경 없음 · 추적 브랜치 · ↓2 · 9분 전 페치" 줄이 있었다. 누구의 정보인지 적혀 있지 않아
        // 사이드바에서 다른 브랜치를 보고 있을 때 그 브랜치의 정보로 읽혔다. 변경 수는 사이드바에, ↑↓는 풀·푸시 버튼에,
        // 추적 브랜치와 페치 시각은 그 버튼의 툴팁에 있으므로 지우고, 할 일이 있는 배너만 남긴다.
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: hasBanner ? 12 : 0)

            if AppUpdater.shared.bannerRelease != nil {
                UpdateNoticeBanner()
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if store.status.isDetached && store.operation == nil {
                NoticeBanner(
                    symbol: "exclamationmark.triangle.fill",
                    tint: Theme.orange,
                    title: "분리된 HEAD",
                    message: "지금 커밋하면 어느 브랜치에도 남지 않습니다. 작업을 이어가려면 여기서 브랜치를 만드세요."
                ) {
                    Button("브랜치 만들기…") { store.sheet = .newBranch }
                        .buttonStyle(PillButtonStyle(prominent: true, compact: true))
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if store.hasPausedGitFlow, store.operation == nil, let run = store.gitFlowRun {
                NoticeBanner(
                    symbol: "arrow.triangle.branch",
                    tint: Theme.orange,
                    title: "Git Flow 마무리가 멈춰 있습니다",
                    message: run.branch
                ) {
                    Button("계속…") { store.sheet = .gitFlowFinish }
                        .buttonStyle(PillButtonStyle(prominent: true, compact: true))
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if let operation = store.operation {
                NoticeBanner(
                    symbol: "arrow.triangle.merge",
                    tint: Theme.orange,
                    title: operation.title + (operation == .rebasing ? store.rebaseStepText.map { " " + $0 } ?? "" : ""),
                    message: store.conflicts.isEmpty
                        ? "충돌은 모두 정리됐습니다. 계속 진행할 수 있습니다."
                        : "충돌 파일 \(store.conflicts.count)개를 변경 사항 칸에서 정리한 뒤 계속하세요."
                ) {
                    Button("중단") { store.abortOperation() }
                        .buttonStyle(PillButtonStyle(compact: true))
                    if operation != .merging {
                        Button("건너뛰기") { Task { await store.skipOperation() } }
                            .buttonStyle(PillButtonStyle(compact: true))
                            .help("지금 멈춘 커밋 하나만 빼고 나머지를 이어 갑니다")
                    }
                    Button("계속") { Task { await store.continueOperation() } }
                        .buttonStyle(PillButtonStyle(prominent: true, compact: true))
                        .disabled(!store.conflicts.isEmpty)
                }
                .disabled(store.isBusy)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

}

/// 현재 브랜치 이름을 크게. 그 아래 저장소·워크트리·원격.
/// 머리글의 브랜치 이름을 어떻게 적을지. 폭에 따라 바깥에서 고른다.
enum BranchNameStyle {
    case full, lastComponent, truncated
}

private struct BranchHero: View {
    @Environment(RepositoryStore.self) private var store
    var nameStyle: BranchNameStyle = .full
    var showsNote = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                // 사이드바를 숨기면 저장소 이름이 보이는 곳이 없어서 여기에 붙인다
                if !store.showsSidebar, nameStyle != .truncated {
                    Text(store.repositoryName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize()
                        .help("저장소")
                }
                Image(systemName: store.status.isDetached && store.detachedPlace?.rebasingBranch == nil ? "circle.dotted" : "arrow.triangle.branch")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(store.isAwayFromBranch ? Theme.orange : Theme.green)
                BranchSwitcherButton(title: store.branchDisplayName.isEmpty ? store.repositoryName : store.branchDisplayName, style: nameStyle)
                // 폭이 모자라면 브랜치 이름보다 먼저 뺀다
                if let note = store.headPlaceNote, showsNote {
                    Text(note)
                        .font(.system(size: 12, weight: .medium, design: store.detachedPlace?.rebasingBranch == nil ? .monospaced : .default))
                        .foregroundStyle(store.operation == .rebasing ? Theme.orange : Theme.secondary)
                        .fixedSize()
                }
                if let current = store.currentBranch, let alias = store.alias(for: PreferenceKey.branch(current)) {
                    AliasChip(alias: alias)
                }
                if store.worktrees.count > 1 {
                    Text(store.activeWorktreeName)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .help("지금 보고 있는 워크트리")
                }
            }
        }
    }
}

/// 페치·풀·푸시를 한 덩어리로 묶은 컨트롤. 할 일이 있는 칸만 진하게. 좁으면 아이콘만 남긴다.
struct SyncControl: View {
    @Environment(RepositoryStore.self) private var store
    @Environment(\.onPanel) private var onPanel
    var compact = false

    var body: some View {
        HStack(spacing: 0) {
            segment(.fetch, symbol: "arrow.triangle.2.circlepath", title: "페치", count: 0, emphasized: false, help: fetchHelp) {
                Task { await store.fetch() }
            }
            segment(.pull, symbol: "arrow.down", title: "풀", count: store.status.behind, emphasized: store.status.behind > 0, help: pullHelp) {
                store.showPull()
            }
            segment(.push, symbol: "arrow.up", title: "푸시", count: store.status.ahead, emphasized: store.status.ahead > 0 || store.status.upstream == nil && store.hasHead && !store.remotes.isEmpty, help: pushHelp) {
                store.showPush()
            }
        }
        // 진한 테마의 띠 위에서는 흰색을 살짝 얹은 알약. 테두리는 두지 않는다.
        .background(onPanel ? Theme.panelRaised : Theme.surface, in: Capsule())
        .overlay(Capsule().stroke(onPanel ? Color.clear : Theme.border, lineWidth: 1))
        .clipShape(Capsule())
        .disabled(store.isBusy || !store.hasHead)
        .opacity(store.hasHead ? 1 : 0.4)
    }

    // 상단 줄에 따로 적던 추적 브랜치와 마지막 페치 시각은 버튼 툴팁에 둔다. 정보가 그 버튼의 동작에 붙어 있어야 읽힌다.
    private var fetchHelp: String {
        var text = "모든 원격에서 가져오기 (⇧⌘F)"
        if let date = store.lastFetchedAt { text += "\n마지막 페치 " + Self.relative.localizedString(for: date, relativeTo: Date()) }
        return text
    }

    private var pullHelp: String {
        guard let upstream = store.status.upstream else { return "풀 (⇧⌘L)\n추적 브랜치가 없습니다" }
        return "\(upstream)에서 풀 (⇧⌘L)" + (store.status.behind > 0 ? "\n받아 올 커밋 \(store.status.behind)개" : "\n받아 올 커밋 없음")
    }

    private var pushHelp: String {
        guard let upstream = store.status.upstream else { return "푸시 (⇧⌘P)\n아직 원격에 올리지 않은 브랜치입니다" }
        return "\(upstream)에 푸시 (⇧⌘P)" + (store.status.ahead > 0 ? "\n올릴 커밋 \(store.status.ahead)개" : "\n올릴 커밋 없음")
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        return formatter
    }()

    private func segment(_ activity: RepositoryStore.SyncActivity, symbol: String, title: String, count: Int, emphasized: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 0) {
                // 진행 중이면 아이콘 자리에 돌림표. 왼쪽에 따로 띄우지 않고 누른 버튼 안에서 보여 준다.
                Group {
                    if store.syncActivity == activity {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .frame(width: 13, height: 13)
                // 글자를 넣고 빼지 않고 폭을 줄였다 늘린다. 그래야 아이콘과 알약이 같이 부드럽게 움직인다.
                Text(title)
                    .padding(.leading, 5)
                    .revealed(!compact)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(emphasized ? Theme.onAccent.opacity(0.25) : (onPanel ? Theme.panelRaised : Theme.raised), in: Capsule())
                        .padding(.leading, 5)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(emphasized ? Theme.onAccent : Theme.text)
            .background(emphasized ? Theme.accent : Color.clear)
            .contentShape(Rectangle())
            .animation(.easeInOut(duration: 0.2), value: emphasized)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// 자주 안 쓰는 동작을 모은 메뉴. 배경 원을 라벨 안에 그려서 가운데가 맞는다.
private struct MoreMenu: View {
    @Environment(RepositoryStore.self) private var store
    /// 머리글이 좁아서 Finder·터미널 버튼을 이 메뉴로 옮겼을 때
    var includesOpenIn = false
    /// 머리글이 좁아서 미니 모드 버튼을 이 메뉴로 옮겼을 때
    var includesPanels = false

    var body: some View {
        Menu {
            if includesPanels {
                Button("미니 모드") { MiniMode.enter() }
                Divider()
            }
            GitFlowMenu(store: store)
            if let branch = store.status.branch, store.pullRequestURL(for: branch) != nil {
                Button("PR 만들기") { store.openPullRequest(for: branch) }
            }
            Divider()
            Button("새 워크트리…") { store.sheet = .newWorktree }
            Button("스태시 만들기…") { store.sheet = .newStash }
                .disabled(store.status.changes.isEmpty)
            Button("마지막 커밋 되돌리기…") { store.undoLastCommit() }
                .disabled(!store.hasHead)
            Divider()
            Button("강제 푸시…") { store.showPush(force: true) }
            Button("태그 푸시") { Task { await store.pushTags() } }
            Divider()
            if includesOpenIn {
                Button("터미널에서 열기") { if let path = store.activeWorktreePath { store.openInTerminal(path) } }
                Button("Finder에서 보기") { if let path = store.activeWorktreePath { store.revealInFinder(path) } }
                Divider()
            }
            Button("새로고침") { Task { await store.refresh() } }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
                .frame(width: 32, height: 32)
                .background(Theme.panelRaised, in: Circle())
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("더 보기")
        .disabled(store.isBusy)
    }
}

/// Git Flow 시작과 마무리. 앱 메뉴와 더 보기 메뉴가 같이 쓴다.
/// 앱 메뉴(`Commands`)에는 화면의 환경 값이 오지 않아서 store를 직접 받는다.
struct GitFlowMenu: View {
    let store: RepositoryStore

    var body: some View {
        Menu("Git Flow") {
            ForEach(GitFlowKind.allCases) { kind in
                Button("\(kind.title) 시작…") { store.sheet = .gitFlowStart(kind) }
            }
            if store.hasPausedGitFlow {
                Divider()
                Button("멈춘 마무리 이어서…") { store.sheet = .gitFlowFinish }
            } else if let branch = store.finishableFlowBranch {
                Divider()
                Button("\(branch) 마무리…") { Task { await store.prepareGitFlowFinish(branch: branch) } }
            }
        }
        .disabled(store.isBusy)
    }
}

/// 패널을 접고 펴는 버튼.
private struct PanelToggle: View {
    let symbol: String
    let help: String
    var active = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundStyle(active ? Theme.text : Theme.secondary)
        }
        .buttonStyle(IconButtonStyle())
        .help(help)
    }
}

/// 머리글의 브랜치 이름. 누르면 브랜치를 찾아 바로 체크아웃할 수 있다.
private struct BranchSwitcherButton: View {
    @Environment(RepositoryStore.self) private var store
    let title: String
    var style: BranchNameStyle = .full
    @State private var query = ""

    var body: some View {
        Button { store.showsBranchSwitcher.toggle() } label: {
            HStack(spacing: 5) {
                // 폭이 모자라면 "feature/" 같은 앞 폴더를 통째로 빼고, 그래도 모자랄 때만 가운데를 줄인다.
                Group {
                    switch style {
                    case .full: Text(title).fixedSize()
                    case .lastComponent: Text(title.split(separator: "/").last.map(String.init) ?? title).fixedSize()
                    case .truncated: Text(title.split(separator: "/").last.map(String.init) ?? title).lineLimit(1).truncationMode(.middle)
                    }
                }
                .font(.system(size: 19, weight: .semibold))
                .help(title)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("브랜치 바꾸기")
        .popover(isPresented: Binding(get: { store.showsBranchSwitcher }, set: { store.showsBranchSwitcher = $0 }), arrowEdge: .bottom) {
            VStack(spacing: 6) {
                SearchField(text: $query, placeholder: "브랜치 찾기")
                let matches = store.localBranches.filter { query.trimmed.isEmpty || $0.name.lowercased().contains(query.trimmed.lowercased()) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(matches) { branch in
                            SelectableRow(isSelected: branch.isHead, action: {
                                store.showsBranchSwitcher = false
                                guard !branch.isHead else { return }
                                if let path = branch.worktreePath, path != store.activeWorktreePath {
                                    store.sidebarSelection = nil
                                    Task { await store.activateWorktree(path) }
                                } else {
                                    Task { await store.checkout(branch) }
                                }
                            }) {
                                HStack(spacing: 8) {
                                    Image(systemName: "arrow.triangle.branch").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                                    Text(branch.name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 0)
                                    if branch.isHead {
                                        Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.green)
                                    } else if branch.worktreePath != nil {
                                        Image(systemName: "tree").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                                    }
                                }
                            }
                        }
                        if matches.isEmpty {
                            Text("맞는 브랜치가 없습니다").font(.system(size: 12)).foregroundStyle(Theme.tertiary).padding(10)
                        }
                    }
                }
                .frame(maxHeight: 320)
                HairlineDivider()
                Button {
                    store.showsBranchSwitcher = false
                    store.sheet = .newBranch
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                        Text("새 브랜치…")
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
}

/// Finder·터미널로 열기.
/// 지금 저장소 폴더를 Finder와 설정에서 고른 터미널에서 여는 버튼.
/// 앱 아이콘은 색이 강해 상단 바의 다른 버튼과 섞이지 않아서, 같은 무채색 기호를 쓴다. 어느 터미널인지는 툴팁에 적는다.
private struct OpenInButtons: View {
    @Environment(RepositoryStore.self) private var store
    @AppStorage(TerminalApp.defaultsKey) private var terminalID = TerminalApp.systemID
    /// `TerminalApp.preferred`는 설치된 앱을 매번 훑어서, 터미널 설정이 바뀔 때만 다시 구한다
    @State private var terminalName = TerminalApp.preferred.name

    var body: some View {
        HStack(spacing: 0) {
            Button {
                if let path = store.activeWorktreePath { store.revealInFinder(path) }
            } label: { Image(systemName: "folder") }
            .buttonStyle(IconButtonStyle())
            .help("Finder에서 보기 (⌃⌘O)")
            Button {
                if let path = store.activeWorktreePath { store.openInTerminal(path) }
            } label: { Image(systemName: "terminal") }
            .buttonStyle(IconButtonStyle())
            .help("\(terminalName)에서 열기 (⌃⌘T)")
        }
        .onChange(of: terminalID) { reloadTerminal() }
        // 고른 터미널을 지우고 돌아왔을 수 있다. 그러면 macOS 터미널로 바뀐다.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in reloadTerminal() }
    }

    private func reloadTerminal() {
        let name = TerminalApp.preferred.name
        if name != terminalName { terminalName = name }
    }
}

/// 경고나 진행 중 작업 안내.
struct NoticeBanner<Actions: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let message: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            actions()
        }
        .padding(12)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint.opacity(0.35), lineWidth: 1))
    }
}

extension RepositoryStore {
    /// 원격과의 관계를 짧게. 추적 브랜치 이름이 현재 브랜치와 같으면 원격 이름만 적는다.
    /// 원격 브랜치 이름 전체는 길어서 잘리는데, 브랜치 이름은 바로 위에 있으니 원격 이름만 적는다.
    /// 이름 뒤에 조사를 붙이지 않는다. 영어 이름은 받침을 알 수 없다.
    /// 원격과의 관계. 추적 대상은 원격과 브랜치를 다 적는다. "동기화됨"이라고 하지 않는다. 마지막 페치 뒤는 모르기 때문이다.
    var syncDescription: String {
        guard hasHead else { return "아직 커밋이 없습니다" }
        guard let upstream = status.upstream else {
            return remotes.isEmpty ? "원격 없음" : "추적하는 원격 브랜치 없음"
        }
        let ahead = status.ahead
        let behind = status.behind
        if ahead == 0, behind == 0 { return "\(upstream), 차이 없음" }
        var parts: [String] = []
        if ahead > 0 { parts.append("↑\(ahead)") }
        if behind > 0 { parts.append("↓\(behind)") }
        return "\(upstream), " + parts.joined(separator: " ")
    }
}

/// 원격과의 관계 한 줄과 마지막 페치 시각. 좁으면 시각부터 뺀다.
struct SyncDescription: View {
    @Environment(RepositoryStore.self) private var store
    var size: CGFloat = 12

    var body: some View {
        ViewThatFits(in: .horizontal) {
            if store.status.upstream != nil {
                fetched.fixedSize()
            }
            Text(store.syncDescription).fixedSize()
            Text(store.syncDescription).lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: size))
        .foregroundStyle(Theme.secondary)
        .help(help)
    }

    private var fetched: Text {
        guard let date = store.lastFetchedAt else { return Text(store.syncDescription + ", 페치한 적 없음") }
        // 1분 안이면 상대 시각이 "지금"이 되어 "지금 페치"로 읽히므로 따로 적는다
        if Date().timeIntervalSince(date) < 60 { return Text(store.syncDescription + ", 방금 페치") }
        return Text(store.syncDescription + ", ") + Text(date, format: .relative(presentation: .named)) + Text(" 페치")
    }

    private var help: String {
        guard let date = store.lastFetchedAt else { return "아직 페치하지 않았습니다. 원격과 비교한 값이 아닙니다." }
        return "마지막 페치 \(date.formatted(date: .abbreviated, time: .shortened)) 기준입니다. 그 뒤 원격에 생긴 커밋은 페치해야 보입니다."
    }
}
