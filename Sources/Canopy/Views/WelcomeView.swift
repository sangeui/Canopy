import SwiftUI
import UniformTypeIdentifiers

/// 저장소를 열기 전 첫 화면. 왼쪽은 앱과 동작, 오른쪽은 최근 저장소나 이 Mac에서 찾은 저장소.
struct WelcomeView: View {
    @Environment(RepositoryStore.self) private var store
    @State private var discovered: [String] = []
    @State private var dropTargeted = false

    private var gitInstalled: Bool { GitInstallation.shared.isInstalled }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Spacer()
                AppIconView(size: 96)
                    .padding(.bottom, 14)
                Text(AppInfo.name)
                    .font(.system(size: 30, weight: .bold))
                Text("버전 \(AppInfo.version)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .padding(.top, 2)
                Text("브랜치와 워크트리를 한눈에 보는 git 클라이언트")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                    .padding(.top, 10)
                Spacer()
                VStack(alignment: .leading, spacing: 8) {
                    WelcomeAction(symbol: "folder", title: "저장소 열기…", detail: "이 Mac의 git 폴더를 엽니다", shortcut: "⌘O", prominent: gitInstalled) {
                        store.openRepositoryPanel()
                    }
                    WelcomeAction(symbol: "square.and.arrow.down", title: "저장소 클론…", detail: "주소로 받아 와서 엽니다", shortcut: "⇧⌘N", prominent: false) {
                        store.sheet = .clone
                    }
                }
                // git이 없으면 열기·클론을 할 수 없다. 강조색 버튼을 흐리게 하면 글자가 묻혀서 둘 다 보통 버튼으로 그린다.
                .disabled(!gitInstalled)
                .opacity(gitInstalled ? 1 : 0.5)
                Spacer().frame(height: 30)
            }
            .padding(.horizontal, 36)
            .frame(width: 360)
            .frame(maxHeight: .infinity)
            .background(Theme.sidebar)

            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: 28)
                if AppUpdater.shared.bannerRelease != nil {
                    UpdateNoticeBanner()
                        .padding(.horizontal, 28)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                }
                if !gitInstalled {
                    GitSetupPanel()
                } else if !store.recentRepositoryPaths.isEmpty {
                    sectionTitle("최근 저장소", detail: "\(store.recentRepositoryPaths.count)개")
                    repositoryList(store.recentRepositoryPaths)
                } else if !discovered.isEmpty {
                    sectionTitle("이 Mac에서 찾은 저장소", detail: "홈 아래 자주 쓰는 폴더를 한 단계만 살펴봤습니다")
                    repositoryList(discovered)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "folder.badge.questionmark")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(Theme.tertiary)
                        Text("아직 연 저장소가 없습니다")
                            .font(.system(size: 15, weight: .semibold))
                        Text("왼쪽에서 열거나, 폴더를 이 창에 끌어다 놓으세요.")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.surface)
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Theme.green, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                        .padding(14)
                        .overlay(Text("놓으면 엽니다").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.green))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: URL.self) { urls, _ in
            guard gitInstalled, let url = urls.first else { return false }
            Task { await store.open(url) }
            return true
        } isTargeted: { dropTargeted = $0 }
        .task {
            store.importLegacyRecents()
            if store.recentRepositoryPaths.isEmpty {
                discovered = await RepositoryFinder.discover()
            }
        }
    }

    private func sectionTitle(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private func repositoryList(_ paths: [String]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(paths, id: \.self) { path in
                    RecentRow(path: path) {
                        Task { await store.open(path: path) }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }
}

/// git이 없을 때 첫 화면 오른쪽. 설치 방법을 고르고, 설치를 마치면 다시 확인한다.
private struct GitSetupPanel: View {
    private static let brewCommand = "brew install git"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "terminal")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.tertiary)
                .padding(.bottom, 12)
            Text("git이 필요합니다")
                .font(.system(size: 20, weight: .bold))
            Text("Canopy는 이 Mac에 설치된 git으로 저장소를 읽고 씁니다.\n지금은 git을 찾지 못했습니다.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 10) {
                option(
                    title: "명령줄 도구 설치",
                    detail: "Apple이 제공하는 개발 도구이고, git이 함께 설치됩니다.\n누르면 macOS 설치 창이 뜹니다."
                ) {
                    Button("명령줄 도구 설치") { GitInstallation.installCommandLineTools() }
                        .buttonStyle(PillButtonStyle(prominent: true, compact: true))
                }
                option(
                    title: "Homebrew를 쓴다면",
                    detail: "터미널에서 이 명령으로 설치해도 됩니다."
                ) {
                    HStack(spacing: 6) {
                        Text(Self.brewCommand)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(Self.brewCommand, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(IconButtonStyle(size: 24))
                        .help("복사")
                    }
                }
            }
            .padding(.top, 22)

            HStack(spacing: 10) {
                Button("다시 확인") { Task { await GitInstallation.shared.recheck() } }
                    .buttonStyle(PillButtonStyle(compact: true))
                Text("설치를 마치고 이 창으로 돌아오면 자동으로 다시 확인합니다.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 18)
        }
        .frame(maxWidth: 460, alignment: .leading)
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func option<Trailing: View>(title: String, detail: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            trailing()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct WelcomeAction: View {
    let symbol: String
    let title: String
    let detail: String
    let shortcut: String
    let prominent: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 11)).foregroundStyle(prominent ? Theme.onAccent.opacity(0.75) : Theme.secondary)
                }
                Spacer()
                Text(shortcut)
                    .font(.system(size: 11))
                    .foregroundStyle(prominent ? Theme.onAccent.opacity(0.6) : Theme.tertiary)
            }
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .foregroundStyle(prominent ? Theme.onAccent : Theme.text)
            .background(prominent ? Theme.accent : (hovering ? Theme.hover : Theme.surface), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(prominent ? Color.clear : Theme.border, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct RecentRow: View {
    let path: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text((path as NSString).lastPathComponent)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text((path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if hovering {
                    Text("열기")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(hovering ? Theme.hover : Color.clear, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .contentShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 홈 아래 자주 쓰는 폴더에서 git 저장소를 한 단계만 찾는다.
enum RepositoryFinder {
    static func discover() async -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = ["Github", "GitHub", "github", "Developer", "Projects", "projects", "code", "Code", "src", "Documents", "Desktop", "workspace"]
            .map { home.appendingPathComponent($0) }
        return await Task.detached(priority: .utility) {
            var found: [String] = []
            for root in roots {
                guard let children = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
                for child in children.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                    if FileManager.default.fileExists(atPath: child.appendingPathComponent(".git").path) {
                        found.append(child.path)
                    }
                    if found.count >= 30 { return found }
                }
            }
            return found
        }.value
    }
}
