import OrchardCore
import SwiftUI

private enum DashboardContinueTarget: Identifiable {
    case managed(ManagedRunSummary)
    case codex(CodexSessionSummary)

    var id: String {
        switch self {
        case let .managed(run):
            return "managed:\(run.id)"
        case let .codex(session):
            return "codex:\(session.deviceID):\(session.id)"
        }
    }

    var title: String {
        switch self {
        case .managed:
            return "继续 run"
        case .codex:
            return "继续会话"
        }
    }

    var message: String {
        switch self {
        case .managed:
            return "继续追问会直接发到当前托管运行。"
        case .codex:
            return "继续追问会直接发到当前 Codex 会话。"
        }
    }

    var subject: String {
        switch self {
        case let .managed(run):
            return run.title
        case let .codex(session):
            return session.titleText
        }
    }

    func projectCommandSource(model: AppModel, serverURL: String) -> ProjectCommandQuickInsertSource? {
        switch self {
        case let .managed(run):
            guard let deviceID = run.deviceID?.nilIfEmpty else {
                return nil
            }
            return ProjectCommandQuickInsertSource(
                model: model,
                serverURL: serverURL,
                context: ProjectCommandQuickInsertContext(
                    deviceID: deviceID,
                    workspaceID: run.workspaceID
                )
            )
        case let .codex(session):
            guard let workspaceID = session.workspaceID?.nilIfEmpty else {
                return nil
            }
            return ProjectCommandQuickInsertSource(
                model: model,
                serverURL: serverURL,
                context: ProjectCommandQuickInsertContext(
                    deviceID: session.deviceID,
                    workspaceID: workspaceID
                )
            )
        }
    }
}

struct DashboardView: View {
    @ObservedObject var model: AppModel
    let serverURL: String
    @Binding var isShowingSettings: Bool

    @State private var isShowingCreateSheet = false
    @State private var createdRunForNavigation: ManagedRunSummary?
    @State private var isShowingCreatedRunDetail = false
    @State private var continueTarget: DashboardContinueTarget?
    @State private var continuePrompt = ""
    @State private var isSubmittingPrompt = false
    @State private var actionInFlightID: String?
    @State private var actionErrorMessage: String?
    @State private var toastMessage: String?

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        List {
            Section {
                HeroCard(
                    eyebrow: "控制面",
                    title: model.overviewTitle,
                    message: model.overviewMessage,
                    symbolName: model.overviewSymbolName,
                    tint: model.overviewTint
                )
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 10, trailing: 0))
                .listRowBackground(Color.clear)

                LazyVGrid(columns: columns, spacing: 12) {
                    MetricCard(
                        title: "在线设备",
                        value: "\(model.snapshot.onlineDeviceCount)",
                        symbolName: "desktopcomputer",
                        tint: .green,
                        detail: "当前可调度机器"
                    )
                    MetricCard(
                        title: "总运行中",
                        value: "\(model.combinedRunningCount)",
                        symbolName: "bolt.horizontal.fill",
                        tint: .blue,
                        detail: "托管运行 + 独立任务 + Codex 推理（含 inflight 兜底）"
                    )
                    MetricCard(
                        title: "托管运行",
                        value: "\(model.snapshot.runningManagedRunCount)",
                        symbolName: "shippingbox.fill",
                        tint: .blue,
                        detail: "作为 Orchard 的运行真相"
                    )
                    MetricCard(
                        title: "独立任务",
                        value: "\(model.unmanagedRunningTaskCount)",
                        symbolName: "terminal.fill",
                        tint: .teal,
                        detail: "直接走 /api/tasks，未归属托管 run"
                    )
                    MetricCard(
                        title: "Codex 推理",
                        value: "\(model.observedRunningCodexCount)",
                        symbolName: "sparkles.rectangle.stack.fill",
                        tint: .indigo,
                        detail: "会话 running + 桌面 inflight 兜底"
                    )
                    MetricCard(
                        title: "桌面活跃线程",
                        value: "\(model.codexDesktopActiveThreadCount)",
                        symbolName: "waveform.path.ecg",
                        tint: .indigo,
                        detail: "来自 Codex 桌面实时快照"
                    )
                    MetricCard(
                        title: "未映射线程",
                        value: "\(model.codexDesktopLiveGapCount)",
                        symbolName: "exclamationmark.arrow.trianglehead.counterclockwise",
                        tint: .orange,
                        detail: "桌面端活跃，但会话桥尚未精确命中"
                    )
                    MetricCard(
                        title: "Codex 待命",
                        value: "\(model.standbyCodexSessionCount)",
                        symbolName: "pause.circle.fill",
                        tint: .indigo,
                        detail: "保留上下文，可直接续问"
                    )
                    MetricCard(
                        title: "进行中轮次",
                        value: "\(model.codexDesktopInflightTurnCount)",
                        symbolName: "hourglass.circle.fill",
                        tint: .orange,
                        detail: "即使会话桥未精确命中也会统计"
                    )
                    MetricCard(
                        title: "失败运行",
                        value: "\(model.snapshot.failedManagedRunCount)",
                        symbolName: "exclamationmark.triangle.fill",
                        tint: .red,
                        detail: "需要人工处理"
                    )
                    MetricCard(
                        title: "最近刷新",
                        value: model.lastRefreshAt?.formatted(date: .omitted, time: .shortened) ?? "--",
                        symbolName: "clock",
                        tint: .secondary,
                        detail: "支持下拉刷新"
                    )
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)

                if model.shouldShowCodexDiagnostics {
                    CodexDiagnosticsCard(
                        summary: model.codexDiagnosticsSummaryText,
                        sourceSummary: model.codexSourceSummaryText,
                        turnSummary: model.codexTurnSummaryText,
                        conclusion: model.codexConclusionText,
                        tint: model.codexDiagnosticsTint
                    )
                    .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 8, trailing: 0))
                    .listRowBackground(Color.clear)

                    if let codexLiveGapNoticeText = model.codexLiveGapNoticeText {
                        NoticeCard(
                            title: "会话映射仍有缺口",
                            message: codexLiveGapNoticeText,
                            symbolName: "exclamationmark.triangle.fill",
                            tint: .orange
                        )
                        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 8, trailing: 0))
                        .listRowBackground(Color.clear)
                    }
                }
            }

            Section {
                Button {
                    isShowingCreateSheet = true
                } label: {
                    NoticeCard(
                        title: "新建托管 run",
                        message: "直接从概览页发起 Codex 托管任务，创建后自动打开详情页。",
                        symbolName: "plus.circle.fill",
                        tint: .blue
                    )
                }
                .buttonStyle(.plain)
            } header: {
                SectionHeaderLabel(
                    title: "快速动作",
                    subtitle: "手机端直接下发新的托管运行"
                )
            }

            if model.hasLocalMatchedDevice {
                Section {
                    if model.localManagedRuns.isEmpty {
                        NoticeCard(
                            title: "本机宿主暂时空闲",
                            message: model.localManagedRunsSummaryText,
                            symbolName: "desktopcomputer",
                            tint: .secondary
                        )
                        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(model.localManagedRuns.prefix(5)) { run in
                            VStack(alignment: .leading, spacing: 10) {
                                NavigationLink {
                                    ManagedRunDetailView(model: model, serverURL: serverURL, initialRun: run)
                                } label: {
                                    ManagedRunRow(run: run)
                                }

                                if run.canContinueRemotely || run.canInterruptRemotely || run.canStopRemotely || run.isStopRequestedRemotely {
                                    CompanionInlineActions(
                                        canContinue: run.canContinueRemotely,
                                        canInterrupt: run.canInterruptRemotely,
                                        canStop: run.canStopRemotely,
                                        isStopRequested: run.isStopRequestedRemotely,
                                        isPerformingAction: actionInFlightID == managedActionID(for: run),
                                        onContinue: {
                                            actionErrorMessage = nil
                                            continuePrompt = ""
                                            continueTarget = .managed(run)
                                        },
                                        onInterrupt: {
                                            Task {
                                                await interruptManagedRun(run)
                                            }
                                        },
                                        onStop: {
                                            Task {
                                                await stopManagedRun(run)
                                            }
                                        }
                                    )
                                    .padding(.leading, 56)
                                    .padding(.bottom, 6)
                                }
                            }
                        }
                    }
                } header: {
                    SectionHeaderLabel(
                        title: "本机接手",
                        subtitle: "\(model.localMatchedDeviceTitle)；\(model.localManagedRunsSummaryText)"
                    )
                }
            }

            Section {
                if let actionErrorMessage, !actionErrorMessage.isEmpty {
                    NoticeCard(
                        title: "操作失败",
                        message: actionErrorMessage,
                        symbolName: "exclamationmark.triangle.fill",
                        tint: .red
                    )
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                    .listRowBackground(Color.clear)
                }

                if model.snapshot.attentionManagedRuns.isEmpty {
                    SectionPlaceholder(
                        title: "当前没有需要立即介入的托管运行。",
                        message: "失败、等待继续或运行中的托管运行会优先显示在这里。",
                        symbolName: "checkmark.circle"
                    )
                } else {
                    ForEach(model.snapshot.attentionManagedRuns.prefix(5)) { run in
                        VStack(alignment: .leading, spacing: 10) {
                            NavigationLink {
                                ManagedRunDetailView(model: model, serverURL: serverURL, initialRun: run)
                            } label: {
                                ManagedRunRow(run: run)
                            }

                            if run.canContinueRemotely || run.canInterruptRemotely || run.canStopRemotely || run.isStopRequestedRemotely {
                                CompanionInlineActions(
                                    canContinue: run.canContinueRemotely,
                                    canInterrupt: run.canInterruptRemotely,
                                    canStop: run.canStopRemotely,
                                    isStopRequested: run.isStopRequestedRemotely,
                                    isPerformingAction: actionInFlightID == managedActionID(for: run),
                                    onContinue: {
                                        actionErrorMessage = nil
                                        continuePrompt = ""
                                        continueTarget = .managed(run)
                                    },
                                    onInterrupt: {
                                        Task {
                                            await interruptManagedRun(run)
                                        }
                                    },
                                    onStop: {
                                        Task {
                                            await stopManagedRun(run)
                                        }
                                    }
                                )
                                .padding(.leading, 56)
                                .padding(.bottom, 6)
                            }
                        }
                    }
                }
            } header: {
                SectionHeaderLabel(
                    title: "需要关注",
                    subtitle: model.snapshot.attentionManagedRuns.isEmpty ? "系统当前比较安静" : "优先处理这些运行"
                )
            }

            Section {
                if model.codexAttentionSessions.isEmpty {
                    SectionPlaceholder(
                        title: "当前没有可关注的 Codex 会话。",
                        message: "桌面端出现推理中或待命线程后，这里会优先显示。",
                        symbolName: "sparkles.tv"
                    )
                } else {
                    ForEach(model.codexAttentionSessions.prefix(5)) { session in
                        VStack(alignment: .leading, spacing: 10) {
                            NavigationLink {
                                CodexSessionDetailView(model: model, serverURL: serverURL, initialSession: session)
                            } label: {
                                CodexSessionRow(session: session)
                            }

                            if session.canContinueRemotely || session.canInterruptRemotely {
                                CompanionInlineActions(
                                    canContinue: session.canContinueRemotely,
                                    canInterrupt: session.canInterruptRemotely,
                                    canStop: false,
                                    isStopRequested: false,
                                    isPerformingAction: actionInFlightID == codexActionID(for: session),
                                    onContinue: {
                                        actionErrorMessage = nil
                                        continuePrompt = ""
                                        continueTarget = .codex(session)
                                    },
                                    onInterrupt: {
                                        Task {
                                            await interruptCodexSession(session)
                                        }
                                    },
                                    onStop: {}
                                )
                                .padding(.leading, 56)
                                .padding(.bottom, 6)
                            }
                        }
                    }
                }
            } header: {
                SectionHeaderLabel(
                    title: "Codex 会话",
                    subtitle: model.codexAttentionSessions.isEmpty ? "暂时没有远程会话" : "推理中、待命和刚结束的线程"
                )
            }

            Section {
                if model.snapshot.onlineDevices.isEmpty {
                    SectionPlaceholder(
                        title: "当前没有在线设备。",
                        message: "设备上线后会在这里显示最近活跃的机器。",
                        symbolName: "desktopcomputer.trianglebadge.exclamationmark"
                    )
                } else {
                    ForEach(model.snapshot.onlineDevices.prefix(5)) { device in
                        NavigationLink {
                            DeviceDetailView(model: model, device: device)
                        } label: {
                            DeviceRow(
                                device: device,
                                combinedRunningCount: model.combinedRunningCount(for: device),
                                codexGapSummary: model.codexDesktopGapSummary(for: device)
                            )
                        }
                    }
                }
            } header: {
                SectionHeaderLabel(
                    title: "在线设备",
                    subtitle: model.snapshot.onlineDevices.isEmpty ? nil : "最近在线的机器"
                )
            }

            if let errorMessage = model.errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                } header: {
                    SectionHeaderLabel(title: "连接状态")
                }
            }
        }
        .companionListStyle()
        .navigationTitle("Orchard")
        .companionToast(message: toastMessage)
        .navigationDestination(isPresented: $isShowingCreatedRunDetail) {
            if let createdRunForNavigation {
                ManagedRunDetailView(
                    model: model,
                    serverURL: serverURL,
                    initialRun: createdRunForNavigation
                )
            } else {
                ProgressView("正在打开运行详情...")
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: CompanionToolbarPlacement.trailing) {
                Button {
                    isShowingCreateSheet = true
                } label: {
                    Image(systemName: "plus")
                }

                SettingsToolbarButton(isPresented: $isShowingSettings)
            }
        }
        .sheet(isPresented: $isShowingCreateSheet) {
            CreateManagedRunSheet(model: model, serverURL: serverURL) { run in
                createdRunForNavigation = run
                isShowingCreatedRunDetail = true
            }
        }
        .sheet(item: $continueTarget) { target in
            CompanionContinuePromptSheet(
                title: target.title,
                message: target.message,
                subject: target.subject,
                prompt: $continuePrompt,
                isSubmitting: isSubmittingPrompt,
                errorMessage: actionErrorMessage,
                projectCommandSource: target.projectCommandSource(model: model, serverURL: serverURL),
                onCancel: {
                    continueTarget = nil
                },
                onSubmit: {
                    Task {
                        await continueTarget(target)
                    }
                }
            )
        }
        .refreshable {
            actionErrorMessage = nil
            await model.refresh(serverURLString: serverURL)
        }
    }

    private func managedActionID(for run: ManagedRunSummary) -> String {
        "managed:\(run.id)"
    }

    private func codexActionID(for session: CodexSessionSummary) -> String {
        "codex:\(session.deviceID):\(session.id)"
    }

    private func continueTarget(_ target: DashboardContinueTarget) async {
        let prompt = continuePrompt.trimmedOrEmpty
        guard !prompt.isEmpty else {
            return
        }

        isSubmittingPrompt = true
        actionInFlightID = target.id
        actionErrorMessage = nil
        defer {
            isSubmittingPrompt = false
            if actionInFlightID == target.id {
                actionInFlightID = nil
            }
        }

        do {
            switch target {
            case let .managed(run):
                _ = try await model.continueManagedRun(
                    serverURLString: serverURL,
                    runID: run.id,
                    prompt: prompt
                )
            case let .codex(session):
                _ = try await model.continueCodexSession(
                    serverURLString: serverURL,
                    deviceID: session.deviceID,
                    sessionID: session.id,
                    prompt: prompt
                )
            }
            continuePrompt = ""
            continueTarget = nil
            showToast("已发送继续指令")
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    private func interruptManagedRun(_ run: ManagedRunSummary) async {
        guard run.canInterruptRemotely else {
            return
        }

        let actionID = managedActionID(for: run)
        actionInFlightID = actionID
        actionErrorMessage = nil
        defer {
            if actionInFlightID == actionID {
                actionInFlightID = nil
            }
        }

        do {
            _ = try await model.interruptManagedRun(
                serverURLString: serverURL,
                runID: run.id
            )
            showToast("已发送中断指令")
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    private func stopManagedRun(_ run: ManagedRunSummary) async {
        guard run.canStopRemotely else {
            return
        }

        let actionID = managedActionID(for: run)
        actionInFlightID = actionID
        actionErrorMessage = nil
        defer {
            if actionInFlightID == actionID {
                actionInFlightID = nil
            }
        }

        do {
            _ = try await model.stopManagedRun(
                serverURLString: serverURL,
                runID: run.id,
                reason: "移动端请求停止"
            )
            showToast("已发送停止指令")
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    private func interruptCodexSession(_ session: CodexSessionSummary) async {
        guard session.canInterruptRemotely else {
            return
        }

        let actionID = codexActionID(for: session)
        actionInFlightID = actionID
        actionErrorMessage = nil
        defer {
            if actionInFlightID == actionID {
                actionInFlightID = nil
            }
        }

        do {
            _ = try await model.interruptCodexSession(
                serverURLString: serverURL,
                deviceID: session.deviceID,
                sessionID: session.id
            )
            showToast("已发送中断指令")
        } catch {
            actionErrorMessage = error.localizedDescription
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

#if DEBUG
@MainActor
struct DashboardView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            DashboardView(
                model: CompanionPreviewData.model,
                serverURL: "http://preview.local/",
                isShowingSettings: .constant(false)
            )
        }
    }
}
#endif
