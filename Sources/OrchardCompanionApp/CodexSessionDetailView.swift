import OrchardCore
import SwiftUI

struct CodexSessionDetailView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var model: AppModel
    let serverURL: String
    let initialSession: CodexSessionSummary

    @State private var detail: CodexSessionDetail?
    @State private var isLoading = false
    @State private var isShowingContinueSheet = false
    @State private var continuePrompt = ""
    @State private var isSubmittingPrompt = false
    @State private var isInterrupting = false
    @State private var localErrorMessage: String?
    @State private var toastMessage: String?
    @State private var projectContextSummary: AgentProjectContextCommandResponse?
    @State private var isLoadingProjectContext = false
    @State private var isShowingProjectContextSheet = false

    private let metricColumns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
    ]

    private var session: CodexSessionSummary {
        detail?.session ?? initialSession
    }

    private var autoRefreshTaskID: String {
        "\(serverURL)|\(session.deviceID)|\(session.id)|\(scenePhase == .active ? "active" : "inactive")"
    }

    private var projectContextTaskID: String {
        "\(serverURL)|\(session.deviceID)|\(session.workspaceID ?? "none")"
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    HeroCard(
                        eyebrow: session.deviceName,
                        title: session.derivedStatusTitle,
                        message: session.statusExplanationText,
                        symbolName: session.derivedStatusSymbolName,
                        tint: session.derivedStatusColor
                    )

                    LazyVGrid(columns: metricColumns, spacing: 14) {
                        DetailHeroMetric(title: "来源", value: session.source)
                        DetailHeroMetric(title: "模型供应商", value: session.modelProvider)
                        DetailHeroMetric(title: "工作目录", value: URL(fileURLWithPath: session.cwd).lastPathComponent)
                        DetailHeroMetric(
                            title: "更新时间",
                            value: session.updatedAt.formatted(date: .omitted, time: .shortened)
                        )
                    }
                }
                .padding(.vertical, 4)
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)
            }

            Section {
                LabeledContent("设备", value: session.deviceName)
                LabeledContent("会话 ID", value: session.id)
                if let workspaceID = session.workspaceID?.nilIfEmpty {
                    LabeledContent("工作区", value: workspaceID)
                }
                LabeledContent("路径", value: session.cwd)
                LabeledContent("状态细分", value: session.derivedStatusTitle)
                LabeledContent("最近轮次", value: session.lastTurnStatusDisplayName)
                if session.isLightweightSummary {
                    LabeledContent("读取方式", value: "当前仍是轻摘要")
                }
            } header: {
                SectionHeaderLabel(title: "概况")
            }

            Section {
                if let workspaceID = session.workspaceID?.nilIfEmpty {
                    projectContextSection(deviceID: session.deviceID, workspaceID: workspaceID)
                } else {
                    SectionPlaceholder(
                        title: "当前会话还没有匹配到 Orchard 工作区。",
                        message: "只要当前工作目录落在某个已注册 workspace 根路径内，控制面就会自动补齐工作区和项目上下文。",
                        symbolName: "shippingbox"
                    )
                }
            } header: {
                SectionHeaderLabel(
                    title: "项目上下文",
                    subtitle: session.workspaceID?.nilIfEmpty ?? URL(fileURLWithPath: session.cwd).lastPathComponent
                )
            }

            Section {
                Text(session.preview)
                    .font(.subheadline)
                    .textSelection(.enabled)
            } header: {
                SectionHeaderLabel(title: "初始上下文")
            }

            Section {
                if isLoading && detail == nil {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                } else if let items = detail?.items, !items.isEmpty {
                    ForEach(items.sorted { $0.sequence < $1.sequence }) { item in
                        CodexSessionItemRow(item: item)
                    }
                } else {
                    SectionPlaceholder(
                        title: "当前没有可展示的会话内容。",
                        message: "刷新后会重新读取本机的 Codex 线程详情。",
                        symbolName: "text.alignleft"
                    )
                }
            } header: {
                SectionHeaderLabel(title: "时间线")
            }

            if let localErrorMessage {
                Section {
                    Text(localErrorMessage)
                        .foregroundStyle(.red)
                } header: {
                    SectionHeaderLabel(title: "错误")
                }
            }
        }
        .companionListStyle()
        .navigationTitle(session.titleText)
        .companionInlineNavigationTitle()
        .companionToast(message: toastMessage)
        .refreshable {
            await loadDetail()
        }
        .toolbar {
            ToolbarItem(placement: CompanionToolbarPlacement.trailing) {
                Menu {
                    Button {
                        Task {
                            await loadDetail()
                            showToast("已刷新")
                        }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }

                    Button {
                        copyTextToPasteboard(session.id)
                        showToast("已复制会话 ID")
                    } label: {
                        Label("复制会话 ID", systemImage: "number")
                    }

                    Button {
                        copyTextToPasteboard(session.cwd)
                        showToast("已复制路径")
                    } label: {
                        Label("复制路径", systemImage: "folder")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 12) {
                    Button("继续追问") {
                        continuePrompt = ""
                        isShowingContinueSheet = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)

                    if session.isRunningLike {
                        Button("中断") {
                            Task {
                                await interruptSession()
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                        .disabled(isInterrupting)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 10)
                .padding(.bottom, 12)
            }
            .background(.bar)
        }
        .sheet(isPresented: $isShowingContinueSheet) {
            CompanionContinuePromptSheet(
                title: "继续会话",
                message: "继续追问会直接发到当前 Codex 会话。",
                subject: session.titleText,
                prompt: $continuePrompt,
                isSubmitting: isSubmittingPrompt,
                errorMessage: localErrorMessage,
                projectCommandSource: session.workspaceID?.nilIfEmpty.map { workspaceID in
                    ProjectCommandQuickInsertSource(
                        model: model,
                        serverURL: serverURL,
                        context: ProjectCommandQuickInsertContext(
                            deviceID: session.deviceID,
                            workspaceID: workspaceID
                        )
                    )
                },
                onCancel: {
                    isShowingContinueSheet = false
                },
                onSubmit: {
                    Task {
                        await continueSession()
                    }
                }
            )
        }
        .sheet(isPresented: $isShowingProjectContextSheet) {
            if let workspaceID = session.workspaceID?.nilIfEmpty {
                ProjectContextInspectorSheet(
                    model: model,
                    serverURL: serverURL,
                    deviceID: session.deviceID,
                    deviceName: session.deviceName,
                    workspaceID: workspaceID
                )
            }
        }
        .task(id: autoRefreshTaskID) {
            guard scenePhase == .active else {
                return
            }

            await loadDetail()

            while !Task.isCancelled {
                try? await Task.sleep(for: CompanionRefreshPolicy.detailInterval)
                guard scenePhase == .active else {
                    return
                }
                await loadDetail()
            }
        }
        .task(id: projectContextTaskID) {
            await loadProjectContextSummary()
        }
    }

    @ViewBuilder
    private func projectContextSection(deviceID: String, workspaceID: String) -> some View {
        if isLoadingProjectContext && projectContextSummary == nil {
            ProgressView("正在读取项目上下文…")
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
        } else if let response = projectContextSummary {
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
                        message: "项目结构已识别，但后续执行标准命令时仍可能缺少 credential。",
                        symbolName: "key.slash.fill",
                        tint: .orange
                    )
                }

                ForEach(Array(summary.renderedLines.prefix(4).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }

                Button("查看完整项目上下文") {
                    isShowingProjectContextSheet = true
                }
            } else if !response.available {
                SectionPlaceholder(
                    title: "当前工作区没有项目上下文。",
                    message: "Codex 仍可继续执行，但不会自动注入部署、主机、数据库等项目事实。",
                    symbolName: "tray"
                )
            }
        } else {
            SectionPlaceholder(
                title: "还没有项目上下文数据。",
                message: "稍后会自动从设备 \(deviceID) 读取。",
                symbolName: "books.vertical"
            )
        }
    }

    private func loadDetail() async {
        isLoading = true
        defer { isLoading = false }

        do {
            detail = try await model.fetchCodexSessionDetail(
                serverURLString: serverURL,
                deviceID: session.deviceID,
                sessionID: session.id
            )
            localErrorMessage = nil
        } catch {
            localErrorMessage = error.localizedDescription
        }
    }

    private func loadProjectContextSummary() async {
        guard let workspaceID = session.workspaceID?.nilIfEmpty else {
            projectContextSummary = nil
            return
        }

        isLoadingProjectContext = true
        defer { isLoadingProjectContext = false }

        do {
            projectContextSummary = try await model.fetchProjectContextSummary(
                serverURLString: serverURL,
                deviceID: session.deviceID,
                workspaceID: workspaceID
            )
        } catch {
            projectContextSummary = AgentProjectContextCommandResponse(
                requestID: "",
                workspaceID: workspaceID,
                available: false,
                errorMessage: error.localizedDescription
            )
        }
    }

    private func continueSession() async {
        isSubmittingPrompt = true
        defer { isSubmittingPrompt = false }

        do {
            detail = try await model.continueCodexSession(
                serverURLString: serverURL,
                deviceID: session.deviceID,
                sessionID: session.id,
                prompt: continuePrompt
            )
            localErrorMessage = nil
            isShowingContinueSheet = false
            showToast("已发送继续指令")
        } catch {
            localErrorMessage = error.localizedDescription
        }
    }

    private func interruptSession() async {
        isInterrupting = true
        defer { isInterrupting = false }

        do {
            detail = try await model.interruptCodexSession(
                serverURLString: serverURL,
                deviceID: session.deviceID,
                sessionID: session.id
            )
            localErrorMessage = nil
            showToast("已发送中断指令")
        } catch {
            localErrorMessage = error.localizedDescription
        }
    }

    private func showToast(_ message: String) {
        toastMessage = message
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if toastMessage == message {
                toastMessage = nil
            }
        }
    }
}

private struct CodexSessionItemRow: View {
    let item: CodexSessionItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Text(item.kind.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if let status = item.status, !status.isEmpty {
                    StatusBadge(title: status, tint: badgeColor)
                }
            }

            Text(item.title)
                .font(.headline)
                .foregroundStyle(.primary)

            if let body = item.body, !body.isEmpty {
                Text(body)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
    }

    private var badgeColor: Color {
        switch item.status {
        case "failed":
            return .red
        case "inProgress":
            return .blue
        case "completed":
            return .green
        case "declined":
            return .orange
        default:
            return .secondary
        }
    }
}
