import Foundation

/// Claude Code 스킬 하나. `/이름`으로 부른다.
struct ClaudeSkill: Identifiable, Hashable {
    let name: String
    /// 설명의 첫 문장. 자동완성 목록에 한 줄로.
    let summary: String
    /// 인자 자리 표시자. "<PR 번호> <파일 경로>"
    let argumentHint: String?
    /// 어디서 왔는지. "프로젝트", "내 스킬", 플러그인 이름
    let source: String
    /// 머리말의 `allowed-tools`. 이 스킬을 부를 때만 Claude에게 더 허용한다. 예: Bash, mcp__atlassian__getJiraIssue
    var allowedTools: [String] = []

    /// 커밋을 다루는 스킬인지. 이런 스킬에는 보고 있는 파일 하나가 아니라 스테이징한 변경 전체가 맞는 문맥이다.
    var isAboutCommit: Bool { name.lowercased().contains("commit") }

    var id: String { source + "/" + name }
}

/// 스킬 파일을 읽어 목록을 만든다. 디스크만 읽고 CLI는 부르지 않는다.
/// 프로젝트 `.claude/skills`, 사용자 `~/.claude/skills`, 설치된 플러그인의 `skills` 폴더 순서.
enum SkillCatalog {
    static func load(projectRoot: String?) -> [ClaudeSkill] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var roots: [(path: String, source: String)] = []
        if let projectRoot { roots.append((projectRoot + "/.claude/skills", "프로젝트")) }
        roots.append((home + "/.claude/skills", "내 스킬"))
        roots += pluginSkillRoots(home: home)

        var seen: Set<String> = []
        var skills: [ClaudeSkill] = []
        for root in roots {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { continue }
            for name in names.sorted() {
                let file = root.path + "/" + name + "/SKILL.md"
                guard !seen.contains(name), let skill = parse(file: file, fallbackName: name, source: root.source) else { continue }
                seen.insert(name)
                skills.append(skill)
            }
        }
        return skills
    }

    /// `installed_plugins.json`에서 설치 경로를 읽는다. 플러그인 이름은 `이름@마켓`에서 앞부분.
    private static func pluginSkillRoots(home: String) -> [(path: String, source: String)] {
        guard let data = FileManager.default.contents(atPath: home + "/.claude/plugins/installed_plugins.json"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = object["plugins"] as? [String: [[String: Any]]] else { return [] }
        return plugins.sorted { $0.key < $1.key }.compactMap { key, entries in
            guard let path = entries.first?["installPath"] as? String else { return nil }
            let name = key.split(separator: "@").first.map(String.init) ?? key
            return (path + "/skills", name)
        }
    }

    /// SKILL.md 머리말만 읽는다. 본문은 읽지 않는다.
    static func parse(file: String, fallbackName: String, source: String) -> ClaudeSkill? {
        guard let handle = FileHandle(forReadingAtPath: file) else { return nil }
        defer { try? handle.close() }
        // 머리말은 앞 8KB면 충분하다
        let head = String(decoding: handle.readData(ofLength: 8192), as: UTF8.self)
        let fields = frontmatter(head)
        let name = fields["name"]?.trimmed ?? fallbackName
        let description = fields["description"]?.trimmed ?? ""
        let tools = (fields["allowed-tools"] ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .split(separator: ",")
            .map { $0.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            .filter { !$0.isEmpty }
        return ClaudeSkill(name: name, summary: firstSentence(description), argumentHint: fields["argument-hint"]?.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")), source: source, allowedTools: tools)
    }

    /// `---` 사이의 `키: 값`. `키: |`나 `키: >`는 들여쓴 줄을 이어 붙인다.
    static func frontmatter(_ text: String) -> [String: String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmed == "---" else { return [:] }
        lines.removeFirst()
        var result: [String: String] = [:]
        var current: String?
        var block = false
        for line in lines {
            if line.trimmed == "---" { break }
            if block, let key = current, line.hasPrefix(" ") || line.hasPrefix("\t") {
                result[key, default: ""] += (result[key]?.isEmpty == false ? " " : "") + line.trimmed
                continue
            }
            block = false
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" ") else { continue }
            let key = String(line[..<colon]).trimmed
            let value = String(line[line.index(after: colon)...]).trimmed
            current = key
            if value == "|" || value == ">" || value == "|-" || value == ">-" {
                block = true
                result[key] = ""
            } else {
                result[key] = value
            }
        }
        return result
    }

    static func firstSentence(_ text: String) -> String {
        let cleaned = text.replacingOccurrences(of: "\n", with: " ")
        for marker in [". ", "다. ", "요. ", "니다 "] {
            if let range = cleaned.range(of: marker) {
                return String(cleaned[..<range.lowerBound]) + (marker.hasPrefix(".") ? "." : String(marker.dropLast()))
            }
        }
        return cleaned.count > 120 ? String(cleaned.prefix(120)) + "…" : cleaned
    }
}
