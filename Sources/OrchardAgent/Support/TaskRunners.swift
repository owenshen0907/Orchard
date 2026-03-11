import Foundation
import OrchardCore

struct TaskLaunchSpec: Sendable {
    var executableURL: URL
    var arguments: [String]
    var environment: [String: String]
    var currentDirectoryURL: URL
}

protocol TaskRunner {
    func makeLaunchSpec(task: TaskRecord, cwd: URL, config: ResolvedAgentConfig) throws -> TaskLaunchSpec
}

enum TaskRunnerFactory {
    static func runner(for kind: TaskKind) -> TaskRunner {
        switch kind {
        case .shell:
            return ShellRunner()
        case .codex:
            return CodexRunner()
        }
    }
}

struct ShellRunner: TaskRunner {
    func makeLaunchSpec(task: TaskRecord, cwd: URL, config: ResolvedAgentConfig) throws -> TaskLaunchSpec {
        guard case let .shell(payload) = task.payload else {
            throw NSError(domain: "OrchardAgent", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "Shell task payload is invalid.",
            ])
        }

        return TaskLaunchSpec(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-lc", payload.command],
            environment: ProcessInfo.processInfo.environment,
            currentDirectoryURL: cwd
        )
    }
}

struct CodexRunner: TaskRunner {
    func makeLaunchSpec(task: TaskRecord, cwd: URL, config: ResolvedAgentConfig) throws -> TaskLaunchSpec {
        guard case let .codex(payload) = task.payload else {
            throw NSError(domain: "OrchardAgent", code: 21, userInfo: [
                NSLocalizedDescriptionKey: "Codex task payload is invalid.",
            ])
        }

        return TaskLaunchSpec(
            executableURL: URL(fileURLWithPath: config.codexBinaryPath),
            arguments: ["exec", payload.prompt, "-C", cwd.path, "-a", "never", "-s", "workspace-write"],
            environment: ProcessInfo.processInfo.environment,
            currentDirectoryURL: cwd
        )
    }
}
