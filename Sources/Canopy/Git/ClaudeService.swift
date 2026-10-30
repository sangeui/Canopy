import Foundation
import Observation

/// 어시스턴트 백엔드 엔진. 설정에서 Claude와 Antigravity 중 하나를 고른다.
enum AssistantEngine: String, CaseIterable, Identifiable, Sendable {
    case claude
    case antigravity

    var id: String { rawValue }

    static let defaultsKey = "assistantEngine"

    static var current: AssistantEngine {
        get {
            guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
                  let engine = AssistantEngine(rawValue: raw) else { return .claude }
            return engine
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }

    var title: String {
        switch self {
        case .claude: "Claude"
        case .antigravity: "Antigravity"
        }
    }

    var cliDisplayName: String {
        switch self {
        case .claude: "claude"
        case .antigravity: "agy / gemini"
        }
    }

    var productName: String {
        switch self {
        case .claude: "Claude Code"
        case .antigravity: "Antigravity CLI"
        }
    }

    var installCommand: String {
        switch self {
        case .claude: "curl -fsSL https://claude.ai/install.sh | bash"
        case .antigravity: "curl -fsSL https://antigravity.google/cli/install.sh | bash"
        }
    }

    var modelDefaultsKey: String {
        switch self {
        case .claude: "claudeModel"
        case .antigravity: "antigravityModel"
        }
    }

    var preferredModel: String {
        get { UserDefaults.standard.string(forKey: modelDefaultsKey) ?? "" }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: modelDefaultsKey) }
    }

    var models: [(id: String, title: String)] {
        switch self {
        case .claude:
            [
                ("", "CLI 기본값"),
                ("claude-fable-5-1", "Fable 5.1"),
                ("claude-opus-5-5", "Opus 5.5"),
                ("claude-sonnet-5-5", "Sonnet 5.5"),
                ("claude-haiku-5-5", "Haiku 5.5"),
            ]
        case .antigravity:
            [
                ("", "CLI 기본값"),
                ("gemini-2.5-pro", "Gemini 2.5 Pro"),
                ("gemini-2.5-flash", "Gemini 2.5 Flash"),
                ("gemini-2.5-flash-lite", "Gemini 2.5 Flash-Lite"),
            ]
        }
    }
}

/// 어시스턴트가 답하는 동안 오는 이벤트. 글 조각, 생각 시작/끝, 도구 호출과 결과.
enum ClaudeEvent: Equatable {
    case text(String)
    case thinkingStarted
    case thinkingStopped
    /// 도구 이름과 한 줄 요약 ("Read Apps/Foo.swift")
    case toolUse(name: String, summary: String)
    case toolResult(summary: String)
}

/// `claude` 또는 `agy`/`gemini`의 `stream-json`(NDJSON) 한 줄씩을 `ClaudeEvent`로 바꾼다.
struct AssistantStreamParser {
    var thinkingIndexes: Set<Int> = []
    var isAntigravityThinking = false
    var sawText = false
    var finalText = ""
    var errorText = ""

    mutating func consume(line: String) -> [ClaudeEvent] {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return [] }
        var events: [ClaudeEvent] = []

        func stopAntigravityThinkingIfNeeded() {
            if isAntigravityThinking {
                isAntigravityThinking = false
                events.append(.thinkingStopped)
            }
        }

        switch type {
        case "stream_event":
            guard let event = object["event"] as? [String: Any], let eventType = event["type"] as? String else { break }
            switch eventType {
            case "content_block_delta":
                if let delta = event["delta"] as? [String: Any] {
                    if delta["type"] as? String == "text_delta", let text = delta["text"] as? String {
                        sawText = true
                        events.append(.text(text))
                    } else if delta["type"] as? String == "thinking_delta", !thinkingIndexes.contains(-1), thinkingIndexes.isEmpty {
                        thinkingIndexes.insert(-1)
                        events.append(.thinkingStarted)
                    }
                }
            case "content_block_start":
                if let block = event["content_block"] as? [String: Any], block["type"] as? String == "thinking" {
                    thinkingIndexes.insert(event["index"] as? Int ?? -1)
                    events.append(.thinkingStarted)
                }
            case "content_block_stop":
                if let index = event["index"] as? Int, thinkingIndexes.remove(index) != nil {
                    events.append(.thinkingStopped)
                }
            default:
                break
            }

        case "thought", "thinking":
            if !isAntigravityThinking {
                isAntigravityThinking = true
                events.append(.thinkingStarted)
            }

        case "message":
            // Antigravity / Gemini CLI stream-json 메시지 이벤트
            let role = object["role"] as? String ?? "assistant"
            guard role == "assistant" || role == "model" else { break }
            if let content = object["content"] as? String, !content.isEmpty {
                stopAntigravityThinkingIfNeeded()
                let isDelta = object["delta"] as? Bool ?? true
                if isDelta {
                    sawText = true
                    events.append(.text(content))
                } else {
                    finalText = content
                    if !sawText {
                        sawText = true
                        events.append(.text(content))
                    }
                }
            }

        case "assistant":
            // Claude Code 도구 호출은 입력이 다 모인 뒤 이 메시지로 온다.
            guard let message = object["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] else { break }
            for block in content where block["type"] as? String == "tool_use" {
                let rawName = block["name"] as? String ?? "도구"
                let name = ClaudeService.normalizeToolName(rawName)
                let input = block["input"] as? [String: Any] ?? [:]
                events.append(.toolUse(name: name, summary: ClaudeService.summarize(tool: name, input: input)))
            }

        case "tool_use", "tool_call":
            // Antigravity / Gemini CLI 도구 호출 이벤트
            stopAntigravityThinkingIfNeeded()
            let rawName = (object["tool_name"] as? String)
                ?? (object["tool"] as? String)
                ?? (object["name"] as? String)
                ?? "도구"
            let name = ClaudeService.normalizeToolName(rawName)
            let input = (object["parameters"] as? [String: Any])
                ?? (object["arguments"] as? [String: Any])
                ?? (object["input"] as? [String: Any])
                ?? [:]
            events.append(.toolUse(name: name, summary: ClaudeService.summarize(tool: name, input: input)))

        case "user":
            guard let message = object["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] else { break }
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
                events.append(.toolResult(summary: lines == 0 ? "결과 없음" : "\(lines)줄"))
            }

        case "tool_result":
            // Antigravity / Gemini CLI 도구 결과 이벤트
            let status = (object["status"] as? String)?.lowercased()
            if status == "error" || status == "failed" {
                events.append(.toolResult(summary: "오류"))
            } else {
                let text = (object["output"] as? String)
                    ?? (object["content"] as? String)
                    ?? (object["result"] as? String)
                    ?? ""
                let lines = text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
                events.append(.toolResult(summary: lines == 0 ? "완료" : "\(lines)줄"))
            }

        case "error":
            if let message = (object["message"] as? String) ?? (object["error"] as? String), !message.isEmpty {
                errorText = message
            }

        case "result", "complete":
            stopAntigravityThinkingIfNeeded()
            if let text = (object["result"] as? String) ?? (object["output"] as? String) ?? (object["response"] as? String), !text.isEmpty {
                finalText = text
            }
            let isError = (object["is_error"] as? Bool == true)
                || ((object["status"] as? String)?.lowercased() == "error")
            if isError {
                if let errObj = object["error"] as? [String: Any], let msg = errObj["message"] as? String, !msg.isEmpty {
                    errorText = msg
                } else if let errStr = object["error"] as? String, !errStr.isEmpty {
                    errorText = errStr
                } else {
                    errorText = finalText.isEmpty ? "어시스턴트가 오류를 돌려줬습니다" : finalText
                }
            }

        default:
            break
        }
        return events
    }
}

struct ClaudeService {
    let executable: URL
    var engine: AssistantEngine = .current

    /// PATH와 흔한 설치 위치에서 선택된 엔진의 CLI 실행 파일을 찾는다. GUI 앱의 PATH는 짧아서 직접 뒤진다.
    static func locate(for engine: AssistantEngine = .current) -> URL? {
        #if CANOPY_DEV
        if let simulated = ProcessInfo.processInfo.environment["CANOPY_SIMULATE_MISSING"] {
            if engine == .claude && simulated.contains("claude") { return nil }
            if engine == .antigravity && (simulated.contains("agy") || simulated.contains("antigravity") || simulated.contains("gemini")) { return nil }
        }
        #endif
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates: [String] = []
        let nvm = "\(home)/.nvm/versions/node"
        let nvmVersions = (try? FileManager.default.contentsOfDirectory(atPath: nvm))?
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending } ?? []
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)

        switch engine {
        case .claude:
            candidates += [
                "\(home)/.local/bin/claude",
                "\(home)/.claude/local/bin/claude",
                "/opt/homebrew/bin/claude",
                "/usr/local/bin/claude",
                "\(home)/.npm-global/bin/claude",
                "\(home)/.volta/bin/claude",
            ]
            candidates += nvmVersions.map { "\(nvm)/\($0)/bin/claude" }
            candidates += pathDirs.map { "\($0)/claude" }

        case .antigravity:
            for binary in ["agy", "gemini"] {
                candidates += [
                    "\(home)/.local/bin/\(binary)",
                    "\(home)/.gemini/bin/\(binary)",
                    "\(home)/.gemini/antigravity-cli/bin/\(binary)",
                    "/Applications/Antigravity.app/Contents/Resources/app/bin/\(binary)",
                    "/Applications/Antigravity.app/Contents/Resources/bin/\(binary)",
                    "/opt/homebrew/bin/\(binary)",
                    "/usr/local/bin/\(binary)",
                    "\(home)/.npm-global/bin/\(binary)",
                    "\(home)/.volta/bin/\(binary)",
                ]
                candidates += nvmVersions.map { "\(nvm)/\($0)/bin/\(binary)" }
                candidates += pathDirs.map { "\($0)/\(binary)" }
            }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// CLI마다 다른 도구 이름을 Canopy 표준 이름(`Read`, `Grep`, `Glob`, `Bash`)으로 맞춘다.
    static func normalizeToolName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "read", "read_file", "readfile", "view_file", "read_many_files":
            return "Read"
        case "grep", "grep_search", "search_file_content", "ripgrep":
            return "Grep"
        case "glob", "find_by_name", "list_directory", "read_folder", "ls":
            return "Glob"
        case "bash", "run_shell_command", "run_command", "shell", "execute_command":
            return "Bash"
        default:
            return raw
        }
    }

    /// "Read Apps/Foo.swift", "Grep CardMetrics in Apps/"처럼 도구 호출을 한 줄로.
    static func summarize(tool: String, input: [String: Any]) -> String {
        switch tool {
        case "Read":
            return (input["file_path"] as? String)
                ?? (input["path"] as? String)
                ?? (input["target_file"] as? String)
                ?? (input["TargetFile"] as? String)
                ?? "파일"
        case "Glob":
            let first = (input["pattern"] as? String) ?? (input["Pattern"] as? String)
            let second = (input["path"] as? String) ?? (input["dir_path"] as? String) ?? (input["SearchDirectory"] as? String)
            let joined = [first, second].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " in ")
            return joined.isEmpty ? "폴더" : joined
        case "Grep":
            let first = (input["pattern"] as? String) ?? (input["query"] as? String) ?? (input["Query"] as? String)
            let second = (input["path"] as? String) ?? (input["dir_path"] as? String) ?? (input[" include"] as? String)
            let joined = [first, second].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " in ")
            return joined.isEmpty ? "검색" : joined
        case "Bash":
            let raw = (input["command"] as? String) ?? (input["CommandLine"] as? String) ?? ""
            let command = raw.split(separator: "\n").first.map(String.init) ?? ""
            return command.count > 90 ? String(command.prefix(90)) + "…" : command
        default:
            let first = input.values.compactMap { $0 as? String }.first ?? ""
            return first.count > 80 ? String(first.prefix(80)) + "…" : first
        }
    }

    /// 설정에서 고른 모델. 비어 있으면 CLI 기본값.
    static var preferredModel: String {
        get { AssistantEngine.current.preferredModel }
        set { AssistantEngine.current.preferredModel = newValue }
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
    func stream(prompt: String, context: String?, directory: URL, extraTools: [String] = [], projectSettings: Bool, maxTurns: Int = 6) -> AsyncThrowingStream<ClaudeEvent, Error> {
        let activeEngine = engine
        let binaryName = executable.lastPathComponent
        return AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = executable

            var arguments: [String] = []
            switch activeEngine {
            case .claude:
                var tools = ["Read", "Grep", "Glob"]
                for tool in extraTools where !tools.contains(tool) { tools.append(tool) }
                let builtIn = tools.filter { !$0.hasPrefix("mcp__") }
                arguments = [
                    "-p",
                    "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                    "--max-turns", String(maxTurns),
                    "--tools",
                ] + builtIn + ["--allowedTools"] + tools
                if !projectSettings {
                    arguments += ["--setting-sources", "user", "--strict-mcp-config"]
                }
                let model = activeEngine.preferredModel
                if !model.isEmpty { arguments += ["--model", model] }
                arguments += ["--", prompt]

            case .antigravity:
                let readOnlyNotice = extraTools.isEmpty
                    ? "\n\n[시스템 제약: 읽기 전용 모드입니다. 파일을 수정·생성·삭제하거나 저장소 상태를 바꾸는 명령을 실행하지 마십시오.]"
                    : ""
                let effectivePrompt = prompt + readOnlyNotice
                arguments = ["--output-format", "stream-json"]
                if binaryName == "gemini" {
                    if extraTools.isEmpty {
                        arguments += ["--approval-mode", "plan"]
                    } else {
                        arguments += ["--sandbox"]
                    }
                } else {
                    arguments += ["--sandbox"]
                }
                let model = activeEngine.preferredModel
                if !model.isEmpty { arguments += ["--model", model] }
                arguments += ["-p", effectivePrompt]
            }

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
            var parser = AssistantStreamParser()
            let lock = NSLock()

            func feed(line: String) {
                for event in parser.consume(line: line) {
                    continuation.yield(event)
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
                    feed(line: line)
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
                if !buffer.isEmpty { feed(line: String(decoding: buffer, as: UTF8.self)); buffer.removeAll() }
                let stderrText = String(decoding: stderrData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let errorText = parser.errorText
                let sawText = parser.sawText
                let finalText = parser.finalText
                lock.unlock()
                if !errorText.isEmpty {
                    continuation.finish(throwing: ClaudeError.failed(errorText))
                } else if process.terminationStatus != 0, process.terminationReason == .exit {
                    continuation.finish(throwing: ClaudeError.failed(stderrText.isEmpty ? "\(binaryName) 종료 코드 \(process.terminationStatus)" : stderrText))
                } else {
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

/// 설정의 어시스턴트 탭이 보는 상태. 선택된 엔진(Claude / Antigravity), CLI 위치, 버전, 로그인 여부와 계정.
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

    var engine: AssistantEngine = AssistantEngine.current {
        didSet {
            guard engine != oldValue else { return }
            AssistantEngine.current = engine
            executable = ClaudeService.locate(for: engine)
            version = nil
            status = nil
            lastError = nil
            checkedAt = nil
            Task { @MainActor in await refresh() }
        }
    }

    private(set) var executable: URL? = ClaudeService.locate(for: AssistantEngine.current)
    private(set) var version: String?
    private(set) var status: Status?
    private(set) var isChecking = false
    private(set) var checkedAt: Date?
    private(set) var lastError: String?

    var isInstalled: Bool { executable != nil }

    static var installCommand: String { AssistantEngine.current.installCommand }

    /// CLI 위치만 다시 찾는다. 파일이 있는지만 보니 가볍다. 앱으로 돌아올 때마다 부른다.
    @MainActor
    func relocate() {
        let found = ClaudeService.locate(for: engine)
        guard found != executable else { return }
        executable = found
        Task { await refresh() }
    }

    /// 설정에서 고른 터미널에서 공식 설치 명령을 돌린다.
    func openInstallInTerminal() {
        TerminalApp.preferred.runCommand(engine.installCommand)
    }

    /// CLI를 다시 찾고 버전과 로그인 상태를 읽는다.
    @MainActor
    func refresh() async {
        let targetEngine = engine
        isChecking = true
        defer { isChecking = false }
        executable = ClaudeService.locate(for: targetEngine)
        guard let executable else {
            version = nil
            status = nil
            lastError = nil
            checkedAt = Date()
            return
        }
        let service = ClaudeService(executable: executable, engine: targetEngine)
        switch targetEngine {
        case .claude:
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

        case .antigravity:
            let versionRaw = await service.output(["--version"])
            version = versionRaw?.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init)
            status = Self.readAntigravityAuthStatus()
            lastError = nil
        }
        checkedAt = Date()
    }

    /// `~/.gemini` 자격 증명 파일과 환경 변수로 Antigravity / Gemini CLI 인증 상태를 판별한다.
    static func readAntigravityAuthStatus(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> Status {
        let env = ProcessInfo.processInfo.environment
        if let key = env["GEMINI_API_KEY"] ?? env["GOOGLE_API_KEY"], !key.isEmpty {
            return Status(loggedIn: true, email: nil, organization: nil, plan: nil, method: "API 키 (환경 변수)")
        }
        var activeEmail: String?
        let accountsPath = "\(home)/.gemini/google_accounts.json"
        if let data = FileManager.default.contents(atPath: accountsPath),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let active = obj["active"] as? String, !active.isEmpty {
                activeEmail = active
            } else if let accounts = obj["accounts"] as? [[String: Any]],
                      let first = accounts.first?["email"] as? String, !first.isEmpty {
                activeEmail = first
            }
        }
        let credentialFiles = [
            "\(home)/.gemini/oauth_creds.json",
            "\(home)/.gemini/antigravity-cli/credentials.json",
            "\(home)/.gemini/credentials.json",
            "\(home)/.config/gcloud/application_default_credentials.json",
        ]
        let hasCredFile = credentialFiles.contains { FileManager.default.fileExists(atPath: $0) }
        if let activeEmail {
            return Status(loggedIn: true, email: activeEmail, organization: nil, plan: nil, method: "Google OAuth")
        }
        if hasCredFile {
            return Status(loggedIn: true, email: nil, organization: nil, plan: nil, method: "Google OAuth")
        }
        for settingsPath in ["\(home)/.gemini/antigravity-cli/settings.json", "\(home)/.gemini/settings.json"] {
            if let data = FileManager.default.contents(atPath: settingsPath),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let selected = obj["selectedAuthType"] as? String, !selected.isEmpty {
                    return Status(loggedIn: true, email: nil, organization: nil, plan: nil, method: selected)
                }
                if let security = obj["security"] as? [String: Any],
                   let auth = security["auth"] as? [String: Any],
                   let selected = auth["selectedType"] as? String, !selected.isEmpty {
                    return Status(loggedIn: true, email: nil, organization: nil, plan: nil, method: selected)
                }
            }
        }
        return Status(loggedIn: false)
    }

    /// 로그인은 브라우저가 열리는 대화형 과정이라 터미널에서 한다.
    func openLoginInTerminal() {
        switch engine {
        case .claude:
            let command = (executable?.path).map { "'\($0)'" } ?? "claude"
            TerminalApp.preferred.runCommand(command + " auth login")
        case .antigravity:
            let command = (executable?.path).map { "'\($0)'" } ?? "agy"
            TerminalApp.preferred.runCommand(command)
        }
    }

    @MainActor
    func logout() async {
        switch engine {
        case .claude:
            guard let executable else { return }
            _ = await ClaudeService(executable: executable, engine: .claude).output(["auth", "logout"])
        case .antigravity:
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            for path in [
                "\(home)/.gemini/oauth_creds.json",
                "\(home)/.gemini/google_accounts.json",
                "\(home)/.gemini/antigravity-cli/credentials.json",
            ] {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        await refresh()
    }
}

enum ClaudeError: LocalizedError {
    case notInstalled(AssistantEngine)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let engine):
            "\(engine.cliDisplayName) CLI를 찾지 못했습니다. \(engine.productName)를 설치하면 여기서 바로 쓸 수 있습니다."
        case .failed(let text):
            text
        }
    }
}
