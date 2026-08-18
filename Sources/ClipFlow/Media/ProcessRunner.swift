import Darwin
import Foundation

/// ffprobe / ffmpeg 共用的进程边界。
///
/// 不经过 shell，文件名中的空格和特殊字符不会被再次解释；超时和 Swift Task 取消
/// 都会终止子进程，避免坏文件长期占住缩略图并发槽位。
enum ProcessRunner {

    struct Output: Sendable {
        let stdout: Data
        let stderr: Data
        let terminationStatus: Int32
    }

    enum RunnerError: Error, Sendable, CustomStringConvertible {
        case executableNotFound(String)
        case launchFailed(String)
        case timedOut
        case failed(status: Int32, message: String)

        var description: String {
            switch self {
            case .executableNotFound(let name):
                return "找不到 \(name)，请先通过 Homebrew 安装 ffmpeg"
            case .launchFailed(let message):
                return "进程启动失败：\(message)"
            case .timedOut:
                return "进程执行超时"
            case .failed(let status, let message):
                let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
                return detail.isEmpty ? "进程失败（状态码 \(status)）" : detail
            }
        }
    }

    static func executable(named name: String) throws -> URL {
        let overrideKey = name == "ffprobe" ? "CLIPFLOW_FFPROBE_PATH" : "CLIPFLOW_FFMPEG_PATH"
        let environment = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let override = environment[overrideKey], !override.isEmpty {
            candidates.append(override)
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ])
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/\(name)" })
        }
        if let path = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) {
            return URL(fileURLWithPath: path)
        }
        throw RunnerError.executableNotFound(name)
    }

    static func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> Output {
        try Task.checkCancellation()

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let state = State(process: process)
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation: continuation)
                process.terminationHandler = { process in
                    state.processEnded(status: process.terminationStatus)
                }

                do {
                    try process.run()
                    state.didLaunch()
                } catch {
                    state.launchFailed(error)
                    return
                }

                // 必须在进程运行期间持续排空两根管道。等退出后再读会在输出超过
                // pipe 缓冲区时形成「子进程等写入、父进程等退出」的死锁。
                DispatchQueue.global(qos: .utility).async {
                    let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    state.streamEnded(.stdout, data: data)
                }
                DispatchQueue.global(qos: .utility).async {
                    let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    state.streamEnded(.stderr, data: data)
                }

                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    state.timeout()
                }
            }
        } onCancel: {
            state.cancel()
        }
    }

    /// 锁只保护一次性 continuation 和进程状态，不在锁内等待子进程。
    private final class State: @unchecked Sendable {
        enum Stream { case stdout, stderr }

        private enum Completion {
            case running
            case cancelled
            case timedOut
            case finished
        }

        private let lock = NSLock()
        private let process: Process
        private var continuation: CheckedContinuation<Output, Error>?
        private var completion = Completion.running
        private var launched = false
        private var terminationStatus: Int32?
        private var stdout: Data?
        private var stderr: Data?

        init(process: Process) {
            self.process = process
        }

        func install(continuation: CheckedContinuation<Output, Error>) {
            lock.withLock { self.continuation = continuation }
        }

        func didLaunch() {
            let shouldStop = lock.withLock {
                launched = true
                return completion == .cancelled || completion == .timedOut
            }
            if shouldStop { stopProcess() }
        }

        func launchFailed(_ error: Error) {
            let continuation = lock.withLock { () -> CheckedContinuation<Output, Error>? in
                guard completion != .finished else { return nil }
                completion = .finished
                return takeContinuation()
            }
            continuation?.resume(throwing: RunnerError.launchFailed(error.localizedDescription))
        }

        func cancel() {
            let shouldStop = lock.withLock {
                guard completion == .running else { return false }
                completion = .cancelled
                return launched
            }
            if shouldStop { stopProcess() }
        }

        func timeout() {
            let shouldStop = lock.withLock {
                guard completion == .running else { return false }
                completion = .timedOut
                return launched
            }
            if shouldStop { stopProcess() }
        }

        func processEnded(status: Int32) {
            lock.withLock { terminationStatus = status }
            completeIfReady()
        }

        func streamEnded(_ stream: Stream, data: Data) {
            lock.withLock {
                switch stream {
                case .stdout: stdout = data
                case .stderr: stderr = data
                }
            }
            completeIfReady()
        }

        private func completeIfReady() {
            let result = lock.withLock {
                () -> (CheckedContinuation<Output, Error>?, Completion, Int32, Data, Data)? in
                guard completion != .finished,
                      let terminationStatus,
                      let stdout,
                      let stderr
                else { return nil }
                let reason = completion
                completion = .finished
                return (takeContinuation(), reason, terminationStatus, stdout, stderr)
            }
            guard let result else { return }
            guard let continuation = result.0 else { return }
            switch result.1 {
            case .cancelled:
                continuation.resume(throwing: CancellationError())
            case .timedOut:
                continuation.resume(throwing: RunnerError.timedOut)
            case .running:
                if result.2 == 0 {
                    continuation.resume(returning: Output(
                        stdout: result.3, stderr: result.4, terminationStatus: result.2
                    ))
                } else {
                    // 同样不能假设 UTF-8：RealMedia 这类老容器的元数据会出现在
                    // ffmpeg 的报错里，`String(data:encoding:.utf8)` 整段返回 nil，
                    // 失败原因就成了空字符串，落进索引后看不出到底为什么失败。
                    let message = String(decoding: result.4, as: UTF8.self)
                    continuation.resume(throwing: RunnerError.failed(
                        status: result.2, message: message
                    ))
                }
            case .finished:
                break
            }
        }

        private func takeContinuation() -> CheckedContinuation<Output, Error>? {
            defer { continuation = nil }
            return continuation
        }

        private func stopProcess() {
            guard process.isRunning else { return }
            let pid = process.processIdentifier
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) {
                if self.process.isRunning {
                    kill(pid, SIGKILL)
                }
            }
        }
    }
}
