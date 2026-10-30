import Foundation

/// `git reflog show --date=unix --format=%H%x1f%h%x1f%gd%x1f%gs%x1e` 출력을 읽고 우리말로 바꾼다.
enum ActivityParser {
    static let format = "%H%x1f%h%x1f%gd%x1f%gs%x1e"

    static func parse(_ output: String) -> [ActivityEntry] {
        output.split(separator: "\u{1e}", omittingEmptySubsequences: true).enumerated().compactMap { index, record -> ActivityEntry? in
            let fields = record.split(separator: "\u{1f}", omittingEmptySubsequences: false).map { $0.trimmed }
            guard fields.count >= 4, !fields[0].isEmpty else { return nil }
            // "HEAD@{1761550000}" → 1761550000
            let digits = fields[2].drop { $0 != "{" }.dropFirst().prefix { $0.isNumber }
            let date = Date(timeIntervalSince1970: TimeInterval(digits) ?? 0)
            let (kind, title) = describe(fields[3])
            return ActivityEntry(index: index, hash: fields[0], shortHash: fields[1], date: date, kind: kind, title: title, raw: fields[3])
        }
    }

    /// reflog 제목을 (종류, 우리말 한 줄)로 바꾼다.
    static func describe(_ subject: String) -> (ActivityEntry.Kind, String) {
        func after(_ prefix: String) -> String? {
            subject.hasPrefix(prefix) ? String(subject.dropFirst(prefix.count)).trimmed : nil
        }
        if let rest = after("checkout: moving from ") {
            let parts = rest.components(separatedBy: " to ")
            if parts.count == 2 {
                return (.checkout, "체크아웃 → \(shortRef(parts[1]))  (\(shortRef(parts[0]))에서)")
            }
            return (.checkout, "체크아웃: \(rest)")
        }
        if let rest = after("commit (amend): ") { return (.amend, "커밋 수정: \(rest)") }
        if let rest = after("commit (initial): ") { return (.commit, "첫 커밋: \(rest)") }
        if let rest = after("commit (merge): ") { return (.merge, "머지 커밋: \(rest)") }
        if let rest = after("commit: ") { return (.commit, "커밋: \(rest)") }
        if let rest = after("merge ") {
            let name = rest.split(separator: ":").first.map(String.init) ?? rest
            if rest.contains("Fast-forward") { return (.merge, "\(name) 머지 (fast-forward)") }
            return (.merge, "\(name) 머지")
        }
        if let rest = after("pull") {
            if rest.contains("Fast-forward") { return (.pull, "풀 (fast-forward)") }
            if rest.contains("Merge") { return (.pull, "풀 (머지)") }
            return (.pull, "풀")
        }
        if let rest = after("reset: moving to ") {
            if rest == "HEAD" { return (.reset, "작업 트리 정리 (스태시 또는 HEAD로 리셋)") }
            return (.reset, "리셋 → \(shortRef(rest))")
        }
        if subject.hasPrefix("rebase") {
            if subject.contains("(start)") { return (.rebase, "리베이스 시작") }
            if subject.contains("(finish)") {
                let target = subject.components(separatedBy: "returning to ").last.map(shortRef) ?? ""
                return (.rebase, "리베이스 완료" + (target.isEmpty ? "" : ": \(target)"))
            }
            if subject.contains("(abort)") { return (.rebase, "리베이스 중단") }
            if let range = subject.range(of: "): ") {
                return (.rebase, "리베이스: \(subject[range.upperBound...])")
            }
            return (.rebase, "리베이스")
        }
        if let rest = after("cherry-pick: ") { return (.cherryPick, "체리픽: \(rest)") }
        if let rest = after("revert: ") { return (.revert, "리버트: \(rest)") }
        if subject.hasPrefix("clone") { return (.clone, "클론") }
        if subject.hasPrefix("initial pull") { return (.clone, "처음 풀") }
        if subject.hasPrefix("Branch: renamed") { return (.other, "브랜치 이름 바꿈") }
        if subject.hasPrefix("update by push") { return (.push, "푸시로 갱신") }
        return (.other, subject)
    }

    /// "refs/heads/main" → "main", 긴 해시 → 7자
    static func shortRef(_ ref: String) -> String {
        var name = ref.trimmed
        if name.hasPrefix("refs/heads/") { name = String(name.dropFirst(11)) }
        if name.count == 40, name.allSatisfy(\.isHexDigit) { name = String(name.prefix(7)) }
        return name
    }
}

/// `git diff --numstat` 출력을 합친다.
enum NumstatParser {
    static func parse(_ output: String) -> DiffStat {
        var stat = DiffStat()
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            stat.files += 1
            stat.additions += Int(parts[0]) ?? 0
            stat.deletions += Int(parts[1]) ?? 0
        }
        return stat
    }
}
