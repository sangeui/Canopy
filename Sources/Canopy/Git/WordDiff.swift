import Foundation

/// 지운 줄과 더한 줄을 짝지어 그 안에서 실제로 바뀐 토큰만 찾아낸다.
/// 줄 전체가 빨갛고 초록인 것만 보면 어디가 바뀌었는지 눈으로 찾아야 한다. 바뀐 낱말만 진하게 칠하면 바로 보인다.
enum WordDiff {
    /// hunk 안의 "지운 줄 묶음 → 더한 줄 묶음"을 순서대로 짝지어 `marks`를 채운다.
    static func annotate(_ hunk: inout DiffHunk) {
        var index = 0
        let lines = hunk.lines
        while index < lines.count {
            guard lines[index].kind == .deletion else { index += 1; continue }
            var deletions: [Int] = []
            while index < lines.count, lines[index].kind == .deletion { deletions.append(index); index += 1 }
            var additions: [Int] = []
            while index < lines.count, lines[index].kind == .addition { additions.append(index); index += 1 }
            guard !additions.isEmpty else { continue }
            // 줄 수가 같으면 순서대로, 다르면 더한 줄마다 가장 닮은 지운 줄을 찾는다.
            // 어느 쪽이든 충분히 닮았을 때만 짝이다. "같은 변수 이름이 우연히 들어 있는" 줄은 짝이 아니다.
            var pairs: [(old: Int, new: Int)] = []
            if deletions.count == additions.count {
                for (old, new) in zip(deletions, additions) where similarity(lines[old].text, lines[new].text) >= 0.5 {
                    pairs.append((old, new))
                }
            } else {
                var unused = deletions
                for new in additions {
                    var best: (index: Int, score: Double)?
                    for old in unused {
                        let score = similarity(lines[old].text, lines[new].text)
                        if score >= 0.6, score > (best?.score ?? 0) { best = (old, score) }
                    }
                    if let best {
                        pairs.append((best.index, new))
                        unused.removeAll { $0 == best.index }
                    }
                }
            }
            for pair in pairs {
                let (oldMarks, newMarks) = compare(lines[pair.old].text, lines[pair.new].text)
                hunk.lines[pair.old].marks = oldMarks
                hunk.lines[pair.new].marks = newMarks
            }
        }
    }

    /// 두 줄이 얼마나 닮았는지. 공백을 뺀 글자 중 공통 토큰에 든 글자의 비율 (긴 쪽 기준). 0이면 전혀 다르다.
    static func similarity(_ old: String, _ new: String) -> Double {
        let oldTokens = tokenize(old), newTokens = tokenize(new)
        guard oldTokens.count <= 160, newTokens.count <= 160, !oldTokens.isEmpty, !newTokens.isEmpty else { return 0 }
        let (oldKeep, newKeep) = commonTokens(oldTokens, newTokens)
        func weight(_ tokens: [Token], _ keep: [Bool], onlyKept: Bool) -> Int {
            zip(tokens, keep).reduce(0) { $0 + (!$1.0.isSpace && (!onlyKept || $1.1) ? $1.0.text.count : 0) }
        }
        let common = weight(oldTokens, oldKeep, onlyKept: true)
        let longest = max(weight(oldTokens, oldKeep, onlyKept: false), weight(newTokens, newKeep, onlyKept: false))
        guard longest > 0 else { return 0 }
        return Double(common) / Double(longest)
    }

    /// 두 토큰 열의 최장 공통 부분열. 각 토큰이 공통에 드는지 돌려준다.
    private static func commonTokens(_ oldTokens: [Token], _ newTokens: [Token]) -> ([Bool], [Bool]) {
        let n = oldTokens.count, m = newTokens.count
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = oldTokens[i].text == newTokens[j].text ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var i = 0, j = 0
        var oldKeep = [Bool](repeating: false, count: n)
        var newKeep = [Bool](repeating: false, count: m)
        while i < n, j < m {
            if oldTokens[i].text == newTokens[j].text {
                oldKeep[i] = true; newKeep[j] = true; i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return (oldKeep, newKeep)
    }

    /// 두 줄을 토큰으로 나눠 공통 부분을 빼고 남는 자리를 돌려준다. 거의 다 바뀐 줄은 칠하지 않는다.
    static func compare(_ old: String, _ new: String) -> ([Range<Int>], [Range<Int>]) {
        let oldTokens = tokenize(old)
        let newTokens = tokenize(new)
        guard oldTokens.count <= 160, newTokens.count <= 160, !oldTokens.isEmpty, !newTokens.isEmpty else { return ([], []) }
        let (oldKeep, newKeep) = commonTokens(oldTokens, newTokens)
        // 공백만 공통이고 나머지가 다 바뀐 줄이면 칠하지 않는다. 그런 줄은 줄 색만으로 충분하다.
        func changedWeight(_ tokens: [Token], _ keep: [Bool]) -> Double {
            let total = tokens.reduce(0) { $0 + ($1.isSpace ? 0 : $1.text.count) }
            guard total > 0 else { return 0 }
            let changed = zip(tokens, keep).reduce(0) { $0 + (!$1.1 && !$1.0.isSpace ? $1.0.text.count : 0) }
            return Double(changed) / Double(total)
        }
        if changedWeight(oldTokens, oldKeep) > 0.7 || changedWeight(newTokens, newKeep) > 0.7 { return ([], []) }
        return (ranges(oldTokens, oldKeep), ranges(newTokens, newKeep))
    }

    private struct Token {
        let text: String
        let start: Int
        var isSpace: Bool { text.first?.isWhitespace ?? false }
    }

    /// 낱말, 공백, 기호 하나씩을 토큰으로 본다.
    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var currentStart = 0
        var kind = 0 // 0 없음, 1 낱말, 2 공백
        var offset = 0
        func flush() {
            if !current.isEmpty { tokens.append(Token(text: current, start: currentStart)); current = "" }
        }
        for character in text {
            let next = character.isLetter || character.isNumber || character == "_" ? 1 : (character.isWhitespace ? 2 : 3)
            if next == 3 {
                flush()
                tokens.append(Token(text: String(character), start: offset))
                kind = 0
            } else if next != kind || current.isEmpty {
                flush()
                current = String(character); currentStart = offset; kind = next
            } else {
                current.append(character)
            }
            offset += 1
        }
        flush()
        return tokens
    }

    /// 공통이 아닌 토큰을 이어진 구간으로 합친다. 사이에 낀 공백은 같이 칠해서 구간이 끊기지 않게 한다.
    private static func ranges(_ tokens: [Token], _ keep: [Bool]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var open: Range<Int>?
        for (token, kept) in zip(tokens, keep) {
            let end = token.start + token.text.count
            if !kept {
                if let current = open, current.upperBound >= token.start {
                    open = current.lowerBound..<end
                } else {
                    if let current = open { result.append(current) }
                    open = token.start..<end
                }
            } else if token.isSpace, let current = open {
                // 바뀐 낱말 사이의 공백은 이어 붙인다. 다음 토큰이 또 바뀌었을 때만 효과가 있다.
                open = current.lowerBound..<current.upperBound
            }
        }
        if let current = open { result.append(current) }
        return result
    }
}

/// diff 한 파일에서 "어느 선언이 바뀌었나"를 뽑는다. 줄 번호가 아니라 함수 이름으로 변경을 읽게 한다.
enum ChangedSymbols {
    private static let pattern = try! NSRegularExpression(
        pattern: #"^\s*(?:(?:public|private|internal|fileprivate|open|static|final|override|mutating|async|lazy|weak|convenience|required|export|default|abstract|@\w+(?:\([^)]*\))?)\s+)*(func|var|let|class|struct|enum|protocol|extension|actor|init|deinit|subscript|def|function|fn|fun|interface|type|const)\b\s*([A-Za-z_][A-Za-z0-9_.]*)?"#
    )

    /// hunk마다 바뀐 줄 바로 위의 선언, 없으면 hunk 머리말의 문맥. 등장 순서대로, 겹치지 않게.
    static func symbols(in file: DiffFile) -> [String] {
        var result: [String] = []
        for hunk in file.hunks {
            var current = hunk.context
            for line in hunk.lines {
                if let declaration = declaration(in: line.text) { current = declaration }
                guard line.kind == .addition || line.kind == .deletion, let current, !current.isEmpty else { continue }
                if !result.contains(current) { result.append(current) }
            }
        }
        return result
    }

    static func declaration(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern.firstMatch(in: text, range: range) else { return nil }
        guard let keywordRange = Range(match.range(at: 1), in: text) else { return nil }
        let keyword = String(text[keywordRange])
        // 함수 안의 지역 변수는 선언으로 치지 않는다. 들여쓰기가 깊은 let/var는 그냥 코드 한 줄이다.
        if ["var", "let", "const"].contains(keyword) {
            let indent = text.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            if indent > 4 { return nil }
        }
        if let nameRange = Range(match.range(at: 2), in: text) {
            return "\(keyword) \(text[nameRange])"
        }
        return keyword == "init" || keyword == "deinit" ? keyword : nil
    }
}
