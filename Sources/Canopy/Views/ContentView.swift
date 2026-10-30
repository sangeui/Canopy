import SwiftUI

struct ContentView: View {
    @Environment(RepositoryStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    /// 메인 창의 시트. 미니 모드에서는 메인 창이 숨어 있으니 푸시·풀은 미니 창이 띄운다.
    /// `store.sheet`를 여기서 바로 읽어야 값이 바뀔 때 화면이 다시 그려진다.
    private var mainSheet: Binding<RepositoryStore.Sheet?> {
        let sheet = MiniMode.isShowing ? nil : store.sheet
        return Binding(get: { sheet }, set: { store.sheet = $0 })
    }

    var body: some View {
        @Bindable var store = store
        ZStack {
            // git이 없으면 저장소를 열 수 없다. 첫 화면이 설치 안내를 보여 준다.
            if store.isOpen && GitInstallation.shared.isInstalled {
                RepositoryView()
            } else {
                WelcomeView()
            }
            if let confirmation = store.confirmation {
                ConfirmationOverlay(confirmation: confirmation)
                    // 다른 확인 창으로 바뀌면 선택을 꺼진 상태로 새로 시작한다
                    .id(confirmation.id)
                    .transition(.opacity)
                    .id(confirmation.id)
            }
            if store.showsPalette {
                CommandPalette()
                    .transition(.opacity)
            }
            // 설정은 Claude 앱처럼 창 안에 뜨는 모달
            if store.showsSettings {
                SettingsOverlay()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
            if AppUpdater.shared.showsSheet {
                UpdateOverlay()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: store.showsSettings)
        .animation(.easeOut(duration: 0.18), value: AppUpdater.shared.showsSheet)
        .animation(.easeOut(duration: 0.12), value: store.showsPalette)
        .animation(.easeOut(duration: 0.12), value: store.confirmation?.id)
        .background(Theme.surface)
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
        .alert("Git 오류", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
        // 미니 모드에서는 메인 창이 숨어 있으니 푸시·풀 창은 미니 창에 붙인다 (MiniView)
        .sheet(item: mainSheet) { sheet in
            switch sheet {
            case .newBranch: NewBranchSheet()
            case .newWorktree: NewWorktreeSheet()
            case .newStash: NewStashSheet()
            case .newTag(let hash): NewTagSheet(targetHash: hash)
            case .newRemote: NewRemoteSheet()
            case .alias(let key, let title): AliasSheet(key: key, title: title)
            case .renameBranch(let name): RenameBranchSheet(name: name)
            case .clone: CloneSheet()
            case .push: PushSheet()
            case .pull: PullSheet()
            case .gitFlowStart(let kind): GitFlowStartSheet(kind: kind)
            case .gitFlowFinish: GitFlowFinishSheet()
            case .rewordCommit(let hash): RewordSheet(hash: hash)
            case .squashCommits(let hashes): SquashSheet(hashes: hashes)
            case .cleanupCommits(let hash): CleanupSheet(hash: hash)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Timing.log("became active")
            // 다른 곳에서 git이나 claude를 설치하고 돌아왔을 수 있다
            ClaudeAccount.shared.relocate()
            if !ClaudeAccount.shared.isInstalled { store.showsAssistant = false }
            Task {
                await GitInstallation.shared.recheck()
                // git이 없으면 새로고침할 때마다 "git을 찾지 못했습니다" 알림이 뜬다. 첫 화면이 설치 안내를 보여 준다.
                guard GitInstallation.shared.isInstalled else { return }
                try? await Task.sleep(for: .milliseconds(250))
                await store.refresh()
            }
        }
        .onAppear { MiniMode.openWindow = openWindow }
        // 미니 창은 SwiftUI 장면이라 여는 것은 여기서 한다. 메인 창은 닫지 않고 숨겨서 상태가 그대로 산다.
        .onReceive(NotificationCenter.default.publisher(for: MiniMode.enterNotification)) { _ in
            guard store.isOpen else { return }
            openWindow(id: MiniMode.windowID)
            MiniMode.mainWindow?.orderOut(nil)
        }

        .onAppear {
            WindowChrome.toggleSidebar = { store.showsSidebar.toggle() }
            AppUpdater.shared.checkOnLaunch()
        }
        .onChange(of: store.isOpen && GitInstallation.shared.isInstalled, initial: true) { _, open in
            WindowChrome.showsSidebarToggle = open
        }
        .onChange(of: AppTheme.shared.paletteID, initial: true) {
            for window in NSApp.windows where window.styleMask.contains(.titled) {
                window.backgroundColor = NSColor(Theme.sidebar)
            }
        }
        // 누르면 화면부터 바꾸고, 전환 애니메이션이 끝난 뒤에 git을 부른다. 둘이 겹치면 애니메이션이 끊긴다.
        .onChange(of: store.sidebarSelection) {
            let selection = store.sidebarSelection
            Task {
                try? await Task.sleep(for: .milliseconds(Theme.switchDelayMilliseconds))
                guard store.sidebarSelection == selection else { return }
                await store.handleSidebarSelection()
            }
        }
        .onChange(of: store.pane) {
            let pane = store.pane
            Timing.log("pane changed: \(pane.rawValue)")
            Task {
                try? await Task.sleep(for: .milliseconds(Theme.switchDelayMilliseconds))
                guard store.pane == pane else { return }
                await store.updateDetail(force: true)
            }
        }
        // git을 설치하고 돌아오면 지난번 저장소를 연다
        .onChange(of: GitInstallation.shared.isInstalled) { _, installed in
            guard installed, !store.isOpen,
                  UserDefaults.standard.object(forKey: "reopenLastRepository") as? Bool ?? true else { return }
            Task { await store.restoreLastSession() }
        }
        .task {
            guard GitInstallation.shared.isInstalled else { return }
            // `swift run Canopy /path/to/repo`처럼 경로를 넘기면 바로 연다.
            let arguments = CommandLine.arguments.dropFirst()
            if arguments.first(where: { !$0.hasPrefix("-") }) == nil, !arguments.contains("--welcome"),
               UserDefaults.standard.object(forKey: "reopenLastRepository") as? Bool ?? true {
                await store.restoreLastSession()
            }
            if let path = arguments.first(where: { !$0.hasPrefix("-") }) {
                Timing.log("task: open start")
                await store.open(path: path)
                Timing.log("task: open done")
                // 아래 실행 인자는 화면 확인용이라 개발 빌드에만 넣는다. 저장소 경로를 넘겨 여는 것은 배포 빌드에서도 된다.
                #if CANOPY_DEV
                // `--history`를 주면 히스토리 칸을 열고 첫 커밋을 고른다. 화면 확인용.
                if arguments.contains("--history") {
                    store.pane = .history
                    store.selectCommit(store.commits.first?.id)
                }
                if let index = arguments.firstIndex(of: "--pane"), index + 1 < arguments.endIndex, let pane = RepositoryStore.Pane(rawValue: arguments[index + 1]) {
                    store.pane = pane
                }
                if let index = arguments.firstIndex(of: "--branch"), index + 1 < arguments.endIndex {
                    let name = arguments[index + 1]
                    if let branch = store.branches.first(where: { $0.name == name }) {
                        store.sidebarSelection = .branch(branch.id)
                    }
                }
                if arguments.contains("--activity") {
                    store.pane = .activity
                    store.selectActivity(store.activities.first)
                }
                // `--blame <경로>`, `--file-history <경로>`: 화면 확인용
                if let index = arguments.firstIndex(of: "--blame"), index + 1 < arguments.endIndex {
                    store.showBlame(arguments[index + 1])
                }
                if let index = arguments.firstIndex(of: "--file-history"), index + 1 < arguments.endIndex {
                    store.showFileHistory(arguments[index + 1])
                }
                if let index = arguments.firstIndex(of: "--theme"), index + 1 < arguments.endIndex {
                    AppTheme.shared.paletteID = arguments[index + 1]
                }
                if let index = arguments.firstIndex(of: "--scope"), index + 1 < arguments.endIndex,
                   let scope = RepositoryStore.HistoryScope(rawValue: arguments[index + 1]) {
                    store.historyScope = scope
                }
                if let index = arguments.firstIndex(of: "--select-change"), index + 1 < arguments.endIndex, let position = Int(arguments[index + 1]) {
                    store.pane = .changes
                    try? await Task.sleep(for: .seconds(2))
                    let ordered = store.status.staged + store.status.unstaged
                    if position < ordered.count {
                        let started = Date()
                        store.selectChange(ordered[position].id)
                        Timing.log("selectChange returned after \(Int(Date().timeIntervalSince(started) * 1000))ms")
                    }
                }
                if arguments.contains("--assistant") {
                    store.showAssistant()
                }
                if arguments.contains("--mini") {
                    try? await Task.sleep(for: .milliseconds(300))
                    MiniMode.enter()
                }
                if arguments.contains("--mini-expanded") {
                    UserDefaults.standard.set(true, forKey: "miniExpanded")
                }
                // `--draft "/rev"`: 입력 상자에 글을 미리 넣는다. 자동완성 화면 확인용.
                if let index = arguments.firstIndex(of: "--draft"), index + 1 < arguments.endIndex {
                    UserDefaults.standard.set(arguments[index + 1], forKey: "debugDraft")
                } else {
                    UserDefaults.standard.removeObject(forKey: "debugDraft")
                }
                if let index = arguments.firstIndex(of: "--ask"), index + 1 < arguments.endIndex,
                   let action = RepositoryStore.AssistantAction(rawValue: arguments[index + 1]) {
                    try? await Task.sleep(for: .seconds(1))
                    store.askAssistant(action: action)
                }
                // `--ask-prompt "/스킬 인자"`: 입력 상자에서 보낸 것처럼 묻는다. 스킬 실행 확인용.
                if let index = arguments.firstIndex(of: "--ask-prompt"), index + 1 < arguments.endIndex {
                    try? await Task.sleep(for: .seconds(1))
                    store.askAssistant(arguments[index + 1])
                }
                if arguments.contains("--palette") {
                    store.showsPalette = true
                }
                if let index = arguments.firstIndex(of: "--palette-query"), index + 1 < arguments.endIndex {
                    UserDefaults.standard.set(arguments[index + 1], forKey: "debugPaletteQuery")
                    store.showsPalette = true
                } else {
                    UserDefaults.standard.removeObject(forKey: "debugPaletteQuery")
                }
                if arguments.contains("--rename-sheet"), let current = store.currentBranch {
                    store.sheet = .renameBranch(current.name)
                }
                if arguments.contains("--sheet") {
                    store.sheet = .newBranch
                }
                // `--push-sheet`, `--pull-sheet`, `--force-push-sheet`: 화면 확인용
                if arguments.contains("--push-sheet") { store.showPush() }
                if arguments.contains("--force-push-sheet") { store.showPush(force: true) }
                if arguments.contains("--pull-sheet") { store.showPull() }
                if let index = arguments.firstIndex(of: "--settings-tab"), index + 1 < arguments.endIndex {
                    UserDefaults.standard.set(arguments[index + 1], forKey: "settingsTab")
                }
                if arguments.contains("--settings") {
                    store.showsSettings = true
                    Timing.log("task: settings shown")
                }
                #endif
            }
        }
    }
}

struct RepositoryView: View {
    @Environment(RepositoryStore.self) private var store

    var body: some View {
        // Claude 카드는 창 안에서 오른쪽 아래에 떠 있는 카드다. 오른쪽 패널이 무엇을 보여 주든 그대로 있다.
        ZStack(alignment: .bottomTrailing) {
            splitLayout
            if store.showsAssistant {
                AssistantCard()
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: store.showsAssistant)
    }

    private var splitLayout: some View {
        VStack(spacing: 0) {
            SplitLayout(showsSidebar: store.showsSidebar, showsDetail: store.showsDetail, expandsDetail: store.expandsDetail, collapsedSidebarWidth: 48) {
                // 아이콘 줄 오른쪽에 목록 칸을 붙여 두고 폭만 바꾼다. 폭이 줄면 아이콘 줄만 보인다.
                SidebarColumn(showsSidebar: store.showsSidebar)
                    .equatable()
            } content: {
                VStack(spacing: 0) {
                    // 상단 바. 제목 표시줄 자리까지 올라가서 창 맨 위 한 줄이 곧 머리글이다.
                    // 사이드바를 접으면 신호등 버튼이 이 칸까지 넘어오므로 그만큼 비운다.
                    StatusBand()
                        .padding(.leading, store.showsSidebar ? 0 : 30)
                        .background(Theme.sidebar)
                        .panelStyle()
                    // 본문은 창 바탕 위에 살짝 떠 있는 둥근 판. 모서리가 각지지 않게 한다.
                    VStack(spacing: 0) {
                        StatusLine()
                        ContentColumn()
                    }
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
                    .padding(.bottom, Theme.panelGap)
                }
                .background(Theme.sidebar)
            } detail: {
                DetailColumn()
                    .equatable()
                    .background(Theme.sidebar)
            }
        }
        // 화면 확인용 명령. 다른 프로그램이 알림 하나로 앱을 조작할 수 있으니 개발 빌드(./make-app.sh --dev)에만 넣는다.
        #if CANOPY_DEV
        .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name("dev.sangeui.canopy.debug"))) { note in
            // 화면 확인용. 바깥에서 패널 토글을 보낼 수 있다.
            let command = note.object as? String ?? ""
            Timing.log("debug command: " + command)
            switch command {
            case "toggleSidebar": store.showsSidebar.toggle()
            case "shiftReturn", "plainReturn":
                // 입력 칸에 ⇧⏎나 ⏎를 실제 키 이벤트로 넣는다. 키 감시가 받는지 확인용.
                NSApp.activate()
                if let window = NSApp.keyWindow ?? MiniMode.mainWindow, let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: command == "shiftReturn" ? .shift : [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) {
                    NSApp.postEvent(event, atStart: false)
                }
            case "toggleDetail": store.showsDetail.toggle()
            case "toggleSettings": store.showsSettings.toggle()
            case "flowStart": store.sheet = .gitFlowStart(.release)
            case "cleanUntracked": store.cleanUntracked()
            case let command where command.hasPrefix("selectFirst:"):
                // 화면 확인용: 히스토리의 위에서 N개를 Shift 클릭한 것처럼
                let count = Int(command.dropFirst("selectFirst:".count)) ?? 2
                let list = store.filteredCommits
                if list.count >= count {
                    store.selectCommit(list[0].id)
                    store.selectCommit(list[count - 1].id, extend: true)
                }
            case let command where command.hasPrefix("codeSearch:"):
                store.commitFilter = String(command.dropFirst("codeSearch:".count))
                Task { await store.searchCode() }
            case let command where command.hasPrefix("cleanup:"):
                store.sheet = .cleanupCommits(String(command.dropFirst("cleanup:".count)))
            case let command where command.hasPrefix("reword:"):
                store.sheet = .rewordCommit(String(command.dropFirst("reword:".count)))
            case "flowRun": Task { await store.runGitFlow() }
            case let command where command.hasPrefix("flowFinish:"):
                Task { await store.prepareGitFlowFinish(branch: String(command.dropFirst("flowFinish:".count))) }
            case let page where page.hasPrefix("settingsPage:"):
                UserDefaults.standard.set(String(page.dropFirst("settingsPage:".count)), forKey: "settingsTab")
            case "toggleMiniExpanded": UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "miniExpanded"), forKey: "miniExpanded")
            case "leaveMini": MiniMode.leave()
            case "enterMini": MiniMode.enter()
            case "closeMini": MiniMode.miniWindow?.performClose(nil)
            case "hideAll": NSApp.windows.forEach { $0.orderOut(nil) }
            case let width where width.hasPrefix("setWidth:"):
                // 화면 확인용: 창 폭을 바꾼다
                if let window = MiniMode.mainWindow, let value = Double(width.dropFirst("setWidth:".count)) {
                    var frame = window.frame
                    frame.size.width = value
                    window.setFrame(frame, display: true)
                }
            case "raiseTitlebar":
                if let window = MiniMode.mainWindow { WindowChrome.keepTitlebarOnTop(window) }
            case "buttonChain":
                // 신호등 버튼 확인용: 닫기 버튼부터 창 맨 위 뷰까지 숨김·투명도·레이어를 적는다
                guard let window = MiniMode.mainWindow, let close = window.standardWindowButton(.closeButton) else { break }
                var view: NSView? = close
                while let current = view {
                    let layer = current.layer
                    Timing.log("chain \(type(of: current)) hidden=\(current.isHidden) alpha=\(current.alphaValue) frame=\(current.frame) layerOpacity=\(layer?.opacity ?? -1) layerHidden=\(layer?.isHidden ?? false) wantsLayer=\(current.wantsLayer) subviews=\(current.subviews.count)")
                    view = current.superview
                }
                Timing.log("chain window titleVisibility=\(window.titleVisibility.rawValue) transparent=\(window.titlebarAppearsTransparent) mask=\(window.styleMask.rawValue) toolbar=\(String(describing: window.toolbar)) style=\(window.toolbarStyle.rawValue) key=\(window.isKeyWindow) active=\(NSApp.isActive) closeInWindow=\(close.convert(close.bounds, to: nil))")
                if let frameView = window.contentView?.superview {
                    for sub in frameView.subviews {
                        Timing.log("chain themeChild \(type(of: sub)) frame=\(sub.frame) hidden=\(sub.isHidden) zPos=\(sub.layer?.zPosition ?? 0)")
                    }
                }
            case "focusSidebarSearch", "focusNothing":
                // 신호등 버튼 확인용: 사이드바 찾기 칸에 포커스를 주거나 뺀다
                NSApp.activate()
                guard let window = MiniMode.mainWindow else { break }
                window.makeKeyAndOrderFront(nil)
                if command == "focusNothing" {
                    window.makeFirstResponder(nil)
                } else {
                    func find(_ view: NSView) -> NSTextField? {
                        if let field = view as? NSTextField, field.isEditable, field.placeholderString == "찾기" { return field }
                        for sub in view.subviews { if let found = find(sub) { return found } }
                        return nil
                    }
                    if let root = window.contentView?.superview, let field = find(root) { window.makeFirstResponder(field) }
                }
                Timing.log("focus \(command) responder=\(String(describing: window.firstResponder))")
            case "showPush": store.showPush()
            case "showComparison": store.showComparison()
            case "toggleExpandDetail": store.expandsDetail.toggle()
            case "goBack": store.goBack()
            case let hover where hover.hasPrefix("hover:"):
                // "hover:x,y" 창 왼쪽 위 기준 좌표로 마우스 이동 이벤트를 넣는다. 그래프 강조 확인용.
                let parts = hover.dropFirst(6).split(separator: ",").compactMap { Double($0) }
                if parts.count == 2, let window = NSApp.keyWindow ?? MiniMode.mainWindow,
                   let event = NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: parts[0], y: window.frame.height - parts[1]), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                    window.acceptsMouseMovedEvents = true
                    NSApp.postEvent(event, atStart: false)
                }
            case "openCompareCommit": if let first = store.compareCommits.ahead.first { store.showCommit(hash: first.hash) }
            case "showPull": store.showPull()
            case "windowButtons":
                // 신호등 버튼이 사라지는 문제 확인용. 창마다 버튼 상태를 적는다.
                for window in NSApp.windows where window.isVisible {
                    let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
                    let states = buttons.map { kind -> String in
                        guard let button = window.standardWindowButton(kind) else { return "nil" }
                        return "hidden=\(button.isHidden) alpha=\(button.alphaValue) frame=\(button.frame) super=\(button.superview.map { "\(type(of: $0)) hidden=\($0.isHidden) alpha=\($0.alphaValue)" } ?? "nil")"
                    }
                    let container = window.standardWindowButton(.closeButton)?.superview?.superview
                    if let frameView = window.contentView?.superview {
                        Timing.log("theme frame subviews: " + frameView.subviews.map { "\(type(of: $0))" }.joined(separator: " < "))
                    }
                    Timing.log("window \(window.identifier?.rawValue ?? "?") key=\(window.isKeyWindow) main=\(window.isMainWindow) active=\(NSApp.isActive) mask=\(window.styleMask.rawValue) container=\(container.map { "\(type(of: $0)) hidden=\($0.isHidden) alpha=\($0.alphaValue) frame=\($0.frame)" } ?? "nil") " + states.joined(separator: " | "))
                }
            case "closeMain": MiniMode.mainWindow?.performClose(nil)
            case _ where command.hasPrefix("click:"):
                // 화면 확인용: 창 왼쪽 위 기준 (x,y) 점에 한 번 누르기를 창 안으로 보낸다. 실제 클릭과 같은 길을 탄다.
                let parts = command.dropFirst(6).split(separator: ",").compactMap { Double($0) }
                if parts.count == 2, let window = MiniMode.mainWindow {
                    let location = NSPoint(x: parts[0], y: window.frame.height - parts[1])
                    let time = ProcessInfo.processInfo.systemUptime
                    let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: time, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                    let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: time + 0.02, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)
                    Timing.log("mouse down")
                    if let down { window.sendEvent(down) }
                    if let up { window.sendEvent(up) }
                }
            case let command where command.hasPrefix("windowWidth:"):
                // 화면 확인용: 창 폭을 한 번에 바꾼다. 좁을 때·넓을 때 모양과 바뀌는 중간을 찍는다.
                if let window = MiniMode.mainWindow, let width = Double(command.dropFirst("windowWidth:".count)) {
                    var frame = window.frame
                    frame.size.width = width
                    window.setFrame(frame, display: true)
                }
            case "scrollHistory":
                // 화면 확인용: 히스토리 목록을 2초 동안 프레임마다 아래로 내리고, 프레임 간격이 늦은 것을 센다
                if let window = MiniMode.mainWindow, let scroll = ContentView.largestScrollView(in: window.contentView) {
                    Task { @MainActor in
                        var last = Date()
                        var slow = 0, worst = 0.0, frames = 0
                        for _ in 0..<120 {
                            let origin = scroll.contentView.bounds.origin
                            scroll.contentView.scroll(to: NSPoint(x: origin.x, y: origin.y + 12))
                            scroll.reflectScrolledClipView(scroll.contentView)
                            try? await Task.sleep(for: .milliseconds(16))
                            let gap = Date().timeIntervalSince(last) * 1000
                            last = Date()
                            frames += 1
                            if gap > 25 { slow += 1 }
                            worst = max(worst, gap)
                        }
                        Timing.log("scrollHistory frames=\(frames) slow=\(slow) worst=\(Int(worst))ms")
                    }
                }
            case "wiggleWindow":
                // 화면 확인용: 창 폭을 1040 ↔ 1500으로 20번 오간다. 프레임마다 다시 배치하게 한다.
                if let window = MiniMode.mainWindow {
                    let start = window.frame
                    Task { @MainActor in
                        let began = Date()
                        for step in 0..<120 {
                            let t = Double(step % 12) / 11
                            let width = 1040 + 460 * (step / 12 % 2 == 0 ? t : 1 - t)
                            var frame = start
                            frame.size.width = width
                            window.setFrame(frame, display: true)
                            try? await Task.sleep(for: .milliseconds(8))
                        }
                        window.setFrame(start, display: true)
                        Timing.log("wiggle: 120 steps in \(Int(Date().timeIntervalSince(began) * 1000))ms")
                    }
                }
            case "paneChanges":
                store.sidebarSelection = nil
                store.pane = .changes
                if let target = store.status.unstaged.first ?? store.orderedChanges.first {
                    store.selectChange(target.id)
                }
            case let size where size.hasPrefix("windowSize:"):
                let parts = size.dropFirst("windowSize:".count).split(separator: ",").compactMap { Double($0) }
                if parts.count == 2, let window = MiniMode.mainWindow {
                    window.setFrame(NSRect(x: 100, y: 100, width: parts[0], height: parts[1]), display: true)
                }
            case "paneHistory": store.sidebarSelection = nil; store.pane = .history
            case "paneActivity": store.sidebarSelection = nil; store.pane = .activity
            case "toggleAssistant": store.showsAssistant.toggle()
            case let theme where theme.hasPrefix("setTheme:"):
                AppTheme.shared.paletteID = String(theme.dropFirst("setTheme:".count))
            case let mode where mode.hasPrefix("setAppearance:"):
                if let parsed = AppearanceMode(rawValue: String(mode.dropFirst("setAppearance:".count))) {
                    AppTheme.shared.appearance = parsed
                }
            case let ver where ver.hasPrefix("simulateUpdate:"):
                AppUpdater.shared.simulateRelease(version: String(ver.dropFirst("simulateUpdate:".count)))
            case "showUpdateSheet":
                AppUpdater.shared.showsSheet = true
            case "hideUpdateSheet":
                AppUpdater.shared.showsSheet = false
            case let file where file.hasPrefix("snapshot:"):
                let path = String(file.dropFirst("snapshot:".count))
                if let view = NSApp.keyWindow?.contentView ?? MiniMode.mainWindow?.contentView,
                   let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
            case "selectNextCommit":
                let list = store.commits
                let index = (list.firstIndex { $0.id == store.selectedCommitID } ?? -1) + 1
                if index < list.count { store.selectCommit(list[index].id) }
            case "selectBranch":
                if let branch = store.localBranches.first(where: { !$0.isHead }) { store.sidebarSelection = .branch(branch.id) }
            case "fetchNow": Task { await store.fetch() }
            case let name where name.hasPrefix("confirmDeleteRemote:"):
                // 화면 확인용: 원격 브랜치 삭제 확인 창만 띄운다
                if let branch = store.branches.first(where: { $0.isRemote && $0.name == String(name.dropFirst("confirmDeleteRemote:".count)) }) {
                    store.deleteRemoteBranch(branch)
                }
            case let name where name.hasPrefix("confirmDeleteLocal:"):
                if let branch = store.localBranches.first(where: { $0.name == String(name.dropFirst("confirmDeleteLocal:".count)) }) {
                    store.deleteBranch(branch)
                }
            case let key where key.hasPrefix("togglePin:"):
                // 화면 확인용: "togglePin:branch:origin/topic"
                store.togglePin(String(key.dropFirst("togglePin:".count)))
            case "dismissConfirmation": store.confirmation = nil
            case "dismissError": store.errorMessage = nil
            case "confirmDeleteBranch":
                if let branch = store.localBranches.first(where: { !$0.isHead && $0.name.hasPrefix("claude/") }) ?? store.localBranches.first(where: { !$0.isHead }) {
                    store.deleteBranch(branch)
                }
            case "confirmReset":
                if let commit = store.commits.dropFirst().first { store.reset(to: commit, mode: .hard) }
            case "acceptConfirmation":
                // 화면 확인용: 떠 있는 확인 창의 버튼을 누른 것처럼
                if let confirmation = store.confirmation {
                    store.confirmation = nil
                    Task { await confirmation.action() }
                }
            case let message where message.hasPrefix("typeCommit:"):
                // 화면 확인용: 커밋 메시지 칸에 포커스를 주고 글을 넣는다
                NSApp.activate()
                MiniMode.mainWindow?.makeKeyAndOrderFront(nil)
                store.focusCommitMessage()
                store.commitMessage = String(message.dropFirst("typeCommit:".count))
            case "cmdReturn", "cmdZ", "cmdShiftZ":
                // 화면 확인용: 메뉴 단축키를 실제 키 이벤트로 누른다
                NSApp.activate()
                MiniMode.mainWindow?.makeKeyAndOrderFront(nil)
                let isReturn = command == "cmdReturn"
                let modifiers: NSEvent.ModifierFlags = command == "cmdShiftZ" ? [.command, .shift] : .command
                if let window = NSApp.keyWindow ?? MiniMode.mainWindow,
                   let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: isReturn ? "\r" : (command == "cmdShiftZ" ? "Z" : "z"), charactersIgnoringModifiers: isReturn ? "\r" : (command == "cmdShiftZ" ? "Z" : "z"), isARepeat: false, keyCode: isReturn ? 36 : 6) {
                    NSApp.postEvent(event, atStart: false)
                }
            case "acceptChoice":
                // 화면 확인용: 확인 창의 선택을 켜고 버튼을 누른 것처럼
                if let choice = store.confirmation?.choice {
                    store.confirmation = nil
                    Task { await choice.action() }
                }
            case "restoreFirstDeleted":
                if let first = store.deletedBranches.first { Task { await store.restoreBranch(first) } }
            case "restoreDeletedRemote":
                if let first = store.deletedBranches.first(where: { $0.remote != nil }) { Task { await store.restoreBranch(first) } }
            case "undo": Task { await store.undo() }
            case "redo": Task { await store.redo() }
            case "confirmDiscard":
                if let first = store.status.unstaged.first { store.selectChange(first.id); store.discardSelectedChange() }
            case "pressBackspace":
                // 화면 확인용: 지금 키 창에 백스페이스 키를 보낸다
                if let window = NSApp.keyWindow ?? MiniMode.mainWindow,
                   let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: 51) {
                    window.sendEvent(down)
                }
            case "toggleFirstChange":
                if let first = store.orderedChanges.first {
                    store.selectChange(first.id)
                    Task { await store.toggleSelectedChange() }
                }
            case "refreshNow": Task { await store.refresh() }
            case "selectDiffLines":
                // 화면 확인용: 첫 diff 글에서 2~4번째 줄을 고른다
                func textViews(_ view: NSView) -> [NSTextView] {
                    (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
                }
                if let content = MiniMode.mainWindow?.contentView, let view = textViews(content).first(where: { $0.string.contains("\n") && !$0.isEditable }) {
                    let text = view.string as NSString
                    var starts: [Int] = [0]
                    for index in 0..<text.length where text.character(at: index) == 10 { starts.append(index + 1) }
                    if starts.count > 4 {
                        view.window?.makeFirstResponder(view)
                        view.setSelectedRange(NSRange(location: starts[2], length: starts[4] - starts[2] + 2))
                    }
                }
            default:
                // "burst:/경로" → 창 내용을 35ms 간격으로 12장 저장한다. 전환 애니메이션을 눈으로 확인할 때 쓴다.
                // "burstSidebar:/경로", "burstDetail:/경로" → 토글한 직후부터 찍는다.
                if command.hasPrefix("burst") {
                    let directory = String(command[command.index(after: command.firstIndex(of: ":")!)...])
                    if command.hasPrefix("burstSidebar") { store.showsSidebar.toggle() }
                    if command.hasPrefix("burstDetail") { store.showsDetail.toggle() }
                    Task { @MainActor in
                        for index in 0..<12 {
                            if let view = NSApp.keyWindow?.contentView ?? NSApp.windows.first?.contentView,
                               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                                view.cacheDisplay(in: view.bounds, to: rep)
                                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("frame-\(index).png"))
                            }
                            try? await Task.sleep(for: .milliseconds(35))
                        }
                    }
                }
            }
        }
        #endif
    }
}

struct ContentColumn: View {
    @Environment(RepositoryStore.self) private var store

    var body: some View {
        // 바깥 ZStack은 그대로 두고 안쪽만 바꿔야 분할 뷰의 너비가 유지된다.
        // 칸 전환은 짧게 서서히. git 작업은 이 애니메이션이 끝난 뒤에 시작해서 겹치지 않게 한다.
        ZStack {
            paneContent
        }
        .animation(.easeOut(duration: Theme.switchDuration), value: store.sidebarSelection)
    }

    @ViewBuilder
    private var paneContent: some View {
        switch store.sidebarSelection {
        case .branch(let id):
            if let branch = store.branches.first(where: { $0.id == id }) {
                BranchHistoryView(branch: branch).id(id).transition(.opacity)
            }
        case .tag(let id):
            if let tag = store.tags.first(where: { $0.id == id }) {
                TagHistoryView(tag: tag).id(id).transition(.opacity)
            }
        case .stash(let id):
            if let stash = store.stashes.first(where: { $0.id == id }) {
                StashView(stash: stash).id(id).transition(.opacity)
            }
        case nil:
            VStack(spacing: 0) {
                Color.clear.frame(height: 2)
                Group {
                    switch store.pane {
                    case .changes: ChangesView()
                    case .history: HistoryView()
                    case .activity: ActivityView()
                    }
                }
                .id(store.pane)
                .transition(.opacity.combined(with: .offset(y: 4)))
            }
            .animation(.easeOut(duration: Theme.switchDuration), value: store.pane)
        }
    }
}

/// 사이드바 칸. 창 크기가 바뀌어도 사이드바 폭은 그대로라 다시 계산하지 않는다.
/// 바깥(SplitLayout의 GeometryReader)이 매 프레임 새로 만들어도 입력이 같으면 건너뛴다. 안쪽은 저장소 상태를 직접 구독한다.
#if CANOPY_DEV
extension ContentView {
    /// 화면 확인용: 문서가 가장 긴 세로 스크롤 뷰(히스토리 목록)
    static func largestScrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        var best: NSScrollView?
        func visit(_ v: NSView) {
            if let scroll = v as? NSScrollView, let doc = scroll.documentView,
               doc.frame.height > (best?.documentView?.frame.height ?? 0) { best = scroll }
            v.subviews.forEach(visit)
        }
        visit(view)
        return best
    }
}
#endif

private struct SidebarColumn: View, Equatable {
    let showsSidebar: Bool

    var body: some View {
        // 아이콘 줄은 늘 보이고, 목록 칸만 접고 편다.
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                SidebarRail()
                    .frame(width: 48)
                SidebarView()
                    .opacity(showsSidebar ? 1 : 0)
            }
            // 아이콘 줄 폭(48)의 가운데, 상단 바 줄 높이의 가운데.
            CanopyLogo(size: 17)
                .help("Canopy")
                .frame(width: 48, height: StatusBand.height)
        }
        .panelStyle()
        .animation(.easeOut(duration: 0.12), value: showsSidebar)
    }
}

/// 오른쪽 칸도 같은 이유로 입력이 없으면 같은 것으로 본다.
extension DetailColumn: Equatable {
    static func == (lhs: DetailColumn, rhs: DetailColumn) -> Bool { true }
}

struct DetailColumn: View {
    @Environment(RepositoryStore.self) private var store

    var body: some View {
        // 바깥 VStack은 그대로 두고 안쪽만 바꿔야 분할 뷰의 너비가 유지된다.
        VStack(spacing: 0) {
            Group {
                if store.trail.isEmpty {
                    Color.clear.frame(height: StatusBand.height).background(Theme.sidebar)
                } else {
                    DetailNavBar()
                }
            }
            .panelStyle()
            ZStack {
                detailContent
                    .id(detailKey)
                    .transition(.opacity)
            }
            .animation(.easeOut(duration: Theme.switchDuration), value: detailKey)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
            .padding(.trailing, Theme.panelGap)
            .padding(.bottom, Theme.panelGap)
        }
    }

    private var detailKey: String {
        switch store.detail {
        case .change(let change): "change:" + change.id
        case .commit(let commit): "commit:" + commit.id
        case .stash(let stash): "stash:" + stash.id
        case .compare, .fileHistory, .blame: store.detail?.id ?? "none"
        case nil: "none"
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch store.detail {
        case .change(let change):
            DiffView(title: change.path, subtitle: change.kind.label, files: store.diffFiles, isLoading: store.isLoadingDiff, change: change)
        case .commit(let commit):
            let graph = store.sidebarSelection == nil ? store.graph : store.refGraph
            CommitDetailView(
                commit: commit,
                files: store.diffFiles,
                isLoading: store.isLoadingDiff,
                ownerName: graph.owner(of: commit.hash)?.name,
                parentOwnerNames: commit.parents.map { graph.owner(of: $0)?.name },
                containingRefs: store.containingRefs,
                onSelectParent: { store.showCommit(hash: $0) }
            )
        case .stash(let stash):
            DiffView(title: stash.title, subtitle: "스태시", files: store.diffFiles, isLoading: store.isLoadingDiff, change: nil)
        case .compare(let base, let head):
            CompareDetailView(base: base, head: head, files: store.diffFiles, isLoading: store.isLoadingDiff)
        case .fileHistory(let path):
            FileHistoryView(path: path, commits: store.fileHistoryCommits, isLoading: store.isLoadingDiff)
        case .blame(let path):
            BlameView(path: path, lines: store.blameLines, isLoading: store.isLoadingDiff)
        case nil:
            EmptyState(
                title: "선택된 항목이 없습니다",
                message: "변경된 파일이나 커밋을 고르면 변경 내용이 여기에 나옵니다.",
                systemImage: "doc.text.magnifyingglass"
            )
        }
    }
}

/// 사이드바 왼쪽 아이콘 줄. 작업 칸(변경 사항·히스토리·활동)을 고른다. 사이드바를 접어도 남는다.
private struct SidebarRail: View {
    @Environment(RepositoryStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var selectionSpace

    /// 고른 작업 칸. 사이드바에서 브랜치 등을 고르면 없다.
    private var activePane: RepositoryStore.Pane? {
        store.sidebarSelection == nil ? store.pane : nil
    }

    var body: some View {
        VStack(spacing: 6) {
            Color.clear.frame(height: 6)
                .titleBarDoubleClick()
            // 로고 자리. 로고는 SidebarColumn이 그린다.
            Color.clear.frame(height: 30)
            HairlineDivider().padding(.horizontal, 10).padding(.vertical, 4)
            ForEach(RepositoryStore.Pane.allCases) { pane in
                let active = activePane == pane
                Button {
                    store.sidebarSelection = nil
                    store.pane = pane
                } label: {
                    Image(systemName: pane.symbol)
                        .font(.system(size: 13))
                        .foregroundStyle(active ? Theme.text : Theme.secondary)
                        .frame(width: 32, height: 30)
                        // 바뀐 파일이 있으면 파란 점, 충돌이 있으면 빨간 점. 강조색은 테마에 따라 빨갈 수 있어 쓰지 않는다.
                        .overlay(alignment: .topTrailing) {
                            if pane == .changes, !store.status.changes.isEmpty {
                                Circle()
                                    .fill(store.conflicts.isEmpty ? Theme.blue : Theme.red)
                                    .frame(width: 6, height: 6)
                                    .offset(x: -5, y: 5)
                            }
                        }
                        // 선택 배경은 하나만 두고 고른 칸으로 옮겨 간다.
                        // 아이콘 줄은 바탕이 진해서 panelRaised(밝은 테마에서 #EFEFEF)가 묻힌다. 바탕 위에 반투명을 얹는다.
                        .background {
                            if active {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.07))
                                    .matchedGeometryEffect(id: "selection", in: selectionSpace)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help(pane == .changes && !store.status.changes.isEmpty ? "\(pane.title) \(store.status.changes.count)" : pane.title)
            }
            .animation(.easeInOut(duration: 0.2), value: activePane)
            Spacer()
            // 펼쳐 있으면 목록 칸 아래 저장소 칸이 같은 일을 한다
            Button { store.showsSidebar = true } label: {
                Image(systemName: "folder.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.green)
                    .frame(width: 32, height: 32)
                    .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help(store.repositoryName + "\n사이드바 펼치기")
            .padding(.bottom, 12)
            .opacity(store.showsSidebar ? 0 : 1)
            .allowsHitTesting(!store.showsSidebar)
        }
        .frame(maxHeight: .infinity)
        // 목록 칸보다 조금 진하게 해서 두 칸을 나눈다
        .background(Theme.sidebar.overlay(Color.black.opacity(colorScheme == .dark ? 0.22 : 0.035)))
    }
}

/// 오른쪽 패널 위의 탭 줄. 열어 본 것들을 오가고 닫는다.
/// 오른쪽 패널 맨 위 줄. 뒤로·앞으로와 지나온 길. 지금 보는 칸은 진하게, 앞으로 갈 칸은 흐리게.
private struct DetailNavBar: View {
    @Environment(RepositoryStore.self) private var store

    var body: some View {
        HStack(spacing: 2) {
            Button { store.goBack() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(IconButtonStyle(size: 24))
                .disabled(!store.canGoBack)
                .help("뒤로 (⌘[)")
            Button { store.goForward() } label: { Image(systemName: "chevron.right") }
                .buttonStyle(IconButtonStyle(size: 24))
                .disabled(!store.canGoForward)
                .help("앞으로 (⌘])")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(store.trail.enumerated()), id: \.offset) { index, item in
                        if index > 0 {
                            Image(systemName: "chevron.compact.right")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.tertiary)
                        }
                        Crumb(item: item, position: index == store.trailIndex ? .current : (index < store.trailIndex ? .past : .ahead)) {
                            store.showTrail(at: index)
                        }
                        .id(index)
                    }
                }
                .padding(.leading, 6)
            }
            // 길이 길어도 지금 칸이 보이게 오른쪽 끝에 붙인다
            .defaultScrollAnchor(.trailing)
            Spacer(minLength: 0)
            Button {
                store.expandsDetail.toggle()
            } label: {
                Image(systemName: store.expandsDetail ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(IconButtonStyle(size: 24))
            .help(store.expandsDetail ? "원래 폭으로" : "넓게 보기\n가운데 칸을 잠시 접습니다")
        }
        .padding(.horizontal, 10)
        // 넓게 보기에서 사이드바까지 접혀 있으면 신호등 버튼이 이 줄까지 넘어온다
        .padding(.leading, store.expandsDetail && !store.showsSidebar ? 30 : 0)
        .frame(height: StatusBand.height)
        .background(Theme.sidebar)
    }
}

/// 지나온 길의 한 칸
private struct Crumb: View {
    enum Position { case past, current, ahead }

    @Environment(\.onPanel) private var onPanel
    let item: RepositoryStore.Detail
    let position: Position
    let action: () -> Void
    @State private var hovering = false

    private var textColor: Color {
        switch position {
        case .current: Theme.text
        case .past: Theme.secondary
        case .ahead: Theme.tertiary
        }
    }

    private var fillColor: Color {
        if position == .current {
            return onPanel ? Theme.panelRaised : Theme.surface
        }
        if hovering {
            return onPanel ? Theme.panelHover : Theme.hover
        }
        return Color.clear
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: item.symbol)
                    .font(.system(size: 10))
                Text(item.crumbTitle)
                    .font(.system(size: 12, weight: position == .current ? .semibold : .regular))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(textColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(fillColor, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(position == .current ? item.title : "\(item.title)\n누르면 여기로 돌아갑니다")
    }
}

/// 스태시 하나의 머리말과 바뀐 파일 목록.
struct StashView: View {
    @Environment(RepositoryStore.self) private var store
    let stash: Stash

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "tray")
                        .foregroundStyle(Theme.secondary)
                    Text(stash.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                HStack(spacing: 6) {
                    if let branch = stash.branch {
                        Text(branch)
                    }
                    Text(stash.date, format: .dateTime.year().month().day().hour().minute())
                    Spacer()
                    Text(stash.ref)
                        .font(.system(size: 11, design: .monospaced))
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
                HStack(spacing: 8) {
                    Button("적용") { Task { await store.applyStash(stash, pop: false) } }
                        .buttonStyle(PillButtonStyle(prominent: true, compact: true))
                    Button("적용 후 삭제") { Task { await store.applyStash(stash, pop: true) } }
                        .buttonStyle(PillButtonStyle(compact: true))
                    Spacer()
                    Button("삭제…") { store.dropStash(stash) }
                        .buttonStyle(PillButtonStyle(compact: true))
                }
                .disabled(store.isBusy)
            }
            .padding(16)
            HairlineDivider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    SectionTitle("바뀐 파일 (\(store.diffFiles.count))")
                    ForEach(store.diffFiles) { file in
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text")
                                .foregroundStyle(Theme.secondary)
                            Text(file.displayPath)
                                .font(.system(size: 13))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            DiffCountLabel(additions: file.additions, deletions: file.deletions)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    }
                }
                .padding(.horizontal, 8)
            }
        }
    }
}

/// "+12 −3" 모양의 작은 숫자.
struct DiffCountLabel: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: 4) {
            if additions > 0 { Text("+\(additions)").foregroundStyle(Theme.added) }
            if deletions > 0 { Text("−\(deletions)").foregroundStyle(Theme.red) }
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
    }
}
