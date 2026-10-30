import AppKit
import SwiftUI

// MARK: 시트 공통 조각

/// 시트 공통 틀. 제목과 한 줄 설명, 본문, 오른쪽 아래 취소/확인.
private struct SheetFrame<Content: View>: View {
    let title: String
    var subtitle: String?
    let confirmTitle: String
    let canConfirm: Bool
    let width: CGFloat
    /// 되돌리기 어려운 동작. 버튼이 빨개지고 ⏎로는 누르지 않는다.
    var destructive = false
    let confirm: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.bottom, 20)
            VStack(alignment: .leading, spacing: 16) {
                content()
            }
            HStack(spacing: 8) {
                Spacer()
                Button("취소") { dismiss() }
                    .buttonStyle(PillButtonStyle())
                    .keyboardShortcut(.cancelAction)
                if destructive {
                    Button(confirmTitle, action: confirm)
                        .buttonStyle(DestructiveButtonStyle())
                        .disabled(!canConfirm)
                        .opacity(canConfirm ? 1 : 0.5)
                } else {
                    Button(confirmTitle, action: confirm)
                        .buttonStyle(PillButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canConfirm)
                }
            }
            .padding(.top, 24)
        }
        .padding(24)
        .frame(width: width)
        .background(Theme.surface)
        .foregroundStyle(Theme.text)
    }
}

/// 라벨을 위에 작게 두고 그 아래 입력을 놓는 한 칸.
private struct SheetField<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondary)
            content()
        }
    }
}

/// 둥근 입력 상자. 글자 입력과 메뉴가 같은 모양으로 들어간다.
private struct SheetBox<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 8) {
            content()
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))
    }
}

private struct SheetTextField: View {
    let label: String
    @Binding var text: String
    var prompt = ""
    var monospaced = false

    var body: some View {
        SheetField(label: label) {
            SheetBox {
                TextField("", text: $text, prompt: Text(prompt).foregroundStyle(Theme.tertiary))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: monospaced ? .monospaced : .default))
            }
        }
    }
}

/// 메뉴로 고르는 칸. Picker를 상자 안에 넣고 오른쪽에 화살표를 둔다.
private struct SheetMenu<Selection: Hashable, Options: View>: View {
    let label: String
    @Binding var selection: Selection
    @ViewBuilder let options: () -> Options

    var body: some View {
        SheetField(label: label) {
            SheetBox {
                Picker("", selection: $selection, content: options)
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                // 글자 상자와 구별되게, 눌러서 고르는 칸임을 보인다
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// 읽기만 하는 한 줄. "시작 커밋: e9d5d89 · 제목"처럼 고른 것이 무엇인지 확인시킬 때 쓴다.
private struct SheetInfo: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .fixedSize()
            Text(value)
                .font(.system(size: 12, design: monospaced ? .monospaced : .default))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// 켜고 끄는 한 줄. 글자가 왼쪽, 스위치가 오른쪽.
private struct SheetToggle: View {
    let title: String
    var note: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let note {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .tint(Theme.green)
        }
    }
}

private struct SheetNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 기준 브랜치 고르기. 현재 브랜치 → (있으면) 미리 정해진 커밋 → 로컬 → 원격 순서.
private struct BaseMenuOptions: View {
    @Environment(RepositoryStore.self) private var store
    var extraBase: String?

    var body: some View {
        Text(headTitle).tag("HEAD")
        if let extraBase {
            Text(extraBase.count == 40 ? "커밋 \(extraBase.prefix(7))" : extraBase).tag(extraBase)
        }
        if !store.localBranches.isEmpty {
            Section("로컬 브랜치") {
                ForEach(store.localBranches) { branch in
                    Text(branch.name).tag(branch.name)
                }
            }
        }
        if !store.remoteBranches.isEmpty {
            Section("원격 브랜치") {
                ForEach(store.remoteBranches) { branch in
                    Text(branch.name).tag(branch.name)
                }
            }
        }
    }

    /// "현재 브랜치 feature/x"처럼 이름으로 말한다. "HEAD"만으로는 어느 브랜치의 끝인지 헷갈린다.
    private var headTitle: String {
        if store.status.isDetached { return "지금 위치 (분리된 HEAD)" }
        if let branch = store.status.branch { return "현재 브랜치 \(branch)" }
        return "현재 HEAD"
    }
}

extension RepositoryStore {
    /// 고른 기준이 실제로 어느 커밋인지. 시트에서 확인용으로 보여 준다.
    func describeBase(_ base: String) -> String {
        if base == "HEAD" {
            if let commit = headCommit { return "\(commit.shortHash)  \(commit.subject)" }
            if let current = currentBranch { return current.shortHash }
            return "아직 커밋이 없습니다"
        }
        if let branch = branches.first(where: { $0.name == base }) {
            let author = branch.authorName.isEmpty ? "" : ", 작성자 \(branch.authorName)"
            return "\(branch.name)의 마지막 커밋 \(branch.shortHash)" + author
        }
        if base.count == 40 { return String(base.prefix(7)) }
        return base
    }
}

// MARK: 브랜치

struct NewBranchSheet: View {
    @Environment(RepositoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var base = "HEAD"
    @State private var checkout = true
    /// 브랜치 목록에 없는 base (커밋 해시나 태그)
    @State private var extraBase: String?

    var body: some View {
        SheetFrame(
            title: "새 브랜치",
            subtitle: "고른 기준 커밋에서 갈라져 나옵니다. 기준은 바꾸지 않습니다.",
            confirmTitle: "만들기",
            canConfirm: !name.trimmed.isEmpty && !store.isBusy,
            width: 460,
            confirm: {
                Task {
                    let created = await store.createBranch(name: name.trimmed, from: base == "HEAD" ? nil : base, checkout: checkout)
                    if created { dismiss() }
                }
            }
        ) {
            SheetTextField(label: "이름", text: $name, prompt: "feature/login")
            SheetMenu(label: "기준", selection: $base) {
                BaseMenuOptions(extraBase: extraBase)
            }
            SheetInfo(label: "시작 커밋", value: store.describeBase(base))
            SheetToggle(title: "만든 뒤 체크아웃", note: "작업 트리를 새 브랜치로 옮깁니다.", isOn: $checkout)
        }
        .onAppear {
            if let preset = store.newBranchBase {
                if !store.branches.contains(where: { $0.name == preset }) { extraBase = preset }
                base = preset
                store.newBranchBase = nil
            }
        }
    }
}

// MARK: 푸시·풀

/// 창 안의 경고 한 줄. 주황 아이콘과 함께.
private struct SheetWarning: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.orange)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 원격 고르기. 내가 붙인 원격 이름과 실제 저장소(`owner/repo`)를 나눠 보여 준다.
/// 이름은 사용자가 마음대로 붙이는 것이라 이름만으로는 어디로 가는지 모른다.
private struct RemoteField: View {
    @Environment(RepositoryStore.self) private var store
    @Binding var selection: String

    var body: some View {
        SheetField(label: "원격") {
            Menu {
                ForEach(store.remotes) { remote in
                    Button {
                        selection = remote.name
                    } label: {
                        // 메뉴에서는 둘째 Text가 이름 아래 작은 글로 붙는다
                        Text(remote.name)
                        Text(remote.repositoryPath)
                    }
                }
            } label: {
                SheetBox {
                    if let remote = store.remotes.first(where: { $0.name == selection }) {
                        Text(remote.name)
                            .font(.system(size: 13, weight: .semibold))
                            // 위아래 Picker 칸의 글자 시작점과 맞춘다
                            .padding(.leading, 4)
                            .foregroundStyle(Theme.text)
                            .fixedSize()
                        Text(remote.repositoryPath)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("원격을 고르세요")
                            .font(.system(size: 13))
                            .padding(.leading, 4)
                            .foregroundStyle(Theme.tertiary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
        }
    }
}

struct PushSheet: View {
    @Environment(RepositoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var branch = ""
    @State private var remote = ""
    @State private var target = ""
    @State private var tags = false
    @State private var force = false
    @State private var counts: RepositoryStore.SyncCounts?

    var body: some View {
        SheetFrame(
            title: "푸시",
            subtitle: "이 컴퓨터의 커밋을 원격 저장소로 보냅니다.",
            confirmTitle: force ? "강제 푸시" : "푸시",
            canConfirm: !branch.isEmpty && !remote.isEmpty && !target.trimmed.isEmpty && !store.isBusy,
            width: 500,
            destructive: force,
            confirm: {
                Task {
                    if await store.push(branch: branch, remote: remote, target: target.trimmed, force: force, tags: tags) { dismiss() }
                }
            }
        ) {
            SheetMenu(label: "브랜치", selection: $branch) {
                ForEach(store.localBranches) { Text($0.name).tag($0.name) }
            }
            RemoteField(selection: $remote)
            if !remote.isEmpty {
                SheetMenu(label: "원격 브랜치", selection: $target) {
                    let names = store.branchNames(on: remote)
                    if !names.contains(target) { Text("\(target) (새로 만듦)").tag(target) }
                    ForEach(names, id: \.self) { Text($0).tag($0) }
                }
                SheetInfo(label: "보낼 커밋", value: summary)
                ForEach(warnings, id: \.self) { SheetWarning(text: $0) }
            }
            SheetToggle(title: "태그도 푸시", isOn: $tags)
            SheetToggle(title: "강제 푸시", note: "원격 브랜치를 이 컴퓨터의 커밋으로 덮어씁니다. 그사이 원격에 다른 커밋이 생겼으면 거부됩니다.", isOn: $force)
        }
        .onAppear {
            force = store.pushPresetForce
            store.pushPresetForce = false
            branch = store.currentBranch?.name ?? store.localBranches.first?.name ?? ""
            chooseDefaults()
        }
        .onChange(of: branch) { chooseDefaults() }
        .onChange(of: remote) { if !remote.isEmpty { target = store.counterpart(of: branch, on: remote) } }
        .task(id: [branch, remote, target]) {
            counts = nil
            guard !branch.isEmpty, !remote.isEmpty, !target.isEmpty else { return }
            counts = await store.syncCounts(branch: branch, remote: remote, target: target)
        }
    }

    private func chooseDefaults() {
        remote = store.defaultRemote(for: branch) ?? ""
        target = remote.isEmpty ? "" : store.counterpart(of: branch, on: remote)
    }

    private var summary: String {
        guard let counts else { return "세는 중…" }
        let ahead = counts.ahead == 0 ? "보낼 커밋이 없습니다" : "커밋 \(counts.ahead)개"
        return counts.targetExists ? ahead : ahead + ", 원격에 새 브랜치를 만듭니다"
    }

    private var warnings: [String] {
        var lines: [String] = []
        if let counts, counts.behind > 0 {
            lines.append(force
                ? "원격에만 있는 커밋 \(counts.behind)개가 원격에서 사라집니다."
                : "원격에만 있는 커밋 \(counts.behind)개가 있어 거부될 수 있습니다. 먼저 풀하세요.")
        }
        if let upstream = store.localBranches.first(where: { $0.name == branch })?.upstream, upstream != "\(remote)/\(target)" {
            lines.append("추적 중인 \(upstream)이 아닌 곳으로 보냅니다.")
        }
        return lines
    }
}

struct PullSheet: View {
    @Environment(RepositoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var remote = ""
    @State private var rebase = RepositoryStore.pullRebases
    @State private var autostash = RepositoryStore.pullAutostash
    @State private var counts: RepositoryStore.SyncCounts?
    /// 받을 커밋을 지금 브랜치에 합쳐 본 결과
    @State private var preview: MergePreview?

    private var current: String { store.currentBranch?.name ?? "" }
    private var source: String { remote.isEmpty ? "" : store.counterpart(of: current, on: remote) }
    private var sourceExists: Bool { store.branchNames(on: remote).contains(source) }

    var body: some View {
        SheetFrame(
            title: "풀",
            subtitle: "원격 브랜치의 커밋을 가져와 현재 브랜치에 합칩니다.",
            confirmTitle: "풀",
            canConfirm: !remote.isEmpty && sourceExists && !store.isBusy,
            width: 500,
            confirm: {
                Task {
                    if await store.pull(remote: remote, branch: source, rebase: rebase, autostash: autostash) { dismiss() }
                }
            }
        ) {
            RemoteField(selection: $remote)
            if !remote.isEmpty {
                SheetInfo(label: "가져올 브랜치", value: "\(remote)/\(source)", monospaced: true)
                SheetInfo(label: "받는 브랜치", value: "현재 브랜치 \(current)", monospaced: false)
                if sourceExists {
                    SheetInfo(label: "받을 커밋", value: summary)
                    if let preview, !preview.isClean {
                        SheetWarning(text: "충돌 파일 \(preview.conflicts.count)개\(rebase ? " (어림값)" : ""): \(preview.conflictSummary). 풀하면 충돌에서 멈추고, 변경 사항 칸에서 정리합니다.")
                    }
                } else {
                    SheetWarning(text: "\(remote)에 \(source) 브랜치가 없습니다. 페치했는데도 없다면 아직 푸시하지 않은 브랜치입니다.")
                }
            }
            SheetToggle(title: "머지 대신 리베이스", note: rebase ? "내 커밋을 받은 커밋 뒤로 옮깁니다. 머지 커밋이 생기지 않습니다." : "양쪽에 커밋이 있으면 머지 커밋이 생깁니다.", isOn: $rebase)
            SheetToggle(title: "변경 사항을 스태시했다가 다시 적용", note: "커밋하지 않은 변경이 있어도 풀합니다.", isOn: $autostash)
        }
        .onAppear { remote = store.defaultRemote(for: current) ?? "" }
        .task(id: remote) {
            counts = nil
            preview = nil
            guard !remote.isEmpty, sourceExists else { return }
            counts = await store.syncCounts(branch: "HEAD", remote: remote, target: source)
            // 받을 것도 내 것도 있을 때만 충돌이 날 수 있다
            if let counts, counts.behind > 0, counts.ahead > 0 {
                preview = await store.previewMerge(ours: store.headRevision, theirs: "refs/remotes/\(remote)/\(source)")
            }
        }
    }

    /// 마지막 페치 기준. 풀은 페치부터 하므로 실제로는 더 받을 수 있다.
    private var summary: String {
        guard let counts else { return "세는 중…" }
        let incoming = counts.behind == 0 ? "새 커밋 없음" : "커밋 \(counts.behind)개"
        let mine = counts.ahead > 0 ? ", 내 커밋 \(counts.ahead)개" : ""
        let clean = preview?.isClean == true ? ", 충돌 없음" : ""
        return incoming + mine + clean + " (마지막 페치 기준)"
    }
}

// MARK: 스태시

struct NewStashSheet: View {
    @Environment(RepositoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var includeUntracked = true

    var body: some View {
        SheetFrame(
            title: "스태시 만들기",
            subtitle: "작업 트리와 스테이징의 변경 \(store.status.changes.count)개를 치워 두고 작업 트리를 깨끗하게 만듭니다.",
            confirmTitle: "스태시",
            canConfirm: !store.isBusy,
            width: 460,
            confirm: {
                Task {
                    if await store.createStash(message: message, includeUntracked: includeUntracked) { dismiss() }
                }
            }
        ) {
            SheetTextField(label: "메시지", text: $message, prompt: "비워도 됩니다")
            SheetToggle(title: "추적하지 않는 파일도 넣기", isOn: $includeUntracked)
        }
    }
}

// MARK: 태그

struct NewTagSheet: View {
    @Environment(RepositoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let targetHash: String
    @State private var name = ""
    @State private var message = ""

    var body: some View {
        SheetFrame(
            title: "태그 만들기",
            subtitle: "메시지를 적으면 주석 태그, 비우면 가벼운 태그가 됩니다.",
            confirmTitle: "만들기",
            canConfirm: !name.trimmed.isEmpty && !store.isBusy,
            width: 460,
            confirm: {
                Task {
                    if await store.createTag(name: name.trimmed, at: targetHash, message: message) { dismiss() }
                }
            }
        ) {
            SheetTextField(label: "이름", text: $name, prompt: "v1.2.0")
            SheetTextField(label: "메시지", text: $message, prompt: "비워도 됩니다")
            SheetInfo(label: "대상 커밋", value: store.describeBase(targetHash), monospaced: false)
        }
    }
}

// MARK: 원격

struct NewRemoteSheet: View {
    @Environment(RepositoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = "origin"
    @State private var url = ""

    var body: some View {
        SheetFrame(
            title: "원격 추가",
            confirmTitle: "추가",
            canConfirm: !name.trimmed.isEmpty && !url.trimmed.isEmpty && !store.isBusy,
            width: 500,
            confirm: {
                Task {
                    if await store.addRemote(name: name.trimmed, url: url.trimmed) { dismiss() }
                }
            }
        ) {
            SheetTextField(label: "이름", text: $name, prompt: "origin")
            SheetTextField(label: "주소", text: $url, prompt: "git@github.com:org/repo.git", monospaced: true)
        }
        .onAppear {
            if store.remotes.contains(where: { $0.name == "origin" }) { name = "" }
        }
    }
}

// MARK: 워크트리

struct NewWorktreeSheet: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case existing = "기존 브랜치"
        case new = "새 브랜치"
        var id: String { rawValue }
    }

    @Environment(RepositoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var mode = Mode.existing
    @State private var existingBranch = ""
    @State private var newBranchName = ""
    @State private var base = "HEAD"
    @State private var path = ""

    /// 아직 어느 워크트리에도 없는 로컬 브랜치, 그리고 같은 이름의 로컬 브랜치가 없는 원격 브랜치.
    /// 원격 브랜치는 `origin/`을 뗀 이름을 넘기면 git이 추적 브랜치를 만들어 준다.
    private var availableBranches: [(label: String, value: String)] {
        let localNames = Set(store.localBranches.map(\.name))
        let locals = store.localBranches
            .filter { $0.worktreePath == nil }
            .map { (label: $0.name, value: $0.name) }
        let remotes = store.remoteBranches
            .filter { !localNames.contains($0.nameWithoutRemote) }
            .map { (label: "\($0.nameWithoutRemote)  (\($0.name))", value: $0.nameWithoutRemote) }
        return locals + remotes
    }

    private var chosenBranch: String {
        mode == .existing ? existingBranch : newBranchName.trimmed
    }

    private var canCreate: Bool {
        !chosenBranch.isEmpty && !path.trimmed.isEmpty && !store.isBusy
    }

    var body: some View {
        SheetFrame(
            title: "새 워크트리",
            subtitle: "다른 폴더에 브랜치를 하나 더 체크아웃합니다. 지금 작업을 두고 다른 브랜치를 볼 때 씁니다.",
            confirmTitle: "만들기",
            canConfirm: canCreate,
            width: 560,
            confirm: {
                Task {
                    let created = await store.addWorktree(
                        path: path.trimmed,
                        branch: chosenBranch,
                        createBranch: mode == .new,
                        from: mode == .new && base != "HEAD" ? base : nil
                    )
                    if created { dismiss() }
                }
            }
        ) {
            UnderlineTabs(tabs: Mode.allCases, selection: $mode, title: { $0.rawValue })
            if mode == .existing {
                if availableBranches.isEmpty {
                    SheetNote(text: "모든 브랜치가 이미 어딘가에 체크아웃되어 있습니다. 새 브랜치로 만들어 보세요.")
                } else {
                    SheetMenu(label: "브랜치", selection: $existingBranch) {
                        ForEach(availableBranches, id: \.value) { entry in
                            Text(entry.label).tag(entry.value)
                        }
                    }
                }
            } else {
                SheetTextField(label: "브랜치 이름", text: $newBranchName, prompt: "feature/login")
                SheetMenu(label: "기준", selection: $base) {
                    BaseMenuOptions()
                }
                SheetInfo(label: "시작 커밋", value: store.describeBase(base))
            }
            SheetField(label: "위치") {
                HStack(spacing: 8) {
                    SheetBox {
                        TextField("", text: $path)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, design: .monospaced))
                    }
                    Button("선택…") { chooseLocation() }
                        .buttonStyle(PillButtonStyle(compact: true))
                }
            }
        }
        .onAppear {
            if existingBranch.isEmpty, let first = availableBranches.first {
                existingBranch = first.value
            }
            if path.isEmpty, !chosenBranch.isEmpty {
                path = store.suggestedWorktreePath(for: chosenBranch)
            }
        }
        .onChange(of: chosenBranch) {
            path = store.suggestedWorktreePath(for: chosenBranch)
        }
    }

    private func chooseLocation() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.prompt = "선택"
        panel.message = "새 워크트리 폴더를 만들 위치를 고르세요"
        panel.nameFieldLabel = "폴더 이름:"
        let suggestion = store.suggestedWorktreePath(for: chosenBranch.isEmpty ? "worktree" : chosenBranch)
        panel.nameFieldStringValue = (suggestion as NSString).lastPathComponent
        panel.directoryURL = URL(fileURLWithPath: (suggestion as NSString).deletingLastPathComponent, isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        path = url.path(percentEncoded: false)
    }
}

// MARK: 브랜치 이름 바꾸기

struct RenameBranchSheet: View {
    @Environment(RepositoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let name: String
    @State private var newName = ""

    var body: some View {
        SheetFrame(
            title: "브랜치 이름 바꾸기",
            subtitle: "로컬 이름만 바뀝니다. 원격 브랜치는 그대로입니다.",
            confirmTitle: "변경",
            canConfirm: !newName.trimmed.isEmpty && newName.trimmed != name && !store.isBusy,
            width: 460,
            confirm: {
                guard let branch = store.localBranches.first(where: { $0.name == name }) else { return }
                Task { if await store.renameBranch(branch, to: newName) { dismiss() } }
            }
        ) {
            SheetInfo(label: "지금 이름", value: name)
            SheetTextField(label: "새 이름", text: $newName, prompt: name)
        }
        .onAppear { newName = name }
    }
}

// MARK: 별명

struct AliasSheet: View {
    @Environment(RepositoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let key: String
    let title: String
    @State private var alias = ""

    var body: some View {
        SheetFrame(
            title: "별명 지정",
            subtitle: "별명은 원래 이름 옆에 같이 보입니다. 비워서 저장하면 지워집니다.",
            confirmTitle: "저장",
            canConfirm: true,
            width: 440,
            confirm: {
                store.setAlias(alias, for: key)
                dismiss()
            }
        ) {
            SheetInfo(label: "대상", value: title)
            SheetTextField(label: "별명", text: $alias, prompt: "예: 로그인 개편")
        }
        .onAppear { alias = store.alias(for: key) ?? "" }
    }
}

// MARK: 클론

struct CloneSheet: View {
    @Environment(RepositoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var parent = NSString(string: "~/Github").expandingTildeInPath
    @State private var folderName = ""
    @State private var nameEdited = false

    private var destination: String { (parent as NSString).appendingPathComponent(folderName) }

    var body: some View {
        SheetFrame(
            title: "저장소 클론",
            subtitle: "받은 뒤 바로 엽니다. 인증은 git의 credential helper와 ssh-agent를 그대로 씁니다.",
            confirmTitle: "클론",
            canConfirm: !url.trimmed.isEmpty && !folderName.trimmed.isEmpty && !store.isBusy,
            width: 540,
            confirm: {
                Task {
                    if await store.clone(url.trimmed, to: destination) { dismiss() }
                }
            }
        ) {
            SheetTextField(label: "주소", text: $url, prompt: "git@github.com:org/repo.git", monospaced: true)
                .onChange(of: url) {
                    guard !nameEdited else { return }
                    var last = url.trimmed.split(separator: "/").last.map(String.init) ?? ""
                    if let colon = last.lastIndex(of: ":") { last = String(last[last.index(after: colon)...]) }
                    if last.hasSuffix(".git") { last = String(last.dropLast(4)) }
                    folderName = last
                }
            SheetField(label: "받을 위치") {
                HStack(spacing: 8) {
                    SheetBox {
                        TextField("", text: $parent)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, design: .monospaced))
                    }
                    Button("선택…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.canCreateDirectories = true
                        panel.prompt = "선택"
                        panel.begin { response in
                            if response == .OK, let chosen = panel.url {
                                parent = chosen.path(percentEncoded: false)
                            }
                        }
                    }
                    .buttonStyle(PillButtonStyle(compact: true))
                }
            }
            SheetTextField(label: "폴더 이름", text: $folderName, prompt: "repo")
                .onChange(of: folderName) { nameEdited = true }
            SheetInfo(label: "저장 경로", value: (destination as NSString).abbreviatingWithTildeInPath, monospaced: true)
            if store.isBusy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    SheetNote(text: "받는 중입니다. 큰 저장소는 시간이 걸립니다.")
                }
            }
        }
    }
}

// MARK: Git Flow

/// Git Flow 브랜치 시작. 종류에 맞는 접두어를 붙여 기준 브랜치에서 만든다.
struct GitFlowStartSheet: View {
    @Environment(RepositoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var kind: GitFlowKind
    @State private var name = ""
    /// 기준 브랜치. 종류를 바꾸면 그 종류의 기본 기준으로 돌아간다.
    @State private var base = ""

    init(kind: GitFlowKind?) {
        _kind = State(initialValue: kind ?? .feature)
    }

    private var branch: String { store.flowConfig.prefix(kind) + name.trimmed }
    private var prompt: String {
        switch kind {
        case .feature, .bugfix: "login"
        case .release, .hotfix: "1.2.0"
        }
    }

    var body: some View {
        SheetFrame(
            title: "Git Flow 시작",
            confirmTitle: "시작",
            canConfirm: !name.trimmed.isEmpty && !name.contains(" ") && !store.isBusy,
            width: 460,
            confirm: {
                Task {
                    if await store.startGitFlow(kind: kind, name: name.trimmed, base: base) { dismiss() }
                }
            }
        ) {
            UnderlineTabs(tabs: GitFlowKind.allCases, selection: $kind, title: { $0.title })
            SheetTextField(label: kind.releases ? "버전" : "이름", text: $name, prompt: prompt)
            SheetInfo(label: "브랜치", value: branch, monospaced: true)
            SheetMenu(label: "기준", selection: $base) {
                ForEach(store.localBranches.map(\.name), id: \.self) { Text($0).tag($0) }
            }
        }
        .onAppear { base = store.flowConfig.base(of: kind) }
        .onChange(of: kind) { base = store.flowConfig.base(of: kind) }
    }
}

/// Git Flow 마무리. 할 일을 단계로 늘어놓고, 실행하면 단계마다 상태가 바뀐다.
/// 충돌로 멈추면 창을 닫고 충돌을 푼 뒤 다시 열어 이어 간다.
struct GitFlowFinishSheet: View {
    @Environment(RepositoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let run = store.gitFlowRun {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Git Flow 마무리")
                        .font(.system(size: 17, weight: .semibold))
                    Text(run.branch)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.secondary)
                        .textSelection(.enabled)
                }
                .padding(.bottom, 18)

                if !run.blockers.isEmpty || !run.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(run.blockers, id: \.self) { GitFlowNotice(text: $0, blocking: true) }
                        ForEach(run.notes, id: \.self) { GitFlowNotice(text: $0, blocking: false) }
                    }
                    .padding(.bottom, 16)
                }

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(run.steps.enumerated()), id: \.element.id) { offset, step in
                        GitFlowStepRow(step: step, isLast: offset == run.steps.count - 1)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 12))
                .animation(.easeOut(duration: 0.15), value: run.steps)

                if run.pushRemote != nil, !run.started {
                    SheetToggle(title: "끝나면 \(run.pushRemote ?? "")에 푸시", isOn: Binding(
                        get: { run.pushes },
                        set: { on in Task { await store.prepareGitFlowFinish(branch: run.branch, pushes: on) } }
                    ))
                    .padding(.top, 14)
                    .disabled(store.isBusy)
                }

                buttons(run)
                    .padding(.top, 22)
            }
            .padding(24)
            .frame(width: 520)
            .background(Theme.surface)
            .foregroundStyle(Theme.text)
        }
    }

    @ViewBuilder
    private func buttons(_ run: GitFlowRun) -> some View {
        HStack(spacing: 8) {
            // 머지가 진행 중이면 취소할 수 없다. 먼저 머지를 중단하거나 마쳐야 지금까지를 되돌리기 기록으로 남길 수 있다.
            if run.started, !run.isFinished, !run.isRunning, store.operation == nil {
                Button("남은 단계 취소") { Task { await store.cancelGitFlow() } }
                    .buttonStyle(PillButtonStyle())
                    .help("남은 단계를 하지 않습니다. 이미 한 단계는 ⌘Z로 되돌릴 수 있습니다")
            }
            Spacer()
            if run.isFinished {
                Button("완료") {
                    store.gitFlowRun = nil
                    dismiss()
                }
                .buttonStyle(PillButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
            } else {
                Button("닫기") {
                    // 시작하지 않은 흐름은 남겨 둘 이유가 없다
                    if !run.started { store.gitFlowRun = nil }
                    dismiss()
                }
                .buttonStyle(PillButtonStyle())
                .keyboardShortcut(.cancelAction)
                // 실행 중에 닫으면 끝난 흐름을 확인할 곳이 없어진다
                .disabled(run.isRunning)
                Button(run.isRunning ? "진행 중…" : (run.started ? "계속" : "마무리")) {
                    Task { await store.runGitFlow() }
                }
                .buttonStyle(PillButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(run.isRunning || !run.blockers.isEmpty || store.operation != nil || store.isBusy)
            }
        }
    }
}

private struct GitFlowNotice: View {
    let text: String
    let blocking: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: blocking ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(blocking ? Theme.red : Theme.orange)
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 단계 한 줄. 왼쪽 표시가 세로선으로 이어져 순서가 보인다.
private struct GitFlowStepRow: View {
    let step: GitFlowStep
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                mark
                    .frame(width: 16, height: 18)
                if !isLast {
                    Rectangle()
                        .fill(Theme.border)
                        .frame(width: 1.5)
                        .frame(maxHeight: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(step.state == .skipped ? Theme.secondary : Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail.text)
                        .font(.system(size: 11))
                        .foregroundStyle(detail.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, isLast ? 0 : 10)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var mark: some View {
        switch step.state {
        case .waiting:
            Circle().stroke(Theme.tertiary, lineWidth: 1.5).frame(width: 10, height: 10)
        case .running:
            ProgressView().controlSize(.mini)
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(Theme.added)
        case .skipped:
            Image(systemName: "minus.circle").font(.system(size: 13)).foregroundStyle(Theme.tertiary)
        case .failed:
            Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(Theme.red)
        }
    }

    private var detail: (text: String, color: Color)? {
        switch step.state {
        case .failed(let message): (message, Theme.red)
        case .skipped: ("이미 되어 있어 건너뛰었습니다", Theme.tertiary)
        case .waiting: step.warning.map { ($0, Theme.orange) }
        default: nil
        }
    }
}

// MARK: 커밋 정리

/// 정리할 구간을 읽어 오는 동안과 못 읽었을 때를 같이 다룬다
private struct RewriteLoader<Content: View>: View {
    let failure: String?
    let isLoading: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        if let failure {
            GitFlowNoticeRow(text: failure, blocking: true)
        } else if isLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("커밋을 읽는 중…").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
        } else {
            content()
        }
    }
}

private struct GitFlowNoticeRow: View {
    let text: String
    let blocking: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: blocking ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(blocking ? Theme.red : Theme.orange)
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

/// 여러 줄 메시지 칸
private struct MessageEditor: View {
    @Binding var text: String

    var body: some View {
        SheetField(label: "메시지") {
            TextEditor(text: $text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .frame(height: 120)
                .padding(8)
                .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// 커밋 하나의 메시지를 고친다. 그 뒤 커밋들은 같은 내용으로 다시 쓴다.
struct RewordSheet: View {
    @Environment(RepositoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let hash: String
    @State private var context: RewriteContext?
    /// 구간을 읽지 못한 이유. 이때는 할 수 있는 것이 없다.
    @State private var failure: String?
    /// 시작하지 못한 이유(훅 거부 등). 편집 칸은 그대로 두고 아래에 보여 준다.
    @State private var runFailure: String?
    @State private var message = ""

    private var commit: Commit? { context?.commits.first { $0.hash == hash } }

    var body: some View {
        SheetFrame(
            title: "메시지 수정",
            subtitle: commit.map { $0.shortHash + "  " + $0.subject },
            confirmTitle: "수정",
            canConfirm: context != nil && !message.trimmed.isEmpty && message.trimmed != commit.map { context?.message(of: $0) ?? "" } && !store.isBusy,
            width: 520,
            confirm: run
        ) {
            RewriteLoader(failure: failure, isLoading: context == nil) {
                MessageEditor(text: $message)
                ForEach(context?.notes ?? [], id: \.self) { GitFlowNoticeRow(text: $0, blocking: false) }
                if let runFailure { GitFlowNoticeRow(text: runFailure, blocking: true) }
            }
        }
        .task {
            switch await store.loadRewrite(from: hash) {
            case .success(let loaded):
                context = loaded
                message = loaded.commits.first.map(loaded.message(of:)) ?? ""
            case .failure(let error):
                failure = error.message
            }
        }
    }

    private func run() {
        guard let context else { return }
        let items = context.commits.map { RewriteItem(commit: $0, action: $0.hash == hash ? .reword(message.trimmed) : .keep) }
        Task {
            if let problem = await store.rewriteHistory(items, context: context, label: "메시지 수정", done: "메시지를 수정했습니다") {
                runFailure = problem
            } else {
                dismiss()
            }
        }
    }
}

/// 붙어 있는 커밋 여러 개를 하나로 합친다
struct SquashSheet: View {
    @Environment(RepositoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// 히스토리 순서(최근 것이 위)
    let hashes: [String]
    @State private var context: RewriteContext?
    /// 구간을 읽지 못한 이유. 이때는 할 수 있는 것이 없다.
    @State private var failure: String?
    /// 시작하지 못한 이유(훅 거부 등). 편집 칸은 그대로 두고 아래에 보여 준다.
    @State private var runFailure: String?
    @State private var message = ""

    var body: some View {
        SheetFrame(
            title: "커밋 \(hashes.count)개 합치기",
            subtitle: "하나의 커밋으로 합칩니다. 변경 내용은 그대로입니다.",
            confirmTitle: "합치기",
            canConfirm: context != nil && failure == nil && !message.trimmed.isEmpty && !store.isBusy,
            width: 520,
            confirm: run
        ) {
            RewriteLoader(failure: failure, isLoading: context == nil) {
                MessageEditor(text: $message)
                ForEach(context?.notes ?? [], id: \.self) { GitFlowNoticeRow(text: $0, blocking: false) }
                if let runFailure { GitFlowNoticeRow(text: runFailure, blocking: true) }
            }
        }
        .task {
            guard let oldest = hashes.last else { return }
            switch await store.loadRewrite(from: oldest) {
            case .success(let loaded):
                // 고른 커밋이 구간 맨 앞에 붙어 있어야 한다. 사이에 다른 커밋이 끼면 합칠 수 없다.
                let selected = Array(loaded.commits.prefix(hashes.count))
                guard Set(selected.map(\.hash)) == Set(hashes) else {
                    failure = "붙어 있는 커밋만 합칠 수 있습니다. 사이에 끼어 있는 커밋까지 같이 고르세요"
                    return
                }
                context = loaded
                message = selected.map(loaded.message(of:)).joined(separator: "\n\n")
            case .failure(let error):
                failure = error.message
            }
        }
    }

    private func run() {
        guard let context, let oldest = hashes.last else { return }
        let selected = Set(hashes)
        let items = context.commits.map { commit -> RewriteItem in
            if commit.hash == oldest { return RewriteItem(commit: commit, action: .reword(message.trimmed)) }
            return RewriteItem(commit: commit, action: selected.contains(commit.hash) ? .fixup : .keep)
        }
        Task {
            if let problem = await store.rewriteHistory(items, context: context, label: "커밋 합치기", done: "커밋 \(hashes.count)개를 합쳤습니다") {
                runFailure = problem
            } else {
                dismiss()
            }
        }
    }
}

/// 고른 커밋부터 HEAD까지를 한 번에 정리한다. 최근 커밋이 위(히스토리와 같은 순서).
struct CleanupSheet: View {
    @Environment(RepositoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let hash: String
    @State private var context: RewriteContext?
    /// 구간을 읽지 못한 이유. 이때는 할 수 있는 것이 없다.
    @State private var failure: String?
    /// 시작하지 못한 이유(훅 거부 등). 편집 칸은 그대로 두고 아래에 보여 준다.
    @State private var runFailure: String?
    /// 오래된 것부터. 화면에는 뒤집어 보여 준다.
    @State private var items: [RewriteItem] = []
    /// 목록에서 고른 커밋. Finder처럼 고른 뒤 아래 버튼으로 할 일을 정한다.
    @State private var selection: Set<String> = []
    /// 메시지를 고치는 커밋의 새 제목
    @State private var subjects: [String: String] = [:]
    @FocusState private var editing: String?

    private var changed: Bool {
        guard let context else { return false }
        return items.map(\.commit.hash) != context.commits.map(\.hash) || items.contains { $0.action != .keep }
    }

    /// 화면 순서(최근 것이 위)
    private var shown: [RewriteItem] { items.reversed() }
    /// 고른 커밋, 오래된 것부터
    private var selected: [RewriteItem] { items.filter { selection.contains($0.id) } }

    /// 고른 커밋이 화면에서 붙어 있고 둘 이상이면 하나로 합칠 수 있다
    private var canSquash: Bool {
        let indexes = selected.compactMap { item in items.firstIndex(of: item) }
        guard indexes.count >= 2, let low = indexes.min(), let high = indexes.max() else { return false }
        return high - low + 1 == indexes.count
    }

    var body: some View {
        SheetFrame(
            title: "커밋 정리",
            subtitle: "위가 최근 커밋입니다. 끌어서 순서를 바꾸고, 커밋을 고른 뒤 아래 버튼으로 정리합니다.",
            confirmTitle: "정리",
            canConfirm: changed && !store.isBusy,
            width: 600,
            confirm: run
        ) {
            RewriteLoader(failure: failure, isLoading: context == nil) {
                VStack(spacing: 0) {
                    List(selection: $selection) {
                        ForEach(shown) { item in
                            row(item)
                                .tag(item.id)
                        }
                        .onMove(perform: moveShown)
                    }
                    .listStyle(.bordered(alternatesRowBackgrounds: true))
                    // 목록은 내용 높이를 모르면 접혀 버린다. 줄 수만큼 주고 많으면 스크롤한다.
                    .frame(height: min(CGFloat(items.count) * 28 + CGFloat(items.filter(\.isRewording).count) * 6 + 4, 340))
                    .onDeleteCommand { toggleDrop() }
                    .contextMenu(forSelectionType: String.self) { ids in
                        if !ids.isEmpty { actions(compact: false) }
                    }
                    actionBar
                }
                ForEach(context?.notes ?? [], id: \.self) { GitFlowNoticeRow(text: $0, blocking: false) }
                if let runFailure { GitFlowNoticeRow(text: runFailure, blocking: true) }
            }
        }
        .task {
            switch await store.loadRewrite(from: hash) {
            case .success(let loaded):
                context = loaded
                items = loaded.commits.map { RewriteItem(commit: $0) }
            case .failure(let error):
                failure = error.message
            }
        }
        #if CANOPY_DEV
        // 화면 확인용: 위 두 커밋을 합치고, 셋째는 메시지 고치기, 넷째는 빼기
        .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name("dev.sangeui.canopy.debug"))) { note in
            guard note.object as? String == "cleanupDemo", items.count >= 4 else { return }
            selection = [shown[0].id, shown[1].id]
            squash()
            reword(shown[2])
            selection = [shown[3].id]
            toggleDrop()
        }
        #endif
    }

    /// 목록 바로 아래 버튼 줄. 고른 것에 할 수 있는 일만 켠다.
    private var actionBar: some View {
        HStack(spacing: 6) {
            actions(compact: true)
            Spacer()
            Text(selection.isEmpty ? "커밋을 고르세요" : "\(selection.count)개 고름")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func actions(compact: Bool) -> some View {
        let single = selected.count == 1 ? selected.first : nil
        Button("하나로 합치기") { squash() }
            .disabled(!canSquash)
            .help("붙어 있는 커밋 둘 이상을 골라 가장 오래된 커밋 하나로 합칩니다")
        Button("메시지 수정") { if let single { reword(single) } }
            .disabled(single == nil)
        Button(selected.allSatisfy { $0.action == .drop } && !selected.isEmpty ? "삭제 취소" : "삭제") { toggleDrop() }
            .disabled(selected.isEmpty)
            .help("선택한 커밋을 삭제합니다 (Delete)")
        Button("원래대로") { reset() }
            .disabled(selected.allSatisfy { $0.action == .keep })
    }

    @ViewBuilder
    private func row(_ item: RewriteItem) -> some View {
        // 고른 행은 파란 배경이라 시스템 글자색(흰색)을 쓴다. 빨강·회색은 잘 안 보인다.
        let picked = selection.contains(item.id)
        HStack(spacing: 8) {
            Group {
                switch item.action {
                case .keep: Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(picked ? Color.primary : Theme.tertiary)
                case .reword: Image(systemName: "pencil").foregroundStyle(picked ? Color.primary : Theme.accent)
                case .fixup: Image(systemName: "arrow.turn.left.down").foregroundStyle(picked ? Color.primary : Theme.secondary)
                case .drop: Image(systemName: "minus.circle").foregroundStyle(picked ? Color.primary : Theme.red)
                }
            }
            .font(.system(size: 11))
            .frame(width: 14)
            .padding(.leading, item.action == .fixup ? 14 : 0)
            Text(item.commit.shortHash)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(picked ? Color.secondary : Theme.tertiary)
            if item.isRewording {
                TextField("새 제목", text: Binding(
                    get: { subjects[item.id] ?? split(item).title },
                    set: { subjects[item.id] = $0; update(item) }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .focused($editing, equals: item.id)
            } else {
                Text(item.commit.subject)
                    .font(.system(size: 13))
                    .strikethrough(item.action == .drop)
                    .foregroundStyle(picked ? Color.primary : (item.action == .drop || item.action == .fixup ? Theme.tertiary : Theme.text))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if item.action == .fixup {
                Text("아래 커밋에 합침").font(.system(size: 11)).foregroundStyle(picked ? Color.primary : Theme.secondary)
            } else if item.action == .drop {
                Text("뺌").font(.system(size: 11)).foregroundStyle(picked ? Color.primary : Theme.red)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: 동작

    /// 고른 커밋 중 가장 오래된 것에 나머지를 합친다. 메시지는 가장 오래된 커밋 것을 쓰고, 고칠 수 있게 연다.
    private func squash() {
        guard canSquash, let oldest = selected.first else { return }
        for item in selected.dropFirst() { set(item, .fixup) }
        if !items.contains(where: { $0.id == oldest.id && $0.isRewording }) { set(oldest, .keep) }
        selection = [oldest.id]
    }

    private func reword(_ item: RewriteItem) {
        set(item, .reword(original(item)))
        update(item)
        editing = item.id
    }

    /// 원래 메시지(줄바꿈 그대로)
    private func original(_ item: RewriteItem) -> String { context?.message(of: item.commit) ?? item.commit.subject }

    /// 원래 메시지의 첫 줄과 나머지
    private func split(_ item: RewriteItem) -> (title: String, rest: String) {
        let text = original(item)
        guard let newline = text.firstIndex(of: "\n") else { return (text, "") }
        return (String(text[..<newline]), String(text[text.index(after: newline)...]))
    }

    private func toggleDrop() {
        let dropping = !selected.allSatisfy { $0.action == .drop }
        for item in selected { set(item, dropping ? .drop : .keep) }
    }

    private func reset() {
        for item in selected { set(item, .keep) }
    }

    private func set(_ item: RewriteItem, _ action: RewriteItem.Action) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].action = action
        normalize()
    }

    /// 합칠 수 없는 합치기를 "유지"로 돌린다.
    /// 가장 오래된 커밋은 합칠 앞 커밋이 없다. 바로 아래 커밋을 빼면, 화면은 "아래 커밋에 합침"인데 git은 그보다 더 아래에 합친다.
    private func normalize() {
        for index in items.indices where items[index].action == .fixup {
            if index == 0 || items[index - 1].action == .drop { items[index].action = .keep }
        }
    }

    /// 첫 줄만 바꾸고 나머지는 원문 그대로 둔다
    private func update(_ item: RewriteItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }), items[index].isRewording else { return }
        let parts = split(item)
        let title = subjects[item.id] ?? parts.title
        items[index].action = .reword(parts.rest.isEmpty ? title : title + "\n" + parts.rest)
    }

    /// 끌어서 옮긴 것을 화면 순서에서 받아 오래된 것부터인 순서로 되돌린다
    private func moveShown(from source: IndexSet, to destination: Int) {
        var display = shown
        display.move(fromOffsets: source, toOffset: destination)
        items = display.reversed()
        normalize()
    }

    private func run() {
        guard let context else { return }
        Task {
            if let problem = await store.rewriteHistory(items, context: context, label: "커밋 정리", done: "커밋을 정리했습니다") {
                runFailure = problem
            } else {
                dismiss()
            }
        }
    }
}
