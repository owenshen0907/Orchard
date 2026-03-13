import OrchardCore
import SwiftUI

struct ManagedRunDetailView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var model: AppModel
    let serverURL: String

    @State private var activeRun: ManagedRunSummary
    @State private var detail: ManagedRunDetail?
    @State private var isLoading = false
    @State private var isShowingContinueSheet = false
    @State private var continuePrompt = ""
    @State private var isSubmittingPrompt = false
    @State private var isInterrupting = false
    @State private var isStopping = false
    @State private var isRetrying = false
    @State private var localErrorMessage: String?
    @State private var toastMessage: String?
    @State private var projectContextSummary: AgentProjectContextCommandResponse?
    @State private var isLoadingProjectContext = false
    @State private var isShowingProjectContextSheet = false

    private let metricColumns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
    ]

    init(model: AppModel, serverURL: String, initialRun: ManagedRunSummary) {
        self.model = model
        self.serverURL = serverURL
        _activeRun = State(initialValue: initialRun)
    }

    private var currentRun: ManagedRunSummary {
        detail?.run ?? activeRun
    }

    private var autoRefreshTaskID: String {
        "\(serverURL)|\(currentRun.id)|\(scenePhase == .active ? "active" : "inactive")"
    }

    private var projectContextTaskID: String {
        "\(currentRun.deviceID ?? "none")|\(currentRun.workspaceID)"
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    HeroCard(
                        eyebrow: currentRun.deviceDisplayName,
                        title: currentRun.statusTitle,
                        message: currentRun.subtitleText,
                        symbolName: currentRun.statusSymbolName,
                        tint: currentRun.stateColor
                    )

                    LazyVGrid(columns: metricColumns, spacing: 14) {
                        DetailHeroMetric(title: "驱动", value: currentRun.driver == .codexCLI ? "Codex CLI" : currentRun.driver.rawValue)
                        DetailHeroMetric(title: "工作区", value: currentRun.workspaceID)
                        DetailHeroMetric(title: "目录", value: currentRun.shortCWD)
                        DetailHeroMetric(
                            title: "更新时间",
                            value: currentRun.updatedAt.formatted(date: .omitted, time: .shortened)
                        )
                    }
                }
                .padding(.vertical, 4)
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)
            }

            Section {
                LabeledContent("运行 ID", value: currentRun.id)
                if let taskID = currentRun.taskID {
                    LabeledContent("底层任务", value: taskID)
                }
                LabeledContent("设备", value: currentRun.deviceDisplayName)
                LabeledContent("路径", value: currentRun.cwd)
                if let exitCode = currentRun.exitCode {
                    LabeledContent("退出码", value: "\(exitCode)")
                }
                if let sessionID = currentRun.codexSessionID {
                    LabeledContent("Codex 会话", value: sessionID)
                }
            } header: {
                SectionHeaderLabel(title: "概况")
            }

            Section {
                if let deviceID = currentRun.deviceID?.nilIfEmpty {
                    projectContextSection(deviceID: deviceID)
                } else {
                    SectionPlaceholder(
                        title: "运行还没有分配设备。",
                        message: "等控制面把任务落到具体设备后，这里会自动显示项目上下文。",
                        symbolName: "desktopcomputer.and.arrow.down"
                    )
                }
            } header: {
                SectionHeaderLabel(title: "项目上下文", subtitle: currentRun.workspaceID)
            }

            if let prompt = currentRun.lastUserPrompt?.trimmedOrEmpty, !prompt.isEmpty {
                Section {
                    Text(prompt)
                        .font(.subheadline)
                        .textSelection(.enabled)
                } header: {
                    SectionHeaderLabel(title: "最近输入")
                }
            }

            Section {
                if isLoading && detail == nil {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                } else if let events = detail?.events, !events.isEmpty {
                    ForEach(events.sorted { $0.createdAt > $1.createdAt }) { event in
                        ManagedRunEventRow(event: event)
                    }
                } else {
                    SectionPlaceholder(
                        title: "当前没有事件记录。",
                        message: "刷新后会重新读取控制面的运行时间线。",
                        symbolName: "list.bullet.rectangle"
                    )
                }
            } header: {
                SectionHeaderLabel(title: "事件")
            }

            Section {
                if let logs = detail?.logs, !logs.isEmpty {
                    ForEach(logs.sorted { $0.createdAt > $1.createdAt }.prefix(200)) { log in
                        ManagedRunLogRow(log: log)
                    }
                } else {
                    SectionPlaceholder(
                        title: "当前还没有日志。",
                        message: "当 Agent 把运行输出同步到控制面后，这里会自动更新。",
                        symbolName: "text.alignleft"
                    )
                }
            } header: {
                SectionHeaderLabel(title: "日志")
            }

            if !canContinueCurrentRun && !canInterruptCurrentRun && !currentRun.status.isTerminal {
                Section {
                    Text("当前 run 还没有进入可交互状态。等到出现“等待输入”或“运行中”后，就可以继续追问或中断。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    SectionHeaderLabel(title: "交互状态")
                }
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
        .navigationTitle(currentRun.title)
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
                        copyTextToPasteboard(currentRun.id)
                        showToast("已复制运行 ID")
                    } label: {
                        Label("复制运行 ID", systemImage: "number")
                    }

                    Button {
                        copyTextToPasteboard(currentRun.cwd)
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
                    if canContinueCurrentRun {
                        Button("继续追问") {
                            continuePrompt = ""
                            isShowingContinueSheet = true
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .disabled(isSubmittingPrompt)
                    }

                    if canInterruptCurrentRun {
                        Button("中断") {
                            Task {
                                await interruptRun()
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                        .disabled(isInterrupting)
                    }

                    if canStopCurrentRun {
                        Button("停止") {
                            Task {
                                await stopRun()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .disabled(isStopping)
                    } else if currentRun.status == .stopRequested {
                        Button("停止中") {}
                            .buttonStyle(.bordered)
                            .disabled(true)
                    }

                    if currentRun.status.isTerminal {
                        Button("重试") {
                            Task {
                                await retryRun()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .disabled(isRetrying)
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
                title: "继续 run",
                message: "继续追问会直接发到当前托管运行。",
                subject: currentRun.title,
                prompt: $continuePrompt,
                isSubmitting: isSubmittingPrompt,
                errorMessage: localErrorMessage,
                projectCommandSource: currentRun.deviceID?.nilIfEmpty.map { deviceID in
                    ProjectCommandQuickInsertSource(
                        model: model,
                        serverURL: serverURL,
                        context: ProjectCommandQuickInsertContext(
                            deviceID: deviceID,
                            workspaceID: currentRun.workspaceID
                        )
                    )
                },
                onCancel: {
                    isShowingContinueSheet = false
                },
                onSubmit: {
                    Task {
                        await continueRun()
                    }
                }
            )
        }
        .sheet(isPresented: $isShowingProjectContextSheet) {
            if let deviceID = currentRun.deviceID?.nilIfEmpty {
                ProjectContextInspectorSheet(
                    model: model,
                    serverURL: serverURL,
                    deviceID: deviceID,
                    deviceName: currentRun.deviceDisplayName,
                    workspaceID: currentRun.workspaceID
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

    private var canStopCurrentRun: Bool {
        !currentRun.status.isTerminal && currentRun.status != .stopRequested
    }

    private var canContinueCurrentRun: Bool {
        currentRun.status == .waitingInput && !(currentRun.codexSessionID?.isEmpty ?? true)
    }

    private var canInterruptCurrentRun: Bool {
        (currentRun.status == .running || currentRun.status == .waitingInput) && !(currentRun.codexSessionID?.isEmpty ?? true)
    }

    @ViewBuilder
    private func projectContextSection(deviceID: String) -> some View {
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
                        message: "项目结构已识别，但后续执行仍可能缺少 credential。",
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

    private func loadDetail(runID: String? = nil) async {
        isLoading = true
        defer { isLoading = false }

        do {
            let loadedDetail = try await model.fetchManagedRunDetail(
                serverURLString: serverURL,
                runID: runID ?? currentRun.id
            )
            detail = loadedDetail
            activeRun = loadedDetail.run
            localErrorMessage = nil
        } catch {
            localErrorMessage = error.localizedDescription
        }
    }

    private func loadProjectContextSummary() async {
        guard let deviceID = currentRun.deviceID?.nilIfEmpty else {
            projectContextSummary = nil
            return
        }

        isLoadingProjectContext = true
        defer { isLoadingProjectContext = false }

        do {
            projectContextSummary = try await model.fetchProjectContextSummary(
                serverURLString: serverURL,
                deviceID: deviceID,
                workspaceID: currentRun.workspaceID
            )
        } catch {
            projectContextSummary = AgentProjectContextCommandResponse(
                requestID: "",
                workspaceID: currentRun.workspaceID,
                available: false,
                errorMessage: error.localizedDescription
            )
        }
    }

    private func stopRun() async {
        isStopping = true
        defer { isStopping = false }

        do {
            activeRun = try await model.stopManagedRun(
                serverURLString: serverURL,
                runID: currentRun.id,
                reason: "移动端请求停止"
            )
            detail = nil
            await loadDetail()
            showToast("已发送停止指令")
        } catch {
            localErrorMessage = error.localizedDescription
        }
    }

    private func continueRun() async {
        isSubmittingPrompt = true
        defer { isSubmittingPrompt = false }

        do {
            let updatedDetail = try await model.continueManagedRun(
                serverURLString: serverURL,
                runID: currentRun.id,
                prompt: continuePrompt
            )
            detail = updatedDetail
            activeRun = updatedDetail.run
            localErrorMessage = nil
            isShowingContinueSheet = false
            showToast("已发送继续指令")
        } catch {
            localErrorMessage = error.localizedDescription
        }
    }

    private func interruptRun() async {
        isInterrupting = true
        defer { isInterrupting = false }

        do {
            let updatedDetail = try await model.interruptManagedRun(
                serverURLString: serverURL,
                runID: currentRun.id
            )
            detail = updatedDetail
            activeRun = updatedDetail.run
            localErrorMessage = nil
            showToast("已发送中断指令")
        } catch {
            localErrorMessage = error.localizedDescription
        }
    }

    private func retryRun() async {
        isRetrying = true
        defer { isRetrying = false }

        do {
            let retried = try await model.retryManagedRun(serverURLString: serverURL, runID: currentRun.id)
            activeRun = retried
            detail = nil
            await loadDetail(runID: retried.id)
            showToast("已创建新的重试运行")
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

private struct ManagedRunEventRow: View {
    let event: ManagedRunEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Text(event.title)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Spacer(minLength: 12)

                Text(event.createdAt, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let message = event.message?.trimmedOrEmpty, !message.isEmpty {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ManagedRunLogRow: View {
    let log: ManagedRunLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(log.createdAt, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(log.deviceID)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }

            Text(log.line)
                .font(.footnote.monospaced())
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
    }
}
