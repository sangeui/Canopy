import SwiftUI

/// Claude 표시. 외부 이미지 에셋 없이 벡터로 그린다.
struct ClaudeMark: View {
    var size: CGFloat = 14
    var color = ClaudeMark.orange

    static let orange = Color(nsColor: NSColor(hex: 0xD97757))

    var body: some View {
        Canvas { context, canvas in
            let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
            let outer = min(canvas.width, canvas.height) * 0.46
            let inner = min(canvas.width, canvas.height) * 0.08
            let rays = 12
            var path = Path()
            for index in 0..<rays {
                let angle = Double(index) * (.pi * 2 / Double(rays)) - .pi / 8
                let length = (index % 3 == 0 ? 1.0 : (index % 2 == 0 ? 0.86 : 0.94)) * outer
                path.move(to: CGPoint(x: center.x + CGFloat(cos(angle)) * inner, y: center.y + CGFloat(sin(angle)) * inner))
                path.addLine(to: CGPoint(x: center.x + CGFloat(cos(angle)) * length, y: center.y + CGFloat(sin(angle)) * length))
            }
            context.stroke(
                path,
                with: .color(color),
                style: StrokeStyle(lineWidth: max(1.3, min(canvas.width, canvas.height) * 0.115), lineCap: .round)
            )
            let hub = min(canvas.width, canvas.height) * 0.11
            context.fill(
                Path(ellipseIn: CGRect(x: center.x - hub, y: center.y - hub, width: hub * 2, height: hub * 2)),
                with: .color(color)
            )
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Claude")
    }
}

/// 메인 창 오른쪽 아래에 떠 있는 Claude 카드. 오른쪽 패널과 따로라서 커밋이나 파일을 바꿔 봐도 닫히지 않는다.
struct AssistantCard: View {
    @Environment(RepositoryStore.self) private var store

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // 머리줄은 띠 없이 아이콘만. 왼쪽 표시는 이 카드가 Claude라는 것만 알린다.
                HStack(spacing: 4) {
                    ClaudeMark(size: 13)
                        .help("Claude")
                    Spacer()
                    if !store.assistantMessages.isEmpty {
                        Button { store.clearAssistant() } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(IconButtonStyle(size: 24))
                        .disabled(store.isAssistantRunning)
                        .help("대화 비우기")
                    }
                    Button { store.showsAssistant = false } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(IconButtonStyle(size: 24))
                    .help("닫기 (⌘I)")
                }
                .padding(.leading, 16)
                .padding(.trailing, 10)
                .frame(height: 40)
                AssistantView()
            }
            .frame(width: min(520, geometry.size.width - 32), height: min(700, geometry.size.height - 32))
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 20, y: 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(16)
        }
    }
}

/// Claude 카드 본문. 맨 위 칩이 질문에 같이 가는 것이고, 메인 창에서 보고 있는 것이 바뀌면 칩도 바뀐다.
struct AssistantView: View {
    @Environment(RepositoryStore.self) private var store
    @State private var draft = ""
    @FocusState private var editing: Bool

    var body: some View {
        VStack(spacing: 0) {
            if !store.assistantAvailable {
                EmptyState(
                    title: "claude CLI가 없습니다",
                    message: "Claude Code를 설치하면 여기서 바로 쓸 수 있습니다.",
                    systemImage: "terminal"
                )
                .safeAreaInset(edge: .bottom, spacing: 0) { floatingComposer }
            } else if store.assistantMessages.isEmpty {
                // 첫 화면: 입력칸 바로 위에 인사 한 줄과 바로 물을 수 있는 것들
                VStack(alignment: .leading, spacing: 10) {
                    Spacer(minLength: 0)
                    Text("무엇을 도와드릴까요?")
                        .font(.system(size: 17, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.bottom, 2)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(RepositoryStore.AssistantAction.allCases) { action in
                            SelectableRow(isSelected: false, action: { store.askAssistant(action: action) }) {
                                Label {
                                    Text(action.title).font(.system(size: 13))
                                } icon: {
                                    Image(systemName: Self.symbol(of: action))
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.secondary)
                                        .frame(width: 18)
                                }
                            }
                        }
                    }
                    .disabled(store.isAssistantRunning)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .safeAreaInset(edge: .bottom, spacing: 0) { floatingComposer }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(store.assistantMessages) { message in
                                AssistantBubble(message: message)
                                    .id(message.id)
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // 입력칸은 대화 위에 떠 있다. 스크롤 뷰에 바로 붙여야 대화가 입력칸 밑까지 이어진다.
                    .safeAreaInset(edge: .bottom, spacing: 0) { floatingComposer }
                    // 위 끝에서 글이 흐려지며 사라진다. 아래 끝은 floatingComposer 뒤의 그라데이션이 맡는다.
                    // 여기서 아래까지 가리면 입력칸 밑으로 지나가는 글까지 지워져 유리 너머로 아무것도 안 비친다.
                    .mask {
                        VStack(spacing: 0) {
                            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 18)
                            Color.black
                        }
                    }
                    .onChange(of: store.assistantMessages.last?.text) {
                        if let last = store.assistantMessages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface)
        .onAppear {
            #if CANOPY_DEV
            // 화면 확인용 입력. 배포 빌드는 읽지 않는다.
            if let seed = UserDefaults.standard.string(forKey: "debugDraft") {
                draft = seed
                editing = true
                // "/스킬 글"이면 스킬 목록이 읽힌 뒤 그 스킬을 칩으로 고르고 나머지를 입력으로 둔다
                if seed.hasPrefix("/"), let space = seed.firstIndex(of: " ") {
                    let name = String(seed[seed.index(after: seed.startIndex)..<space])
                    let rest = String(seed[seed.index(after: space)...])
                    Task {
                        for _ in 0..<20 {
                            try? await Task.sleep(for: .milliseconds(300))
                            if let match = store.skills.first(where: { $0.name == name }) {
                                pick(match)
                                draft = rest
                                return
                            }
                        }
                    }
                }
            }
            #endif
            // 자동완성이 떠 있을 때만 화살표·탭·esc를 가로챈다. 입력 칸이 먼저 가져가기 때문이다.
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // ⇧⏎는 보내지 않고 커서 자리에 줄을 바꾼다. 그냥 ⏎는 아래 onSubmit이 보낸다.
                if editing, event.keyCode == 36 || event.keyCode == 76,
                   event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .shift,
                   let textView = NSApp.keyWindow?.firstResponder as? NSTextView {
                    // 한글을 조합하는 중이면 그 글자를 먼저 확정한다. 안 그러면 줄바꿈이 조합 중인 글자를 덮는다.
                    if textView.hasMarkedText() { textView.unmarkText() }
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return nil
                }
                let items = suggestions
                guard !items.isEmpty else { return event }
                switch event.keyCode {
                case 126: _ = moveHighlight(-1); return nil
                case 125: _ = moveHighlight(1); return nil
                case 48: pick(items[min(highlighted, items.count - 1)]); return nil   // tab
                case 53: draft = ""; return nil
                default: return event
                }
            }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }

    static func symbol(of action: RepositoryStore.AssistantAction) -> String {
        switch action {
        case .explain: "text.magnifyingglass"
        case .review: "checklist"
        case .commitMessage: "square.and.pencil"
        }
    }

    /// 입력칸 왼쪽 아래 +. 빠른 질문과 스킬을 여기서 고른다.
    private var addMenu: some View {
        Menu {
            ForEach(RepositoryStore.AssistantAction.allCases) { action in
                Button { store.askAssistant(action: action) } label: {
                    Label(action.title, systemImage: Self.symbol(of: action))
                }
                .disabled(store.isAssistantRunning)
            }
            Divider()
            Button {
                skill = nil
                draft = "/"
                editing = true
            } label: {
                Label("스킬 사용 (/)", systemImage: "slash.circle")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!store.assistantAvailable)
        .help("빠른 질문과 스킬")
    }

    /// `/`로 시작하면 스킬 자동완성. 고르면 칩이 되고 입력은 인자만 받는다.
    @State private var skill: ClaudeSkill?
    @State private var highlighted = 0
    @State private var keyMonitor: Any?

    private var suggestions: [ClaudeSkill] {
        guard skill == nil, draft.hasPrefix("/"), !draft.contains(" ") else { return [] }
        let needle = draft.dropFirst().lowercased()
        let all = store.skills
        guard !needle.isEmpty else { return Array(all.prefix(8)) }
        let starts = all.filter { $0.name.lowercased().hasPrefix(needle) }
        let contains = all.filter { !$0.name.lowercased().hasPrefix(needle) && $0.name.lowercased().contains(needle) }
        return Array((starts + contains).prefix(8))
    }

    private var floatingComposer: some View {
        composer
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            // 입력칸 뒤로 바탕색이 점점 짙어져, 밑으로 지나가는 글이 유리 너머로 흐려지며 사라진다
            .background(alignment: .bottom) {
                // 입력칸 가운데쯤부터는 바탕색으로 꽉 채워, 입력칸 아래 여백으로 글이 새어 나오지 않게 한다
                LinearGradient(stops: [.init(color: Theme.surface.opacity(0), location: 0),
                                       .init(color: Theme.surface.opacity(0.9), location: 0.35),
                                       .init(color: Theme.surface, location: 0.6)],
                               startPoint: .top, endPoint: .bottom)
                    .padding(.top, -28)
                    .padding(.bottom, -40)
                    .allowsHitTesting(false)
            }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            ContextBar(commitMode: skill?.isAboutCommit == true)
            let items = suggestions
            if !items.isEmpty {
                SkillSuggestions(items: items, highlighted: min(highlighted, items.count - 1)) { pick($0) }
            }
            // 칩 글자와 입력 글자를 같은 기준선에 맞춘다. 위쪽에 맞추면 칩의 위아래 여백만큼 칩 글자가 내려간다.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let skill {
                    SkillChip(skill: skill) { self.skill = nil }
                }
                TextField(skill?.argumentHint ?? "Claude에게 물어보기", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...6)
                    .focused($editing)
                    .onSubmit { submit() }
                    .disabled(!store.assistantAvailable)
                    .onKeyPress(.upArrow) { moveHighlight(-1) }
                    .onKeyPress(.downArrow) { moveHighlight(1) }
                    .onKeyPress(.tab) {
                        let items = suggestions
                        guard !items.isEmpty else { return .ignored }
                        pick(items[min(highlighted, items.count - 1)])
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        guard !suggestions.isEmpty else { return .ignored }
                        draft = ""
                        return .handled
                    }
                    .onKeyPress(.delete) {
                        guard draft.isEmpty, skill != nil else { return .ignored }
                        skill = nil
                        return .handled
                    }
                    .onChange(of: draft) { highlighted = 0 }
            }
            HStack(spacing: 8) {
                addMenu
                    .padding(.leading, -6)
                Spacer()
                if store.isAssistantRunning {
                    Button {
                        store.cancelAssistant()
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(SendButtonStyle())
                    .help("중단")
                } else {
                    Button { send() } label: {
                        Image(systemName: "arrow.up")
                    }
                    .buttonStyle(SendButtonStyle())
                    .disabled((draft.trimmed.isEmpty && skill == nil) || !store.assistantAvailable)
                    .help("보내기 (⏎)\n줄바꿈 (⇧⏎)")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .modifier(ComposerSurface())
    }

    private func moveHighlight(_ delta: Int) -> KeyPress.Result {
        let count = suggestions.count
        guard count > 0 else { return .ignored }
        highlighted = (highlighted + delta + count) % count
        return .handled
    }

    private func pick(_ picked: ClaudeSkill) {
        skill = picked
        draft = ""
        highlighted = 0
        editing = true
    }

    /// 엔터. 자동완성이 떠 있으면 고르고, 아니면 보낸다.
    private func submit() {
        let items = suggestions
        if !items.isEmpty {
            pick(items[min(highlighted, items.count - 1)])
        } else {
            send()
        }
    }

    private func send() {
        let text = draft.trimmed
        guard !store.isAssistantRunning else { return }
        let prompt: String
        if let skill {
            prompt = "/" + skill.name + (text.isEmpty ? "" : " " + text)
        } else {
            guard !text.isEmpty else { return }
            prompt = text
        }
        draft = ""
        skill = nil
        store.askAssistant(prompt)
    }
}

/// 입력칸 바탕. macOS 26은 리퀴드 글래스, 그 전은 반투명 재질과 얇은 테두리.
private struct ComposerSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
        } else {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.border, lineWidth: 1))
        }
    }
}

/// 질문에 같이 갈 것들. 칩을 누르면 뺐다 넣었다 하고, 눈 모양을 누르면 실제로 보낼 글을 보여 준다.
private struct ContextBar: View {
    @Environment(RepositoryStore.self) private var store
    /// 커밋 스킬을 골랐으면 보고 있는 것과 상관없이 스테이징한 변경 전체가 간다. 보내는 것과 같은 칩을 보여 준다.
    var commitMode = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if commitMode {
                    ForEach(store.commitContext) { item in
                        ContextChip(item: item, included: true, fixed: true)
                    }
                } else {
                    ForEach(store.assistantContextItems) { item in
                        ContextChip(item: item, included: store.isAssistantContextIncluded(item))
                    }
                }
            }
        }
        .help(commitMode ? "커밋 스킬에는 스테이징한 변경 전체가 갑니다" : "질문에 같이 가는 것. 메인 창에서 고른 것을 따라갑니다")
    }
}

private struct ContextChip: View {
    @Environment(RepositoryStore.self) private var store
    let item: RepositoryStore.AssistantContextItem
    let included: Bool
    /// 눌러서 뺄 수 없는 칩
    var fixed = false
    @State private var previewing = false
    @State private var preview = ""

    var body: some View {
        // 한 줄짜리 칩. 누르면 실제로 보낼 글을 보여 주고, ×로 이번 질문에서 뺀다(뺀 것은 +로 다시 넣는다).
        HStack(spacing: 5) {
            Button { previewing.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: item.symbol)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondary)
                    // 줄이지 않는다. 칩 줄은 가로로 스크롤된다.
                    Text(item.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .fixedSize()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(item.detail + "\n누르면 보낼 내용을 봅니다")
            .popover(isPresented: $previewing, arrowEdge: .bottom) {
                ScrollView {
                    Text(preview.isEmpty ? "읽는 중…" : preview)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                .frame(width: 520, height: 420)
                .task { preview = await store.assistantText(for: item) }
            }
            if !fixed {
                Button { store.toggleAssistantContext(item) } label: {
                    Image(systemName: included ? "xmark" : "plus")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 14, height: 14)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(included ? "이번 질문에서 제외" : "다시 포함")
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, fixed ? 8 : 5)
        .padding(.vertical, 4)
        .background(Theme.raised, in: Capsule())
        .opacity(included ? 1 : 0.5)
    }
}

/// 답이 오기 전까지 Claude가 한 일. 생각한 시간, 읽은 파일, 찾은 것. 답이 오면 접힌 한 줄로 남는다.
private struct AssistantSteps: View {
    let steps: [RepositoryStore.AssistantStep]
    let live: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 5) {
                    if live { ProgressView().controlSize(.mini) }
                    Text(headline)
                        .lineLimit(1)
                    if !live {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded || live {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(steps) { step in
                        HStack(spacing: 6) {
                            Image(systemName: symbol(step))
                                .font(.system(size: 10))
                                .frame(width: 12)
                            Text(label(step))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let result = step.result {
                                Text(result).foregroundStyle(Theme.tertiary)
                            } else if step.finishedAt == nil, live, case .tool = step.kind {
                                ProgressView().controlSize(.mini)
                            }
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.secondary)
                    }
                }
                .padding(.leading, 2)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: expanded)
    }

    private var headline: String {
        let tools = steps.filter { if case .tool = $0.kind { return true } else { return false } }
        let thinking = steps.filter { $0.kind == .thinking }
        var parts: [String] = []
        if !thinking.isEmpty {
            let seconds = thinking.reduce(0) { $0 + Int(($1.finishedAt ?? Date()).timeIntervalSince($1.startedAt).rounded()) }
            parts.append(seconds > 0 ? "\(seconds)초 생각" : "생각")
        }
        if !tools.isEmpty {
            let reads = tools.filter { $0.kind == .tool("Read") }.count
            let commands = tools.filter { $0.kind == .tool("Bash") }.count
            let searches = tools.filter { $0.kind == .tool("Grep") || $0.kind == .tool("Glob") }.count
            let others = tools.count - reads - commands - searches
            if reads > 0 { parts.append("파일 \(reads)개 읽음") }
            if searches > 0 { parts.append("검색 \(searches)회") }
            if commands > 0 { parts.append("명령 \(commands)개 실행") }
            if others > 0 { parts.append("도구 \(others)회") }
        }
        if live { return parts.isEmpty ? "시작하는 중" : parts.joined(separator: ", ") + "…" }
        return parts.isEmpty ? "과정" : parts.joined(separator: ", ")
    }

    private func symbol(_ step: RepositoryStore.AssistantStep) -> String {
        switch step.kind {
        case .thinking: "brain"
        case .tool("Read"): "doc.text"
        case .tool("Grep"), .tool("Glob"): "magnifyingglass"
        case .tool("Bash"): "terminal"
        case .tool: "wrench"
        }
    }

    private func label(_ step: RepositoryStore.AssistantStep) -> String {
        switch step.kind {
        case .thinking: step.summary
        case .tool(let name): "\(name) \(step.summary)"
        }
    }
}

/// 대화 한 칸. 내 질문은 오른쪽에 작게(붙인 것 이름과 함께), 답은 문서처럼.
private struct AssistantBubble: View {
    @Environment(RepositoryStore.self) private var store
    let message: RepositoryStore.AssistantMessage

    var body: some View {
        if message.role == .user {
            VStack(alignment: .trailing, spacing: 4) {
                // 빠른 질문은 긴 지시문 대신 그 이름(설명·리뷰…)만 보인다
                Text(RepositoryStore.AssistantAction.allCases.first { $0.prompt == message.text }?.title ?? message.text)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 14))
                    .textSelection(.enabled)
                if !message.attached.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "paperclip").font(.system(size: 9))
                        Text(message.attached.joined(separator: ", ")).lineLimit(1).truncationMode(.middle)
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    if !message.steps.isEmpty {
                        AssistantSteps(steps: message.steps, live: message.isStreaming && message.text.isEmpty)
                    }
                    if message.text.isEmpty, message.isStreaming, message.steps.isEmpty {
                        ProgressView().controlSize(.small)
                    } else if let error = message.error {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.orange)
                            Text(error).font(.system(size: 12)).foregroundStyle(Theme.secondary).textSelection(.enabled)
                        }
                    } else {
                        MarkdownView(source: message.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if message.action == .commitMessage, !message.isStreaming, message.error == nil, !message.text.isEmpty {
                        Button("커밋 메시지에 넣기") { store.useAsCommitMessage(message.text) }
                            .buttonStyle(PillButtonStyle(prominent: true, compact: true))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}


/// 입력 상자 위에 뜨는 스킬 목록. 위아래로 고르고 엔터나 탭으로 넣는다.
private struct SkillSuggestions: View {
    let items: [ClaudeSkill]
    let highlighted: Int
    let pick: (ClaudeSkill) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, skill in
                Button { pick(skill) } label: {
                    HStack(spacing: 8) {
                        Text("/" + skill.name)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(ClaudeMark.orange)
                            .lineLimit(1)
                        Text(skill.summary)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 8)
                        Text(skill.source)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.tertiary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(index == highlighted ? Theme.raised : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// 고른 스킬. 입력 앞에 붙고, ×나 빈 칸에서 백스페이스로 뺀다.
private struct SkillChip: View {
    let skill: ClaudeSkill
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text("/" + skill.name)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(ClaudeMark.orange)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(ClaudeMark.orange.opacity(0.12), in: Capsule())
        .help(skill.summary)
    }
}
