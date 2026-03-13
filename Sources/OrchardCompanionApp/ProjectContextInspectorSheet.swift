import OrchardCore
import SwiftUI

struct ProjectContextInspectorSheet: View {
    @ObservedObject var model: AppModel
    let serverURL: String
    let deviceID: String
    let deviceName: String
    let workspaceID: String

    @Environment(\.dismiss) private var dismiss

    @State private var summaryResponse: AgentProjectContextCommandResponse?
    @State private var lookupResponse: AgentProjectContextCommandResponse?
    @State private var selectedSubject: ProjectContextRemoteSubject = .service
    @State private var selector = ""
    @State private var isLoadingSummary = false
    @State private var isRunningLookup = false
    @State private var localErrorMessage: String?

    private var canRunLookup: Bool {
        summaryResponse?.available == true && !isRunningLookup
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HeroCard(
                        eyebrow: deviceName,
                        title: "项目上下文",
                        message: "查看当前工作区注入给 Codex 的非敏感项目事实，并远程查询 host、service、database、command、credential。",
                        symbolName: "books.vertical.fill",
                        tint: .teal
                    )
                }

                Section {
                    LabeledContent("设备", value: deviceName)
                    LabeledContent("工作区", value: workspaceID)
                } header: {
                    SectionHeaderLabel(title: "目标")
                }

                Section {
                    if isLoadingSummary && summaryResponse == nil {
                        ProgressView("正在读取项目上下文…")
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 8)
                    } else if let response = summaryResponse {
                        ProjectContextSummarySection(response: response)
                    } else {
                        SectionPlaceholder(
                            title: "还没有读取到项目上下文。",
                            message: "点击右上角刷新后重试。",
                            symbolName: "books.vertical"
                        )
                    }
                } header: {
                    SectionHeaderLabel(title: "摘要")
                }

                Section {
                    Picker("类型", selection: $selectedSubject) {
                        ForEach(ProjectContextRemoteSubject.allCases, id: \.self) { subject in
                            Text(subject.displayName).tag(subject)
                        }
                    }

                    TextField("筛选关键词（可选）", text: $selector)
#if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
#endif

                    HStack(spacing: 12) {
                        Button("查询") {
                            Task {
                                await runLookup()
                            }
                        }
                        .disabled(!canRunLookup)

                        Button("查看全部") {
                            selector = ""
                            Task {
                                await runLookup()
                            }
                        }
                        .disabled(!canRunLookup)

                        if isRunningLookup {
                            Spacer()
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                } header: {
                    SectionHeaderLabel(
                        title: "远程查询",
                        subtitle: "按 host、service、database、command、credential 细查当前工作区。"
                    )
                }

                Section {
                    if let response = lookupResponse {
                        ProjectContextLookupSection(response: response)
                    } else {
                        SectionPlaceholder(
                            title: "还没有查询结果。",
                            message: summaryResponse?.available == true
                                ? "选择类型后点“查询”，或者直接点“查看全部”。"
                                : "当前工作区还没有可查询的项目上下文。",
                            symbolName: "magnifyingglass"
                        )
                    }
                } header: {
                    SectionHeaderLabel(title: "查询结果")
                }

                if let localErrorMessage, !localErrorMessage.isEmpty {
                    Section("错误") {
                        Text(localErrorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("项目上下文")
            .companionInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: CompanionToolbarPlacement.leading) {
                    Button("关闭") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: CompanionToolbarPlacement.trailing) {
                    Button("刷新") {
                        Task {
                            await loadSummary()
                        }
                    }
                    .disabled(isLoadingSummary)
                }
            }
            .task {
                await loadSummary()
            }
        }
    }

    private func loadSummary() async {
        isLoadingSummary = true
        defer { isLoadingSummary = false }

        do {
            summaryResponse = try await model.fetchProjectContextSummary(
                serverURLString: serverURL,
                deviceID: deviceID,
                workspaceID: workspaceID
            )
            localErrorMessage = nil
            if summaryResponse?.available != true {
                lookupResponse = nil
            }
        } catch {
            localErrorMessage = error.localizedDescription
        }
    }

    private func runLookup() async {
        guard canRunLookup else {
            return
        }

        isRunningLookup = true
        defer { isRunningLookup = false }

        do {
            lookupResponse = try await model.lookupProjectContext(
                serverURLString: serverURL,
                deviceID: deviceID,
                workspaceID: workspaceID,
                subject: selectedSubject,
                selector: selector.nilIfEmpty
            )
            localErrorMessage = nil
        } catch {
            localErrorMessage = error.localizedDescription
        }
    }
}

private struct ProjectContextSummarySection: View {
    let response: AgentProjectContextCommandResponse

    var body: some View {
        if let errorMessage = response.errorMessage?.nilIfEmpty {
            NoticeCard(
                title: "项目上下文读取失败",
                message: errorMessage,
                symbolName: "exclamationmark.triangle.fill",
                tint: .orange
            )
        } else if response.available, let summary = response.summary {
            if let summaryText = summary.summary?.nilIfEmpty {
                Text(summaryText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if !summary.localSecretsPresent {
                NoticeCard(
                    title: "当前宿主机未发现本机密钥文件",
                    message: "项目结构可以远程查看，但实际执行仍可能缺少 credential。",
                    symbolName: "key.slash.fill",
                    tint: .orange
                )
            }

            ProjectContextLinesView(lines: summary.renderedLines)
        } else if !response.available {
            SectionPlaceholder(
                title: "当前工作区还没有配置项目上下文。",
                message: "这类 run 仍可执行，但不会自动注入部署、主机、数据库等项目事实。",
                symbolName: "tray"
            )
        } else {
            SectionPlaceholder(
                title: "项目上下文暂时不可用。",
                message: "稍后刷新重试。",
                symbolName: "books.vertical"
            )
        }
    }
}

private struct ProjectContextLookupSection: View {
    let response: AgentProjectContextCommandResponse

    var body: some View {
        if let errorMessage = response.errorMessage?.nilIfEmpty {
            NoticeCard(
                title: "查询失败",
                message: errorMessage,
                symbolName: "exclamationmark.triangle.fill",
                tint: .orange
            )
        } else if let lookup = response.lookup {
            ProjectContextLinesView(lines: lookup.renderedLines)
        } else {
            SectionPlaceholder(
                title: "没有查询结果。",
                message: response.available ? "换一个类型或筛选词再试。" : "当前工作区没有项目上下文可供查询。",
                symbolName: "magnifyingglass"
            )
        }
    }
}

private struct ProjectContextLinesView: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                Text(line)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, index == 0 ? 0 : 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension ProjectContextRemoteSubject {
    var displayName: String {
        switch self {
        case .environment:
            return "环境"
        case .host:
            return "主机"
        case .service:
            return "服务"
        case .database:
            return "数据库"
        case .command:
            return "命令"
        case .credential:
            return "凭据"
        }
    }
}
