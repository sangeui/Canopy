import Foundation
import Observation

/// 이 Mac에서 쓸 git을 찾는다.
///
/// `/usr/bin/git`은 명령줄 도구가 없으면 실행하는 순간 macOS 설치 창을 띄운다.
/// 그래서 실행하기 전에 `xcode-select -p`가 가리키는 폴더에 git이 실제로 있는지 보고, 없으면 Homebrew git을 찾는다.
@Observable
final class GitInstallation: @unchecked Sendable {
    static let shared = GitInstallation()

    /// 찾은 git. 없으면 nil
    private(set) var executable: URL?

    var isInstalled: Bool { executable != nil }

    private init() {
        executable = Self.locate()
    }

    /// 다시 찾는다. 설치를 마치고 앱으로 돌아왔을 때 부른다.
    /// `xcode-select`를 실행하고 기다리므로(수십 ms) 메인 스레드가 아닌 곳에서 찾고 결과만 메인에서 넣는다.
    @MainActor
    func recheck() async {
        let found = await Task.detached(priority: .userInitiated) { Self.locate() }.value
        if found != executable { executable = found }
    }

    static func locate() -> URL? {
        #if CANOPY_DEV
        // 화면 확인용: CANOPY_SIMULATE_MISSING=git
        if ProcessInfo.processInfo.environment["CANOPY_SIMULATE_MISSING"]?.contains("git") == true { return nil }
        #endif
        if let developer = developerDirectory(), FileManager.default.isExecutableFile(atPath: developer + "/usr/bin/git") {
            return URL(fileURLWithPath: "/usr/bin/git")
        }
        let brew = ["/opt/homebrew/bin/git", "/usr/local/bin/git"]
        return brew.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// `xcode-select -p`. 명령줄 도구도 Xcode도 없으면 nil. 이 명령은 설치 창을 띄우지 않는다.
    private static func developerDirectory() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// macOS의 명령줄 도구 설치 창을 띄운다. git이 함께 설치된다.
    static func installCommandLineTools() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["--install"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
