import Foundation

/// 저장소 설정 중 git이 명령을 실행하게 하는 것. 이런 저장소는 처음 열 때 신뢰할지 묻는다.
///
/// 압축 파일로 받았거나 남이 준 저장소의 `.git/config`에는 머지 드라이버, 필터, 훅 같은 실행 명령이 들어 있을 수 있다.
/// Canopy는 열자마자 상태를 읽고 충돌을 미리 계산하므로, 묻지 않으면 사용자가 아무것도 누르지 않아도 그 명령이 돈다.
/// `core.fsmonitor`, `diff.external`, `textconv`는 모든 호출에서 끄고 있어서 묻지 않는다.
enum RepositoryTrust {
    /// 실행 명령이 되는 설정과 훅. 사람이 읽을 수 있게 "merge.evil.driver = …"처럼 적는다.
    static func executableSettings(in repo: GitRepository) async -> [String] {
        var found: [String] = []
        let config = (try? await repo.run(["config", "--local", "--includes", "--list"]).stdout) ?? ""
        for line in config.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].lowercased()
            let value = String(line[line.index(after: equals)...])
            if isExecutable(key: key, value: value) {
                found.append("\(line[..<equals]) = \(value)")
            }
        }
        found += await hooks(in: repo).map { "훅 " + $0 }
        return found
    }

    static func isExecutable(key: String, value: String) -> Bool {
        let simple: Set<String> = ["core.hookspath", "core.sshcommand", "core.gitproxy", "core.askpass", "gpg.program"]
        if simple.contains(key) { return true }
        if key.hasPrefix("gpg."), key.hasSuffix(".program") { return true }
        if key.hasPrefix("filter."), key.hasSuffix(".clean") || key.hasSuffix(".smudge") || key.hasSuffix(".process") { return true }
        if key.hasPrefix("merge."), key.hasSuffix(".driver") { return true }
        // 내장 도우미(osxkeychain, store)는 괜찮다. "!명령"이나 경로만 본다.
        if key == "credential.helper" || (key.hasPrefix("credential.") && key.hasSuffix(".helper")) {
            return value.hasPrefix("!") || value.contains("/")
        }
        // ext:: 주소는 페치·푸시 때 임의의 명령을 실행한다
        if key.hasPrefix("protocol."), key.hasSuffix(".allow") { return key == "protocol.ext.allow" && value != "never" }
        if key.hasPrefix("remote."), key.hasSuffix("url") { return value.hasPrefix("ext::") }
        return false
    }

    /// 실행할 수 있는 훅 파일 이름. `core.hooksPath`를 따른다. `.sample`은 git이 실행하지 않는다.
    private static func hooks(in repo: GitRepository) async -> [String] {
        guard let path = try? await repo.run(["rev-parse", "--git-path", "hooks"]).stdout.trimmed else { return [] }
        let folder = path.hasPrefix("/") ? URL(fileURLWithPath: path) : repo.directory.appendingPathComponent(path)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        // git은 정해진 이름의 파일만 훅으로 실행한다. 훅 폴더의 보조 스크립트는 그 훅이 부를 때만 돈다.
        return names.filter { name in
            hookNames.contains(name) && FileManager.default.isExecutableFile(atPath: folder.appendingPathComponent(name).path)
        }.sorted()
    }

    /// git이 실행하는 훅 이름 (githooks(5))
    private static let hookNames: Set<String> = [
        "applypatch-msg", "pre-applypatch", "post-applypatch", "pre-commit", "pre-merge-commit",
        "prepare-commit-msg", "commit-msg", "post-commit", "pre-rebase", "post-checkout", "post-merge",
        "pre-push", "pre-receive", "update", "proc-receive", "post-receive", "post-update",
        "reference-transaction", "push-to-checkout", "pre-auto-gc", "post-rewrite", "sendemail-validate",
        "fsmonitor-watchman", "p4-changelist", "p4-prepare-changelist", "p4-post-changelist", "p4-pre-submit",
        "post-index-change",
    ]

    // MARK: 신뢰 기록

    private static let defaultsKey = "trustedRepositories"

    /// 설정이 바뀌면 다시 묻도록, 신뢰할 때의 설정을 줄여서 함께 적어 둔다
    static func fingerprint(_ settings: [String]) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in settings.sorted().joined(separator: "\n").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    static func isTrusted(root: String, settings: [String]) -> Bool {
        let trusted = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        return trusted[root] == fingerprint(settings)
    }

    /// 신뢰한 저장소 경로. 설정 화면에서 보여 주고 지운다.
    static var trustedRoots: [String] {
        ((UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String]) ?? [:]).keys.sorted()
    }

    static func revoke(root: String) {
        var trusted = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        trusted.removeValue(forKey: root)
        UserDefaults.standard.set(trusted, forKey: defaultsKey)
    }

    static func trust(root: String, settings: [String]) {
        var trusted = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        trusted[root] = fingerprint(settings)
        UserDefaults.standard.set(trusted, forKey: defaultsKey)
    }
}
