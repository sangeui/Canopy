import AppKit
import SwiftUI

/// 창 크기와 위치를 기억하고, 숨긴 제목 표시줄 자리를 두 번 누르면 창을 키운다.
/// 번들 없이 실행해도 되게 autosave 이름을 직접 주고, 제목 표시줄 띠는 AppKit이 끌기용으로 먼저 받으므로
/// 창 단위 이벤트 감시로 두 번 클릭을 잡는다.
private struct WindowFrameSaver: NSViewRepresentable {
    static let titleBarHeight: CGFloat = 28
    private static var monitor: Any?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.setFrameAutosaveName("CanopyMainWindow")
            // 제목 표시줄을 투명하게 해서 맨 위까지 테마 색이 이어지게 한다.
            // `.hiddenTitleBar`가 이미 맞춰 둔 것은 다시 넣지 않는다. 같은 값이라도 넣으면 제목 표시줄을 다시 배치해서
            // 신호등 버튼이 그려지지 않은 채 남는 때가 있었다.
            if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
            if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
            if window.titlebarSeparatorStyle != .none { window.titlebarSeparatorStyle = .none }
            if !window.styleMask.contains(.fullSizeContentView) { window.styleMask.insert(.fullSizeContentView) }
            window.backgroundColor = NSColor(Theme.sidebar)
            Self.installMonitor()
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    private static func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            Timing.log("mouse down")
            guard event.clickCount == 2, let window = event.window, let content = window.contentView,
                  window.frameAutosaveName == "CanopyMainWindow" else { return event }
            let point = event.locationInWindow
            let inTitleBar = point.y > content.bounds.height - titleBarHeight
            // 신호등 버튼 같은 AppKit 컨트롤 위는 건드리지 않는다.
            if inTitleBar, !(content.hitTest(point) is NSControl) {
                let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
                switch action {
                case "Minimize": window.miniaturize(nil)
                case "None": break
                default: window.performZoom(nil)
                }
                return nil
            }
            return event
        }
    }
}

/// 창의 신호등 버튼을 지킨다.
///
/// 제목 표시줄을 숨긴 창에서는 SwiftUI 화면(AppKitWindowHostingView)과 신호등 버튼이 든 제목 표시줄 뷰가
/// 창 맨 위 뷰(NSThemeFrame) 안에 나란히 놓인다. 이따금 SwiftUI 화면이 제목 표시줄 뷰보다 위로 올라가면
/// 불투명한 사이드바가 버튼을 덮어 버튼이 사라진 것처럼 보였다(버튼 자체는 숨김도 투명도도 정상).
/// 그 순서를 확인해서 제목 표시줄 뷰를 맨 위로 되돌린다.
enum WindowChrome {
    @MainActor static func keepTitlebarOnTop(_ window: NSWindow) {
        guard let close = window.standardWindowButton(.closeButton),
              let frameView = window.contentView?.superview else { return }
        // 닫기 버튼에서 위로 올라가 창 맨 위 뷰의 바로 아래 자식(제목 표시줄 컨테이너)을 찾는다
        var container: NSView = close
        while let parent = container.superview, parent !== frameView { container = parent }
        guard container.superview === frameView, frameView.subviews.last !== container else { return }
        frameView.addSubview(container, positioned: .above, relativeTo: nil)
        Timing.log("titlebar raised above content")
    }

    /// 사이드바 버튼을 누르면 할 일. ContentView가 넣는다.
    @MainActor static var toggleSidebar: (() -> Void)?
    /// 사이드바 버튼을 보일지. 첫 화면에는 사이드바가 없어서 숨긴다. ContentView가 넣는다.
    @MainActor static var showsSidebarToggle = false
    @MainActor private static let target = ButtonTarget()

    /// 사이드바 버튼을 신호등 버튼 바로 오른쪽에 고정한다(Finder·Xcode처럼).
    /// 사이드바를 접든 펴든 같은 자리에 있다. SwiftUI 화면은 제목 표시줄 아래에 깔려 그 자리를 누를 수 없어서
    /// 신호등 버튼이 든 제목 표시줄 뷰에 AppKit 단추로 넣는다.
    @MainActor static func keepSidebarToggle(_ window: NSWindow) {
        guard let zoom = window.standardWindowButton(.zoomButton), let titlebar = zoom.superview else { return }
        let id = NSUserInterfaceItemIdentifier("canopy.sidebarToggle")
        let button: NSButton
        if let existing = titlebar.subviews.first(where: { $0.identifier == id }) as? NSButton {
            button = existing
        } else {
            let image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "사이드바")?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
            button = NSButton(image: image ?? NSImage(), target: target, action: #selector(ButtonTarget.press))
            button.identifier = id
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.toolTip = "사이드바 접기와 펼치기 (⌃⌘S)"
            titlebar.addSubview(button)
        }
        let frame = NSRect(x: zoom.frame.maxX + 14, y: zoom.frame.midY - 11, width: 22, height: 22)
        if button.frame != frame { button.frame = frame }
        if button.isHidden == showsSidebarToggle { button.isHidden = !showsSidebarToggle }
        // 사이드바가 늘 어두운 테마에서는 밝게, 아니면 시스템 보조 글자색
        let tint = AppTheme.shared.palette.sidebarScheme == .dark ? NSColor.white.withAlphaComponent(0.7) : NSColor.secondaryLabelColor
        if button.contentTintColor != tint { button.contentTintColor = tint }
    }

    private final class ButtonTarget: NSObject {
        @objc func press() { MainActor.assumeIsolated { WindowChrome.toggleSidebar?() } }
    }
}

/// 앱 단위 이벤트. Dock 아이콘을 눌렀을 때와 미니 창을 닫았을 때 메인 창을 되살린다.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var closeObserver: Any?
    private var updateObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 미니 창을 빨간 단추로 닫으면 숨겨 둔 메인 창을 다시 보인다. 안 그러면 보이는 창이 하나도 없다.
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow, window.identifier?.rawValue.contains(MiniMode.windowID) == true else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { MiniMode.showMainWindow() } }
        }
        // 창이 갱신될 때마다 제목 표시줄 뷰가 맨 위인지 본다. 포인터 비교 한 번이라 가볍다.
        updateObserver = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow, window.styleMask.contains(.fullSizeContentView) else { return }
            MainActor.assumeIsolated {
                WindowChrome.keepTitlebarOnTop(window)
                // 사이드바 버튼은 메인 창에만
                if window.identifier?.rawValue.contains(MiniMode.windowID) != true {
                    WindowChrome.keepSidebarToggle(window)
                }
            }
        }
    }

    /// Dock 아이콘을 눌렀는데 보이는 창이 없으면 메인 창을 보인다.
    /// 숨겨 둔 메인 창이 있으면 그것을, 빨간 단추로 닫았으면 새로 연다.
    /// 이 메서드를 직접 구현하면 SwiftUI가 알아서 새 창을 열지 않으므로 여는 것까지 여기서 한다.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        MainActor.assumeIsolated { MiniMode.showMainWindow() }
        return false
    }
}

@main
struct CanopyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = RepositoryStore()

    init() {
        // `swift run`으로 띄우면 번들이 없어서 Dock에 안 나온다. 일반 앱처럼 보이게 한다.
        NSApplication.shared.setActivationPolicy(.regular)
        // 닫힌 파이프에 쓰다가 프로세스가 죽지 않게 한다.
        signal(SIGPIPE, SIG_IGN)
        // 번들 없이 `swift run`으로 띄워도 Dock에 우리 아이콘이 보이게 한다.
        // .app으로 띄우면 하지 않는다. 덮어쓰면 시스템이 라이트·다크에 맞춰 고르는 아이콘 대신 이 그림 하나로 굳는다.
        if Bundle.main.bundleURL.pathExtension != "app",
           let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"), let icon = NSImage(contentsOf: url) {
            NSApplication.shared.applicationIconImage = icon
        }
        AppTheme.shared.applyAppearance()
        // 창을 모두 닫고 끝냈을 때 다음 실행에서 "창 없음"을 되살리지 않는다. 언제 열어도 메인 창부터 보인다.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }

    @MainActor static func redo(_ store: RepositoryStore) {
        if textHandles(redo: true) {
            NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
        } else {
            Task { await store.redo() }
        }
    }

    /// ⌘Z를 글자 되돌리기로 보낼지. 커밋 메시지·검색·Claude 입력 칸처럼 편집할 수 있는 칸에 있고,
    /// 그 칸에 되돌릴 글자가 있을 때만 그렇다. diff 본문은 줄을 고르려고 포커스를 받지만 편집할 수 없으니 git 되돌리기로 간다.
    @MainActor static func textHandles(redo: Bool) -> Bool {
        guard let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.isEditable,
              let manager = text.undoManager else { return false }
        return redo ? manager.canRedo : manager.canUndo
    }

    var body: some Scene {
        WindowGroup(AppInfo.name, id: MiniMode.mainWindowID) {
            ContentView()
                .environment(store)
                .frame(minWidth: 1040, minHeight: 640)
                .background(WindowFrameSaver())
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }
        .windowStyle(.hiddenTitleBar)
        // 애플 뮤직의 미니 플레이어처럼 작은 창. 켜면 메인 창은 숨고, 크게 보기를 누르면 돌아온다.
        Window("Canopy 미니", id: MiniMode.windowID) {
            MiniView()
                .environment(store)
        }
        .windowStyle(.hiddenTitleBar)
        // 높이는 MiniWindowAccessor가 애니메이션으로 맞춘다. .contentSize로 두면 SwiftUI가 한 번에 바꿔서 튄다.
        .windowResizability(.contentMinSize)
        .defaultPosition(.topTrailing)
        .commands {
            // 단축키는 Fork 2.70의 메뉴를 그대로 따른다. Fork에 없는 것(Claude, 미니 모드, 활동)만 따로 정했다.
            CommandGroup(after: .appInfo) {
                Button("업데이트 확인…") { AppUpdater.shared.checkInteractively() }
            }
            CommandGroup(replacing: .appSettings) {
                Button("설정…") { store.showsSettings.toggle() }
                    .keyboardShortcut(",")
            }
            CommandGroup(replacing: .printItem) {}
            // 글을 쓰는 칸에 있으면 글자 되돌리기, 아니면 앱에서 한 git 작업 되돌리기
            CommandGroup(replacing: .undoRedo) {
                Button(store.undoTitle ?? "실행 취소") {
                    // ⇧⌘Z가 Shift를 무시하고 이 항목에 걸리는 때가 있다. 그때는 다시 하기로 보낸다.
                    if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                        Self.redo(store)
                    } else if Self.textHandles(redo: false) {
                        NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
                    } else {
                        Task { await store.undo() }
                    }
                }
                .keyboardShortcut("z")
                Button(store.redoTitle ?? "실행 복귀") { Self.redo(store) }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .newItem) {
                Button("저장소 클론…") { store.sheet = .clone }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("저장소 열기…") { store.openRepositoryPanel() }
                    .keyboardShortcut("o")
                Divider()
                Button("빠른 실행…") { store.showsPalette.toggle() }
                    .keyboardShortcut("p")
            }
            CommandMenu("저장소") {
                Button("커밋") { store.focusCommitMessage() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(!store.isOpen)
                Divider()
                Button("페치") { Task { await store.fetch() } }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .disabled(!store.isOpen)
                Button("풀…") { store.showPull() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(!store.isOpen)
                Button("푸시…") { store.showPush() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(!store.isOpen)
                Divider()
                Button("스태시 저장…") { store.sheet = .newStash }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                    .disabled(!store.isOpen || store.status.changes.isEmpty)
                Button("바로 스태시") { Task { await store.quickStash() } }
                    .keyboardShortcut("h", modifiers: [.command, .shift, .option])
                    .disabled(!store.isOpen || store.status.changes.isEmpty)
                Divider()
                Button("브랜치 체크아웃…") { store.showsBranchSwitcher = true }
                    .keyboardShortcut("b")
                    .disabled(!store.isOpen)
                Button("새 브랜치…") { store.sheet = .newBranch }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                    .disabled(!store.isOpen)
                Button("새 태그…") { store.newTagAtHead() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(!store.isOpen || !store.hasHead)
                Button("새 워크트리…") { store.sheet = .newWorktree }
                    .disabled(!store.isOpen)
                Divider()
                GitFlowMenu(store: store)
                    .disabled(!store.isOpen || store.isBusy)
                Button("PR 만들기") { if let branch = store.status.branch { store.openPullRequest(for: branch) } }
                    .disabled(!store.isOpen || store.status.branch.flatMap(store.pullRequestURL(for:)) == nil)
                Divider()
                Button("마지막 커밋 되돌리기…") { store.undoLastCommit() }
                    .disabled(!store.isOpen || !store.hasHead)
                Divider()
                Button("Finder에서 보기") { if let path = store.activeWorktreePath { store.revealInFinder(path) } }
                    .keyboardShortcut("o", modifiers: [.command, .control])
                    .disabled(!store.isOpen)
                Button("터미널에서 열기") { if let path = store.activeWorktreePath { store.openInTerminal(path) } }
                    .keyboardShortcut("t", modifiers: [.command, .control])
                    .disabled(!store.isOpen)
            }
            CommandMenu("변경 사항") {
                // 엔터·스페이스·⌫는 변경 목록이 직접 받는다. 메뉴에 걸면 글 입력 칸의 엔터까지 가로챈다.
                Button("선택한 파일 스테이징/해제 (⏎)") { Task { await store.stageOrUnstageSelected() } }
                    .disabled(store.selectedChanges.isEmpty)
                Button("선택한 변경 버리기… (⌫)") { store.discardSelectedChange() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(store.selectedChanges.isEmpty)
                Divider()
                Button("모두 스테이징") { Task { await store.stageAll() } }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                    .disabled(store.status.unstaged.isEmpty)
                Button("모두 해제") { Task { await store.unstageAll() } }
                    .keyboardShortcut("s", modifiers: [.command, .option, .shift])
                    .disabled(store.status.staged.isEmpty)
                Button("추적 안 된 파일 정리…") { store.cleanUntracked() }
                    .disabled(!store.isOpen)
                Divider()
                Button("커밋") { Task { await store.commit() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!store.canCommit)
                Button("커밋하고 푸시") { Task { await store.commitAndPush() } }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .disabled(!store.canCommit)
            }
            CommandMenu("보기") {
                Button("변경 사항") {
                    store.sidebarSelection = nil
                    store.pane = .changes
                }
                .keyboardShortcut("1")
                .disabled(!store.isOpen)
                Button("모든 커밋 (히스토리)") {
                    store.sidebarSelection = nil
                    store.pane = .history
                }
                .keyboardShortcut("2")
                .disabled(!store.isOpen)
                Button("활동") {
                    store.sidebarSelection = nil
                    store.pane = .activity
                }
                .keyboardShortcut("3")
                .disabled(!store.isOpen)
                Button("잃어버린 커밋 (활동)") {
                    store.sidebarSelection = nil
                    store.pane = .activity
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])
                .disabled(!store.isOpen)
                Divider()
                Button("HEAD 보기") { store.revealHead() }
                    .keyboardShortcut("0")
                    .disabled(!store.isOpen || !store.hasHead)
                Button("커밋 찾기") { store.focusCommitSearch() }
                    .keyboardShortcut("f")
                    .disabled(!store.isOpen)
                Button(store.historyScope == .all ? "현재 브랜치만 보기" : "모든 브랜치 보기") { store.toggleCurrentBranchFilter() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(!store.isOpen)
                Divider()
                Button("뒤로") { store.goBack() }
                    .keyboardShortcut("[")
                    .disabled(!store.canGoBack)
                Button("앞으로") { store.goForward() }
                    .keyboardShortcut("]")
                    .disabled(!store.canGoForward)
                Menu("커밋 상세") {
                    Button("메시지") { store.commitTab = .message }
                        .keyboardShortcut("1", modifiers: [.command, .option])
                    Button("변경") { store.commitTab = .changes }
                        .keyboardShortcut("2", modifiers: [.command, .option])
                    Button("위치") { store.commitTab = .place }
                        .keyboardShortcut("3", modifiers: [.command, .option])
                }
                Button(store.showsDetail ? "오른쪽 패널 숨기기" : "오른쪽 패널 보기") { store.showsDetail.toggle() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button(store.showsSidebar ? "사이드바 숨기기" : "사이드바 보기") { store.showsSidebar.toggle() }
                    .keyboardShortcut("s", modifiers: [.command, .control])
                    .disabled(!store.isOpen)
                Divider()
                Button("새로고침") { Task { await store.refresh() } }
                    .keyboardShortcut("r")
                    .disabled(!store.isOpen)
                Divider()
                Button(store.showsAssistant ? "Claude 닫기" : "Claude") { store.toggleAssistant() }
                    .keyboardShortcut("i")
                    .disabled(!store.isOpen || !store.assistantAvailable)
                Button("미니 모드 전환") { MiniMode.enter() }
                    .keyboardShortcut("m", modifiers: [.command, .option])
                    .disabled(!store.isOpen)
            }
        }
    }
}
