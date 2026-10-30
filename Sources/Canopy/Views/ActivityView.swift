import SwiftUI

/// reflog를 날짜별로 묶어 "최근에 무슨 일을 했나"를 보여 준다.
struct ActivityView: View {
    @Environment(RepositoryStore.self) private var store

    private var grouped: [(day: String, entries: [ActivityEntry])] {
        var result: [(day: String, entries: [ActivityEntry])] = []
        let calendar = Calendar.current
        for entry in store.activities {
            let label: String
            if calendar.isDateInToday(entry.date) {
                label = "오늘"
            } else if calendar.isDateInYesterday(entry.date) {
                label = "어제"
            } else {
                label = entry.date.formatted(.dateTime.year().month().day().weekday(.wide))
            }
            if let last = result.last, last.day == label {
                result[result.count - 1].entries.append(entry)
            } else {
                result.append((label, [entry]))
            }
        }
        return result
    }

    var body: some View {
        if store.activities.isEmpty, store.deletedBranches.isEmpty {
            EmptyState(
                title: "기록된 활동이 없습니다",
                message: "커밋, 체크아웃, 머지 같은 일을 하면 여기에 순서대로 남습니다.",
                systemImage: "clock.arrow.circlepath"
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    // 설명 문장은 접어 두고 첫 섹션 제목 옆 물음표로 연다. 한 줄에 다 안 들어가서 잘리느니 없는 편이 낫다.
                    if !store.deletedBranches.isEmpty {
                        SectionTitle("최근 지운 브랜치") { ActivityHelpButton() }
                        ForEach(store.deletedBranches) { deleted in
                            DeletedBranchRow(deleted: deleted)
                        }
                    }
                    ForEach(Array(grouped.enumerated()), id: \.element.day) { index, group in
                        if index == 0, store.deletedBranches.isEmpty {
                            SectionTitle(group.day) { ActivityHelpButton() }
                        } else {
                            SectionTitle(group.day)
                                .padding(.top, 6)
                        }
                        ForEach(group.entries) { entry in
                            ActivityRow(entry: entry, isSelected: store.selectedActivityID == entry.id) {
                                store.selectActivity(entry)
                            }
                            .contextMenu { ActivityMenu(entry: entry) }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
        }
    }
}

/// 활동 칸 설명. 물음표를 누르면 나온다.
private struct ActivityHelpButton: View {
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: "questionmark.circle")
        }
        .buttonStyle(IconButtonStyle(size: 28))
        .help("활동 칸 설명")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("활동 칸")
                    .font(.system(size: 13, weight: .semibold))
                Text("이 저장소에서 HEAD가 움직인 기록(reflog)입니다. 커밋, 체크아웃, 머지, 리셋이 모두 남습니다.")
                Text("줄을 누르면 그때의 커밋이 오른쪽에 열립니다.")
                Text("줄을 우클릭하면 그 시점에서 새 브랜치를 만들거나, 현재 브랜치를 그 시점으로 되돌릴 수 있습니다. 리셋으로 사라진 커밋도 여기서 되찾습니다.")
                Text("이 앱에서 지운 브랜치는 맨 위 \"최근 지운 브랜치\"에서 복구합니다.")
            }
            .font(.system(size: 12))
            .padding(16)
            .frame(width: 340)
        }
    }
}

/// 활동 한 줄의 우클릭 메뉴. 그 시점에서 브랜치를 내거나 그 시점으로 돌아간다.
private struct ActivityMenu: View {
    @Environment(RepositoryStore.self) private var store
    let entry: ActivityEntry

    var body: some View {
        Button("이 시점에서 새 브랜치…") {
            store.newBranchBase = entry.hash
            store.sheet = .newBranch
        }
        Menu("현재 브랜치를 이 시점으로 되돌리기") {
            ForEach(ResetMode.allCases) { mode in
                Button(mode.title) { store.reset(toActivity: entry, mode: mode) }
            }
        }
        Divider()
        Button("해시 복사") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.hash, forType: .string)
        }
    }
}

/// 이 앱에서 지운 브랜치 한 줄. 복구하거나 목록에서 지운다.
private struct DeletedBranchRow: View {
    @Environment(RepositoryStore.self) private var store
    let deleted: DeletedBranch

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: deleted.remote == nil ? "arrow.triangle.branch" : "cloud")
                .font(.system(size: 12))
                .foregroundStyle(Theme.tertiary)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(deleted.displayName)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(deleted.date, format: .relative(presentation: .named))
                    Text(deleted.hash.prefix(7)).font(.system(size: 11, design: .monospaced))
                    if deleted.remote != nil { Text("원격에서 지움") }
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 8)
            Button("복구") { Task { await store.restoreBranch(deleted) } }
                .buttonStyle(PillButtonStyle(compact: true))
                .disabled(store.isBusy)
                .help(deleted.remote == nil ? "같은 커밋으로 브랜치를 다시 만듭니다" : "같은 커밋을 원격에 다시 올립니다")
            Button("삭제") { store.forgetDeletedBranch(deleted) }
                .buttonStyle(TextButtonStyle())
                .help("이 목록에서만 지웁니다")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}

private struct ActivityRow: View {
    let entry: ActivityEntry
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        SelectableRow(isSelected: isSelected, action: select) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: entry.kind.symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(color)
                    .frame(width: 18, height: 18)
                    .background(color.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 6) {
                        Text(entry.date, format: .dateTime.hour().minute())
                        Text(entry.shortHash)
                            .font(.system(size: 11, design: .monospaced))
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .help(entry.raw)
    }

    private var color: Color {
        switch entry.kind {
        case .commit, .amend: Theme.green
        case .checkout: Theme.blue
        case .merge, .rebase, .cherryPick: Theme.purple
        case .pull, .push, .clone: Theme.secondary
        case .reset, .revert: Theme.orange
        case .other: Theme.secondary
        }
    }
}
