import Foundation

/// `git worktree list --porcelain` 출력을 읽는다. 항목은 빈 줄로 나뉜다.
enum WorktreeParser {
    static func parse(_ output: String) -> [Worktree] {
        var result: [Worktree] = []
        var path: String?
        var head: String?
        var branch: String?
        var isBare = false
        var isDetached = false
        var isLocked = false
        var isPrunable = false

        func flush() {
            guard let currentPath = path else { return }
            result.append(Worktree(
                path: currentPath,
                head: head,
                branch: branch,
                isBare: isBare,
                isDetached: isDetached,
                isMain: result.isEmpty,
                isLocked: isLocked,
                isPrunable: isPrunable
            ))
            path = nil
            head = nil
            branch = nil
            isBare = false
            isDetached = false
            isLocked = false
            isPrunable = false
        }

        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("worktree ") {
                flush()
                path = String(line.dropFirst(9))
            } else if line.hasPrefix("HEAD ") {
                head = String(line.dropFirst(5))
            } else if line.hasPrefix("branch ") {
                let ref = String(line.dropFirst(7))
                branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst(11)) : ref
            } else if line == "bare" {
                isBare = true
            } else if line == "detached" {
                isDetached = true
            } else if line.hasPrefix("locked") {
                isLocked = true
            } else if line.hasPrefix("prunable") {
                isPrunable = true
            }
        }
        flush()
        return result
    }
}
