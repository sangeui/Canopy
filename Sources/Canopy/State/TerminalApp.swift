import AppKit

/// "터미널에서 열기"에 쓰는 앱. 설정 › 일반에서 고른다.
/// macOS에는 기본 터미널 설정이 따로 없고, 최근 사용 기록이나 사용 횟수로는 주로 쓰는 앱을 맞히지 못해서 사용자가 고르게 한다.
struct TerminalApp: Identifiable, Hashable {
    let bundleID: String
    let name: String
    let url: URL

    var id: String { bundleID }

    static let defaultsKey = "terminalApp"
    static let systemID = "com.apple.Terminal"

    /// 후보. 설치돼 있고 Info.plist에 폴더를 연다고 적은 앱만 보여 준다.
    private static let candidates = [
        systemID,
        "com.mitchellh.ghostty",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.github.wez.wezterm",
        "net.kovidgoyal.kitty",
        "org.alacritty",
    ]

    static var installed: [TerminalApp] {
        candidates.compactMap { id in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id), opensFolders(url) else { return nil }
            // macOS 터미널은 시스템 언어에 따라 "Terminal"로 나올 수 있어 이름을 정해 둔다
            let name = id == systemID ? "터미널" : FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            return TerminalApp(bundleID: id, name: name, url: url)
        }
    }

    /// 고른 앱. 고른 적이 없거나 지워졌으면 macOS 터미널.
    static var preferred: TerminalApp {
        let all = installed
        let id = UserDefaults.standard.string(forKey: defaultsKey) ?? systemID
        return all.first { $0.bundleID == id } ?? all.first { $0.bundleID == systemID }
            ?? TerminalApp(bundleID: systemID, name: "터미널", url: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
    }

    var icon: NSImage {
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    func open(folder path: String) {
        NSWorkspace.shared.open([URL(fileURLWithPath: path, isDirectory: true)], withApplicationAt: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// 실행 권한이 있는 스크립트 파일을 이 앱으로 열어 실행한다
    func run(script file: URL) {
        NSWorkspace.shared.open([file], withApplicationAt: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// 셸 명령 한 줄을 이 터미널의 새 창에서 돌린다.
    /// macOS 터미널은 AppleScript로 새 창에 명령을 넣고, 다른 앱은 `.command` 파일을 열어 실행하게 한다.
    func runCommand(_ command: String) {
        if bundleID == Self.systemID {
            let quoted = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let script = "tell application \"Terminal\"\nactivate\ndo script \"\(quoted)\"\nend tell"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            // 자동화 권한을 거부했으면 AppleScript가 실패한다. 그때는 권한이 필요 없는 .command 파일 열기로 한다.
            process.terminationHandler = { finished in
                guard finished.terminationStatus != 0 else { return }
                DispatchQueue.main.async { self.openCommandFile(command) }
            }
            if (try? process.run()) == nil { openCommandFile(command) }
            return
        }
        openCommandFile(command)
    }

    private func openCommandFile(_ command: String) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("canopy-\(UUID().uuidString.prefix(8)).command")
        let body = "#!/bin/zsh -l\n\(command)\n"
        guard (try? body.write(to: file, atomically: true, encoding: .utf8)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        run(script: file)
    }

    /// 앱이 폴더를 문서로 받는다고 적었는지. `public.folder` 또는 `public.directory`
    private static func opensFolders(_ url: URL) -> Bool {
        guard let types = Bundle(url: url)?.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]] else { return false }
        return types.contains { type in
            let utis = type["LSItemContentTypes"] as? [String] ?? []
            return utis.contains("public.folder") || utis.contains("public.directory")
        }
    }
}
