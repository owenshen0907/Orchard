import Foundation
import OrchardCore

struct OrchardRuntimeConversationDriverSelection: Sendable {
    var kind: ConversationDriverKind
    var displayName: String
    var reason: String
}

struct OrchardRuntimeConversationLaunchContext: Sendable {
    var task: TaskRecord
    var runtimeDirectory: URL
    var cwd: URL
    var lineHandler: @Sendable (String) -> Void
    var progressHandler: @Sendable (ManagedCodexTaskSnapshot) -> Void
    var completion: @Sendable (ManagedCodexTaskTerminalResult) -> Void
}

enum OrchardRuntimeConversationRecovery: Sendable {
    case attached(OrchardRuntimeConversationController)
    case finished(ManagedCodexTaskTerminalResult)
    case unavailable
}

struct OrchardRuntimeConversationController: Sendable {
    var kind: ConversationDriverKind
    var displayName: String

    private let startOperation: @Sendable () async throws -> Void
    private let requestStopOperation: @Sendable () async -> Void
    private let continueOperation: @Sendable (String) async throws -> Void
    private let interruptOperation: @Sendable () async throws -> Void
    private let currentSnapshotOperation: @Sendable () async -> ManagedCodexTaskSnapshot?

    init(
        kind: ConversationDriverKind,
        displayName: String,
        startOperation: @escaping @Sendable () async throws -> Void,
        requestStopOperation: @escaping @Sendable () async -> Void,
        continueOperation: @escaping @Sendable (String) async throws -> Void,
        interruptOperation: @escaping @Sendable () async throws -> Void,
        currentSnapshotOperation: @escaping @Sendable () async -> ManagedCodexTaskSnapshot?
    ) {
        self.kind = kind
        self.displayName = displayName
        self.startOperation = startOperation
        self.requestStopOperation = requestStopOperation
        self.continueOperation = continueOperation
        self.interruptOperation = interruptOperation
        self.currentSnapshotOperation = currentSnapshotOperation
    }

    func start() async throws {
        try await startOperation()
    }

    func requestStop() async {
        await requestStopOperation()
    }

    func `continue`(with prompt: String) async throws {
        try await continueOperation(prompt)
    }

    func requestInterrupt() async throws {
        try await interruptOperation()
    }

    func currentSnapshot() async -> ManagedCodexTaskSnapshot? {
        await currentSnapshotOperation()
    }
}

protocol OrchardRuntimeConversationDriver: Sendable {
    var kind: ConversationDriverKind { get }
    func makeController(context: OrchardRuntimeConversationLaunchContext) throws -> OrchardRuntimeConversationController
    func recoverController(context: OrchardRuntimeConversationLaunchContext) async throws -> OrchardRuntimeConversationRecovery
}

enum OrchardRuntimeConversationDriverFactory {
    static func selection(for task: TaskRecord) -> OrchardRuntimeConversationDriverSelection? {
        guard task.kind == .codex else {
            return nil
        }

        guard case let .codex(payload) = task.payload else {
            return nil
        }

        let kind = payload.driver ?? .codexCLI
        let reason: String
        if let requestedDriver = payload.driver {
            reason = "任务 payload 已显式指定使用 \(requestedDriver.displayName) driver。"
        } else {
            reason = "任务 payload 还没有显式 driver，当前默认走 Codex CLI。"
        }

        return OrchardRuntimeConversationDriverSelection(
            kind: kind,
            displayName: kind.displayName,
            reason: reason
        )
    }

    static func driver(
        for task: TaskRecord,
        config: ResolvedAgentConfig
    ) throws -> any OrchardRuntimeConversationDriver {
        guard let selection = selection(for: task) else {
            throw NSError(domain: "OrchardRuntimeDriver", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "任务 \(task.id) 不是可由对话驱动层接管的类型。",
            ])
        }

        switch selection.kind {
        case .codexCLI:
            return CodexCLIRuntimeConversationDriver(config: config)
        case .claudeCode:
            throw NSError(domain: "OrchardRuntimeDriver", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Claude Code driver 还未接入；当前先由 Codex CLI 打通 Runtime 抽象。",
            ])
        }
    }
}

private struct CodexCLIRuntimeConversationDriver: OrchardRuntimeConversationDriver {
    var kind: ConversationDriverKind { .codexCLI }

    let config: ResolvedAgentConfig

    func makeController(context: OrchardRuntimeConversationLaunchContext) throws -> OrchardRuntimeConversationController {
        let controller = try ManagedCodexTaskController(
            task: context.task,
            runtimeDirectory: context.runtimeDirectory,
            cwd: context.cwd,
            codexBinaryPath: config.codexBinaryPath,
            lineHandler: context.lineHandler,
            progressHandler: context.progressHandler,
            completion: context.completion
        )
        return adapt(controller)
    }

    func recoverController(context: OrchardRuntimeConversationLaunchContext) async throws -> OrchardRuntimeConversationRecovery {
        let recovery = try await ManagedCodexTaskController.recover(
            task: context.task,
            runtimeDirectory: context.runtimeDirectory,
            cwd: context.cwd,
            codexBinaryPath: config.codexBinaryPath,
            lineHandler: context.lineHandler,
            progressHandler: context.progressHandler,
            completion: context.completion
        )

        switch recovery {
        case let .attached(controller):
            return .attached(adapt(controller))
        case let .finished(terminal):
            return .finished(terminal)
        case .unavailable:
            return .unavailable
        }
    }

    private func adapt(_ controller: ManagedCodexTaskController) -> OrchardRuntimeConversationController {
        OrchardRuntimeConversationController(
            kind: kind,
            displayName: kind.displayName,
            startOperation: {
                try await controller.start()
            },
            requestStopOperation: {
                await controller.requestStop()
            },
            continueOperation: { prompt in
                try await controller.continue(with: prompt)
            },
            interruptOperation: {
                try await controller.requestInterrupt()
            },
            currentSnapshotOperation: {
                await controller.currentSnapshot()
            }
        )
    }
}
