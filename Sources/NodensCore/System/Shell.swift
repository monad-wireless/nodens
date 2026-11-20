import Foundation

/// Result of one child process.
public struct ProcessResult: Sendable, Equatable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool

    public init(status: Int32, stdout: String, stderr: String, timedOut: Bool) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }

    public var succeeded: Bool { status == 0 && !timedOut }
}

/// Runs child processes with a hard deadline.
///
/// A child that outlives its deadline gets SIGTERM, then SIGKILL, so a hung
/// engine or CLI never hangs the menu.
public enum Shell {
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async -> ProcessResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runBlocking(executable, arguments, timeout: timeout))
            }
        }
    }

    public static func runBlocking(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return ProcessResult(status: -1, stdout: "", stderr: "\(error)", timedOut: false)
        }

        // Drain both pipes while the child runs, so a full pipe cannot stall it.
        let collector = OutputCollector()
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global().async {
            collector.setOut(outPipe.fileHandleForReading.readDataToEndOfFile())
            drained.leave()
        }
        drained.enter()
        DispatchQueue.global().async {
            collector.setErr(errPipe.fileHandleForReading.readDataToEndOfFile())
            drained.leave()
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
        }
        _ = drained.wait(timeout: .now() + 2)

        let (out, err) = collector.snapshot()
        return ProcessResult(
            status: process.isRunning ? -1 : process.terminationStatus,
            stdout: String(decoding: out, as: UTF8.self),
            stderr: String(decoding: err, as: UTF8.self),
            timedOut: timedOut
        )
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func setOut(_ data: Data) {
        lock.lock()
        out = data
        lock.unlock()
    }

    func setErr(_ data: Data) {
        lock.lock()
        err = data
        lock.unlock()
    }

    func snapshot() -> (Data, Data) {
        lock.lock()
        defer { lock.unlock() }
        return (out, err)
    }
}

public extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
