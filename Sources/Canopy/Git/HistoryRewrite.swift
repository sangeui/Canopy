import Foundation

/// 커밋 정리(인터랙티브 리베이스)에서 커밋 하나에 할 일
struct RewriteItem: Identifiable, Equatable {
    enum Action: Equatable {
        case keep
        /// 메시지를 이것으로 바꾼다
        case reword(String)
        /// 바로 앞(더 오래된) 커밋에 합친다. 메시지는 앞 커밋 것을 쓴다.
        case fixup
        case drop
    }

    let commit: Commit
    var action: Action = .keep

    var id: String { commit.hash }

    var isRewording: Bool {
        if case .reword = action { return true }
        return false
    }
}

/// 정리할 구간과 미리 알릴 것
struct RewriteContext: Equatable {
    /// 오래된 것부터
    let commits: [Commit]
    /// 가장 오래된 커밋의 부모. 맨 처음 커밋부터면 nil
    let base: String?
    /// 이미 푸시한 커밋 수. 다시 쓰면 강제 푸시가 필요하다.
    let pushedCount: Int
    /// 다시 쓰는 커밋을 가리키는 다른 로컬 브랜치. 그 브랜치는 옛 커밋에 남는다.
    let otherBranches: [String]
    /// 커밋마다 원래 메시지 그대로(`%B`). `%s`는 첫 문단의 여러 줄을 한 줄로 합쳐 버린다.
    var messages: [String: String] = [:]

    func message(of commit: Commit) -> String {
        messages[commit.hash]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? (commit.body.isEmpty ? commit.subject : commit.subject + "\n\n" + commit.body)
    }

    var notes: [String] {
        var notes: [String] = []
        if pushedCount > 0 { notes.append("이미 푸시한 커밋 \(pushedCount)개를 다시 씁니다. 다음 푸시는 강제 푸시가 필요합니다") }
        if !otherBranches.isEmpty { notes.append("\(otherBranches.joined(separator: ", "))은(는) 옛 커밋에 그대로 남습니다") }
        return notes
    }
}

enum HistoryRewrite {
    /// `git rebase -i`에 넣을 할 일 목록. `items`는 오래된 것부터.
    /// 메시지를 바꾸는 커밋(합친 묶음이면 그 묶음의 마지막) 뒤에 `exec git commit --amend -F <파일>`을 둔다.
    /// `reword` 명령을 쓰지 않는 까닭: Canopy는 편집기를 띄우지 않으므로(GIT_EDITOR=true) 옛 메시지가 그대로 남는다.
    /// 묶음(남길 커밋 하나와 거기 합칠 커밋들)마다 머리 앞에서 HEAD를 적어 두고, 머리가 정말 들어갔는지 본다.
    /// 머리가 충돌로 건너뛰어졌거나 비어서 빠지면 HEAD가 그대로다. 그대로 두면 뒤의 `fixup`이 구간 밖 기준 커밋
    /// (이미 푸시했을 수 있는)에 합쳐지고 메시지까지 바뀐다. 그래서 그때는 남은 할 일에서 그 묶음의 `fixup`을 `pick`으로
    /// 바꿔 따로 남기고(git은 exec가 할 일 파일을 고치면 다시 읽는다), 메시지도 바꾸지 않는다.
    /// - Parameters:
    ///   - hasBase: 맨 처음 커밋부터 다시 쓰는 것(`--root`)이 아닌지. 그때는 모두 빼도 기준 커밋이 남는다.
    ///   - messageFile: 커밋 해시를 받아 그 커밋의 새 메시지를 적은 파일 경로를 돌려준다
    ///   - markFile: 커밋 해시를 받아 그 묶음 앞의 HEAD를 적을 파일 경로를 돌려준다. 뒤에 `.skip`을 붙인 파일도 쓴다.
    static func todo(_ items: [RewriteItem], hasBase: Bool, messageFile: (String) -> String, markFile: (String) -> String) throws -> [String] {
        if let first = items.first(where: { $0.action != .drop }), first.action == .fixup {
            throw RewriteError("가장 오래된 커밋은 앞 커밋에 합칠 수 없습니다. 합칠 커밋 아래에 남길 커밋을 두세요")
        }
        if !hasBase, !items.contains(where: { $0.action != .drop }) {
            throw RewriteError("맨 처음 커밋까지 모두 삭제할 수는 없습니다")
        }
        for item in items {
            if case .reword(let message) = item.action, message.trimmed.isEmpty {
                throw RewriteError("\(item.commit.shortHash)의 새 메시지가 비어 있습니다")
            }
        }
        var lines: [String] = []
        var index = 0
        while index < items.count {
            let item = items[index]
            let hash = item.commit.hash
            switch item.action {
            case .drop:
                lines.append("drop \(hash)")
                index += 1
            case .fixup:
                // 머리 뒤에서 함께 처리하므로 여기 오지 않는다
                index += 1
            case .keep, .reword:
                // 이 머리에 붙는 커밋: 다음 남길 커밋 전까지의 fixup. 사이의 drop은 그대로 둔다.
                var tail: [RewriteItem] = []
                var next = index + 1
                while next < items.count, items[next].action == .fixup || items[next].action == .drop {
                    tail.append(items[next])
                    next += 1
                }
                let fixups = tail.filter { $0.action == .fixup }.map(\.commit.hash)
                let rewording: Bool = { if case .reword = item.action { return true } else { return false } }()
                guard rewording || !fixups.isEmpty else {
                    lines.append("pick \(hash)")
                    lines += tail.map { "drop \($0.commit.hash)" }
                    index = next
                    continue
                }
                let mark = shellQuote(markFile(hash))
                let skip = shellQuote(markFile(hash) + ".skip")
                lines.append("exec git rev-parse -q --verify HEAD > \(mark); rm -f \(skip); true")
                lines.append("pick \(hash)")
                if !fixups.isEmpty {
                    let todoPath = "\"$(git rev-parse --git-path rebase-merge/git-rebase-todo)\""
                    let edits = fixups.map { "-e 's/^fixup \($0).*/pick \($0)/'" }.joined(separator: " ")
                    lines.append("exec if [ \"$(git rev-parse -q --verify HEAD)\" = \"$(cat \(mark))\" ]; then touch \(skip); sed -i '' \(edits) \(todoPath); fi")
                }
                for other in tail {
                    lines.append((other.action == .fixup ? "fixup " : "drop ") + other.commit.hash)
                }
                if rewording {
                    // 훅은 끈다. prepare-commit-msg처럼 --no-verify로 안 꺼지는 훅이 실패하면 메시지가 조용히 빠진다.
                    let amend = "git -c core.hooksPath=/dev/null commit --amend --no-verify --allow-empty --cleanup=verbatim -q -F " + shellQuote(messageFile(hash))
                    lines.append("exec if [ ! -e \(skip) ] && [ \"$(git rev-parse -q --verify HEAD)\" != \"$(cat \(mark))\" ]; then \(amend); fi")
                }
                index = next
            }
        }
        return lines
    }

    /// 작은따옴표로 감싼다. 경로에 공백이나 작은따옴표가 있어도 셸이 한 덩어리로 읽는다.
    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct RewriteError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
