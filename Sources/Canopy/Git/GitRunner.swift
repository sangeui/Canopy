import Foundation

/// git 명령 한 번을 실행한 결과.
struct GitOutput {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

/// git이 0이 아닌 코드로 끝났을 때 던지는 오류. stderr를 그대로 메시지로 쓴다.
struct GitError: LocalizedError {
    let arguments: [String]
    let exitCode: Int32
    let stderr: String

    var errorDescription: String? {
        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty {
            return "git \(arguments.joined(separator: " ")) 실패 (종료 코드 \(exitCode))"
        }
        return message
    }
}

/// git을 `Process`로 실행한다. 어느 git을 쓸지는 `GitInstallation`이 찾는다.
///
/// stdout과 stderr를 각각 다른 스레드에서 끝까지 읽는다. 한쪽만 읽으면
/// 다른 쪽 파이프가 가득 찼을 때 git이 멈춘다.
struct GitRunner {
    /// 실행할 git. 비우면 `GitInstallation`이 찾은 것을 쓴다.
    var executable: URL?

    func run(_ arguments: [String], in directory: URL, input: String? = nil, extraEnvironment: [String: String] = [:]) async throws -> GitOutput {
        // 찾은 git이 없으면 실행하지 않는다. `/usr/bin/git`을 그냥 부르면 명령줄 도구 설치 창이 뜬다.
        guard let executable = executable ?? GitInstallation.shared.executable else {
            throw GitError(arguments: arguments, exitCode: -1, stderr: "git을 찾지 못했습니다. 명령줄 도구나 Homebrew로 git을 설치하세요.")
        }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.currentDirectoryURL = directory

                var environment = ProcessInfo.processInfo.environment
                // 자격 증명을 묻는 프롬프트에서 멈추지 않고 바로 실패하게 한다.
                environment["GIT_TERMINAL_PROMPT"] = "0"
                // 메시지를 영어로 고정하고, status가 index.lock을 잡으려다 다른 명령과 부딪히지 않게 한다.
                environment["LC_ALL"] = "C"
                environment["GIT_OPTIONAL_LOCKS"] = "0"
                // 머지·리베이스 계속하기가 편집기를 열지 않고 기본 메시지로 끝나게 한다.
                environment["GIT_EDITOR"] = "true"
                // GUI 앱의 PATH는 짧아서 gh가 git을 못 찾을 수 있다.
                environment["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
                for (key, value) in extraEnvironment { environment[key] = value }
                process.environment = environment

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                let stdinPipe: Pipe?
                if input != nil {
                    stdinPipe = Pipe()
                    process.standardInput = stdinPipe
                } else {
                    stdinPipe = nil
                    process.standardInput = FileHandle.nullDevice
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                if let stdinPipe, let input, let data = input.data(using: .utf8) {
                    try? stdinPipe.fileHandleForWriting.write(contentsOf: data)
                    try? stdinPipe.fileHandleForWriting.close()
                }

                let group = DispatchGroup()
                var stdoutData = Data()
                var stderrData = Data()
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.wait()
                process.waitUntilExit()

                continuation.resume(returning: GitOutput(
                    stdout: String(decoding: stdoutData, as: UTF8.self),
                    stderr: String(decoding: stderrData, as: UTF8.self),
                    exitCode: process.terminationStatus
                ))
            }
        }
    }
}
