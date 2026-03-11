import Darwin
import Foundation
import OrchardCore

struct TaskExecutionResult: Sendable {
    var status: TaskStatus
    var exitCode: Int?
    var summary: String
}

final class TaskProcessController: @unchecked Sendable {
    private enum StreamKind {
        case stdout
        case stderr
    }

    private let task: TaskRecord
    private let runtimeDirectory: URL
    private let launchSpec: TaskLaunchSpec
    private let lineHandler: @Sendable (String) -> Void
    private let completion: @Sendable (TaskExecutionResult) -> Void
    private let queue: DispatchQueue
    private let combinedLogHandle: FileHandle
    private let stdoutAccumulator = StreamAccumulator()
    private let stderrAccumulator = StreamAccumulator()
    private var process: Process?
    private var stopRequested = false

    init(
        task: TaskRecord,
        runtimeDirectory: URL,
        launchSpec: TaskLaunchSpec,
        lineHandler: @escaping @Sendable (String) -> Void,
        completion: @escaping @Sendable (TaskExecutionResult) -> Void
    ) throws {
        self.task = task
        self.runtimeDirectory = runtimeDirectory
        self.launchSpec = launchSpec
        self.lineHandler = lineHandler
        self.completion = completion
        self.queue = DispatchQueue(label: "orchard.task.\(task.id)")

        try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true, attributes: nil)
        let logURL = runtimeDirectory.appendingPathComponent("combined.log", isDirectory: false)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        self.combinedLogHandle = try FileHandle(forWritingTo: logURL)

        let taskData = try OrchardJSON.encoder.encode(task)
        try taskData.write(to: runtimeDirectory.appendingPathComponent("task.json", isDirectory: false), options: .atomic)
    }

    deinit {
        try? combinedLogHandle.close()
    }

    func start() throws {
        let stdout = Pipe()
        let stderr = Pipe()
        let process = Process()
        process.executableURL = launchSpec.executableURL
        process.arguments = launchSpec.arguments
        process.environment = launchSpec.environment
        process.currentDirectoryURL = launchSpec.currentDirectoryURL
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.queue.async { [weak self] in
                self?.handleData(data, kind: .stdout)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.queue.async { [weak self] in
                self?.handleData(data, kind: .stderr)
            }
        }

        process.terminationHandler = { [weak self] process in
            self?.queue.async { [weak self] in
                self?.handleTermination(process)
            }
        }

        try process.run()
        self.process = process
        _ = setpgid(process.processIdentifier, process.processIdentifier)
    }

    func requestStop() {
        queue.async { [weak self] in
            guard let self, let process = self.process else { return }
            self.stopRequested = true
            let pid = process.processIdentifier
            if kill(-pid, SIGTERM) != 0 {
                _ = kill(pid, SIGTERM)
            }
            self.queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, let process = self.process, process.isRunning else { return }
                let pid = process.processIdentifier
                if kill(-pid, SIGKILL) != 0 {
                    _ = kill(pid, SIGKILL)
                }
            }
        }
    }

    private func handleData(_ data: Data, kind: StreamKind) {
        let accumulator = switch kind {
        case .stdout:
            stdoutAccumulator
        case .stderr:
            stderrAccumulator
        }
        if data.isEmpty {
            emit(lines: accumulator.flushRemainder())
            return
        }
        emit(lines: accumulator.consume(data))
    }

    private func emit(lines: [String]) {
        guard !lines.isEmpty else { return }
        for line in lines {
            let normalized = String(line.prefix(4096))
            if let data = (normalized + "\n").data(using: .utf8) {
                try? combinedLogHandle.write(contentsOf: data)
            }
            lineHandler(normalized)
        }
    }

    private func handleTermination(_ process: Process) {
        emit(lines: stdoutAccumulator.flushRemainder())
        emit(lines: stderrAccumulator.flushRemainder())
        try? combinedLogHandle.synchronize()

        let status: TaskStatus
        let summary: String
        let exitCode = Int(process.terminationStatus)

        if stopRequested {
            status = .cancelled
            summary = "Task cancelled after stop request."
        } else if process.terminationReason == .exit && process.terminationStatus == 0 {
            status = .succeeded
            summary = "Task completed successfully."
        } else {
            status = .failed
            if process.terminationReason == .uncaughtSignal {
                summary = "Task terminated by signal \(process.terminationStatus)."
            } else {
                summary = "Task exited with code \(process.terminationStatus)."
            }
        }

        completion(TaskExecutionResult(status: status, exitCode: exitCode, summary: summary))
    }
}

private final class StreamAccumulator: @unchecked Sendable {
    private var buffer = Data()

    func consume(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []

        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.prefix(upTo: newline)
            lines.append(String(decoding: lineData, as: UTF8.self))
            buffer.removeSubrange(...newline)
        }

        return lines
    }

    func flushRemainder() -> [String] {
        guard !buffer.isEmpty else { return [] }
        defer { buffer.removeAll(keepingCapacity: false) }
        return [String(decoding: buffer, as: UTF8.self)]
    }
}
