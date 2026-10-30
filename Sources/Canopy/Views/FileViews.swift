import SwiftUI

/// 브랜치 둘의 변경. 갈라진 지점부터 head까지 바뀐 파일을 커밋 상세와 같은 모양으로 보여 준다.
struct CompareDetailView: View {
    @Environment(RepositoryStore.self) private var store
    let base: String
    let head: String
    let files: [DiffFile]
    let isLoading: Bool

    var body: some View {
        VStack(spacing: 0) {
            // 두 이름은 제목에서 한 번만. 탭에도 같은 이름이 있으니 설명 문장에는 다시 쓰지 않는다.
            DetailHeader(title: "\(base) → \(head)") {
                Text("비교")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.blue)
                Spacer()
                if isLoading { ProgressView().controlSize(.small) }
            } meta: {
                Text("갈라진 뒤 바뀐 내용")
                Spacer()
                if !isLoading {
                    Text(verbatim: "커밋 \(store.compareCommits.ahead.count)개, 파일 \(files.count)개")
                    DiffCountLabel(
                        additions: files.reduce(0) { $0 + $1.additions },
                        deletions: files.reduce(0) { $0 + $1.deletions }
                    )
                }
            } actions: {
                if let branch = store.branches.first(where: { !$0.isRemote && $0.name == head }), !branch.isHead {
                    Button("\(head) 체크아웃") { Task { await store.checkout(branch) } }
                        .buttonStyle(PillButtonStyle(compact: true))
                        .disabled(store.isBusy)
                }
                Spacer()
            }
            HairlineDivider()
            ChangesBody(files: files, isLoading: isLoading, top: isLoading ? nil : AnyView(VStack(alignment: .leading, spacing: 14) {
                if let conflicts = store.compareConflicts {
                    CompareConflictsSection(base: base, head: head, conflicts: conflicts)
                }
                CompareCommitsSection(base: base, head: head, commits: store.compareCommits)
            }))
        }
    }
}

/// 비교 화면의 충돌 미리보기. head를 base에 합치면 충돌하는 파일과, 합친 결과의 충돌 부분.
/// 접힌 채로 두고 펼치면 파일마다 충돌 표시가 들어간 diff를 보여 준다.
private struct CompareConflictsSection: View {
    let base: String
    let head: String
    let conflicts: RepositoryStore.CompareConflicts
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.orange)
                    Text("\(base)에 합치면 충돌")
                        .font(.system(size: 12, weight: .semibold))
                    Text(verbatim: "파일 \(conflicts.preview.conflicts.count)개")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    Text("실제로 합치지 않고 계산만 해 본 결과입니다. <<<<<<< 쪽이 \(base), >>>>>>> 쪽이 \(head)입니다.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(conflicts.files) { file in
                        DiffFileCard(file: file, showsHeader: true, change: nil)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            } else {
                Text(conflicts.preview.conflictSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
        }
        .background(Theme.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// 비교 화면의 커밋 목록. head에만 있는 커밋을 펼쳐 두고, base에만 있는 커밋은 접어 둔다.
private struct CompareCommitsSection: View {
    let base: String
    let head: String
    let commits: RepositoryStore.CompareCommits
    @State private var showsBehind = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !commits.ahead.isEmpty {
                group(title: "커밋", commits: commits.ahead)
            }
            if !commits.behind.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { showsBehind.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .rotationEffect(.degrees(showsBehind ? 90 : 0))
                            Text("\(base)에만 있는 커밋")
                                .font(.system(size: 12, weight: .semibold))
                            Text(count(commits.behind))
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(head)에는 아직 들어오지 않은 커밋입니다")
                    if showsBehind {
                        rows(commits.behind)
                        Color.clear.frame(height: 6)
                    }
                }
                .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func group(title: String, commits: [Commit]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(count(commits)).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
            rows(commits)
            Color.clear.frame(height: 6)
        }
        .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 12))
    }

    private func count(_ commits: [Commit]) -> String {
        commits.count >= RepositoryStore.CompareCommits.limit ? "\(commits.count)개 넘음" : "\(commits.count)개"
    }

    private func rows(_ commits: [Commit]) -> some View {
        ForEach(commits) { commit in
            CompareCommitRow(commit: commit)
        }
    }
}

private struct CompareCommitRow: View {
    @Environment(RepositoryStore.self) private var store
    let commit: Commit
    @State private var hovering = false

    var body: some View {
        Button { store.showCommit(hash: commit.hash) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(commit.subject)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(commit.authorName)
                    Text(commit.date, format: .relative(presentation: .named))
                    Spacer()
                    Text(commit.shortHash).font(.system(size: 11, design: .monospaced))
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Theme.raised : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("이 커밋 열기")
    }
}

/// 한 파일의 커밋 역사. 고르면 그 커밋을 연다.
struct FileHistoryView: View {
    @Environment(RepositoryStore.self) private var store
    let path: String
    let commits: [Commit]
    let isLoading: Bool

    var body: some View {
        VStack(spacing: 0) {
            DetailHeader(title: (path as NSString).lastPathComponent) {
                DetailKindMark(symbol: "clock", title: "파일 히스토리", identifier: isLoading ? "…" : "\(commits.count)개 커밋", tint: Theme.secondary)
                Spacer()
                if isLoading { ProgressView().controlSize(.small) }
            } meta: {
                Text(path)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            } actions: {
                Button("줄별 작성자 보기") { store.showBlame(path) }
                    .buttonStyle(PillButtonStyle(compact: true))
                Spacer()
            }
            HairlineDivider()
            if commits.isEmpty, !isLoading {
                EmptyState(title: "기록이 없습니다", message: "아직 커밋되지 않은 파일이거나 경로가 바뀌었습니다.", systemImage: "clock")
            } else {
                CommitList(commits: commits, graph: nil, selectedID: nil) { id in
                    if let id { store.showCommit(hash: id) }
                }
            }
        }
    }
}

/// 줄마다 마지막으로 바꾼 커밋. 같은 커밋이 이어지는 줄은 한 묶음으로 보여 준다.
struct BlameView: View {
    @Environment(RepositoryStore.self) private var store
    let path: String
    let lines: [BlameLine]
    let isLoading: Bool

    /// 같은 커밋이 연달아 나온 묶음의 첫 줄 번호
    private var runStarts: Set<Int> {
        var starts: Set<Int> = []
        var previous: String?
        for line in lines where line.hash != previous {
            starts.insert(line.number)
            previous = line.hash
        }
        return starts
    }

    /// 묶음마다 번갈아 칠할 색의 차례
    private var runIndex: [Int: Int] {
        var result: [Int: Int] = [:]
        var index = -1
        var previous: String?
        for line in lines {
            if line.hash != previous { index += 1; previous = line.hash }
            result[line.number] = index
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            DetailHeader(title: (path as NSString).lastPathComponent) {
                DetailKindMark(symbol: "person.text.rectangle", title: "줄별 작성자", identifier: isLoading ? "…" : "\(lines.count)줄", tint: Theme.secondary)
                Spacer()
                if isLoading { ProgressView().controlSize(.small) }
            } meta: {
                Text(path)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            } actions: {
                Button("파일 히스토리 보기") { store.showFileHistory(path) }
                    .buttonStyle(PillButtonStyle(compact: true))
                Button {
                    store.toggleBlameAcrossFiles()
                } label: {
                    Label("다른 파일에서 옮긴 줄도 찾기", systemImage: store.blameAcrossFiles ? "checkmark" : "arrow.left.arrow.right")
                }
                .buttonStyle(PillButtonStyle(compact: true))
                .disabled(isLoading)
                .help("다른 파일에서 옮겨 오거나 복사한 줄은 그 줄을 처음 쓴 커밋을 보여 줍니다. 큰 파일은 몇 초 걸립니다.")
                Spacer()
            }
            HairlineDivider()
            if lines.isEmpty, !isLoading {
                EmptyState(title: "줄 정보를 읽지 못했습니다", message: "아직 커밋되지 않은 파일은 볼 수 없습니다.", systemImage: "person.text.rectangle")
            } else {
                let starts = runStarts
                let indexes = runIndex
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(lines) { line in
                            BlameRow(line: line, showsInfo: starts.contains(line.number), shaded: (indexes[line.number] ?? 0) % 2 == 1) {
                                store.showCommit(hash: line.hash)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }
}

private struct BlameRow: View {
    let line: BlameLine
    let showsInfo: Bool
    let shaded: Bool
    let open: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: open) {
                HStack(spacing: 8) {
                    if showsInfo {
                        Text(line.shortHash)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.secondary)
                        Text(line.author)
                            .font(.system(size: 11))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(line.date, format: .relative(presentation: .named))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.tertiary)
                            .lineLimit(1)
                    }
                }
                .frame(width: 210, alignment: .leading)
                .padding(.horizontal, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(showsInfo ? line.summary : "")
            Text(verbatim: "\(line.number)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.tertiary)
                .frame(width: 40, alignment: .trailing)
                .padding(.trailing, 10)
            Text(line.text.replacingOccurrences(of: "\t", with: "    "))
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .textSelection(.enabled)
            Spacer(minLength: 20)
        }
        .padding(.vertical, 1)
        .background(shaded ? Theme.codeBackground : Color.clear)
    }
}

/// 변경 줄과 diff 카드에서 쓰는 "파일 역사 / 줄별 작성자" 메뉴 항목.
struct FileHistoryMenuItems: View {
    @Environment(RepositoryStore.self) private var store
    let path: String

    var body: some View {
        Button("파일 히스토리") { store.showFileHistory(path) }
        Button("줄별 작성자 (blame)") { store.showBlame(path) }
    }
}
