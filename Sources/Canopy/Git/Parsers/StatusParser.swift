import Foundation

/// `git status --porcelain=v2 --branch -z` 출력을 읽는다.
enum StatusParser {
    static func parse(_ output: String) -> StatusSnapshot {
        var snapshot = StatusSnapshot()
        let records = output.split(separator: "\u{0}", omittingEmptySubsequences: true).map(String.init)
        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1

            if record.hasPrefix("# ") {
                parseHeader(record, into: &snapshot)
                continue
            }
            guard let first = record.first else { continue }
            switch first {
            case "1":
                // 1 XY sub mH mI mW hH hI path
                let parts = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard parts.count == 9 else { continue }
                snapshot.changes += entries(xy: parts[1], path: String(parts[8]), original: nil)
            case "2":
                // 2 XY sub mH mI mW hH hI Xscore path NUL origPath
                let parts = record.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                guard parts.count == 10 else { continue }
                var original: String?
                if index < records.count {
                    original = records[index]
                    index += 1
                }
                snapshot.changes += entries(xy: parts[1], path: String(parts[9]), original: original)
            case "u":
                // u XY sub m1 m2 m3 mW h1 h2 h3 path
                let parts = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard parts.count == 11 else { continue }
                snapshot.changes.append(FileChange(path: String(parts[10]), originalPath: nil, kind: .unmerged, area: .conflicted))
            case "?":
                snapshot.changes.append(FileChange(path: String(record.dropFirst(2)), originalPath: nil, kind: .untracked, area: .untracked))
            default:
                continue
            }
        }
        return snapshot
    }

    private static func parseHeader(_ line: String, into snapshot: inout StatusSnapshot) {
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return }
        let value = String(parts[2])
        switch parts[1] {
        case "branch.oid":
            snapshot.headOID = value == "(initial)" ? nil : value
        case "branch.head":
            snapshot.branch = value
        case "branch.upstream":
            snapshot.upstream = value
        case "branch.ab":
            let ab = value.split(separator: " ")
            if ab.count == 2 {
                snapshot.ahead = Int(ab[0].dropFirst()) ?? 0
                snapshot.behind = Int(ab[1].dropFirst()) ?? 0
            }
        default:
            break
        }
    }

    private static func entries(xy: Substring, path: String, original: String?) -> [FileChange] {
        guard xy.count == 2 else { return [] }
        let x = xy[xy.startIndex]
        let y = xy[xy.index(after: xy.startIndex)]
        var result: [FileChange] = []
        if x != ".", let kind = ChangeKind(rawValue: x) {
            result.append(FileChange(path: path, originalPath: original, kind: kind, area: .staged))
        }
        if y != ".", let kind = ChangeKind(rawValue: y) {
            result.append(FileChange(path: path, originalPath: nil, kind: kind, area: .unstaged))
        }
        return result
    }
}
