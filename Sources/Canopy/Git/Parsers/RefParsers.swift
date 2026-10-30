import Foundation

/// `git stash list --format=...` 출력을 읽는다.
enum StashParser {
    static let format = "%gd%x1f%H%x1f%at%x1f%gs%x1e"

    static func parse(_ output: String) -> [Stash] {
        output.split(separator: "\u{1e}", omittingEmptySubsequences: true).compactMap { record -> Stash? in
            let fields = record.split(separator: "\u{1f}", omittingEmptySubsequences: false).map { $0.trimmed }
            guard fields.count >= 4 else { return nil }
            // "stash@{3}" → 3
            let digits = fields[0].filter(\.isNumber)
            guard let index = Int(digits) else { return nil }
            return Stash(
                index: index,
                hash: fields[1],
                date: Date(timeIntervalSince1970: TimeInterval(fields[2]) ?? 0),
                message: fields[3]
            )
        }
    }
}

/// `git for-each-ref refs/tags --format=...` 출력을 읽는다.
enum TagParser {
    static let format = "%(refname:short)%1f%(objectname:short)%1f%(*objectname:short)%1f%(creatordate:unix)%1f%(contents:subject)%1e"

    static func parse(_ output: String) -> [Tag] {
        output.split(separator: "\u{1e}", omittingEmptySubsequences: true).compactMap { record -> Tag? in
            let fields = record.split(separator: "\u{1f}", omittingEmptySubsequences: false).map { $0.trimmed }
            guard fields.count >= 5, !fields[0].isEmpty else { return nil }
            let isAnnotated = !fields[2].isEmpty
            return Tag(
                name: fields[0],
                targetHash: isAnnotated ? fields[2] : fields[1],
                date: Date(timeIntervalSince1970: TimeInterval(fields[3]) ?? 0),
                subject: fields[4],
                isAnnotated: isAnnotated
            )
        }
    }
}

/// `git remote -v` 출력에서 fetch 주소만 모은다.
enum RemoteParser {
    static func parse(_ output: String) -> [Remote] {
        var result: [Remote] = []
        for raw in output.split(separator: "\n") {
            let parts = raw.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard parts.count >= 2, parts.count < 3 || parts[2] == "(fetch)" else { continue }
            let name = String(parts[0])
            if result.contains(where: { $0.name == name }) { continue }
            result.append(Remote(name: name, url: String(parts[1])))
        }
        return result
    }
}
