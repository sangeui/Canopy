import Foundation

/// `git for-each-ref --format=<format> refs/heads refs/remotes` 출력을 읽는다.
enum BranchParser {
    static let format = "%(refname)%1f%(refname:short)%1f%(HEAD)%1f%(upstream:short)%1f%(upstream:track)%1f%(worktreepath)%1f%(objectname:short)%1f%(committerdate:unix)%1f%(authorname)%1f%(objectname)%1e"

    static func parse(_ output: String) -> [Branch] {
        output.split(separator: "\u{1e}", omittingEmptySubsequences: true).compactMap { record -> Branch? in
            let fields = record.split(separator: "\u{1f}", omittingEmptySubsequences: false).map { $0.trimmed }
            guard fields.count >= 7 else { return nil }
            let fullName = fields[0]
            let isRemote = fullName.hasPrefix("refs/remotes/")
            // origin/HEAD는 가리키는 곳만 알려주는 항목이라 목록에서 뺀다.
            if isRemote, fields[1].hasSuffix("/HEAD") { return nil }
            let (ahead, behind) = parseTrack(fields[4])
            return Branch(
                fullName: fullName,
                name: fields[1],
                isRemote: isRemote,
                isHead: fields[2] == "*",
                upstream: fields[3].isEmpty ? nil : fields[3],
                ahead: ahead,
                behind: behind,
                worktreePath: fields[5].isEmpty ? nil : fields[5],
                shortHash: fields[6],
                date: fields.count > 7 ? Date(timeIntervalSince1970: TimeInterval(fields[7]) ?? 0) : .distantPast,
                authorName: fields.count > 8 ? fields[8] : "",
                upstreamGone: fields[4].contains("gone"),
                hash: fields.count > 9 ? fields[9] : ""
            )
        }
    }

    /// "[ahead 1, behind 2]" → (1, 2). "[gone]"이나 빈 문자열은 (0, 0).
    static func parseTrack(_ text: String) -> (ahead: Int, behind: Int) {
        var ahead = 0
        var behind = 0
        let inner = text.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        for token in inner.split(separator: ",") {
            let parts = token.trimmed.split(separator: " ")
            guard parts.count == 2, let count = Int(parts[1]) else { continue }
            if parts[0] == "ahead" { ahead = count }
            if parts[0] == "behind" { behind = count }
        }
        return (ahead, behind)
    }
}
