import Foundation

/// unified diff를 파일 → hunk → 줄로 나눈다.
enum DiffParser {
    static func parse(_ text: String) -> [DiffFile] {
        var files: [DiffFile] = []
        var current: DiffFile?
        var hunk: DiffHunk?
        var oldLine = 0
        var newLine = 0
        var nextID = 0

        func makeID() -> Int {
            nextID += 1
            return nextID
        }
        func closeHunk() {
            if let finished = hunk { current?.hunks.append(finished) }
            hunk = nil
        }
        func closeFile() {
            closeHunk()
            if var finished = current {
                // 지운 줄과 더한 줄을 짝지어 바뀐 낱말을 표시해 둔다.
                for index in finished.hunks.indices {
                    WordDiff.annotate(&finished.hunks[index])
                    var hasher = Hasher()
                    hasher.combine(finished.newPath ?? finished.oldPath)
                    hasher.combine(finished.hunks[index].header)
                    for line in finished.hunks[index].lines {
                        hasher.combine(line.kind)
                        hasher.combine(line.text)
                        hasher.combine(line.marks)
                    }
                    finished.hunks[index].signature = hasher.finalize()
                }
                files.append(finished)
            }
            current = nil
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, raw) in lines.enumerated() {
            let line = String(raw)

            if line.hasPrefix("diff --git ") {
                closeFile()
                current = DiffFile(id: makeID(), oldPath: nil, newPath: nil, hunks: [], isBinary: false, headerLines: [])
                continue
            }
            guard current != nil else { continue }

            if line.hasPrefix("@@") {
                closeHunk()
                let start = hunkStart(line)
                oldLine = start.old
                newLine = start.new
                hunk = DiffHunk(id: makeID(), header: line, lines: [])
                continue
            }

            if hunk == nil {
                if line.hasPrefix("--- ") {
                    current?.oldPath = stripPrefix(String(line.dropFirst(4)))
                } else if line.hasPrefix("+++ ") {
                    current?.newPath = stripPrefix(String(line.dropFirst(4)))
                } else if line.hasPrefix("rename from ") {
                    current?.oldPath = String(line.dropFirst(12))
                    current?.headerLines.append(line)
                } else if line.hasPrefix("rename to ") {
                    current?.newPath = String(line.dropFirst(10))
                    current?.headerLines.append(line)
                } else if line.hasPrefix("Binary files") {
                    current?.isBinary = true
                } else {
                    current?.headerLines.append(line)
                }
                continue
            }

            // split의 마지막 빈 조각은 끝의 개행이 만든 것이라 건너뛴다.
            if line.isEmpty, index == lines.count - 1 { continue }

            let kind: DiffLine.Kind
            var content = line
            var old: Int?
            var new: Int?
            if line.hasPrefix("+") {
                kind = .addition
                content = String(line.dropFirst())
                new = newLine
                newLine += 1
            } else if line.hasPrefix("-") {
                kind = .deletion
                content = String(line.dropFirst())
                old = oldLine
                oldLine += 1
            } else if line.hasPrefix("\\") {
                kind = .meta
                content = String(line.dropFirst(2))
            } else {
                kind = .context
                content = line.isEmpty ? "" : String(line.dropFirst())
                old = oldLine
                new = newLine
                oldLine += 1
                newLine += 1
            }
            hunk?.lines.append(DiffLine(id: makeID(), kind: kind, text: content, oldNumber: old, newNumber: new))
        }
        closeFile()
        return files
    }

    /// "@@ -12,7 +12,8 @@ ..." → (12, 12)
    static func hunkStart(_ header: String) -> (old: Int, new: Int) {
        let parts = header.split(separator: " ")
        guard parts.count >= 3 else { return (0, 0) }
        func first(_ range: Substring) -> Int {
            let number = range.dropFirst().split(separator: ",").first ?? ""
            return Int(number) ?? 0
        }
        return (first(parts[1]), first(parts[2]))
    }

    private static func stripPrefix(_ raw: String) -> String? {
        let path = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\t"))
        if path == "/dev/null" { return nil }
        if path.hasPrefix("a/") || path.hasPrefix("b/") { return String(path.dropFirst(2)) }
        return path
    }
}
