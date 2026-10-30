import AppKit
import SwiftUI

/// 미니 모드 전환. 애플 뮤직의 미니 플레이어처럼 메인 창을 숨기고 작은 창 하나만 띄운다.
/// 메인 창은 닫지 않고 숨기기만 해서, 고른 커밋·창 크기·새로고침이 그대로 산다.
@MainActor
enum MiniMode {
    nonisolated static let windowID = "mini"
    nonisolated static let mainWindowID = "main"
    /// SwiftUI의 창 열기 동작. 메인 창이 처음 뜰 때 받아 둔다. 창이 모두 닫힌 뒤에도 이것으로 새로 연다.
    static var openWindow: OpenWindowAction?
    static let enterNotification = Notification.Name("CanopyEnterMiniMode")

    static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.frameAutosaveName == "CanopyMainWindow" }
    }

    /// 메인 창을 앞으로. 숨겨 둔 것이 있으면 다시 보이고, 닫혀서 없으면 새로 연다.
    static func showMainWindow() {
        if let main = mainWindow {
            main.makeKeyAndOrderFront(nil)
        } else {
            openWindow?(id: mainWindowID)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    static var miniWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.contains(windowID) == true }
    }

    /// 미니 창이 떠 있는지
    static var isShowing: Bool { miniWindow?.isVisible == true }

    /// ⌥⌘M. 미니 창이 떠 있으면 크게, 아니면 미니로.
    static func enter() {
        if miniWindow?.isVisible == true {
            leave()
        } else {
            NotificationCenter.default.post(name: enterNotification, object: nil)
        }
    }

    /// 메인 창을 다시 보이고 미니 창을 닫는다.
    static func leave() {
        showMainWindow()
        miniWindow?.close()
    }
}

/// 미니 창. 지금 브랜치가 "재생 중인 곡"이고 페치·풀·푸시가 재생 버튼이다.
/// 펼치면 변경 목록과 한 줄 커밋 칸이 나온다.
struct MiniView: View {
    @Environment(RepositoryStore.self) private var store
    @AppStorage("miniExpanded") private var expanded = false
    @AppStorage("miniFloating") private var floating = true
    /// 내용이 원하는 높이. 창 높이는 SwiftUI에 맡기지 않고 이 값으로 직접 애니메이션한다.
    @State private var contentHeight: CGFloat = 0

    static let width: CGFloat = 360
    /// 펼치고 접는 시간. 창 높이와 안쪽 내용이 같은 시간에 움직여야 튀지 않는다.
    static let expandDuration: Double = 0.18
    static let titleBarHeight: CGFloat = 28

    /// 미니 창에서 띄우는 창은 푸시·풀뿐이다. 나머지는 메인 창으로 돌아가서 한다.
    /// `store.sheet`는 여기서 바로 읽는다. Binding의 get 안에서만 읽으면 값이 바뀌어도 화면이 모른다.
    private var miniSheetBinding: Binding<RepositoryStore.Sheet?> {
        let sheet: RepositoryStore.Sheet?
        switch store.sheet {
        case .push, .pull: sheet = MiniMode.isShowing ? store.sheet : nil
        default: sheet = nil
        }
        return Binding(get: { sheet }, set: { store.sheet = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if expanded {
                // 창이 아래로 열리며 드러나므로 제자리에서 흐려지기만 한다. 위에서 내려오면 윗줄과 겹친다.
                MiniChanges()
                    .transition(.opacity)
            }
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        // 내용은 제목 표시줄 아래(안전 영역)부터 놓인다. 첫 줄을 제목 표시줄 자리로 끌어올린다.
        .padding(.top, -MiniView.titleBarHeight)
        // 창이 내용보다 작거나 큰 동안(애니메이션 중)에도 위에 붙어 있고 넘치는 것은 잘린다.
        // 최소 높이를 0으로 둬야 SwiftUI가 내용 높이를 창 최소 높이로 잡아 줄어드는 창을 되돌리지 않는다.
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
        .clipped()
        .background(Theme.sidebar)
        .panelStyle()
        .background(MiniWindowAccessor(floating: floating, height: contentHeight, duration: Self.expandDuration))
        .animation(.easeInOut(duration: Self.expandDuration), value: expanded)
        .sheet(item: miniSheetBinding) { sheet in
            switch sheet {
            case .push: PushSheet()
            default: PullSheet()
            }
        }
        .onDisappear {
            // 빨간 단추로 닫아도 메인 창은 돌아와야 한다.
            MiniMode.mainWindow?.makeKeyAndOrderFront(nil)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 첫 줄: 신호등 자리, 저장소 이름, 고정, 크게 보기
            HStack(spacing: 6) {
                Color.clear.frame(width: 58, height: 1)
                Text(store.repositoryName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                Spacer()
                Button { floating.toggle() } label: {
                    Image(systemName: floating ? "pin.fill" : "pin")
                }
                .buttonStyle(IconButtonStyle(size: 24))
                .help(floating ? "항상 위에 두지 않기" : "항상 위에 두기")
                Button { MiniMode.leave() } label: {
                    Image(systemName: "pip.exit")
                }
                .buttonStyle(IconButtonStyle(size: 24))
                .help("크게 보기 (⌥⌘M)")
            }
            .frame(height: 22)

            // 둘째 줄: 브랜치 이름. 길면 앞쪽 폴더부터 뺀다.
            HStack(spacing: 8) {
                Image(systemName: store.status.isDetached && store.detachedPlace?.rebasingBranch == nil ? "circle.dotted" : "arrow.triangle.branch")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(store.isAwayFromBranch ? Theme.orange : Theme.green)
                ViewThatFits(in: .horizontal) {
                    Text(store.branchDisplayName).fixedSize()
                    Text(lastComponent).fixedSize()
                    Text(lastComponent).lineLimit(1).truncationMode(.middle)
                }
                .font(.system(size: 17, weight: .semibold))
                .help(store.branchDisplayName)
                Spacer(minLength: 0)
            }

            // 셋째 줄: 상태와 동기화. 좁으면 동기화 버튼이 아이콘만 남는다.
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(changeSummary)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    SyncDescription(size: 11)
                }
                Spacer(minLength: 8)
                SyncControl(compact: true)
            }

            // 마지막 줄: 최근 활동과 펼치기
            HStack(spacing: 6) {
                if let last = store.lastActivity {
                    Image(systemName: last.kind.symbol)
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.tertiary)
                    Text(last.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(last.date, format: .relative(presentation: .named))
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
                Spacer(minLength: 4)
                Button { expanded.toggle() } label: {
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .buttonStyle(IconButtonStyle(size: 22))
                .help(expanded ? "접기" : "변경 사항과 커밋")
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .contentShape(Rectangle())
        // 빈 곳을 두 번 누르면 크게 보기
        .onTapGesture(count: 2) { MiniMode.leave() }
    }

    private var lastComponent: String {
        store.branchDisplayName.split(separator: "/").last.map(String.init) ?? store.branchDisplayName
    }

    private var changeSummary: String {
        if !store.conflicts.isEmpty { return "충돌 \(store.conflicts.count)개" }
        if store.status.changes.isEmpty { return "변경 없음" }
        var parts = ["변경 \(Set(store.status.changes.map(\.path)).count)개"]
        if !store.status.staged.isEmpty { parts.append("스테이징 \(store.status.staged.count)") }
        return parts.joined(separator: ", ")
    }
}

/// 펼친 미니 창의 아래쪽. 변경 파일을 눌러 스테이징하고 한 줄로 커밋한다.
private struct MiniChanges: View {
    @Environment(RepositoryStore.self) private var store
    @FocusState private var editing: Bool

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            if store.status.changes.isEmpty {
                Text("커밋할 변경이 없습니다")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(store.orderedChanges) { change in
                            row(change)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(height: min(CGFloat(store.status.changes.count) * 28 + 12, 220))
            }
            HStack(spacing: 8) {
                TextField("커밋 메시지", text: $store.commitMessage)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($editing)
                    .onSubmit { commit() }
                Button { commit() } label: {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(SendButtonStyle())
                .disabled(!store.canCommit)
                .help(store.status.staged.isEmpty ? "스테이징한 파일이 없습니다" : "파일 \(store.status.staged.count)개 커밋 (⏎)")
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            // 띠 색 위에 흰색을 살짝 얹는다. 진한 테마에서 검은 칸이 되지 않게.
            .background(Theme.panelRaised, in: Capsule())
            .overlay(Capsule().stroke(Theme.panelBorder, lineWidth: 1))
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            .padding(.top, 4)
        }
        .overlay(alignment: .top) { HairlineDivider().opacity(0.6) }
    }

    private func row(_ change: FileChange) -> some View {
        HStack(spacing: 8) {
            Button { Task { await store.toggleStaged(change) } } label: {
                Image(systemName: change.isStaged ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(change.isStaged ? Theme.green : Theme.tertiary)
            }
            .buttonStyle(.plain)
            .disabled(change.area == .conflicted || store.isBusy)
            .help(change.isStaged ? "스테이징 해제" : "스테이징")
            Text(change.fileName)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(change.directory)
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 4)
            Text(String(change.kind.rawValue))
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.secondary)
        }
        .padding(.horizontal, 14)
        .frame(height: 27)
        .contentShape(Rectangle())
        .onTapGesture {
            guard change.area != .conflicted else { return }
            Task { await store.toggleStaged(change) }
        }
    }

    private func commit() {
        guard store.canCommit else { return }
        Task { await store.commit() }
    }
}

/// 미니 창의 AppKit 설정. 항상 위, 모든 데스크톱에 보이기, 창 크기 고정.
private struct MiniWindowAccessor: NSViewRepresentable {
    let floating: Bool
    /// 창 높이. 바뀌면 위쪽 가장자리를 그대로 두고 내용과 같은 시간에 늘이거나 줄인다.
    /// SwiftUI가 내용 크기로 창을 맞추게 두면 창은 한 번에 바뀌고 내용만 따로 움직여서 튄다.
    let height: CGFloat
    let duration: Double

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { apply(to: view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { apply(to: view.window) }
    }

    private func apply(to window: NSWindow?) {
        guard let window else { return }
        window.level = floating ? .floating : .normal
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        if floating { window.collectionBehavior.insert(.canJoinAllSpaces) } else { window.collectionBehavior.remove(.canJoinAllSpaces) }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        // 내용이 제목 표시줄 자리까지 올라가서 첫 줄이 신호등 버튼과 나란히 선다.
        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }

        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(Theme.sidebar)
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = true
        window.styleMask.remove(.resizable)
        resize(window)
    }

    private func resize(_ window: NSWindow) {
        guard height > 0, abs(window.frame.height - height) > 0.5 else { return }
        var frame = window.frame
        frame.origin.y = frame.maxY - height
        frame.size.height = height
        // 처음 뜰 때는 바로 맞춘다
        guard window.isVisible else {
            window.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(frame, display: true)
        }
    }
}
