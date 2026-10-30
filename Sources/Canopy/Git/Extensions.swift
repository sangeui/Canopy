import Foundation

/// 앱 이름. 창 제목, 시작 화면, 번들에 같이 쓴다.
enum AppInfo {
    static let name = "Canopy"
    static let bundleIdentifier = "dev.sangeui.canopy"
    static let githubRepo = "sangeui/Canopy"
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "개발 빌드"
    }

    /// `remote`("v0.3.0" 또는 "0.3.0")가 `current`("0.2.0")보다 새 버전인지 숫자 단위로 비교한다.
    static func isNewer(remote: String, than current: String) -> Bool {
        guard let remoteParts = parseVersion(remote), let currentParts = parseVersion(current) else { return false }
        let count = max(remoteParts.count, currentParts.count)
        for index in 0..<count {
            let r = index < remoteParts.count ? remoteParts[index] : 0
            let c = index < currentParts.count ? currentParts[index] : 0
            if r != c { return r > c }
        }
        return false
    }

    static func cleanVersion(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("v") { text.removeFirst() }
        return text
    }

    private static func parseVersion(_ raw: String) -> [Int]? {
        let cleaned = cleanVersion(raw).split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
        guard !cleaned.isEmpty else { return nil }
        let parts = cleaned.split(separator: ".")
        var numbers: [Int] = []
        for part in parts {
            guard let value = Int(part) else { return nil }
            numbers.append(value)
        }
        return numbers.isEmpty ? nil : numbers
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    /// 비었으면 nil
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension Substring {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// 심볼릭 링크를 푼 절대 경로. git이 돌려주는 경로와 같은 모양으로 맞출 때 쓴다.
func canonicalPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}


/// 느린 곳을 찾을 때 쓰는 시간 기록. `CANOPY_TIMING=<파일 경로>`로 띄우면 그 파일에 붙여 쓴다.
enum Timing {
    static let path = ProcessInfo.processInfo.environment["CANOPY_TIMING"]

    static func log(_ text: String) {
        guard let path else { return }
        let line = "\(Date().timeIntervalSince1970) \(text)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
        }
    }
}
