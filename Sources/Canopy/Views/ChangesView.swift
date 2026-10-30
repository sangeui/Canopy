import SwiftUI

struct ChangesView: View {
    @Environment(RepositoryStore.self) private var store
    @State private var filter = ""
    @FocusState private var listFocused: Bool
    @State private var selectAllMonitor: Any?

    private var query: String { filter.trimmed.lowercased() }

    private func matches(_ change: FileChange) -> Bool {
        query.isEmpty || change.path.lowercased().contains(query)
    }

    var body: some View {
        VStack(spacing: 0) {
            if store.status.changes.count > 8 {
                SearchField(text: $filter, placeholder: "파일 이름으로 찾기")
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
            if store.status.changes.isEmpty {
                // 고칠 것이 없으면 빈 묶음 둘 대신 한 줄. "깨끗함"은 머리글 아래 상태 줄이 이미 말한다.
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(Theme.tertiary)
                    Text("커밋할 변경이 없습니다")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !store.conflicts.isEmpty {
                        SectionTitle("충돌 (\(store.conflicts.count))")
                        ForEach(store.conflicts.filter(matches)) { change in
                            ChangeRow(change: change)
                        }
                        Text("파일을 고쳐서 저장한 뒤 \"해결됨으로 표시\"하거나, 한쪽 변경만 남길 수 있습니다.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondary)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 8)
                    }

                    SectionTitle("스테이징됨 (\(store.status.staged.count))") {
                        if !store.status.staged.isEmpty {
                            Button("모두 해제") { Task { await store.unstageAll() } }
                                .buttonStyle(TextButtonStyle())
                                .disabled(store.isBusy)
                        }
                    }
                    if store.status.staged.isEmpty {
                        EmptyRow(text: "체크하거나 ⏎로 스테이징")
                    }
                    ForEach(store.status.staged.filter(matches)) { change in
                        ChangeRow(change: change)
                    }

                    if !unstaged.isEmpty {
                        SectionTitle("변경 사항 (\(unstaged.count))") {
                            Button("모두 스테이징") { Task { await store.stageAll() } }
                                .buttonStyle(TextButtonStyle())
                                .disabled(store.isBusy)
                        }
                        .padding(.top, 10)
                    }
                    ForEach(unstaged.filter(matches)) { change in
                        ChangeRow(change: change)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .animation(.easeInOut(duration: 0.2), value: store.status.changes)
            }
            // Fork처럼 키보드로: 엔터 = 스테이징/해제, 스페이스 = 토글, Delete = 버리기, 위아래(+Shift) = 이동, ⌘A = 모두 선택
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onKeyPress(phases: .down) { press in
                switch press.key {
                case .return:
                    Task { await store.stageOrUnstageSelected() }
                case .space:
                    Task { await store.toggleSelectedChange() }
                case .delete, .deleteForward, KeyEquivalent("\u{7F}"):
                    store.discardSelectedChange()
                case .upArrow:
                    store.moveChangeSelection(by: -1, extend: press.modifiers.contains(.shift))
                case .downArrow:
                    store.moveChangeSelection(by: 1, extend: press.modifiers.contains(.shift))
                default:
                    return .ignored
                }
                return .handled
            }
            .onChange(of: store.selectedChangeID) { if store.selectedChangeID != nil { listFocused = true } }
            // 같은 줄을 다시 눌러도 목록이 키보드를 받게 한다
            .simultaneousGesture(TapGesture().onEnded { listFocused = true })
            // ⌫: 맥에서 백스페이스는 onKeyPress(.delete)로 잘 안 들어온다. 삭제 명령으로 받는다.
            .onDeleteCommand { store.discardSelectedChange() }
            // ⌘A는 메뉴의 "모두 선택"이 먼저 가져가므로 창 단위로 가로챈다. 글을 쓰는 중이면 건드리지 않는다.
            .onAppear {
                guard selectAllMonitor == nil else { return }
                selectAllMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                          event.charactersIgnoringModifiers == "a",
                          listFocused,
                          !(event.window?.firstResponder is NSTextView) else { return event }
                    store.selectAllChanges()
                    return nil
                }
            }
            .onDisappear {
                if let selectAllMonitor { NSEvent.removeMonitor(selectAllMonitor) }
                selectAllMonitor = nil
            }
            }
            CommitComposer()
        }
    }

    private var unstaged: [FileChange] {
        store.status.unstaged.filter { $0.area != .conflicted }
    }
}

/// 둥근 검색 칸.
struct SearchField: View {
    @Environment(\.onPanel) private var onPanel
    @Binding var text: String
    let placeholder: String
    /// 값이 바뀌면 이 칸에 커서를 둔다 (⌘F 같은 단축키)
    var focusRequest = 0
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($focused)
                .onChange(of: focusRequest) { focused = true }
                .onAppear { if focusRequest > 0 { focused = true } }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        // 진한 테마의 사이드바 위에서는 어두운 회색 대신 흰색을 살짝 얹는다. 검게 보이지 않게.
        .background(onPanel ? Theme.panelRaised : Theme.raised, in: Capsule())
    }
}

private struct EmptyRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.tertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
    }
}

private struct ChangeRow: View {
    @Environment(RepositoryStore.self) private var store
    let change: FileChange

    var body: some View {
        SelectableRow(
            isSelected: store.selectedChangeIDs.contains(change.id),
            action: {
                let flags = NSEvent.modifierFlags
                store.selectChange(change.id, extend: flags.contains(.shift), toggle: flags.contains(.command))
            }
        ) {
            HStack(spacing: 10) {
                if change.area == .conflicted {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.red)
                } else {
                    Button {
                        Task { await store.toggleStaged(change) }
                    } label: {
                        Image(systemName: change.isStaged ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 15))
                            .foregroundStyle(change.isStaged ? Theme.green : Theme.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help(change.isStaged ? "스테이징 해제" : "스테이징")
                }

                Text(String(change.kind.rawValue))
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 18, height: 18)
                    .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(color)
                    .help(change.kind.label)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        if let original = change.originalPath {
                            Text((original as NSString).lastPathComponent)
                                .foregroundStyle(Theme.secondary)
                                .strikethrough()
                            Image(systemName: "arrow.right")
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.secondary)
                        }
                        Text(change.fileName)
                            .font(.system(size: 13))
                            .lineLimit(1)
                    }
                    if !change.directory.isEmpty {
                        Text(change.directory)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
            }
        }
        .contextMenu {
            if change.area == .conflicted {
                Button("내 변경만 남기기") { Task { await store.resolveConflict(change, keepOurs: true) } }
                Button("상대 변경만 남기기") { Task { await store.resolveConflict(change, keepOurs: false) } }
                Button("해결됨으로 표시") { Task { await store.markResolved(change) } }
                Divider()
            } else {
                Button(change.isStaged ? "스테이징 해제" : "스테이징") { Task { await store.toggleStaged(change) } }
                if !change.isStaged {
                    Button("변경 내용 버리기…", role: .destructive) { store.discard(change) }
                }
                Divider()
            }
            // 여러 개를 골랐고 그 안에서 눌렀으면 고른 것 모두를
            let targets = store.selectedChangeIDs.contains(change.id) ? store.selectedChanges : [change]
            Button(targets.count > 1 ? "\(targets.count)개 패치로 복사" : "패치로 복사") { Task { await store.copyPatch(for: targets) } }
                .disabled(change.area == .conflicted || targets.allSatisfy { $0.area == .untracked })
            if change.area == .untracked {
                Button("추적 안 된 파일 모두 정리…") { store.cleanUntracked() }
            }
            Button("기본 앱으로 열기") { store.openWithDefaultApp(change) }
            Button("Finder에서 보기") {
                if let path = store.absolutePath(of: change) { store.revealInFinder(path) }
            }
            Divider()
            FileHistoryMenuItems(path: change.path)
        }
    }

    private var color: Color {
        switch change.kind {
        case .added, .untracked: Theme.added
        case .deleted: Theme.red
        case .modified, .typeChanged: Theme.orange
        case .renamed, .copied: Theme.blue
        case .unmerged: Theme.red
        }
    }
}

/// 커밋 메시지 칸. 스테이징한 것이 없고 글도 없으면 한 줄로 접혀 있다가, 스테이징하거나 누르면 펼쳐진다.
private struct CommitComposer: View {
    @Environment(RepositoryStore.self) private var store
    @FocusState private var editing: Bool

    private var expanded: Bool {
        editing || !store.status.staged.isEmpty || !store.commitMessage.isEmpty || store.amend
    }

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $store.commitMessage)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, -4)
                    .focused($editing)
                if store.commitMessage.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.tertiary)
                        .padding(.top, 1)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: expanded ? 44 : 20, maxHeight: expanded ? 120 : 20)

            if expanded {
                HStack(spacing: 10) {
                    Toggle("마지막 커밋 수정", isOn: $store.amend)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .disabled(!store.hasHead)
                        .onChange(of: store.amend) { store.amendToggled() }
                    if store.assistantAvailable, !store.status.staged.isEmpty {
                        Button { store.askAssistant(action: .commitMessage) } label: {
                            HStack(spacing: 4) {
                                ClaudeMark(size: 10)
                                Text("메시지 제안")
                            }
                        }
                            .buttonStyle(TextButtonStyle())
                            .disabled(store.isAssistantRunning)
                            .help("스테이징한 변경으로 커밋 메시지를 제안받습니다")
                    }
                    Spacer()
                    Text(store.status.staged.isEmpty
                         ? "스테이징된 파일 없음"
                         : "파일 \(store.status.staged.count)개 → \(store.status.isDetached ? "분리된 HEAD" : store.branchDisplayName)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                    Button {
                        Task { await store.commit() }
                    } label: {
                        Image(systemName: "arrow.up")
                    }
                    .buttonStyle(SendButtonStyle())
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!store.canCommit)
                    .help("커밋 (⌘↩)")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, expanded ? 12 : 9)
        .padding(.bottom, expanded ? 10 : 9)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.border, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onTapGesture { editing = true }
        .onChange(of: store.commitMessageFocusRequest) { editing = true }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .animation(.easeInOut(duration: 0.18), value: expanded)
    }

    private var placeholder: String {
        if !store.conflicts.isEmpty { return "충돌을 먼저 정리하세요" }
        if store.status.staged.isEmpty, !editing { return "스테이징한 뒤 커밋 메시지를 적으세요" }
        return "커밋 메시지를 입력하세요"
    }
}
