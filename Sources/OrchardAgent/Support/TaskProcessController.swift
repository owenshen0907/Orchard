import Darwin
import Foundation
import OrchardCore

struct TaskExecutionResult: Sendable {
    var status: TaskStatus
    var exitCode: Int?
    var summary: String
}

enum TaskProcessRecovery {
    case attached(TaskProcessController)
    case finished(TaskExecutionResult)
    case unavailable
}

private struct TaskRuntimeRecord: Codable, Sendable {
    var taskID: String
    var pid: Int32
    var cwd: String
    var startedAt: Date
    var lastSeenAt: Date
    var logOffset: UInt64
    var stopRequested: Bool
}

final class TaskProcessController: @unchecked Sendable {
    private let task: TaskRecord
    private let runtimeDirectory: URL
    private let launchSpec: TaskLaunchSpec
    private let lineHandler: @Sendable (String) -> Void
    private let completion: @Sendable (TaskExecutionResult) -> Void
    private let queue: DispatchQueue
    private let logURL: URL
    private let taskURL: URL
    private let runtimeURL: URL
    private let exitStatusURL: URL
    private let wrapperScriptURL: URL
    private let stdoutAccumulator = StreamAccumulator()

    private var process: Process?
    private var processID: pid_t?
    private var timer: DispatchSourceTimer?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var readOffset: UInt64 = 0
    private var stopRequested = false
    private var completionSent = false
    private var detachedExitObservedAt: Date?

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
        self.logURL = runtimeDirectory.appendingPathComponent("combined.log", isDirectory: false)
        self.taskURL = runtimeDirectory.appendingPathComponent("task.json", isDirectory: false)
        self.runtimeURL = runtimeDirectory.appendingPathComponent("runtime.json", isDirectory: false)
        self.exitStatusURL = runtimeDirectory.appendingPathComponent("exit-status", isDirectory: false)
        self.wrapperScriptURL = runtimeDirectory.appendingPathComponent("run.sh", isDirectory: false)

        try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true, attributes: nil)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }

        let taskData = try OrchardJSON.encoder.encode(task)
        try taskData.write(to: taskURL, options: .atomic)
    }

    private init(
        task: TaskRecord,
        runtimeDirectory: URL,
        launchSpec: TaskLaunchSpec,
        restoredRuntime: TaskRuntimeRecord,
        lineHandler: @escaping @Sendable (String) -> Void,
        completion: @escaping @Sendable (TaskExecutionResult) -> Void
    ) throws {
        self.task = task
        self.runtimeDirectory = runtimeDirectory
        self.launchSpec = launchSpec
        self.lineHandler = lineHandler
        self.completion = completion
        self.queue = DispatchQueue(label: "orchard.task.\(task.id)")
        self.logURL = runtimeDirectory.appendingPathComponent("combined.log", isDirectory: false)
        self.taskURL = runtimeDirectory.appendingPathComponent("task.json", isDirectory: false)
        self.runtimeURL = runtimeDirectory.appendingPathComponent("runtime.json", isDirectory: false)
        self.exitStatusURL = runtimeDirectory.appendingPathComponent("exit-status", isDirectory: false)
        self.wrapperScriptURL = runtimeDirectory.appendingPathComponent("run.sh", isDirectory: false)
        self.processID = pid_t(restoredRuntime.pid)
        self.readOffset = restoredRuntime.logOffset
        self.stopRequested = restoredRuntime.stopRequested

        try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true, attributes: nil)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
    }

    deinit {
        timer?.cancel()
        try? stdoutHandle?.close()
        try? stderrHandle?.close()
    }

    static func loadPersistedTask(runtimeDirectory: URL) throws -> TaskRecord {
        let taskURL = runtimeDirectory.appendingPathComponent("task.json", isDirectory: false)
        return try OrchardJSON.decoder.decode(TaskRecord.self, from: Data(contentsOf: taskURL))
    }

    static func recover(
        task: TaskRecord,
        runtimeDirectory: URL,
        launchSpec: TaskLaunchSpec,
        lineHandler: @escaping @Sendable (String) -> Void,
        completion: @escaping @Sendable (TaskExecutionResult) -> Void
    ) throws -> TaskProcessRecovery {
        let runtimeURL = runtimeDirectory.appendingPathComponent("runtime.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: runtimeURL.path) else {
            return .unavailable
        }

        let runtime = try OrchardJSON.decoder.decode(TaskRuntimeRecord.self, from: Data(contentsOf: runtimeURL))
        let controller = try TaskProcessController(
            task: task,
            runtimeDirectory: runtimeDirectory,
            launchSpec: launchSpec,
            restoredRuntime: runtime,
            lineHandler: lineHandler,
            completion: completion
        )

        guard let pid = controller.processID else {
            return .unavailable
        }

        if let exitCode = controller.readExitCode() {
            controller.pollLogFile()
            return .finished(controller.result(forExitCode: exitCode))
        }

        if processExists(pid) {
            controller.beginMonitoring(startFromExistingOffset: true)
            return .attached(controller)
        }

        return .unavailable
    }

    func start() throws {
        try removeExitStatusIfNeeded()
        try writeWrapperScript()

        let stdoutHandle = try FileHandle(forWritingTo: logURL)
        let stderrHandle = try FileHandle(forWritingTo: logURL)
        try stdoutHandle.seekToEnd()
        try stderrHandle.seekToEnd()
        self.stdoutHandle = stdoutHandle
        self.stderrHandle = stderrHandle

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [wrapperScriptURL.path]
        process.environment = launchSpec.environment
        process.currentDirectoryURL = runtimeDirectory
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        process.terminationHandler = { [weak self] process in
            self?.queue.async { [weak self] in
                self?.handleObservedTermination(status: Int(process.terminationStatus))
            }
        }

        try process.run()
        self.process = process
        self.processID = process.processIdentifier
        self.stopRequested = false
        _ = setpgid(process.processIdentifier, process.processIdentifier)
        try persistRuntime()
        beginMonitoring(startFromExistingOffset: false)
    }

    func requestStop() {
        queue.async { [weak self] in
            guard let self, let pid = self.processID else { return }
            self.stopRequested = true
            try? self.persistRuntime()

            _ = kill(pid, SIGTERM)

            self.queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, let pid = self.processID, !self.completionSent else { return }
                if Self.processExists(pid) {
                    if kill(-pid, SIGKILL) != 0 {
                        _ = kill(pid, SIGKILL)
                    }
                }
            }
        }
    }

    private func beginMonitoring(startFromExistingOffset: Bool) {
        if startFromExistingOffset, readOffset == 0 {
            readOffset = currentLogSize()
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.pollLogFile()
            self.pollDetachedTermination()
        }
        self.timer = timer
        timer.resume()
    }

    private func pollLogFile() {
        guard !completionSent else { return }

        let currentSize = currentLogSize()
        if currentSize < readOffset {
            readOffset = 0
            stdoutAccumulator.reset()
        }
        guard currentSize > readOffset else { return }

        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: readOffset)
            let data = try handle.readToEnd() ?? Data()
            guard !data.isEmpty else { return }
            readOffset += UInt64(data.count)
            try? persistRuntime()
            emit(lines: stdoutAccumulator.consume(data))
        } catch {
            return
        }
    }

    private func pollDetachedTermination() {
        guard process == nil, let pid = processID, !completionSent else { return }

        if let exitCode = readExitCode() {
            emit(lines: stdoutAccumulator.flushRemainder())
            finish(with: result(forExitCode: exitCode))
            return
        }

        if Self.processExists(pid) {
            detachedExitObservedAt = nil
            return
        }

        if detachedExitObservedAt == nil {
            detachedExitObservedAt = Date()
            return
        }

        guard let detachedExitObservedAt, Date().timeIntervalSince(detachedExitObservedAt) >= 2 else {
            return
        }

        emit(lines: stdoutAccumulator.flushRemainder())
        finish(with: TaskExecutionResult(
            status: .failed,
            exitCode: nil,
            summary: "Task process disappeared before exit status was recorded."
        ))
    }

    private func handleObservedTermination(status: Int) {
        guard !completionSent else { return }
        pollLogFile()
        emit(lines: stdoutAccumulator.flushRemainder())
        let exitCode = readExitCode() ?? status
        finish(with: result(forExitCode: exitCode))
    }

    private func finish(with result: TaskExecutionResult) {
        guard !completionSent else { return }
        completionSent = true
        timer?.cancel()
        timer = nil
        process = nil
        try? persistRuntime()
        completion(result)
    }

    private func emit(lines: [String]) {
        guard !lines.isEmpty else { return }
        for line in lines {
            lineHandler(String(line.prefix(4096)))
        }
    }

    private func result(forExitCode exitCode: Int) -> TaskExecutionResult {
        if stopRequested {
            return TaskExecutionResult(status: .cancelled, exitCode: exitCode, summary: "Task cancelled after stop request.")
        }
        if exitCode == 0 {
            return TaskExecutionResult(status: .succeeded, exitCode: exitCode, summary: "Task completed successfully.")
        }
        return TaskExecutionResult(status: .failed, exitCode: exitCode, summary: "Task exited with code \(exitCode).")
    }

    private func persistRuntime() throws {
        guard let processID else { return }
        let runtime = TaskRuntimeRecord(
            taskID: task.id,
            pid: Int32(processID),
            cwd: launchSpec.currentDirectoryURL.path,
            startedAt: task.startedAt ?? Date(),
            lastSeenAt: Date(),
            logOffset: readOffset,
            stopRequested: stopRequested
        )
        let data = try OrchardJSON.encoder.encode(runtime)
        try data.write(to: runtimeURL, options: .atomic)
    }

    private func writeWrapperScript() throws {
        let command = ([launchSpec.executableURL.path] + launchSpec.arguments)
            .map(Self.shellEscape)
            .joined(separator: " ")

        let script = """
        #!/bin/zsh
        cd \(Self.shellEscape(launchSpec.currentDirectoryURL.path)) || exit 1
        orchard_forward_stop() {
          if [[ -n "${orchard_child_pid:-}" ]]; then
            kill -TERM "$orchard_child_pid" 2>/dev/null || true
          fi
        }
        trap orchard_forward_stop TERM INT
        \(command) &
        orchard_child_pid=$!
        wait "$orchard_child_pid"
        orchard_exit_code=$?
        printf '%s' "$orchard_exit_code" > \(Self.shellEscape(exitStatusURL.path))
        exit "$orchard_exit_code"
        """

        try script.write(to: wrapperScriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapperScriptURL.path)
    }

    private func removeExitStatusIfNeeded() throws {
        if FileManager.default.fileExists(atPath: exitStatusURL.path) {
            try FileManager.default.removeItem(at: exitStatusURL)
        }
    }

    private func readExitCode() -> Int? {
        guard let data = try? Data(contentsOf: exitStatusURL) else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(text)
    }

    private func currentLogSize() -> UInt64 {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path),
            let size = attributes[.size] as? NSNumber
        else {
            return 0
        }
        return size.uint64Value
    }

    private static func processExists(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    private static func shellEscape(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
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

    func reset() {
        buffer.removeAll(keepingCapacity: false)
    }
}
