import Foundation

/// 저장소에 든 Claude 설정. 신뢰하기 전에는 쓰지 않는다.
///
/// `claude -p`는 폴더 신뢰 확인을 건너뛴다(CLI 도움말: "Only use this in directories you trust").
/// 그대로 두면 남이 준 저장소의 `.claude/settings.json` 훅, `.mcp.json` 서버, Bash를 허용한 스킬이
/// 질문 한 번에 이 Mac에서 돌 수 있다.
struct ClaudeProjectConfig {
    /// 사람이 읽을 수 있는 목록. ".claude/settings.local.json", "스킬 generate-commit · Bash, Read"
    var items: [String] = []
    /// 파일 내용까지 줄인 값. 바뀌면 다시 묻는다.
    var fingerprint = ""

    var isEmpty: Bool { items.isEmpty }

    static func scan(root: String, skills: [ClaudeSkill], engine: AssistantEngine = .current) -> ClaudeProjectConfig {
        let base = URL(fileURLWithPath: root, isDirectory: true)
        var config = ClaudeProjectConfig()
        var contents = ""
        let configPaths: [String]
        switch engine {
        case .claude:
            configPaths = [".claude/settings.json", ".claude/settings.local.json", ".mcp.json"]
        case .antigravity:
            configPaths = [
                ".agents/settings.json",
                ".agents/hooks.json",
                ".agents/mcp_config.json",
                ".gemini/settings.json",
                "GEMINI.md",
                "AGENTS.md",
            ]
        }
        for path in configPaths {
            let url = base.appendingPathComponent(path)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            config.items.append(path)
            contents += path + "\n" + text
        }
        for skill in skills where skill.source == "프로젝트" {
            let tools = skill.allowedTools.isEmpty ? "" : " (" + skill.allowedTools.joined(separator: ", ") + ")"
            config.items.append("스킬 " + skill.name + tools)
            contents += skill.name + skill.allowedTools.joined()
        }
        config.fingerprint = RepositoryTrust.fingerprint([contents])
        return config
    }

    // MARK: 신뢰 기록

    private static let defaultsKey = "trustedClaudeProjects"

    func isTrusted(root: String) -> Bool {
        let trusted = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
        return trusted[root] == fingerprint
    }

    static var trustedRoots: [String] {
        ((UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String]) ?? [:]).keys.sorted()
    }

    static func revoke(root: String) {
        var trusted = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        trusted.removeValue(forKey: root)
        UserDefaults.standard.set(trusted, forKey: defaultsKey)
    }

    func trust(root: String) {
        var trusted = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
        trusted[root] = fingerprint
        UserDefaults.standard.set(trusted, forKey: Self.defaultsKey)
    }
}
