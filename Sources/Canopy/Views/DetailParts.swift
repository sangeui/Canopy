import SwiftUI

/// 커밋 상세와 PR 상세가 같이 쓰는 조각. 두 화면의 뼈대는 같고(고정 머리말 → 탭 → 스크롤 본문),
/// 머리말 맨 위의 종류 표시로 무엇을 보고 있는지 바로 알 수 있게 한다.

/// "커밋 e9d5d89", "PR #5234"처럼 종류와 식별자를 묶은 표시. 머리말 첫 줄에 하나만 놓는다.
struct DetailKindMark: View {
    let symbol: String
    let title: String
    let identifier: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            Text(identifier)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.1), in: Capsule())
        .lineLimit(1)
    }
}

/// 이름 첫 글자를 넣은 동그라미.
struct AvatarCircle: View {
    let name: String
    var size: CGFloat = 20

    var body: some View {
        Circle()
            .fill(Theme.raised)
            .frame(width: size, height: size)
            .overlay(
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
            )
    }
}

/// 상세 화면의 고정 머리말. 종류 표시 → 제목 → 누가·언제 → 동작 순서로 쌓는다. 스크롤되지 않는다.
struct DetailHeader<Eyebrow: View, Meta: View, Actions: View>: View {
    let title: String
    @ViewBuilder let eyebrow: () -> Eyebrow
    @ViewBuilder let meta: () -> Meta
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) { eyebrow() }
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .lineSpacing(2)
                .lineLimit(2)
                .textSelection(.enabled)
            HStack(spacing: 8) { meta() }
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
            HStack(spacing: 8) { actions() }
                .padding(.top, 2)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 머리말 아래 탭 줄. 선택한 탭만 본문에 나온다.
struct DetailTabStrip<Tab: Hashable & Identifiable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    let title: (Tab) -> String
    var badge: ((Tab) -> String?)?

    var body: some View {
        HStack {
            UnderlineTabs(tabs: tabs, selection: $selection, title: title, badge: badge)
            Spacer()
        }
        .padding(.horizontal, 16)
        HairlineDivider()
    }
}

/// 바뀐 파일 목록. 종류 색점, 경로, 더하고 뺀 줄 수. 누르면 그 파일의 diff로 내려간다.
struct ChangedFileList: View {
    let files: [DiffFile]
    let onSelect: (DiffFile) -> Void

    var body: some View {
        let totalAdditions = files.reduce(0) { $0 + $1.additions }
        let totalDeletions = files.reduce(0) { $0 + $1.deletions }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("바뀐 파일")
                    .font(.system(size: 12, weight: .semibold))
                Text(verbatim: "\(files.count)개")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                Spacer()
                DiffCountLabel(additions: totalAdditions, deletions: totalDeletions)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)
            ForEach(files) { file in
                itemView(for: file)
            }
            Color.clear.frame(height: 6)
        }
        .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 12))
    }

    private func itemView(for file: DiffFile) -> some View {
        Button { onSelect(file) } label: {
            // 파일 이름을 앞에 두고 폴더는 뒤에 흐리게. 폭이 모자라면 폴더를 통째로 뺀다.
            ViewThatFits(in: .horizontal) {
                fileRow(file, showsFolder: true)
                fileRow(file, showsFolder: false)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText(for: file))
        .contextMenu { FileHistoryMenuItems(path: file.displayPath) }
    }

    private func helpText(for file: DiffFile) -> String {
        let base = "\(kindTitle(for: file))\n\(file.displayPath)"
        if file.isRename, let oldPath = file.oldPath {
            return "\(base)\n원래 \(oldPath)"
        }
        return base
    }

    private func fileRow(_ file: DiffFile, showsFolder: Bool) -> some View {
        let path = file.displayPath as NSString
        return HStack(spacing: 8) {
            Text(path.lastPathComponent)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(file.newPath == nil ? Theme.secondary : Theme.text)
                .strikethrough(file.newPath == nil, color: Theme.secondary)
                .fixedSize()
            // 수정은 흔해서 따로 적지 않는다. 새로 만듦·삭제·이름 바뀜만 적는다.
            if let kind = kindLabel(for: file) {
                Text(kind)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(color(for: file))
                    .fixedSize()
            }
            if showsFolder, !path.deletingLastPathComponent.isEmpty {
                Text(path.deletingLastPathComponent)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
                    .fixedSize()
            }
            Spacer(minLength: 12)
            DiffCountLabel(additions: file.additions, deletions: file.deletions)
                .fixedSize()
        }
    }

    private func kindLabel(for file: DiffFile) -> String? {
        if file.oldPath == nil { return "새 파일" }
        if file.newPath == nil { return "삭제" }
        if file.isRename { return "이름 바뀜" }
        return nil
    }

    private func color(for file: DiffFile) -> Color {
        if file.oldPath == nil { return Theme.added }
        if file.newPath == nil { return Theme.red }
        if file.isRename { return Theme.blue }
        return Theme.orange
    }

    private func kindTitle(for file: DiffFile) -> String {
        if file.oldPath == nil { return "추가됨" }
        if file.newPath == nil { return "삭제됨" }
        if file.isRename { return "이름 바뀜" }
        return "수정됨"
    }
}

/// 파일 목록 뒤에 파일별 diff 카드를 이어 붙인 본문. 목록에서 고르면 그 카드로 스크롤한다.
struct ChangesBody: View {
    let files: [DiffFile]
    let isLoading: Bool
    var hint: String?
    /// 파일 목록 위에 덧붙일 내용. 비교 화면의 커밋 목록.
    var top: AnyView?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if let top { top }
                    if isLoading, files.isEmpty {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("변경을 읽는 중…").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        }
                        .padding(4)
                    } else if files.isEmpty {
                        Text("보여 줄 텍스트 변경이 없습니다.")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondary)
                            .padding(4)
                    } else {
                        ChangedFileList(files: files) { file in
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("file-\(file.id)", anchor: .top) }
                        }
                        if let hint {
                            Text(hint)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.tertiary)
                                .lineLimit(1)
                                .padding(.horizontal, 4)
                        }
                    }
                    ForEach(files) { file in
                        DiffFileCard(file: file, showsHeader: true, change: nil)
                            .id("file-\(file.id)")
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
