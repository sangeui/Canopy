import SwiftUI

/// 설정. Claude 앱처럼 창 안에 떠 있는 모달이다. 왼쪽에 검색과 항목, 오른쪽에 그 항목의 내용.
struct SettingsOverlay: View {
    @Environment(RepositoryStore.self) private var store

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.22)
                    .ignoresSafeArea()
                    .onTapGesture { store.showsSettings = false }
                SettingsPanel()
                    .frame(width: min(960, geometry.size.width - 64), height: min(720, geometry.size.height - 64))
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border, lineWidth: 1))
                    .shadow(color: .black.opacity(0.25), radius: 30, y: 10)
            }
        }
    }
}

/// 설정 항목. 왼쪽 목록의 한 줄이자 오른쪽 페이지.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general, appearance, git, claude, security, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "일반"
        case .appearance: "모양"
        case .claude: "Claude"
        case .git: "Git"
        case .security: "보안"
        case .about: "정보"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintbrush.pointed"
        case .claude: ""
        case .git: "arrow.triangle.branch"
        case .security: "lock.shield"
        case .about: "info.circle"
        }
    }
}

private struct SettingsPanel: View {
    @Environment(RepositoryStore.self) private var store
    @AppStorage("settingsTab") private var pageID = SettingsPage.general.rawValue
    @State private var query = ""
    @Namespace private var selectionSpace

    private var page: SettingsPage { SettingsPage(rawValue: pageID) ?? .general }

    private var visiblePages: [SettingsPage] {
        let needle = query.trimmed.lowercased()
        return SettingsPage.allCases.filter { needle.isEmpty || $0.title.lowercased().contains(needle) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("설정").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button { store.showsSettings = false } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(IconButtonStyle(size: 26))
                .keyboardShortcut(.cancelAction)
                .help("닫기 (esc)")
            }
            .padding(.horizontal, 18)
            .frame(height: 48)
            HairlineDivider()
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 236)
                HairlineDivider().frame(width: 1).frame(maxHeight: .infinity)
                ScrollView {
                    Group {
                        switch page {
                        case .general: GeneralSettings()
                        case .appearance: AppearanceSettings()
                        case .claude: ClaudeSettings()
                        case .git: GitSettings()
                        case .security: SecuritySettings()
                        case .about: AboutSettings()
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.top)
                .id(page)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            SearchField(text: $query, placeholder: "검색")
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)
            // 항목이 몇 개 안 돼서 묶음 제목 없이 한 목록으로 둔다
            ForEach([0], id: \.self) { _ in
                ForEach(visiblePages) { item in
                    Button { pageID = item.rawValue } label: {
                        HStack(spacing: 10) {
                            if item == .claude {
                                ClaudeMark(size: 15, color: page == item ? ClaudeMark.orange : Theme.text)
                            } else {
                                Image(systemName: item.symbol)
                                    .font(.system(size: 14))
                                    .frame(width: 16)
                            }
                            Text(item.title).font(.system(size: 13))
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        // 선택 배경은 하나만 두고 고른 줄로 옮겨 간다
                        .background {
                            if page == item {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Theme.raised)
                                    .matchedGeometryEffect(id: "selection", in: selectionSpace)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: pageID)
            Spacer()
        }
    }
}

// MARK: 공통 조각 (Claude 앱 설정의 줄)

/// 페이지 제목
private struct SettingsTitle: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 16, weight: .semibold)).padding(.bottom, 6)
    }
}

/// 묶음 머리말. 제목 아래로 줄이 이어진다.
private struct SettingsSection: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 14, weight: .semibold)).padding(.top, 18)
    }
}

/// 한 줄. 왼쪽에 이름과 설명, 오른쪽에 컨트롤. 아래에 가는 선.
private struct SettingsRow<Control: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let control: () -> Control

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 16)
                control()
            }
            .padding(.vertical, 14)
            HairlineDivider()
        }
    }
}

private struct SettingsSwitch: View {
    @Binding var isOn: Bool
    var body: some View {
        Toggle("", isOn: $isOn).toggleStyle(.switch).controlSize(.small).labelsHidden().tint(Theme.green)
    }
}

/// 값 글자만 보이는 읽기 전용 컨트롤
private struct SettingsValue: View {
    let text: String
    var monospaced = false
    var body: some View {
        Text(text)
            .font(.system(size: 12, design: monospaced ? .monospaced : .default))
            .foregroundStyle(Theme.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }
}

// MARK: 일반

private struct GeneralSettings: View {
    @AppStorage("reopenLastRepository") private var reopenLast = true
    @AppStorage(TerminalApp.defaultsKey) private var terminal = TerminalApp.systemID
    /// 설정 창을 열 때 한 번만 찾는다
    @State private var terminals = TerminalApp.installed

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsTitle(text: "일반")
            SettingsRow(title: "마지막 저장소 다시 열기") {
                SettingsSwitch(isOn: $reopenLast)
            }
            SettingsRow(title: "터미널 앱") {
                Picker("", selection: $terminal) {
                    ForEach(terminals) { app in
                        Label { Text(app.name) } icon: { Image(nsImage: app.icon) }
                            .tag(app.bundleID)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .onAppear {
                    // 고른 앱이 지워졌으면 macOS 터미널로 돌린다
                    if !terminals.contains(where: { $0.bundleID == terminal }) { terminal = TerminalApp.systemID }
                }
            }
        }
    }
}

// MARK: 모양

private struct AppearanceSettings: View {
    @State private var theme = AppTheme.shared

    private let columns = [GridItem(.adaptive(minimum: 132), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsTitle(text: "모양")
            SettingsRow(title: "화면 모드") {
                Picker("", selection: $theme.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            SettingsSection(text: "테마")
            Color.clear.frame(height: 8)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(ThemePalette.all) { palette in
                    ThemeSwatch(palette: palette, isSelected: theme.paletteID == palette.id, isDark: isDark) {
                        theme.paletteID = palette.id
                    }
                }
            }
        }
    }

    private var isDark: Bool {
        switch theme.appearance {
        case .dark: true
        case .light: false
        case .system: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }
}

/// 테마 하나의 미리보기. 왼쪽 사이드바 색, 오른쪽 본문, 강조색 점으로 작은 창을 흉내 낸다.
private struct ThemeSwatch: View {
    let palette: ThemePalette
    let isSelected: Bool
    let isDark: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 8) {
                preview
                HStack(spacing: 6) {
                    Text(palette.name)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(palette.tintColor)
                    }
                }
            }
            .padding(8)
            .background(hovering ? Theme.hover : Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Theme.accent : Theme.border, lineWidth: isSelected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var sidebarFill: Color {
        Color(nsColor: NSColor(hex: isDark ? palette.sidebarDark : palette.sidebarLight))
    }

    private var sidebarText: Color {
        let dark: Bool
        switch palette.sidebarScheme {
        case .dark: dark = true
        case .light: dark = false
        default: dark = isDark
        }
        return dark ? Color.white.opacity(0.75) : Color.black.opacity(0.55)
    }

    private var preview: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Circle().fill(palette.tintColor).frame(width: 8, height: 8)
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(sidebarText)
                        .frame(width: index == 1 ? 34 : 24, height: 4)
                }
            }
            .padding(8)
            .frame(width: 50, alignment: .topLeading)
            .frame(maxHeight: .infinity)
            .background(sidebarFill)
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(palette.tintColor).frame(width: 30, height: 4)
                ForEach(0..<3, id: \.self) { _ in
                    Capsule()
                        .fill(isDark ? Color.white.opacity(0.25) : Color.black.opacity(0.12))
                        .frame(width: 48, height: 4)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: NSColor(hex: isDark ? palette.surfaceDark : palette.surfaceLight)))
        }
        .frame(height: 70)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
    }
}

// MARK: Claude

private struct ClaudeSettings: View {
    @State private var account = ClaudeAccount.shared
    @AppStorage("claudeModel") private var model = ""
    @State private var confirmingLogout = false

    private static let models: [(id: String, title: String)] = [
        ("", "CLI 기본값"),
        ("claude-fable-5-1", "Fable 5.1"),
        ("claude-opus-5-5", "Opus 5.5"),
        ("claude-sonnet-5-5", "Sonnet 5.5"),
        ("claude-haiku-5-5", "Haiku 5.5"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsTitle(text: "Claude")
            // 상태 카드. 한눈에 "쓸 수 있는지"가 보여야 한다.
            HStack(spacing: 14) {
                ClaudeMark(size: 34, color: account.isInstalled && account.status?.loggedIn == true ? ClaudeMark.orange : Theme.tertiary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline).font(.system(size: 14, weight: .semibold))
                    Text(subheadline).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(2)
                }
                Spacer()
                if account.isChecking {
                    ProgressView().controlSize(.small)
                } else {
                    Button("다시 확인") { Task { await account.refresh() } }
                        .buttonStyle(PillButtonStyle(compact: true))
                }
            }
            .padding(16)
            .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 12))
            .padding(.vertical, 8)

            if !account.isInstalled {
                SettingsRow(title: "Claude Code 설치") {
                    Button("\(TerminalApp.preferred.name)에서 설치") { account.openInstallInTerminal() }
                        .buttonStyle(PillButtonStyle(prominent: true, compact: true))
                        .help(ClaudeAccount.installCommand)
                }
            }

            // claude가 없으면 아래 항목은 쓸 일이 없어 끈다
            Group {
                loginRow
                SettingsRow(title: "모델") {
                    Picker("", selection: $model) {
                        ForEach(Self.models, id: \.id) { Text($0.title).tag($0.id) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .disabled(!account.isInstalled)
            .opacity(account.isInstalled ? 1 : 0.45)
        }
        .task { if account.checkedAt == nil { await account.refresh() } }
        .confirmationDialog("Claude에서 로그아웃할까요?", isPresented: $confirmingLogout) {
            Button("로그아웃", role: .destructive) { Task { await account.logout() } }
        } message: {
            Text("터미널의 claude 명령도 같이 로그아웃됩니다.")
        }
    }

    @ViewBuilder
    private var loginRow: some View {
        SettingsRow(title: "로그인") {
            if account.status?.loggedIn == true {
                Button("로그아웃…") { confirmingLogout = true }
                    .buttonStyle(PillButtonStyle(compact: true))
                    .disabled(account.isChecking)
            } else {
                // 꺼진 강조색 버튼은 흐리게 하면 글자가 묻혀서, claude가 없으면 보통 버튼으로 그린다
                Button("\(TerminalApp.preferred.name)에서 로그인") { account.openLoginInTerminal() }
                    .buttonStyle(PillButtonStyle(prominent: account.isInstalled, compact: true))
                    .disabled(!account.isInstalled)
            }
        }
    }

    private var headline: String {
        if !account.isInstalled { return "claude CLI가 없습니다" }
        if account.isChecking && account.status == nil { return "확인하는 중…" }
        if account.status?.loggedIn == true { return "쓸 수 있습니다" }
        return "로그인이 필요합니다"
    }

    private var subheadline: String {
        if !account.isInstalled { return "설치하면 커밋 설명, 리뷰, 커밋 메시지 제안을 쓸 수 있습니다." }
        if let status = account.status, status.loggedIn {
            return [status.email, status.method].compactMap { $0 }.joined(separator: "\n")
        }
        if let error = account.lastError { return error }
        return "아래에서 로그인하면 바로 쓸 수 있습니다."
    }
}

// MARK: git

private struct GitSettings: View {
    @Environment(RepositoryStore.self) private var store

    @AppStorage("historyCompact") private var compact = false
    @AppStorage("pullRebase") private var pullRebase = false
    @AppStorage("pullAutostash") private var pullAutostash = true
    @AppStorage("gitFlowFinish") private var gitFlowFinish = true
    @AppStorage("rerere") private var remembersResolutions = false

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 0) {
            SettingsTitle(text: "Git")
            SettingsSection(text: "풀")
            SettingsRow(title: "방식") {
                Picker("", selection: $pullRebase) {
                    Text("머지").tag(false)
                    Text("리베이스").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            SettingsRow(title: "자동 스태시", subtitle: "커밋하지 않은 변경을 잠깐 치워 두고 풀합니다.") {
                SettingsSwitch(isOn: $pullAutostash)
            }
            SettingsRow(title: "충돌 해결 기억", subtitle: "같은 충돌은 전에 푼 대로 채워 둡니다.\n켜면 이 저장소의 터미널 git도 기억을 씁니다.") {
                SettingsSwitch(isOn: $remembersResolutions)
            }
            SettingsSection(text: "히스토리")
            SettingsRow(title: "기본 범위") {
                Picker("", selection: $store.historyScope) {
                    ForEach(RepositoryStore.HistoryScope.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            SettingsRow(title: "구조만 보기", subtitle: "평범한 연속 커밋을 접습니다.") {
                SettingsSwitch(isOn: $compact)
            }
            SettingsSection(text: "Git Flow")
            SettingsRow(title: "마무리 쓰기", subtitle: "끄면 브랜치 시작만 씁니다.") {
                SettingsSwitch(isOn: $gitFlowFinish)
            }
        }
    }
}

// MARK: 보안

private struct SecuritySettings: View {
    @AppStorage("loadsRemoteImages") private var loadsRemoteImages = false
    @State private var gitTrusted = RepositoryTrust.trustedRoots
    @State private var claudeTrusted = ClaudeProjectConfig.trustedRoots

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsTitle(text: "보안")
            SettingsRow(title: "원격 이미지 자동으로 불러오기", subtitle: "끄면 이미지마다 \"불러오기\"를 눌러야 받습니다.") {
                SettingsSwitch(isOn: $loadsRemoteImages)
            }

            // 제목은 저장소를 열 때 묻는 확인 창("이 저장소를 신뢰할까요?")의 말과 맞춘다
            SettingsSection(text: "신뢰한 저장소")
            trustedList(gitTrusted, empty: "없음") { root in
                RepositoryTrust.revoke(root: root)
                gitTrusted = RepositoryTrust.trustedRoots
            }

            SettingsSection(text: "Claude 설정을 신뢰한 저장소")
            trustedList(claudeTrusted, empty: "없음") { root in
                ClaudeProjectConfig.revoke(root: root)
                claudeTrusted = ClaudeProjectConfig.trustedRoots
            }
        }
    }

    @ViewBuilder
    private func trustedList(_ roots: [String], empty: String, revoke: @escaping (String) -> Void) -> some View {
        if roots.isEmpty {
            SettingsRow(title: empty) { EmptyView() }
        } else {
            ForEach(roots, id: \.self) { root in
                SettingsRow(title: (root as NSString).lastPathComponent, subtitle: (root as NSString).abbreviatingWithTildeInPath) {
                    Button("신뢰 해제") { revoke(root) }
                        .buttonStyle(PillButtonStyle(compact: true))
                }
            }
        }
    }
}

// MARK: 정보

private struct AboutSettings: View {
    @State private var updater = AppUpdater.shared

    var body: some View {
        @Bindable var updater = updater
        VStack(alignment: .leading, spacing: 0) {
            SettingsTitle(text: "정보")
            HStack(spacing: 14) {
                AppIconView(size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Canopy").font(.system(size: 15, weight: .semibold))
                    Text("버전 \(AppInfo.version)").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                if let release = updater.availableRelease {
                    Button("Canopy \(release.version) 업데이트…") { updater.showsSheet = true }
                        .buttonStyle(PillButtonStyle(prominent: true, compact: true))
                } else if updater.isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Button("업데이트 확인…") { updater.checkInteractively() }
                        .buttonStyle(PillButtonStyle(compact: true))
                }
            }
            .padding(16)
            .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 12))
            .padding(.vertical, 8)

            SettingsSection(text: "업데이트")
            SettingsRow(title: "새 버전 자동으로 확인", subtitle: "앱을 열 때 GitHub Releases에 새 버전이 있는지 확인하고 알려 줍니다.") {
                SettingsSwitch(isOn: $updater.automaticallyChecks)
            }
            SettingsRow(title: "릴리스 및 소스 코드", subtitle: "github.com/\(AppInfo.githubRepo)") {
                Button("GitHub 열기 ↗") {
                    if let url = URL(string: "https://github.com/\(AppInfo.githubRepo)/releases") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(PillButtonStyle(compact: true))
            }
        }
    }
}
