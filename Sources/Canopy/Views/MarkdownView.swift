import SwiftUI

/// GitHub 글에서 자주 쓰는 블록만 다루는 작은 마크다운 파서.
/// 줄 안의 굵게·기울임·코드·링크는 Foundation의 AttributedString에 맡긴다.
enum MarkdownBlock: Hashable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(language: String?, text: String)
    case quote([String])
    case list(items: [MarkdownListItem])
    case table(header: [String], rows: [[String]])
    case rule
    case image(url: String, alt: String)
}

struct MarkdownListItem: Hashable {
    let text: String
    let depth: Int
    let ordered: Bool
    let number: Int?
    /// nil이면 보통 항목, true/false면 체크리스트
    let checked: Bool?
}

enum MarkdownParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = preprocess(source).components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var index = 0
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            // 문단 안의 이미지는 따로 블록으로 뺀다.
            let (text, images) = extractImages(paragraph.joined(separator: " "))
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                blocks.append(.paragraph(text))
            }
            blocks += images
            paragraph = []
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }
            // 코드 블록
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    body.append(lines[index])
                    index += 1
                }
                index += 1
                blocks.append(.code(language: language.isEmpty ? nil : language, text: body.joined(separator: "\n")))
                continue
            }
            // 제목
            if let heading = parseHeading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                index += 1
                continue
            }
            // 구분선
            if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                index += 1
                continue
            }
            // setext 제목: 글 한 줄 다음에 --- 또는 ===
            if index + 1 < lines.count, paragraph.isEmpty {
                let next = lines[index + 1].trimmingCharacters(in: .whitespaces)
                if next.count >= 3, next.allSatisfy({ $0 == "=" }) || next.allSatisfy({ $0 == "-" }) {
                    blocks.append(.heading(level: next.first == "=" ? 1 : 2, text: trimmed))
                    index += 2
                    continue
                }
            }
            // 인용
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quoted.append(String(lines[index].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quoted))
                continue
            }
            // 표
            if trimmed.hasPrefix("|"), index + 1 < lines.count, isTableSeparator(lines[index + 1]) {
                flushParagraph()
                let header = splitTableRow(trimmed)
                index += 2
                var rows: [[String]] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(splitTableRow(lines[index]))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }
            // 목록
            if parseListItem(line) != nil {
                flushParagraph()
                var items: [MarkdownListItem] = []
                while index < lines.count, let item = parseListItem(lines[index]) {
                    items.append(item)
                    index += 1
                    // 들여쓴 이어지는 줄은 같은 항목에 붙인다.
                    while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
                          parseListItem(lines[index]) == nil, lines[index].hasPrefix("  ") {
                        let last = items.removeLast()
                        items.append(MarkdownListItem(text: last.text + " " + lines[index].trimmingCharacters(in: .whitespaces), depth: last.depth, ordered: last.ordered, number: last.number, checked: last.checked))
                        index += 1
                    }
                }
                blocks.append(.list(items: items))
                continue
            }
            paragraph.append(trimmed)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    /// HTML 주석을 걷어내고, 태그를 하나씩 읽어 서식 태그는 마크다운으로, 블록 태그는 줄바꿈으로 바꾼다.
    /// 모르는 태그는 지운다. 그래야 어떤 봇 댓글이 와도 태그가 그대로 보이지 않는다.
    static func preprocess(_ source: String) -> String {
        var text = source.replacingOccurrences(of: "\r\n", with: "\n")
        while let open = text.range(of: "<!--") {
            if let close = text.range(of: "-->", range: open.upperBound..<text.endIndex) {
                text.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                text.removeSubrange(open.lowerBound..<text.endIndex)
            }
        }
        var result = ""
        var cursor = text.startIndex
        while let open = text[cursor...].firstIndex(of: "<") {
            result += text[cursor..<open]
            let next = text.index(after: open)
            // "a < b"처럼 태그가 아닌 부등호는 그대로 둔다.
            guard next < text.endIndex, text[next].isLetter || text[next] == "/" || text[next] == "!",
                  let close = text[open...].firstIndex(of: ">") else {
                result += "<"
                cursor = next
                continue
            }
            result += replacement(forTag: String(text[open...close]))
            cursor = text.index(after: close)
        }
        result += text[cursor...]
        let entities: [(String, String)] = [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")]
        for (from, to) in entities { result = result.replacingOccurrences(of: from, with: to) }
        return result
    }

    private static func replacement(forTag tag: String) -> String {
        let inner = tag.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        let closing = inner.hasPrefix("/")
        let body = closing ? String(inner.dropFirst()) : inner
        let name = String(body.prefix { $0.isLetter || $0.isNumber }).lowercased()
        switch name {
        case "br": return "\n"
        case "b", "strong": return "**"
        case "i", "em": return "*"
        case "code", "kbd", "tt", "samp": return "`"
        case "s", "del", "strike": return "~~"
        case "img": return closing ? "" : tag
        case "a": return ""
        case "summary": return closing ? "**\n" : "\n**"
        case "pre": return "\n```\n"
        case "hr": return "\n---\n"
        case "li": return closing ? "" : "\n- "
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(String(name.last!)) ?? 1
            return closing ? "\n" : "\n" + String(repeating: "#", count: level) + " "
        case "td", "th": return closing ? "" : " "
        case "details", "div", "p", "dl", "dd", "dt", "ul", "ol", "table", "thead", "tbody", "tr", "blockquote",
             "center", "picture", "section", "article", "figure", "figcaption", "nav", "header", "footer":
            return "\n"
        default:
            return ""
        }
    }

    /// `![alt](url)`과 `<img src="url">`을 블록으로 꺼낸다. 남은 글을 함께 돌려준다.
    static func extractImages(_ text: String) -> (String, [MarkdownBlock]) {
        var remaining = text
        var images: [MarkdownBlock] = []
        // 마크다운 이미지
        while let bang = remaining.range(of: "![") {
            guard let closeBracket = remaining[bang.upperBound...].firstIndex(of: "]"),
                  remaining.index(after: closeBracket) < remaining.endIndex,
                  remaining[remaining.index(after: closeBracket)] == "(",
                  let closeParen = remaining[closeBracket...].firstIndex(of: ")") else { break }
            let alt = String(remaining[bang.upperBound..<closeBracket])
            var url = String(remaining[remaining.index(closeBracket, offsetBy: 2)..<closeParen])
            if let space = url.firstIndex(of: " ") { url = String(url[..<space]) }
            images.append(.image(url: url, alt: alt))
            remaining.removeSubrange(bang.lowerBound...closeParen)
        }
        // HTML 이미지
        while let open = remaining.range(of: "<img", options: .caseInsensitive) {
            guard let close = remaining[open.upperBound...].firstIndex(of: ">") else { break }
            let tag = String(remaining[open.lowerBound...close])
            let width = attribute("width", in: tag).flatMap { Int($0.filter(\.isNumber)) }
            if let url = attribute("src", in: tag), (width ?? 100) > 32 {
                images.append(.image(url: url, alt: attribute("alt", in: tag) ?? ""))
            }
            remaining.removeSubrange(open.lowerBound...close)
        }
        // <a href="url">...</a>는 링크 글만 남긴다.
        remaining = remaining.replacingOccurrences(of: "</a>", with: "", options: .caseInsensitive)
        while let open = remaining.range(of: "<a ", options: .caseInsensitive), let close = remaining[open.upperBound...].firstIndex(of: ">") {
            remaining.removeSubrange(open.lowerBound...close)
        }
        return (remaining, images)
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let range = tag.range(of: name + "=\"", options: .caseInsensitive) else { return nil }
        let rest = tag[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    private static func parseHeading(_ line: String) -> MarkdownBlock? {
        var level = 0
        var rest = Substring(line)
        while rest.first == "#", level < 6 {
            level += 1
            rest = rest.dropFirst()
        }
        guard level > 0, rest.first == " " || rest.isEmpty else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmingCharacters(in: .whitespaces)
        return .heading(level: level, text: text)
    }

    private static func isRule(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: " ", with: "")
        return stripped.count >= 3 && (stripped.allSatisfy { $0 == "-" } || stripped.allSatisfy { $0 == "*" } || stripped.allSatisfy { $0 == "_" })
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|") || trimmed.contains("---") else { return false }
        let cells = splitTableRow(trimmed)
        return !cells.isEmpty && cells.allSatisfy { cell in
            let inner = cell.trimmingCharacters(in: .whitespaces)
            return !inner.isEmpty && inner.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    static func splitTableRow(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func parseListItem(_ line: String) -> MarkdownListItem? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.count
        let rest = line.dropFirst(indent)
        let depth = indent / 2
        if rest.hasPrefix("- ") || rest.hasPrefix("* ") || rest.hasPrefix("+ ") {
            var text = String(rest.dropFirst(2))
            var checked: Bool?
            if text.hasPrefix("[ ] ") { checked = false; text = String(text.dropFirst(4)) }
            else if text.lowercased().hasPrefix("[x] ") { checked = true; text = String(text.dropFirst(4)) }
            return MarkdownListItem(text: text, depth: depth, ordered: false, number: nil, checked: checked)
        }
        let digits = rest.prefix { $0.isNumber }
        if !digits.isEmpty, rest.dropFirst(digits.count).hasPrefix(". ") {
            return MarkdownListItem(text: String(rest.dropFirst(digits.count + 2)), depth: depth, ordered: true, number: Int(digits), checked: nil)
        }
        return nil
    }

    /// 줄 안의 서식. 실패하면 그냥 글자.
    static func inline(_ text: String) -> AttributedString {
        var result: AttributedString
        if let parsed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            result = parsed
        } else {
            result = AttributedString(text)
        }
        for run in result.runs {
            if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                result[run.range].font = .system(size: 12, design: .monospaced)
                result[run.range].backgroundColor = Theme.raised
            }
        }
        return result
    }
}

/// 마크다운을 SwiftUI로 그린다.
struct MarkdownView: View {
    let source: String
    var baseSize: CGFloat = 13

    var body: some View {
        let blocks = MarkdownParser.parse(source)
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(MarkdownParser.inline(text))
                .font(.system(size: headingSize(level), weight: .semibold))
                .padding(.top, level <= 2 ? 10 : 6)
                .textSelection(.enabled)
        case .paragraph(let text):
            Text(MarkdownParser.inline(text))
                .font(.system(size: baseSize))
                .lineSpacing(5)
                .textSelection(.enabled)
        case .code(let language, let text):
            VStack(alignment: .leading, spacing: 0) {
                if let language {
                    Text(language)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 10)
                        .padding(.top, 6)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(text)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
        case .quote(let lines):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.border).frame(width: 3)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(MarkdownParser.inline(line))
                            .font(.system(size: baseSize))
                            .lineSpacing(4)
                            .foregroundStyle(Theme.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        case .list(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        if let checked = item.checked {
                            Image(systemName: checked ? "checkmark.square.fill" : "square")
                                .font(.system(size: 12))
                                .foregroundStyle(checked ? Theme.green : Theme.secondary)
                        } else if item.ordered, let number = item.number {
                            Text(verbatim: "\(number).")
                                .font(.system(size: baseSize))
                                .foregroundStyle(Theme.secondary)
                                .frame(minWidth: 16, alignment: .trailing)
                        } else {
                            Text(item.depth == 0 ? "•" : "◦")
                                .font(.system(size: baseSize))
                                .foregroundStyle(Theme.secondary)
                        }
                        Text(MarkdownParser.inline(item.text))
                            .font(.system(size: baseSize))
                            .lineSpacing(4)
                            .textSelection(.enabled)
                    }
                    .padding(.leading, CGFloat(item.depth) * 16)
                }
            }
        case .table(let header, let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                            Text(MarkdownParser.inline(cell))
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.codeBackground)
                        }
                    }
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                        GridRow {
                            ForEach(0..<header.count, id: \.self) { column in
                                Text(MarkdownParser.inline(column < row.count ? row[column] : ""))
                                    .font(.system(size: 12))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                        }
                        if rowIndex < rows.count - 1 { Divider() }
                    }
                }
                .frame(minWidth: 0)
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        case .rule:
            HairlineDivider().padding(.vertical, 2)
        case .image(let url, let alt):
            RemoteImageView(urlString: url, alt: alt)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: baseSize + 7
        case 2: baseSize + 4
        case 3: baseSize + 2
        default: baseSize + 1
        }
    }
}


/// 마크다운 속 이미지. 기본은 눌러야 받는다. 받으면 폭에 맞춰 보여 주고, 못 받으면 대체 글과 브라우저 열기 버튼을 둔다.
///
/// 저절로 받으면 그 주소로 요청이 나간다. 커밋 본문의 이미지로 누가 언제 봤는지 알 수 있고,
/// 저장소 파일에 숨은 지시가 Claude 답에 비밀 값을 담은 이미지 주소를 넣게 하면 그리는 순간 값이 밖으로 나간다.
struct RemoteImageView: View {
    @Environment(RepositoryStore.self) private var store: RepositoryStore?
    @AppStorage("loadsRemoteImages") private var loadsAutomatically = false
    let urlString: String
    let alt: String
    @State private var image: NSImage?
    @State private var failed = false
    @State private var requested = false

    private var host: String { URL(string: urlString)?.host() ?? urlString }

    var body: some View {
        Group {
            if !(loadsAutomatically || requested) {
                HStack(spacing: 8) {
                    Image(systemName: "photo")
                        .foregroundStyle(Theme.tertiary)
                    Text(alt.isEmpty ? "이미지" : alt)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Text(host)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                    Spacer()
                    Button("불러오기") { requested = true }
                        .buttonStyle(PillButtonStyle(compact: true))
                        .help("이 주소에서 이미지를 받습니다\n\(urlString)")
                }
                .padding(10)
                .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 8))
            } else if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: min(image.size.width, 720), alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if failed {
                HStack(spacing: 8) {
                    Image(systemName: "photo")
                        .foregroundStyle(Theme.tertiary)
                    Text(alt.isEmpty ? "이미지를 열지 못했습니다" : alt)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Spacer()
                    Button("브라우저에서 열기") { store?.openURL(urlString) }
                        .buttonStyle(PillButtonStyle(compact: true))
                }
                .padding(10)
                .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 8))
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(alt.isEmpty ? "이미지 받는 중…" : alt).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                .padding(8)
            }
        }
        .task(id: "\(urlString)|\(loadsAutomatically || requested)") {
            guard loadsAutomatically || requested else { return }
            failed = false
            image = await RemoteImageLoader.shared.image(for: urlString)
            failed = image == nil
        }
    }
}

/// 이미지를 받아 기억해 둔다. http·https 주소만 받는다. 인증 정보는 붙이지 않는다.
final class RemoteImageLoader: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = RemoteImageLoader()
    private let cache = NSCache<NSString, NSImage>()
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    func image(for urlString: String) async -> NSImage? {
        if let cached = cache.object(forKey: urlString as NSString) { return cached }
        guard let url = URL(string: urlString), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              !(http.mimeType ?? "").hasPrefix("text/html"),
              let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: urlString as NSString)
        return image
    }
}
