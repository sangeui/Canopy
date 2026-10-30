import AppKit
import CryptoKit
import Foundation
import Observation
import SwiftUI

/// GitHub Releases의 배포판 정보.
struct ReleaseInfo: Equatable, Sendable {
    let version: String
    let tagName: String
    let title: String
    let notes: String
    let publishedAt: Date?
    let htmlURL: URL
    let dmgURL: URL?
    let zipURL: URL?
    let sha256URL: URL?
    let tarballURL: URL?

    /// 배너에 한 줄로 보여 줄 요약. 마크다운 머리말과 빈 줄을 건너뛰고 첫 본문 줄을 고른다.
    var summaryLine: String {
        for raw in notes.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(">"), !line.hasPrefix("```"), !line.hasPrefix("---") else { continue }
            for prefix in ["- ", "* ", "+ ", "1. ", "2. "] where line.hasPrefix(prefix) {
                line = String(line.dropFirst(prefix.count))
            }
            line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            if !line.isEmpty { return line }
        }
        return "릴리스 노트를 확인하고 한 번에 새 버전으로 업데이트할 수 있습니다."
    }

    static func parse(json data: Data) -> ReleaseInfo? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["draft"] as? Bool != true,
              object["prerelease"] as? Bool != true,
              let tagName = object["tag_name"] as? String,
              let htmlString = object["html_url"] as? String,
              let htmlURL = URL(string: htmlString) else { return nil }

        let version = AppInfo.cleanVersion(tagName)
        let title = (object["name"] as? String)?.trimmed.nilIfEmpty ?? "Canopy \(version)"
        let body = (object["body"] as? String)?.trimmed ?? ""
        let publishedAt: Date? = {
            guard let dateString = object["published_at"] as? String else { return nil }
            let formatter = ISO8601DateFormatter()
            return formatter.date(from: dateString)
        }()

        var dmgURL: URL?
        var zipURL: URL?
        var sha256URL: URL?
        if let assets = object["assets"] as? [[String: Any]] {
            for asset in assets {
                guard let name = asset["name"] as? String,
                      let urlString = asset["browser_download_url"] as? String,
                      let url = URL(string: urlString) else { continue }
                if name.hasSuffix(".dmg") {
                    dmgURL = url
                } else if name.hasSuffix(".zip") {
                    zipURL = url
                } else if name.hasSuffix(".dmg.sha256") || name.hasSuffix(".sha256") {
                    sha256URL = url
                }
            }
        }
        let tarballURL = (object["tarball_url"] as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://github.com/\(AppInfo.githubRepo)/archive/refs/tags/\(tagName).tar.gz")
        return ReleaseInfo(
            version: version,
            tagName: tagName,
            title: title,
            notes: body,
            publishedAt: publishedAt,
            htmlURL: htmlURL,
            dmgURL: dmgURL,
            zipURL: zipURL,
            sha256URL: sha256URL,
            tarballURL: tarballURL
        )
    }
}

/// GitHub Releases를 확인해 새 버전을 알리고, DMG(또는 릴리스 아카이브)를 받아 검증한 뒤 앱을 즉시 교체·재실행한다.
@Observable
@MainActor
final class AppUpdater {
    static let shared = AppUpdater()

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(ReleaseInfo)
        case downloading(ReleaseInfo)
        case building(ReleaseInfo)
        case installing(ReleaseInfo)
        case failed(String)
    }

    private static let autoCheckKey = "automaticallyChecksForUpdates"
    private static let skippedVersionKey = "skippedUpdateVersion"
    private static let lastCheckKey = "lastUpdateCheckTimestamp"
    /// 자동 확인 최소 간격 (4시간). GitHub API 속도 제한을 아끼고 매번 네트워크를 부르지 않게 한다.
    private static let autoCheckInterval: TimeInterval = 4 * 3600

    private(set) var phase: Phase = .idle
    private(set) var availableRelease: ReleaseInfo?
    private(set) var lastCheckedAt: Date?
    /// 릴리스 노트와 업데이트 시트를 띄울지
    var showsSheet = false
    /// 이번 실행에서 배너의 "나중에"를 눌러 숨겼는지
    private var dismissedInSession = false

    var automaticallyChecks: Bool {
        get {
            if UserDefaults.standard.object(forKey: Self.autoCheckKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: Self.autoCheckKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.autoCheckKey)
        }
    }

    var skippedVersion: String? {
        get { UserDefaults.standard.string(forKey: Self.skippedVersionKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.skippedVersionKey) }
    }

    /// 상단 배너를 띄울 새 버전이 있는지
    var bannerRelease: ReleaseInfo? {
        guard let release = availableRelease, !dismissedInSession, skippedVersion != release.version else { return nil }
        return release
    }

    var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .building, .installing: true
        default: false
        }
    }

    private init() {
        let timestamp = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        if timestamp > 0 { lastCheckedAt = Date(timeIntervalSince1970: timestamp) }
    }

    /// 앱을 켰을 때 부른다. 자동 확인이 켜져 있고 마지막 확인 뒤 4시간이 지났을 때만 조용히 확인한다.
    func checkOnLaunch() {
        #if CANOPY_DEV
        if let simulated = ProcessInfo.processInfo.environment["CANOPY_SIMULATE_UPDATE"], !simulated.isEmpty {
            simulateRelease(version: simulated)
            return
        }
        #endif
        guard automaticallyChecks else { return }
        if let last = lastCheckedAt, Date().timeIntervalSince(last) < Self.autoCheckInterval { return }
        Task { await checkForUpdates(userInitiated: false) }
    }

    /// 메뉴나 설정에서 "업데이트 확인…"을 눌렀을 때
    func checkInteractively() {
        showsSheet = true
        Task { await checkForUpdates(userInitiated: true) }
    }

    func dismissBannerForSession() {
        dismissedInSession = true
    }

    func skipCurrentRelease() {
        if let version = availableRelease?.version {
            skippedVersion = version
        }
        showsSheet = false
    }

    func checkForUpdates(userInitiated: Bool) async {
        guard !isBusy else { return }
        phase = .checking
        let urlString = "https://api.github.com/repos/\(AppInfo.githubRepo)/releases/latest"
        guard let url = URL(string: urlString) else {
            phase = .failed("업데이트 확인 주소가 올바르지 않습니다.")
            return
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Canopy/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw UpdateError("서버 응답을 읽지 못했습니다.")
            }
            if http.statusCode == 404 {
                recordCheckTime()
                phase = .upToDate
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                throw UpdateError("GitHub 서버가 상태 코드 \(http.statusCode)을(를) 돌려줬습니다.")
            }
            guard let release = ReleaseInfo.parse(json: data) else {
                throw UpdateError("릴리스 정보를 해석하지 못했습니다.")
            }
            recordCheckTime()
            // `swift run` 개발 빌드는 현재 버전 숫자가 없으므로 0.0.0으로 비교하지 않고 최신 버전과 같다고 본다(수동 확인 시 안내)
            let currentVersion = AppInfo.version
            if AppInfo.isNewer(remote: release.version, than: currentVersion) {
                availableRelease = release
                dismissedInSession = false
                phase = .available(release)
            } else {
                availableRelease = nil
                phase = .upToDate
            }
        } catch {
            if userInitiated {
                phase = .failed((error as? UpdateError)?.message ?? "네트워크 연결을 확인한 뒤 다시 시도하세요.")
            } else {
                phase = .idle
            }
        }
    }

    private func recordCheckTime() {
        let now = Date()
        lastCheckedAt = now
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Self.lastCheckKey)
    }

    /// 새 버전의 DMG(또는 릴리스 소스 아카이브)를 받아 무결성을 검증하고, 지금 앱을 즉시 덮어쓴 뒤 다시 실행한다.
    func installUpdate() async {
        guard var release = availableRelease else { return }
        phase = .downloading(release)
        do {
            // 릴리스 직후 GitHub Actions가 DMG 업로드를 마쳤을 수 있으므로 에셋이 비어 있으면 한 번 더 최신 태그 정보를 조회한다
            if release.dmgURL == nil, release.zipURL == nil,
               let tagAPI = URL(string: "https://api.github.com/repos/\(AppInfo.githubRepo)/releases/tags/\(release.tagName)") {
                var req = URLRequest(url: tagAPI)
                req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                req.setValue("Canopy/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
                req.timeoutInterval = 10
                if let (data, resp) = try? await URLSession.shared.data(for: req),
                   (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
                   let refreshed = ReleaseInfo.parse(json: data) {
                    release = refreshed
                    availableRelease = refreshed
                }
            }

            let stage = FileManager.default.temporaryDirectory.appendingPathComponent("canopy-update-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: stage) }

            let candidateDmgURL = release.dmgURL
                ?? URL(string: "https://github.com/\(AppInfo.githubRepo)/releases/download/\(release.tagName)/Canopy-\(release.version).dmg")
            let candidateShaURL = release.sha256URL
                ?? URL(string: "https://github.com/\(AppInfo.githubRepo)/releases/download/\(release.tagName)/Canopy-\(release.version).dmg.sha256")

            // 1순위: 릴리스에 첨부된 DMG 파일로 즉시 설치
            if let dmgURL = candidateDmgURL,
               let (downloadedURL, response) = try? await URLSession.shared.download(from: dmgURL),
               let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                let dmgFile = stage.appendingPathComponent("Canopy-\(release.version).dmg")
                try FileManager.default.moveItem(at: downloadedURL, to: dmgFile)

                if let shaURL = candidateShaURL,
                   let (shaData, shaResp) = try? await URLSession.shared.data(from: shaURL),
                   (shaResp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
                   let expected = String(data: shaData, encoding: .utf8)?.split(whereSeparator: { $0.isWhitespace }).first?.lowercased(),
                   expected.count == 64 {
                    let fileData = try Data(contentsOf: dmgFile)
                    let digest = SHA256.hash(data: fileData).map { String(format: "%02x", $0) }.joined()
                    guard digest == expected else {
                        throw UpdateError("다운로드한 파일의 체크섬(SHA-256)이 일치하지 않습니다.")
                    }
                }

                phase = .installing(release)
                try await Task.detached(priority: .userInitiated) {
                    try Self.mountAndReplaceApp(dmgFile: dmgFile, stage: stage)
                }.value
                return
            }

            // 2순위: 릴리스에 첨부된 ZIP 번들로 즉시 설치
            if let zipURL = release.zipURL,
               let (downloadedURL, response) = try? await URLSession.shared.download(from: zipURL),
               let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                let zipFile = stage.appendingPathComponent("Canopy-\(release.version).zip")
                try FileManager.default.moveItem(at: downloadedURL, to: zipFile)
                phase = .installing(release)
                try await Task.detached(priority: .userInitiated) {
                    try Self.unzipAndReplaceApp(zipFile: zipFile, stage: stage)
                }.value
                return
            }

            // 3순위: 릴리스에 아직 DMG 에셋이 없으면 릴리스 소스 아카이브를 받아 그 자리에서 빌드·설치 후 재실행
            guard let tarballURL = release.tarballURL
                ?? URL(string: "https://github.com/\(AppInfo.githubRepo)/archive/refs/tags/\(release.tagName).tar.gz") else {
                throw UpdateError("설치 파일을 찾을 수 없습니다.")
            }
            var tarRequest = URLRequest(url: tarballURL)
            tarRequest.setValue("Canopy/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
            let (downloadedTar, tarResp) = try await URLSession.shared.download(for: tarRequest)
            guard let http = tarResp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw UpdateError("릴리스 아카이브를 받지 못했습니다.")
            }
            let tarFile = stage.appendingPathComponent("source.tar.gz")
            try FileManager.default.moveItem(at: downloadedTar, to: tarFile)

            phase = .building(release)
            let version = release.version
            try await Task.detached(priority: .userInitiated) {
                try Self.buildFromSourceAndReplaceApp(tarFile: tarFile, version: version, stage: stage)
            }.value
        } catch {
            phase = .failed((error as? UpdateError)?.message ?? error.localizedDescription)
        }
    }

    nonisolated private static func mountAndReplaceApp(dmgFile: URL, stage: URL) throws {
        let mountPoint = stage.appendingPathComponent("mnt", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        let attach = Process()
        attach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        attach.arguments = ["attach", dmgFile.path, "-readonly", "-nobrowse", "-noverify", "-noautoopen", "-mountpoint", mountPoint.path]
        attach.standardOutput = FileHandle.nullDevice
        attach.standardError = FileHandle.nullDevice
        try attach.run()
        attach.waitUntilExit()
        guard attach.terminationStatus == 0 else {
            throw UpdateError("디스크 이미지를 열지 못했습니다.")
        }
        defer {
            let detach = Process()
            detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            detach.arguments = ["detach", mountPoint.path, "-quiet", "-force"]
            try? detach.run()
            detach.waitUntilExit()
        }

        let sourceApp = mountPoint.appendingPathComponent("Canopy.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: sourceApp.path) else {
            throw UpdateError("디스크 이미지 안에 Canopy.app이 없습니다.")
        }
        try verifyAndInstallApp(sourceApp: sourceApp)
    }

    nonisolated private static func unzipAndReplaceApp(zipFile: URL, stage: URL) throws {
        let unpackDir = stage.appendingPathComponent("unzip", isDirectory: true)
        try FileManager.default.createDirectory(at: unpackDir, withIntermediateDirectories: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zipFile.path, unpackDir.path]
        ditto.standardOutput = FileHandle.nullDevice
        ditto.standardError = FileHandle.nullDevice
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            throw UpdateError("압축 파일을 풀지 못했습니다.")
        }
        let sourceApp = unpackDir.appendingPathComponent("Canopy.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: sourceApp.path) else {
            throw UpdateError("압축 파일 안에 Canopy.app이 없습니다.")
        }
        try verifyAndInstallApp(sourceApp: sourceApp)
    }

    nonisolated private static func buildFromSourceAndReplaceApp(tarFile: URL, version: String, stage: URL) throws {
        let srcRoot = stage.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: srcRoot, withIntermediateDirectories: true)

        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", tarFile.path, "-C", srcRoot.path, "--strip-components=1"]
        tar.standardOutput = FileHandle.nullDevice
        tar.standardError = FileHandle.nullDevice
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else {
            throw UpdateError("릴리스 소스 압축을 풀지 못했습니다.")
        }

        let makeApp = srcRoot.appendingPathComponent("make-app.sh")
        guard FileManager.default.fileExists(atPath: makeApp.path) else {
            throw UpdateError("릴리스 안에서 빌드 스크립트(make-app.sh)를 찾지 못했습니다.")
        }

        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/bin/zsh")
        build.currentDirectoryURL = srcRoot
        build.arguments = [makeApp.path, "--version", version]
        build.standardOutput = FileHandle.nullDevice
        build.standardError = FileHandle.nullDevice
        try build.run()
        build.waitUntilExit()
        guard build.terminationStatus == 0 else {
            throw UpdateError("새 버전 빌드에 실패했습니다. Xcode Command Line Tools가 설치돼 있는지 확인하세요.")
        }

        let builtApp = srcRoot.appendingPathComponent("build/Canopy.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: builtApp.path) else {
            throw UpdateError("빌드된 Canopy.app을 찾지 못했습니다.")
        }
        try verifyAndInstallApp(sourceApp: builtApp)
    }

    nonisolated private static func verifyAndInstallApp(sourceApp: URL) throws {
        // 코드 서명 무결성 확인
        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verify.arguments = ["--verify", "--strict", sourceApp.path]
        verify.standardOutput = FileHandle.nullDevice
        verify.standardError = FileHandle.nullDevice
        try verify.run()
        verify.waitUntilExit()
        guard verify.terminationStatus == 0 else {
            throw UpdateError("새 버전 앱의 서명 검증에 실패했습니다.")
        }

        // 지금 실행 중인 위치가 .app 번들이고 쓸 수 있으면 그 자리를, 아니면 /Applications 또는 ~/Applications를 쓴다
        let currentBundle = Bundle.main.bundleURL
        let targetApp: URL
        if currentBundle.pathExtension == "app",
           FileManager.default.isWritableFile(atPath: currentBundle.deletingLastPathComponent().path) {
            targetApp = currentBundle
        } else if FileManager.default.isWritableFile(atPath: "/Applications") {
            targetApp = URL(fileURLWithPath: "/Applications/Canopy.app")
        } else {
            let userApps = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
            try FileManager.default.createDirectory(at: userApps, withIntermediateDirectories: true)
            targetApp = userApps.appendingPathComponent("Canopy.app")
        }

        if FileManager.default.fileExists(atPath: targetApp.path) {
            try FileManager.default.removeItem(at: targetApp)
        }
        try FileManager.default.copyItem(at: sourceApp, to: targetApp)

        // 미공증 빌드여도 업데이트 뒤 Gatekeeper에 막히지 않게 격리 속성을 지운다
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-cr", targetApp.path]
        xattr.standardOutput = FileHandle.nullDevice
        xattr.standardError = FileHandle.nullDevice
        try? xattr.run()
        xattr.waitUntilExit()

        // 현재 프로세스가 끝난 뒤 새 앱을 열도록 백그라운드 셸을 띄우고 종료한다
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/zsh")
        let escaped = targetApp.path.replacingOccurrences(of: "'", with: "'\\''")
        relaunch.arguments = ["-c", "sleep 0.6 && open -a '\(escaped)'"]
        try? relaunch.run()

        DispatchQueue.main.async {
            NSApplication.shared.terminate(nil)
        }
    }

    #if CANOPY_DEV
    func simulateRelease(version: String) {
        let sampleNotes = """
        ### 주요 기능 및 추가
        - 앱 실행 시 새 버전을 자동으로 감지하고 한 번에 설치하는 인앱 업데이트 추가
        - 터미널 한 줄 명령(`curl | zsh`)으로 바로 설치하는 스크립트 제공

        ### 개선 및 사용성
        - DMG 디스크 이미지를 APFS 포맷으로 전환하여 마운트 호환성 개선
        - 리소스 번들 경량화로 앱 용량 3.8MB 절감
        """
        let clean = AppInfo.cleanVersion(version)
        let release = ReleaseInfo(
            version: clean,
            tagName: "v" + clean,
            title: "Canopy \(clean)",
            notes: sampleNotes,
            publishedAt: Date(),
            htmlURL: URL(string: "https://github.com/\(AppInfo.githubRepo)/releases")!,
            dmgURL: URL(string: "https://github.com/\(AppInfo.githubRepo)/releases/download/v\(clean)/Canopy-\(clean).dmg"),
            zipURL: nil,
            sha256URL: nil,
            tarballURL: URL(string: "https://github.com/\(AppInfo.githubRepo)/archive/refs/tags/v\(clean).tar.gz")
        )
        availableRelease = release
        dismissedInSession = false
        skippedVersion = nil
        phase = .available(release)
    }
    #endif
}

private struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: 화면 조각 (배너 및 릴리스 노트 모달)

/// 새 버전이 있을 때 상단에 뜨는 배너.
struct UpdateNoticeBanner: View {
    @State private var updater = AppUpdater.shared

    var body: some View {
        if let release = updater.bannerRelease {
            NoticeBanner(
                symbol: "arrow.down.circle.fill",
                tint: Theme.green,
                title: "새로운 버전 Canopy \(release.version) 업데이트가 있습니다",
                message: release.summaryLine
            ) {
                Button("나중에") { updater.dismissBannerForSession() }
                    .buttonStyle(PillButtonStyle(compact: true))
                Button("릴리스 노트…") { updater.showsSheet = true }
                    .buttonStyle(PillButtonStyle(compact: true))
                Button("지금 업데이트") {
                    updater.showsSheet = true
                    Task { await updater.installUpdate() }
                }
                .buttonStyle(PillButtonStyle(prominent: true, compact: true))
            }
        }
    }
}

/// 업데이트 확인 및 릴리스 노트 모달.
struct UpdateOverlay: View {
    @State private var updater = AppUpdater.shared

    var body: some View {
        ZStack {
            Color.black.opacity(0.24)
                .ignoresSafeArea()
                .onTapGesture {
                    if !updater.isBusy { updater.showsSheet = false }
                }
            VStack(alignment: .leading, spacing: 0) {
                header
                HairlineDivider()
                content
                HairlineDivider()
                footer
            }
            .frame(width: 560)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 30, y: 10)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            AppIconView(size: 40)
            VStack(alignment: .leading, spacing: 2) {
                if let release = updater.availableRelease {
                    Text("Canopy \(release.version) 업데이트")
                        .font(.system(size: 16, weight: .semibold))
                    Text("현재 버전 \(AppInfo.version)" + (release.publishedAt.map { " · " + $0.formatted(date: .abbreviated, time: .omitted) + " 배포" } ?? ""))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                } else {
                    Text("소프트웨어 업데이트")
                        .font(.system(size: 16, weight: .semibold))
                    Text("현재 버전 \(AppInfo.version)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                }
            }
            Spacer()
            Button { updater.showsSheet = false } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(IconButtonStyle(size: 26))
            .keyboardShortcut(.cancelAction)
            .disabled(updater.isBusy)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var content: some View {
        switch updater.phase {
        case .checking:
            statusBox(progress: true, title: "새 버전을 확인하는 중…", subtitle: "GitHub Releases에서 최신 배포 정보를 가져오고 있습니다.")
        case .downloading(let release):
            statusBox(progress: true, title: "Canopy \(release.version) 다운로드 중…", subtitle: "새 버전 설치 파일을 받고 무결성을 검증합니다.")
        case .building(let release):
            statusBox(progress: true, title: "Canopy \(release.version) 빌드 및 설치 준비 중…", subtitle: "릴리스 소스를 이 Mac에 맞게 빌드한 뒤 자동으로 교체합니다.")
        case .installing(let release):
            statusBox(progress: true, title: "Canopy \(release.version) 설치 중…", subtitle: "앱을 교체하고 완료되면 자동으로 다시 실행합니다.")
        case .upToDate, .idle:
            if let release = updater.availableRelease {
                releaseNotesView(release)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(Theme.green)
                    Text("최신 버전을 쓰고 있습니다")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Canopy \(AppInfo.version)이(가) 현재 설치된 가장 최신 버전입니다.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 44)
            }
        case .available(let release):
            releaseNotesView(release)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("업데이트를 완료하지 못했습니다")
                            .font(.system(size: 14, weight: .semibold))
                        Text(message)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let release = updater.availableRelease {
                    HairlineDivider().padding(.vertical, 4)
                    releaseNotesScroll(release)
                }
            }
            .padding(20)
        }
    }

    private func statusBox(progress: Bool, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            if progress {
                ProgressView().controlSize(.regular)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 36)
    }

    private func releaseNotesView(_ release: ReleaseInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("릴리스 노트")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                Spacer()
                Button("GitHub에서 보기 ↗") {
                    NSWorkspace.shared.open(release.htmlURL)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
            }
            releaseNotesScroll(release)
        }
        .padding(20)
    }

    private func releaseNotesScroll(_ release: ReleaseInfo) -> some View {
        ScrollView {
            MarkdownView(source: release.notes.isEmpty ? "릴리스 노트가 없습니다." : release.notes, baseSize: 12.5)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 180, maxHeight: 320)
        .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if updater.availableRelease != nil {
                Button("이 버전 건너뛰기") { updater.skipCurrentRelease() }
                    .buttonStyle(PillButtonStyle())
                    .disabled(updater.isBusy)
            }
            Spacer()
            if updater.availableRelease != nil {
                Button("나중에") {
                    updater.dismissBannerForSession()
                    updater.showsSheet = false
                }
                .buttonStyle(PillButtonStyle())
                .disabled(updater.isBusy)

                Button("지금 업데이트 및 다시 실행") {
                    Task { await updater.installUpdate() }
                }
                .buttonStyle(PillButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(updater.isBusy)
            } else {
                if case .failed = updater.phase {
                    Button("다시 확인") {
                        Task { await updater.checkForUpdates(userInitiated: true) }
                    }
                    .buttonStyle(PillButtonStyle())
                }
                Button("확인") { updater.showsSheet = false }
                    .buttonStyle(PillButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(updater.isBusy)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}
