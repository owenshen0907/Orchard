import OrchardCore
import SwiftUI

struct ProjectCommandQuickInsertContext {
    let deviceID: String
    let workspaceID: String
}

struct ProjectCommandQuickInsertSource {
    let model: AppModel
    let serverURL: String
    let context: ProjectCommandQuickInsertContext
}

struct ProjectCommandQuickInsertSuggestion {
    let commandID: String
    let suggestedTitle: String
    let suggestedPrompt: String
}

enum ProjectCommandPromptIntent {
    case createManagedRun
    case continueConversation
}

struct ProjectCommandQuickInsertSection: View {
    let source: ProjectCommandQuickInsertSource
    let intent: ProjectCommandPromptIntent
    let helperText: String
    let actionTitle: String
    var maxVisibleCount = 4
    var onSelect: (ProjectCommandQuickInsertSuggestion) -> Void

    @State private var isLoading = false
    @State private var isAvailable = false
    @State private var commands: [ProjectContextQuickCommandLookupItem] = []
    @State private var errorMessage: String?

    private var taskID: String {
        [source.serverURL, source.context.deviceID, source.context.workspaceID, "command"].joined(separator: "|")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(helperText)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if isLoading && commands.isEmpty {
                ProgressView("正在读取标准操作命令…")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else if let errorMessage, !errorMessage.isEmpty {
                NoticeCard(
                    title: "标准操作命令读取失败",
                    message: errorMessage,
                    symbolName: "exclamationmark.triangle.fill",
                    tint: .orange
                )
            } else if !isAvailable {
                SectionPlaceholder(
                    title: "当前工作区还没有项目上下文。",
                    message: "先让目标设备上报 project-context，才能把标准命令快捷填充到提示词里。",
                    symbolName: "tray"
                )
            } else if commands.isEmpty {
                SectionPlaceholder(
                    title: "当前项目还没有登记标准操作命令。",
                    message: "可以把常用部署、巡检、日志等动作维护到 project-context 的 commands 里。",
                    symbolName: "terminal"
                )
            } else {
                ForEach(Array(commands.prefix(maxVisibleCount))) { item in
                    Button {
                        onSelect(ProjectCommandPromptComposer.makeSuggestion(for: item, intent: intent))
                    } label: {
                        ProjectCommandQuickInsertCard(item: item, actionTitle: actionTitle)
                    }
                    .buttonStyle(.plain)
                }

                if commands.count > maxVisibleCount {
                    Text("已显示前 \(maxVisibleCount) 条，共 \(commands.count) 条；完整清单可在“项目上下文”里查看。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: taskID) {
            await loadCommands()
        }
    }

    private func loadCommands() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let response = try await source.model.lookupProjectContext(
                serverURLString: source.serverURL,
                deviceID: source.context.deviceID,
                workspaceID: source.context.workspaceID,
                subject: .command,
                selector: nil
            )

            if let errorMessage = response.errorMessage?.nilIfEmpty {
                self.errorMessage = errorMessage
                isAvailable = response.available
                commands = []
                return
            }

            isAvailable = response.available
            errorMessage = nil
            commands = try decodeCommands(from: response)
        } catch {
            errorMessage = error.localizedDescription
            isAvailable = false
            commands = []
        }
    }

    private func decodeCommands(from response: AgentProjectContextCommandResponse) throws -> [ProjectContextQuickCommandLookupItem] {
        guard response.available else {
            return []
        }
        guard let lookup = response.lookup else {
            return []
        }
        guard let payloadJSON = lookup.payloadJSON?.data(using: .utf8) else {
            throw NSError(
                domain: "OrchardCompanionProjectCommand",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "控制面返回了命令查询结果，但没有结构化 payload。"]
            )
        }

        let payload = try OrchardJSON.decoder.decode(ProjectContextQuickCommandLookupPayload.self, from: payloadJSON)
        return payload.items
    }
}

private struct ProjectCommandQuickInsertCard: View {
    let item: ProjectContextQuickCommandLookupItem
    let actionTitle: String

    private var accentColor: Color {
        item.hasMissingCredentials ? .orange : .blue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.command.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    Text(item.command.id)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                MetaCapsule(
                    title: item.command.runnerDisplayName,
                    symbolName: item.command.runnerSymbolName,
                    tint: accentColor
                )
            }

            if let scopeSummary = item.scopeSummary {
                Text(scopeSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(item.command.command)
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(3)
                .multilineTextAlignment(.leading)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label(item.credentialStatusSummary, systemImage: item.hasMissingCredentials ? "key.slash.fill" : "key.fill")
                    .font(.caption)
                    .foregroundStyle(item.hasMissingCredentials ? .orange : .secondary)
                    .lineLimit(2)

                Spacer(minLength: 8)

                Text(actionTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accentColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(accentColor.opacity(0.08))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(accentColor.opacity(0.10), lineWidth: 1)
                }
        }
    }
}

enum ProjectCommandPromptComposer {
    fileprivate static func makeSuggestion(
        for item: ProjectContextQuickCommandLookupItem,
        intent: ProjectCommandPromptIntent
    ) -> ProjectCommandQuickInsertSuggestion {
        ProjectCommandQuickInsertSuggestion(
            commandID: item.command.id,
            suggestedTitle: item.command.name,
            suggestedPrompt: makePrompt(for: item, intent: intent)
        )
    }

    static func appendPrompt(_ promptBlock: String, to existingPrompt: String) -> String {
        let existing = existingPrompt.trimmedOrEmpty
        guard !existing.isEmpty else {
            return promptBlock
        }
        return existing + "\n\n" + promptBlock
    }

    private static func makePrompt(
        for item: ProjectContextQuickCommandLookupItem,
        intent: ProjectCommandPromptIntent
    ) -> String {
        var lines: [String] = []
        lines.append(introLine(for: item, intent: intent))
        lines.append("")
        lines.append("已知命令事实：")
        lines.append("- 执行器：\(item.command.runnerDisplayName)")
        lines.append("- 命令模板：\(item.command.command)")

        if let workingDirectory = item.command.workingDirectory?.trimmedOrEmpty.nilIfEmpty {
            lines.append("- 工作目录：\(workingDirectory)")
        }
        if let environments = summary(for: item.environments, formatter: { formatReference(id: $0.id, name: $0.name) }) {
            lines.append("- 环境：\(environments)")
        }
        if let host = item.host.map({ formatReference(id: $0.id, name: $0.name) }) {
            lines.append("- 主机：\(host)")
        }
        if let services = summary(for: item.services, formatter: { formatReference(id: $0.id, name: $0.name) }) {
            lines.append("- 服务：\(services)")
        }
        if let databases = summary(for: item.databases, formatter: { formatReference(id: $0.id, name: $0.name) }) {
            lines.append("- 数据库：\(databases)")
        }
        lines.append("- 凭据：\(credentialSummary(for: item.credentials))")

        if !item.command.notes.isEmpty {
            lines.append("- 备注：\(item.command.notes.joined(separator: "；"))")
        }

        lines.append("")
        lines.append("执行要求：")
        lines.append("1. 先核对关联环境、主机、服务、数据库和凭据状态是否满足。")
        lines.append("2. 如果命令模板包含 `{{credential...}}` 占位符，优先根据 project-context 与本机 local secrets 补齐；不要输出敏感值。")
        lines.append("3. 在合适的工作目录执行该命令；如果需要做等效调整，先说明原因，再继续执行。")

        switch intent {
        case .createManagedRun:
            lines.append("4. 完成后汇报执行结果、关键输出、健康检查结论，以及建议的下一步。")
        case .continueConversation:
            lines.append("4. 完成后汇报执行结果、关键输出，以及是否还需要继续做健康检查、查看日志或回滚处理。")
        }

        return lines.joined(separator: "\n")
    }

    private static func introLine(
        for item: ProjectContextQuickCommandLookupItem,
        intent: ProjectCommandPromptIntent
    ) -> String {
        switch intent {
        case .createManagedRun:
            return "请基于当前工作区的 project-context 执行标准操作命令 `\(item.command.id)`（\(item.command.name)）。"
        case .continueConversation:
            return "继续当前任务，并执行项目上下文中的标准操作命令 `\(item.command.id)`（\(item.command.name)）。"
        }
    }

    private static func summary<T>(for items: [T], formatter: (T) -> String) -> String? {
        let values = items
            .map(formatter)
            .map { $0.trimmedOrEmpty }
            .filter { !$0.isEmpty }
        guard !values.isEmpty else {
            return nil
        }
        return values.joined(separator: "、")
    }

    private static func credentialSummary(for credentials: [ProjectContextQuickCredential]) -> String {
        guard !credentials.isEmpty else {
            return "未声明额外凭据"
        }

        return credentials.map { credential in
            if credential.configured {
                return "\(credential.id)（已配置）"
            }

            let missing = credential.missingRequiredFields
                .map(\.trimmedOrEmpty)
                .filter { !$0.isEmpty }
            if missing.isEmpty {
                return "\(credential.id)（未配置）"
            }
            return "\(credential.id)（缺少 \(missing.joined(separator: ", "))）"
        }
        .joined(separator: "；")
    }

    private static func formatReference(id: String, name: String) -> String {
        let trimmedName = name.trimmedOrEmpty
        if trimmedName.isEmpty || trimmedName == id {
            return id
        }
        return "\(id)（\(trimmedName)）"
    }
}

private struct ProjectContextQuickCommandLookupPayload: Decodable {
    let items: [ProjectContextQuickCommandLookupItem]

    private enum CodingKeys: String, CodingKey {
        case items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([ProjectContextQuickCommandLookupItem].self, forKey: .items) ?? []
    }
}

private struct ProjectContextQuickCommandLookupItem: Decodable, Identifiable {
    let command: ProjectContextQuickCommand
    let host: ProjectContextQuickHost?
    let environments: [ProjectContextQuickEnvironment]
    let services: [ProjectContextQuickService]
    let databases: [ProjectContextQuickDatabase]
    let credentials: [ProjectContextQuickCredential]

    private enum CodingKeys: String, CodingKey {
        case command
        case host
        case environments
        case services
        case databases
        case credentials
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        command = try container.decode(ProjectContextQuickCommand.self, forKey: .command)
        host = try container.decodeIfPresent(ProjectContextQuickHost.self, forKey: .host)
        environments = try container.decodeIfPresent([ProjectContextQuickEnvironment].self, forKey: .environments) ?? []
        services = try container.decodeIfPresent([ProjectContextQuickService].self, forKey: .services) ?? []
        databases = try container.decodeIfPresent([ProjectContextQuickDatabase].self, forKey: .databases) ?? []
        credentials = try container.decodeIfPresent([ProjectContextQuickCredential].self, forKey: .credentials) ?? []
    }

    var id: String { command.id }

    var scopeSummary: String? {
        let parts = [
            summary(for: environments, formatter: { $0.name }),
            host?.name.trimmedOrEmpty.nilIfEmpty,
            summary(for: services, formatter: { $0.name }),
            summary(for: databases, formatter: { $0.name }),
        ].compactMap { $0 }

        guard !parts.isEmpty else {
            return nil
        }
        return parts.joined(separator: " · ")
    }

    var credentialStatusSummary: String {
        guard !credentials.isEmpty else {
            return "无额外凭据"
        }
        if hasMissingCredentials {
            return credentials
                .filter { !$0.configured }
                .map { credential in
                    let missing = credential.missingRequiredFields.joined(separator: ", ")
                    return missing.isEmpty ? credential.id : "\(credential.id): \(missing)"
                }
                .joined(separator: "；")
        }
        return credentials.map(\.id).joined(separator: "；") + " 已配置"
    }

    var hasMissingCredentials: Bool {
        credentials.contains { !$0.configured }
    }

    private func summary<T>(for items: [T], formatter: (T) -> String) -> String? {
        let values = items
            .map(formatter)
            .map { $0.trimmedOrEmpty }
            .filter { !$0.isEmpty }
        guard !values.isEmpty else {
            return nil
        }
        return values.joined(separator: "、")
    }
}

private struct ProjectContextQuickCommand: Decodable {
    let id: String
    let name: String
    let runner: String
    let command: String
    let workingDirectory: String?
    let notes: [String]

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case runner
        case command
        case workingDirectory
        case notes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        runner = try container.decode(String.self, forKey: .runner)
        command = try container.decode(String.self, forKey: .command)
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
        notes = try container.decodeIfPresent([String].self, forKey: .notes) ?? []
    }

    var runnerDisplayName: String {
        switch runner.lowercased() {
        case "local-shell":
            return "本机 Shell"
        case "ssh":
            return "SSH"
        default:
            return runner.trimmedOrEmpty.nilIfEmpty ?? runner
        }
    }

    var runnerSymbolName: String {
        switch runner.lowercased() {
        case "ssh":
            return "network"
        default:
            return "terminal"
        }
    }
}

private struct ProjectContextQuickEnvironment: Decodable {
    let id: String
    let name: String
}

private struct ProjectContextQuickHost: Decodable {
    let id: String
    let name: String
}

private struct ProjectContextQuickService: Decodable {
    let id: String
    let name: String
}

private struct ProjectContextQuickDatabase: Decodable {
    let id: String
    let name: String
}

private struct ProjectContextQuickCredential: Decodable {
    let id: String
    let configured: Bool
    let missingRequiredFields: [String]

    private enum CodingKeys: String, CodingKey {
        case id
        case configured
        case missingRequiredFields
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        configured = try container.decode(Bool.self, forKey: .configured)
        missingRequiredFields = try container.decodeIfPresent([String].self, forKey: .missingRequiredFields) ?? []
    }
}
