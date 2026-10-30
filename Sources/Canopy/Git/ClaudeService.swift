import Foundation

/// `claude` CLI(Claude Code)를 돌려 답을 받는다. 글자가 오는 대로 흘려보낸다.
/// 도구는 읽기(Read·Grep·Glob)만 허용해서 저장소를 건드리지 않는다.
/// Claude가 답하는 동안 오는 것. 글 조각, 생각 시작/끝, 도구 호출과 결과.
enum ClaudeEvent {
    case text(String)
    case thinkingStarted
    case thinkingStopped
    /// 도구 이름과 한 줄 요약 ("Read Apps/Foo.swift")
    case toolUse(name: String, summary: String)
    case toolResult(summary: String)
}

struct ClaudeService {
    let executable: URL

    /// PATH와 흔한 설치 위치에서 `claude`를 찾는다. GUI 앱의 PATH는 짧아서 직접 뒤진다.
    static func locate() -> URL? {
        #if CANOPY_DEV
        // 화면 확인용: CANOPY_SIMULATE_MISSING=claude
        if ProcessInfo.processInfo.environment["CANOPY_SIMULATE_MISSING"]?.contains("claude") == true { return nil }
        #endif
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.volta/bin/claude",
        ]
        // nvm으로 깐 node마다 bin이 따로 있다. 최신 버전부터 본다.
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            candidates += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.map { "\(nvm)/\($0)/bin/claude" }
        }
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            candidates.append("\(directory)/claude")
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// "Read Apps/Foo.swift", "Grep CardMetrics in Apps/"처럼 도구 호출을 한 줄로.
    static func summarize(tool: String, input: [String: Any]) -> String {
        switch tool {
        case "Read": return input["file_path"] as? String ?? "파일"
        case "Glob": return [input["pattern"] as? String, input["path"] as? String].compactMap { $0 }.joined(separator: " in ")
        case "Grep": return [input["pattern"] as? String, input["path"] as? String].compactMap { $0 }.joined(separator: " in ")
        case "Bash":
            let command = (input["command"] as? String ?? "").split(separator: "\n").first.map(String.init) ?? ""
            return command.count > 90 ? String(command.prefix(90)) + "…" : command
        default:
            let first = input.values.compactMap { $0 as? String }.first ?? ""
            return first.count > 80 ? String(first.prefix(80)) + "…" : first
        }
    }

    /// 설정에서 고른 모델. 비어 있으면 CLI 기본값.
    static var preferredModel: String {
        get { UserDefaults.standard.string(forKey: "claudeModel") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "claudeModel") }
    }

    /// 짧은 명령을 돌려 stdout을 받는다. 버전·로그인 상태 확인용.
    func output(_ arguments: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", executable.deletingLastPathComponent().path, environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
                process.environment = environment
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch { continuation.resume(returning: nil); return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }

    /// 프롬프트를 보내고 답을 조각으로 받는다. `context`는 stdin으로 넣어 diff 같은 긴 글을 붙인다.
    /// - Parameters:
    ///   - extraTools: 스킬이 머리말에 적어 둔 도구. 그 스킬을 부를 때만 더한다. 기본은 Read·Grep·Glob뿐이다.
    ///   - projectSettings: 저장소의 `.claude` 설정·`.mcp.json`·스킬을 쓸지. `-p`는 폴더 신뢰 확인을 건너뛰므로
    ///     신뢰하지 않은 저장소에서는 사용자 설정만 읽는다.
    func stream(prompt: String, context: String?, directory: URL, extraTools: [String] = [], projectSettings: Bool, maxTurns: Int = 6) -> AsyncThrowingStream<ClaudeEvent, Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = executable
            var tools = ["Read", "Grep", "Glob"]
            for tool in extraTools where !tools.contains(tool) { tools.append(tool) }
            // --tools가 쓸 수 있는 도구 자체를 정한다. --allowedTools는 묻지 않고 허락할 도구일 뿐이라
            // 그것만 주면 사용자 설정에 따라 Bash 같은 다른 도구도 쓰였다. MCP 도구는 --tools에 넣지 않는다.
            let builtIn = tools.filter { !$0.hasPrefix("mcp__") }
            var arguments = [
                "-p",
                "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                "--max-turns", String(maxTurns),
                "--tools",
            ] + builtIn + ["--allowedTools"] + tools
            if !projectSettings {
                arguments += ["--setting-sources", "user", "--strict-mcp-config"]
            }
            let model = Self.preferredModel
            if !model.isEmpty { arguments += ["--model", model] }
            // 프롬프트가 "-"로 시작해도 옵션으로 읽히지 않게 맨 뒤에 둔다
            arguments += ["--", prompt]
            process.arguments = arguments
            process.currentDirectoryURL = directory
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", executable.deletingLastPathComponent().path, environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
            process.environment = environment

            let stdout = Pipe()
            let stderr = Pipe()
            let stdin = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.standardInput = stdin

            var buffer = Data()
            var thinkingIndexes: Set<Int> = []
            var sawText = false
            var finalText = ""
            var errorText = ""
            let lock = NSLock()

            func consume(line: String) {
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let type = object["type"] as? String else { return }
                switch type {
                case "stream_event":
                    guard let event = object["event"] as? [String: Any], let eventType = event["type"] as? String else { return }
                    switch eventType {
                    case "content_block_delta":
                        if let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta", let text = delta["text"] as? String {
                            sawText = true
                            continuation.yield(.text(text))
                        }
                    case "content_block_start":
                        if let block = event["content_block"] as? [String: Any], block["type"] as? String == "thinking" {
                            thinkingIndexes.insert(event["index"] as? Int ?? -1)
                            continuation.yield(.thinkingStarted)
                        }
                    case "content_block_stop":
                        if let index = event["index"] as? Int, thinkingIndexes.remove(index) != nil {
                            continuation.yield(.thinkingStopped)
                        }
                    default:
                        break
                    }
                case "assistant":
                    // 도구 호출은 입력이 다 모인 뒤 이 메시지로 온다.
                    guard let message = object["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] else { return }
                    for block in content where block["type"] as? String == "tool_use" {
                        let name = block["name"] as? String ?? "도구"
                        let input = block["input"] as? [String: Any] ?? [:]
                        continuation.yield(.toolUse(name: name, summary: Self.summarize(tool: name, input: input)))
                    }
                case "user":
                    guard let message = object["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] else { return }
                    for block in content where block["type"] as? String == "tool_result" {
                        let text: String
                        if let string = block["content"] as? String {
                            text = string
                        } else if let parts = block["content"] as? [[String: Any]] {
                            text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
                        } else {
                            text = ""
                        }
                        let lines = text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
                        continuation.yield(.toolResult(summary: lines == 0 ? "결과 없음" : "\(lines)줄"))
                    }
                case "result":
                    if let text = object["result"] as? String { finalText = text }
                    if object["is_error"] as? Bool == true { errorText = finalText.isEmpty ? "Claude가 오류를 돌려줬습니다" : finalText }
                default:
                    break
                }
            }

            stdout.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                lock.lock(); defer { lock.unlock() }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    consume(line: line)
                }
            }
            var stderrData = Data()
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                lock.lock(); stderrData.append(chunk); lock.unlock()
            }

            process.terminationHandler = { process in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                lock.lock()
                if !buffer.isEmpty { consume(line: String(decoding: buffer, as: UTF8.self)); buffer.removeAll() }
                let stderrText = String(decoding: stderrData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                lock.unlock()
                if !errorText.isEmpty {
                    continuation.finish(throwing: ClaudeError.failed(errorText))
                } else if process.terminationStatus != 0, process.terminationReason == .exit {
                    continuation.finish(throwing: ClaudeError.failed(stderrText.isEmpty ? "claude 종료 코드 \(process.terminationStatus)" : stderrText))
                } else {
                    // 조각이 하나도 안 왔으면(스트리밍이 꺼진 환경) 최종 글이라도 보낸다.
                    if !sawText, !finalText.isEmpty { continuation.yield(.text(finalText)) }
                    continuation.finish()
                }
            }

            continuation.onTermination = { _ in
                if process.isRunning { process.terminate() }
            }

            do {
                try process.run()
            } catch {
                continuation.finish(throwing: error)
                return
            }
            if let context, let data = context.data(using: .utf8) {
                try? stdin.fileHandleForWriting.write(contentsOf: data)
            }
            try? stdin.fileHandleForWriting.close()
        }
    }
}

/// 설정의 Claude 탭이 보는 상태. CLI 위치, 버전, 로그인 여부와 계정.
@Observable
final class ClaudeAccount: @unchecked Sendable {
    static let shared = ClaudeAccount()

    struct Status: Equatable {
        var loggedIn = false
        var email: String?
        var organization: String?
        var plan: String?
        var method: String?
    }

    private(set) var executable: URL? = ClaudeService.locate()
    private(set) var version: String?
    private(set) var status: Status?
    private(set) var isChecking = false
    private(set) var checkedAt: Date?
    private(set) var lastError: String?

    var isInstalled: Bool { executable != nil }

    /// 공식 설치 명령 (code.claude.com/docs/en/quickstart)
    static let installCommand = "curl -fsSL https://claude.ai/install.sh | bash"

    /// CLI 위치만 다시 찾는다. 파일이 있는지만 보니 가볍다. 앱으로 돌아올 때마다 부른다.
    @MainActor
    func relocate() {
        let found = ClaudeService.locate()
        guard found != executable else { return }
        executable = found
        // 새로 설치했거나 지웠으면 버전과 로그인 상태도 다시 읽는다
        Task { await refresh() }
    }

    /// 설정에서 고른 터미널에서 공식 설치 명령을 돌린다.
    func openInstallInTerminal() {
        TerminalApp.preferred.runCommand(Self.installCommand)
    }

    /// CLI를 다시 찾고 버전과 로그인 상태를 읽는다.
    @MainActor
    func refresh() async {
        isChecking = true
        defer { isChecking = false }
        executable = ClaudeService.locate()
        guard let executable else {
            version = nil
            status = nil
            lastError = nil
            checkedAt = Date()
            return
        }
        let service = ClaudeService(executable: executable)
        async let versionText = service.output(["--version"])
        async let statusText = service.output(["auth", "status", "--json"])
        version = (await versionText)?.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").first.map(String.init)
        if let text = await statusText, let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            status = Status(
                loggedIn: object["loggedIn"] as? Bool ?? false,
                email: object["email"] as? String,
                organization: object["orgName"] as? String,
                plan: object["subscriptionType"] as? String,
                method: object["authMethod"] as? String
            )
            lastError = nil
        } else {
            status = nil
            lastError = "로그인 상태를 읽지 못했습니다"
        }
        checkedAt = Date()
    }

    /// 로그인은 브라우저가 열리는 대화형 과정이라 터미널에서 한다.
    /// 설정에서 고른 터미널에서 `claude auth login`을 돌린다.
    func openLoginInTerminal() {
        let command = (executable?.path).map { "'\($0)'" } ?? "claude"
        TerminalApp.preferred.runCommand(command + " auth login")
    }

    @MainActor
    func logout() async {
        guard let executable else { return }
        _ = await ClaudeService(executable: executable).output(["auth", "logout"])
        await refresh()
    }
}

enum ClaudeError: LocalizedError {
    case notInstalled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: "claude CLI를 찾지 못했습니다. Claude Code를 설치하면 여기서 바로 쓸 수 있습니다."
        case .failed(let text): text
        }
    }
}
