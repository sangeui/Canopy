import Foundation

/// `git blame --line-porcelain` 출력을 줄 단위로 읽는다.
enum BlameParser {
    static func parse(_ output: String) -> [BlameLine] {
        var lines: [BlameLine] = []
        var hash = ""
        var number = 0
        var author = ""
        var date = Date.distantPast
        var summary = ""
        // 같은 커밋이 두 번째 나올 때는 머리 정보를 생략하므로 커밋별로 기억해 둔다.
        var known: [String: (author: String, date: Date, summary: String)] = [:]
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("\t") {
                if let info = known[hash] {
                    if author.isEmpty { author = info.author }
                    if date == .distantPast { date = info.date }
                    if summary.isEmpty { summary = info.summary }
                } else {
                    known[hash] = (author, date, summary)
                }
                lines.append(BlameLine(number: number, hash: hash, author: author, date: date, summary: summary, text: String(line.dropFirst())))
                hash = ""; number = 0; author = ""; date = .distantPast; summary = ""
                continue
            }
            if hash.isEmpty {
                let parts = line.split(separator: " ")
                guard parts.count >= 3, parts[0].count == 40 else { continue }
                hash = String(parts[0])
                number = Int(parts[2]) ?? 0
                continue
            }
            if line.hasPrefix("author ") { author = String(line.dropFirst(7)) }
            else if line.hasPrefix("author-time ") { date = Date(timeIntervalSince1970: TimeInterval(line.dropFirst(12)) ?? 0) }
            else if line.hasPrefix("summary ") { summary = String(line.dropFirst(8)) }
        }
        return lines
    }
}
