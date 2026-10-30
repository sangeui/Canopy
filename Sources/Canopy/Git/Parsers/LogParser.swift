import Foundation

/// `git log --format=<format>` 출력을 읽는다. 필드는 0x1f, 레코드는 0x1e로 나눈다.
enum LogParser {
    static let format = "%H%x1f%h%x1f%an%x1f%ae%x1f%at%x1f%P%x1f%D%x1f%s%x1f%b%x1e"

    static func parse(_ output: String) -> [Commit] {
        output.split(separator: "\u{1e}", omittingEmptySubsequences: true).compactMap { record -> Commit? in
            let fields = record.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard fields.count >= 8 else { return nil }
            let hash = fields[0].trimmed
            guard !hash.isEmpty else { return nil }
            let seconds = TimeInterval(fields[4]) ?? 0
            let parents = fields[5].split(separator: " ").map(String.init)
            let refs = fields[6]
                .split(separator: ",")
                .map { $0.trimmed }
                .filter { !$0.isEmpty }
            let body = fields.count > 8 ? fields[8].trimmed : ""
            return Commit(
                hash: hash,
                shortHash: String(fields[1]),
                authorName: String(fields[2]),
                authorEmail: String(fields[3]),
                date: Date(timeIntervalSince1970: seconds),
                parents: parents,
                refs: refs,
                subject: String(fields[7]),
                body: body
            )
        }
    }
}
