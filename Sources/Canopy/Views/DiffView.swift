import SwiftUI

struct DiffView: View {
    @Environment(RepositoryStore.self) private var store: RepositoryStore?
    let title: String
    let subtitle: String
    let files: [DiffFile]
    let isLoading: Bool
    /// 작업 트리 변경일 때. hunk 단위 버튼을 붙이는 기준이 된다.
    let change: FileChange?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .foregroundStyle(Theme.secondary)
                Text(title)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                Spacer()
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    DiffCountLabel(
                        additions: files.reduce(0) { $0 + $1.additions },
                        deletions: files.reduce(0) { $0 + $1.deletions }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            HairlineDivider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if change?.area == .conflicted {
                        ConflictNote(operation: store?.operation)
                    }
                    if files.isEmpty, !isLoading {
                        Text("보여 줄 텍스트 변경이 없습니다.")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondary)
                            .padding(4)
                    }
                    ForEach(files) { file in
                        DiffFileCard(file: file, showsHeader: files.count > 1, change: change)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// 충돌 파일 위에 붙이는 설명. 표시의 어느 쪽이 어느 쪽인지 알려 준다.
/// 리베이스 중에는 HEAD가 내 브랜치가 아니라 옮겨 가는 기준 쪽이라 특히 헷갈린다.
private struct ConflictNote: View {
    let operation: RepositoryOperation?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(sides)
                Text("표시 세 줄을 지우고 남길 내용만 둔 뒤 스테이징하면 충돌이 풀립니다.")
                    .foregroundStyle(Theme.secondary)
            }
            .font(.system(size: 12))
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
    }

    private var sides: String {
        switch operation {
        case .rebasing: "리베이스 중이라 <<<<<<< 쪽(HEAD)이 옮겨 가는 기준 브랜치, >>>>>>> 쪽이 내 커밋입니다."
        case .merging: "<<<<<<< 쪽(HEAD)이 현재 브랜치, >>>>>>> 쪽이 머지하는 브랜치입니다."
        case .cherryPicking, .reverting: "<<<<<<< 쪽(HEAD)이 현재 브랜치, >>>>>>> 쪽이 가져오는 커밋입니다."
        case nil: "<<<<<<< 쪽이 HEAD, >>>>>>> 쪽이 들어오는 변경입니다."
        }
    }
}

/// 파일 하나의 diff를 둥근 코드 카드로 보여 준다.
struct DiffFileCard: View {
    @Environment(RepositoryStore.self) private var store: RepositoryStore?
    let file: DiffFile
    let showsHeader: Bool
    var change: FileChange?
    /// 카드 너비. 긴 줄은 접지 않고 옆으로 스크롤하되, 짧은 내용은 카드 폭을 채우게 한다.
    @State private var cardWidth: CGFloat = 0
    /// hunk마다 마우스로 고른 줄. 고르면 머리말 버튼이 "고른 줄"로 바뀐다.
    @State private var selectedLines: [Int: Set<Int>] = [:]

    /// 추적 중인 파일의 작업 트리 변경일 때만 hunk 단위로 올리고 내릴 수 있다.
    private var allowsHunkActions: Bool {
        guard let change, store != nil else { return false }
        return change.area == .staged || change.area == .unstaged
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader {
                VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .foregroundStyle(Theme.secondary)
                    if file.isRename, let oldPath = file.oldPath {
                        Text((oldPath as NSString).lastPathComponent).foregroundStyle(Theme.secondary).strikethrough().lineLimit(1)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.secondary)
                    }
                    // 바뀐 파일 목록과 같이 이름을 앞에, 폴더를 뒤에 흐리게. 폭이 모자라면 폴더를 뺀다.
                    let path = file.displayPath as NSString
                    Text(path.lastPathComponent)
                        .fontWeight(.medium)
                        .fixedSize()
                    ViewThatFits(in: .horizontal) {
                        Text(path.deletingLastPathComponent)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.tertiary)
                            .fixedSize()
                        Color.clear.frame(width: 0, height: 0)
                    }
                    .help(file.displayPath)
                    Spacer(minLength: 8)
                    DiffCountLabel(additions: file.additions, deletions: file.deletions)
                        .fixedSize()
                }
                .font(.system(size: 12, design: .monospaced))
                // 줄 번호 대신 "어느 선언이 바뀌었나"로 변경을 읽는다.
                let symbols = ChangedSymbols.symbols(in: file)
                if !symbols.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "function")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.tertiary)
                        Text(symbols.prefix(8).joined(separator: ", ") + (symbols.count > 8 ? "  외 \(symbols.count - 8)" : ""))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .help("바뀐 선언: " + symbols.joined(separator: ", "))
                }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.codeBackground)
                .contextMenu {
                    if store != nil {
                        FileHistoryMenuItems(path: file.displayPath)
                    }
                }
                HairlineDivider()
            }
            if file.isBinary {
                Text("바이너리 파일이라 내용을 보여 주지 않습니다.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .padding(12)
            } else if file.hunks.isEmpty, !file.headerLines.isEmpty {
                Text(file.headerLines.joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.secondary)
                    .padding(12)
            }
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
            ForEach(file.hunks) { hunk in
                HStack(spacing: 8) {
                    Group {
                        if let start = hunk.newStart {
                            Text(verbatim: "\(start)줄부터") + Text(hunk.context.map { "   " + $0 } ?? "").fontWeight(.medium)
                        } else {
                            Text(hunk.header)
                        }
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .help(hunk.header)
                    Spacer()
                    if allowsHunkActions, let store, let change {
                        let picked = changedLines(in: hunk)
                        if !picked.isEmpty {
                            // 줄을 끌어서 고르면 그 줄만 다룬다
                            Text(verbatim: "\(picked.count)줄").foregroundStyle(Theme.secondary).font(.system(size: 11))
                            if change.isStaged {
                                Button("선택한 줄 해제") { act { await store.stageLines(picked, in: hunk, of: file, staged: true) } }
                                    .buttonStyle(TextButtonStyle())
                            } else {
                                Button("선택한 줄 스테이징") { act { await store.stageLines(picked, in: hunk, of: file, staged: false) } }
                                    .buttonStyle(TextButtonStyle())
                                Button("선택한 줄 버리기") { store.discardLines(picked, in: hunk, of: file); selectedLines = [:] }
                                    .buttonStyle(TextButtonStyle())
                            }
                        } else if change.isStaged {
                            Button("이 부분 해제") { Task { await store.stageHunk(hunk, of: file, staged: true) } }
                                .buttonStyle(TextButtonStyle())
                        } else {
                            Button("이 부분 스테이징") { Task { await store.stageHunk(hunk, of: file, staged: false) } }
                                .buttonStyle(TextButtonStyle())
                            Button("버리기") { store.discardHunk(hunk, of: file) }
                                .buttonStyle(TextButtonStyle())
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.codeBackground)
                // 줄마다 뷰를 만들면 큰 diff에서 그리는 데 한참 걸린다. hunk 하나를 글 하나로 그린다.
                HunkText(
                    hunk: hunk,
                    minimumColumns: Int(cardWidth / HunkText.characterWidth),
                    onSelectLines: allowsHunkActions ? { ids in selectedLines[hunk.id] = ids } : nil
                )
                // 파일이 바뀌면 글 칸을 새로 만든다. 화면의 선택 표시도 같이 사라져서 머리말 버튼과 어긋나지 않는다.
                // 미리 계산한 요약값을 쓴다. 파일 전체를 매번 해시하면 창 크기를 바꿀 때마다 무겁다.
                .id(hunk.signature)
            }
                }
                .frame(minWidth: cardWidth, alignment: .leading)
            }
        }
        // 폭은 40칸 단위로만 기억한다. 창 크기를 바꾸는 동안 매 프레임 카드를 다시 그리지 않게 한다.
        .onGeometryChange(for: CGFloat.self) { ($0.size.width / (HunkText.characterWidth * 40)).rounded(.up) * HunkText.characterWidth * 40 } action: { cardWidth = $0 }
        // 줄 id는 읽을 때마다 앞에서부터 다시 매긴다. 파일이 바뀌면 같은 id가 다른 줄일 수 있으니 고른 것을 비운다.
        .onChange(of: file.hunks.map(\.signature)) { selectedLines = [:] }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))
    }

    /// 고른 줄 중 바뀐 줄(+/-)만
    private func changedLines(in hunk: DiffHunk) -> Set<Int> {
        guard let ids = selectedLines[hunk.id], !ids.isEmpty else { return [] }
        return Set(hunk.lines.filter { ids.contains($0.id) && ($0.kind == .addition || $0.kind == .deletion) }.map(\.id))
    }

    private func act(_ work: @escaping () async -> Void) {
        selectedLines = [:]
        Task { await work() }
    }
}

/// hunk 한 덩이를 NSTextView 하나로. SwiftUI Text는 수천 줄짜리 글을 몇십 초씩 그리지만 NSTextView는 바로 그린다.
/// 줄 번호·표시·본문을 고정폭 글자로 맞추고, 줄 전체 배경은 뒤쪽을 공백으로 채워 만든다.
struct HunkText: View {
    let hunk: DiffHunk
    /// 카드 폭만큼은 배경이 이어지게 모자란 줄을 공백으로 채운다.
    var minimumColumns: Int = 0
    /// 글자를 끌어 고르면 그 범위에 걸친 줄의 id. nil이면 줄 고르기를 쓰지 않는다.
    var onSelectLines: ((Set<Int>) -> Void)?

    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    /// 고정폭 글자 하나의 너비
    static let characterWidth: CGFloat = ("0" as NSString).size(withAttributes: [.font: font]).width

    /// 만든 글을 기억해 둔다. 창 크기를 바꾸거나 다른 상태가 바뀌어 화면을 다시 그릴 때마다 수천 줄을 새로 만들지 않는다.
    private static let cache: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
        cache.countLimit = 400
        return cache
    }()

    /// 카드 폭에 맞춘 칸 수는 40칸 단위로 올림한다. 창을 조금씩 늘리고 줄여도 글을 다시 만들 일이 거의 없다.
    private var paddedColumns: Int {
        let widest = hunk.lines.reduce(0) { max($0, $1.text.count) }
        let wanted = max(widest, minimumColumns - 15)
        return (wanted + 39) / 40 * 40
    }

    var body: some View {
        HunkTextView(attributed: cachedAttributed, lineIDs: hunk.lines.map(\.id), onSelectLines: onSelectLines)
    }

    private var cachedAttributed: NSAttributedString {
        let key = "\(hunk.signature == 0 ? hunk.hashValue : hunk.signature):\(paddedColumns):\(AppTheme.shared.paletteID)" as NSString
        if let cached = Self.cache.object(forKey: key) { return cached }
        let built = attributed
        Self.cache.setObject(built, forKey: key)
        return built
    }

    private var attributed: NSAttributedString {
        let result = NSMutableAttributedString()
        let columns = paddedColumns
        let tertiary = NSColor(Theme.tertiary)
        let secondary = NSColor(Theme.secondary)
        let text = NSColor(Theme.text)
        let green = NSColor(Theme.added), red = NSColor(Theme.red)
        let added = NSColor(Theme.addedBackground), removed = NSColor(Theme.removedBackground)
        let addedStrong = NSColor(Theme.added).withAlphaComponent(0.3), removedStrong = NSColor(Theme.red).withAlphaComponent(0.25)
        let base: [NSAttributedString.Key: Any] = [.font: Self.font]
        for (index, line) in hunk.lines.enumerated() {
            let start = result.length
            result.append(NSAttributedString(string: pad(line.oldNumber, 5) + " " + pad(line.newNumber, 5) + "  ", attributes: base.merging([.foregroundColor: tertiary]) { $1 }))
            let markerColor: NSColor = line.kind == .addition ? green : (line.kind == .deletion ? red : secondary)
            result.append(NSAttributedString(string: markerText(line) + " ", attributes: base.merging([.foregroundColor: markerColor]) { $1 }))
            let bodyStart = result.length
            let body = line.text.replacingOccurrences(of: "\t", with: "    ")
            let padded = body + String(repeating: " ", count: max(0, columns - body.count))
            result.append(NSAttributedString(string: padded, attributes: base.merging([.foregroundColor: line.kind == .meta ? secondary : text]) { $1 }))
            if index < hunk.lines.count - 1 { result.append(NSAttributedString(string: "\n", attributes: base)) }
            let rowRange = NSRange(location: start, length: result.length - start)
            switch line.kind {
            case .addition: result.addAttribute(.backgroundColor, value: added, range: rowRange)
            case .deletion: result.addAttribute(.backgroundColor, value: removed, range: rowRange)
            default: break
            }
            // 바뀐 낱말은 줄 배경보다 진하게. marks는 문자 오프셋이고 탭 치환 전 글 기준이라 탭이 없는 줄에서만 정확하다.
            if !line.marks.isEmpty, !line.text.contains("\t") {
                let strong = line.kind == .addition ? addedStrong : removedStrong
                let utf16 = Array(line.text.utf16)
                let characters = Array(line.text)
                for mark in line.marks where mark.lowerBound >= 0 && mark.upperBound <= characters.count && mark.lowerBound < mark.upperBound {
                    // 문자 오프셋 → UTF-16 오프셋
                    let lower = String(characters[0..<mark.lowerBound]).utf16.count
                    let upper = String(characters[0..<mark.upperBound]).utf16.count
                    guard upper <= utf16.count else { continue }
                    result.addAttribute(.backgroundColor, value: strong, range: NSRange(location: bodyStart + lower, length: upper - lower))
                }
            }
        }
        return result
    }

    private func pad(_ number: Int?, _ width: Int) -> String {
        let text = number.map(String.init) ?? ""
        return String(repeating: " ", count: max(0, width - text.count)) + text
    }

    private func markerText(_ line: DiffLine) -> String {
        switch line.kind {
        case .addition: "+"
        case .deletion: "-"
        case .context: " "
        case .meta: "\\"
        }
    }
}

/// 줄바꿈 없이 내용 크기 그대로 그리는 읽기 전용 NSTextView. 가로 스크롤은 바깥 ScrollView가 맡는다.
private struct HunkTextView: NSViewRepresentable {
    let attributed: NSAttributedString
    var lineIDs: [Int] = []
    var onSelectLines: ((Set<Int>) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// 고른 글자 범위를 줄 번호로 바꿔 알린다. 줄은 "\n"으로만 나뉜다.
    final class Coordinator: NSObject, NSTextViewDelegate {
        var lineIDs: [Int] = []
        var onSelectLines: ((Set<Int>) -> Void)?

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let onSelectLines, let view = notification.object as? NSTextView else { return }
            let range = view.selectedRange()
            guard range.length > 0 else { DispatchQueue.main.async { onSelectLines([]) }; return }
            let text = view.string as NSString
            let before = text.substring(to: range.location)
            let first = before.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
            let inside = text.substring(with: NSRange(location: range.location, length: max(0, range.length - 1)))
            let last = first + inside.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
            let ids = Set((first...last).compactMap { $0 < lineIDs.count ? lineIDs[$0] : nil })
            // 글을 바꾸는 중에도 이 알림이 온다. 화면을 그리는 도중 상태를 바꾸지 않게 다음 차례로 미룬다.
            DispatchQueue.main.async { onSelectLines(ids) }
        }
    }

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        context.coordinator.lineIDs = lineIDs
        context.coordinator.onSelectLines = onSelectLines
        view.delegate = context.coordinator
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isRichText = true
        view.textContainerInset = NSSize(width: 4, height: 4)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.heightTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isHorizontallyResizable = true
        view.isVerticallyResizable = true
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textStorage?.setAttributedString(attributed)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.lineIDs = lineIDs
        context.coordinator.onSelectLines = onSelectLines
        if view.textStorage?.isEqual(to: attributed) == false {
            view.textStorage?.setAttributedString(attributed)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let width = used.width + view.textContainerInset.width * 2
        let height = used.height + view.textContainerInset.height * 2
        return CGSize(width: max(width, proposal.width ?? 0), height: height)
    }
}

struct DiffLineRow: View {
    let line: DiffLine
    /// PR 파일 탭에서 줄에 댓글을 달 때. 마우스를 올리면 왼쪽에 + 가 나온다.
    var onComment: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if let onComment {
                Button(action: onComment) {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 16, height: 16)
                        .background(Theme.blue, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .opacity(hovering ? 1 : 0)
                .padding(.leading, 4)
                .padding(.top, 1)
                .help("이 줄에 댓글 달기")
            }
            Text(line.oldNumber.map(String.init) ?? "")
                .frame(width: 40, alignment: .trailing)
                .foregroundStyle(Theme.tertiary)
            Text(line.newNumber.map(String.init) ?? "")
                .frame(width: 40, alignment: .trailing)
                .foregroundStyle(Theme.tertiary)
            Text(marker)
                .frame(width: 22)
                .foregroundStyle(markerColor)
            Text(attributedText)
                .lineLimit(1)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(line.kind == .meta ? Theme.secondary : Theme.text)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.vertical, 1)
        .padding(.trailing, 10)
        .background(hovering && onComment != nil ? Theme.hover : background)
        .onHover { if onComment != nil { hovering = $0 } }
    }

    /// 바뀐 낱말 구간만 진하게 칠한 줄. 짝이 없는 줄은 그냥 글자다.
    private var attributedText: AttributedString {
        var result = AttributedString(line.text)
        guard !line.marks.isEmpty else { return result }
        let tint = line.kind == .addition ? Theme.added.opacity(0.28) : Theme.red.opacity(0.22)
        let characters = Array(line.text)
        for mark in line.marks {
            guard mark.lowerBound >= 0, mark.upperBound <= characters.count, mark.lowerBound < mark.upperBound else { continue }
            let lower = result.index(result.startIndex, offsetByCharacters: mark.lowerBound)
            let upper = result.index(result.startIndex, offsetByCharacters: mark.upperBound)
            result[lower..<upper].backgroundColor = tint
        }
        return result
    }

    private var marker: String {
        switch line.kind {
        case .addition: "+"
        case .deletion: "-"
        case .context: " "
        case .meta: "\\"
        }
    }

    private var markerColor: Color {
        switch line.kind {
        case .addition: Theme.added
        case .deletion: Theme.red
        default: Theme.secondary
        }
    }

    private var background: Color {
        switch line.kind {
        case .addition: Theme.addedBackground
        case .deletion: Theme.removedBackground
        default: Color.clear
        }
    }
}

struct CommitDetailView: View {
    @Environment(RepositoryStore.self) private var store
    let commit: Commit
    let files: [DiffFile]
    let isLoading: Bool
    var ownerName: String?
    var parentOwnerNames: [String?] = []
    var containingRefs = GitRepository.ContainingRefs()
    var onSelectParent: ((String) -> Void)?

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            DetailHeader(title: commit.subject) {
                DetailKindMark(symbol: "circle.fill", title: "커밋", identifier: commit.shortHash, tint: Theme.secondary)
                if let ownerName {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
                        Text(ownerName).lineLimit(1).truncationMode(.middle)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .help("이 커밋이 속한 브랜치")
                }
                Spacer()
                if isLoading { ProgressView().controlSize(.small) }
            } meta: {
                // 폭이 모자라면 절대 시각부터 뺀다. 줄임표는 내지 않는다.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        AvatarCircle(name: commit.authorName)
                        Text(commit.authorName).foregroundStyle(Theme.text)
                        Text(commit.date, format: .dateTime.year().month().day().hour().minute())
                        Text(commit.date, format: .relative(presentation: .named)).foregroundStyle(Theme.tertiary)
                    }
                    .fixedSize()
                    HStack(spacing: 8) {
                        AvatarCircle(name: commit.authorName)
                        Text(commit.authorName).foregroundStyle(Theme.text)
                        Text(commit.date, format: .relative(presentation: .named)).foregroundStyle(Theme.tertiary)
                    }
                    .fixedSize()
                    HStack(spacing: 8) {
                        AvatarCircle(name: commit.authorName)
                        Text(commit.authorName).foregroundStyle(Theme.text)
                    }
                    .fixedSize()
                }
                Spacer()
            } actions: {
                Button("여기서 새 브랜치…") {
                    store.newBranchBase = commit.hash
                    store.sheet = .newBranch
                }
                .buttonStyle(PillButtonStyle(compact: true))
                Button("체리픽") { Task { await store.cherryPick(commit) } }
                    .buttonStyle(PillButtonStyle(compact: true))
                    .disabled(store.isBusy)
                    .help("이 커밋을 현재 브랜치로 가져옵니다")
                Spacer()
                Menu {
                    CommitMenu(commit: commit)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .frame(width: 28, height: 28)
                        .background(Theme.raised, in: Circle())
                        .contentShape(Circle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            DetailTabStrip(
                tabs: RepositoryStore.CommitTab.allCases,
                selection: $store.commitTab,
                title: { $0.title },
                badge: { tab in
                    switch tab {
                    case .changes: isLoading && files.isEmpty ? nil : "\(files.count)"
                    case .message: commit.body.trimmed.isEmpty ? nil : "·"
                    case .place: nil
                    }
                }
            )
            Group {
                switch store.commitTab {
                case .changes:
                    ChangesBody(files: files, isLoading: isLoading)
                case .message:
                    ScrollView {
                        CommitMessageBody(commit: commit)
                            .padding(18)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .place:
                    ScrollView {
                        CommitPlaceGrid(
                            commit: commit,
                            parentOwnerNames: parentOwnerNames,
                            containingRefs: containingRefs,
                            onSelectParent: onSelectParent
                        )
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .id(store.commitTab)
            .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.18), value: store.commitTab)
    }
}

/// 커밋 메시지 전체. 제목 줄과 본문을 문서처럼 보여 준다.
struct CommitMessageBody: View {
    let commit: Commit

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(commit.subject)
                .font(.system(size: 15, weight: .semibold))
                .lineSpacing(3)
                .textSelection(.enabled)
            if commit.body.trimmed.isEmpty {
                Text("본문이 없습니다. 제목 한 줄뿐인 커밋입니다.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.tertiary)
            } else {
                MarkdownView(source: commit.body)
            }
        }
    }
}

/// 커밋이 역사 어디에 있는지. 부모, 담고 있는 브랜치·원격·태그, PR, 해시.
struct CommitPlaceGrid: View {
    @Environment(RepositoryStore.self) private var store: RepositoryStore?
    let commit: Commit
    var parentOwnerNames: [String?] = []
    var containingRefs = GitRepository.ContainingRefs()
    var onSelectParent: ((String) -> Void)?

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 10) {
            GridRow {
                label("부모")
                HStack(spacing: 6) {
                    if commit.parents.isEmpty {
                        Text("첫 커밋").foregroundStyle(Theme.secondary)
                    }
                    ForEach(Array(commit.parents.enumerated()), id: \.offset) { index, parent in
                        Button {
                            onSelectParent?(parent)
                        } label: {
                            HStack(spacing: 4) {
                                Text(String(parent.prefix(7))).font(.system(size: 12, design: .monospaced))
                                if index < parentOwnerNames.count, let name = parentOwnerNames[index] {
                                    Text(name).foregroundStyle(Theme.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("부모 커밋으로 이동")
                    }
                    if commit.isMerge {
                        Text("머지 커밋").foregroundStyle(Theme.secondary)
                    }
                }
            }
            if !containingRefs.branches.isEmpty {
                GridRow {
                    label("브랜치")
                    wrapped(containingRefs.branches)
                }
            }
            if !containingRefs.remotes.isEmpty {
                GridRow {
                    label("원격")
                    wrapped(containingRefs.remotes)
                }
            }
            if !containingRefs.tags.isEmpty {
                GridRow {
                    label("태그")
                    wrapped(containingRefs.tags)
                }
            }
            GridRow {
                label("작성자")
                Text(verbatim: "\(commit.authorName) <\(commit.authorEmail)>")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            GridRow {
                label("해시")
                HStack(spacing: 8) {
                    Text(commit.hash)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button("복사") { store?.copyHash(commit) }
                        .buttonStyle(TextButtonStyle())
                }
            }
        }
        .font(.system(size: 12))
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(Theme.secondary)
            .frame(width: 44, alignment: .leading)
    }

    /// 이름이 많으면 줄을 바꿔 가며 적는다. 15개가 넘으면 접는다.
    private func wrapped(_ names: [String]) -> some View {
        let shown = Array(names.prefix(15))
        return VStack(alignment: .leading, spacing: 3) {
            Text(shown.joined(separator: ", "))
                .lineSpacing(4)
                .textSelection(.enabled)
            if names.count > shown.count {
                Text("외 \(names.count - shown.count)개").foregroundStyle(Theme.secondary)
            }
        }
    }
}

/// 테스트와 스크린샷용. 머리말 없이 메시지와 변경을 한 장에 그린다.
struct CommitDetailContent: View {
    let commit: Commit
    let files: [DiffFile]
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            CommitMessageBody(commit: commit)
            ChangedFileList(files: files) { _ in }
            ForEach(files) { file in
                DiffFileCard(file: file, showsHeader: true, change: nil)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
