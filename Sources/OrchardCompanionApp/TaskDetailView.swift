import OrchardCore
import SwiftUI

struct TaskDetailView: View {
    @ObservedObject var model: AppModel
    let serverURL: String
    let initialTask: TaskRecord

    @State private var detail: TaskDetail?
    @State private var isLoading = false
    @State private var isRetrying = false
    @State private var isShowingRetryTask = false
    @State private var isShowingStopConfirmation = false
    @State private var localErrorMessage: String?
    @State private var retryTaskDestination: TaskRecord?
    @State private var toastMessage: String?

    private let metricColumns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
    ]

    init(model: AppModel, serverURL: String, initialTask: TaskRecord, initialDetail: TaskDetail? = nil) {
        self.model = model
        self.serverURL = serverURL
        self.initialTask = initialTask
        _detail = State(initialValue: initialDetail)
    }

    private var currentTask: TaskRecord {
        detail?.task ?? initialTask
    }

    private var heroMessage: String {
        if let summary = currentTask.summary?.displaySnippet(limit: 120) {
            return summary
        }
        return currentTask.payloadPreview.displaySnippet(limit: 120)
    }

    private var logCountTitle: String {
        guard let count = detail?.logs.count else {
            return "日志"
        }
        return "日志 · \(count)"
    }

    private var failureSummaryTitle: String? {
        guard currentTask.status == .failed else {
            return nil
        }
        if let exitCode = currentTask.exitCode {
            return "失败摘要 · 退出码 \(exitCode)"
        }
        return "失败摘要"
    }

    private var failureSummaryMessage: String? {
        guard currentTask.status == .failed else {
            return nil
        }

        if let summary = currentTask.summary?.trimmedOrEmpty, !summary.isEmpty {
            return summary
        }
        return "当前没有失败摘要，建议继续查看下方日志定位原因。"
    }

    private var actionTitle: String? {
        switch currentTask.status {
        case .queued:
            return "取消任务"
        case .running:
            return "停止任务"
        case .stopRequested:
            return "停止中"
        case .succeeded, .failed, .cancelled:
            return nil
        }
    }

    private var actionDisabled: Bool {
        currentTask.status == .stopRequested
    }

    private var canRetry: Bool {
        switch currentTask.status {
        case .failed, .cancelled, .succeeded:
            return true
        case .queued, .running, .stopRequested:
            return false
        }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    HeroCard(
                        eyebrow: currentTask.kind.displayName,
                        title: currentTask.statusTitle,
                        message: heroMessage,
                        symbolName: currentTask.statusSymbolName,
                        tint: currentTask.stateColor
                    )

                    LazyVGrid(columns: metricColumns, spacing: 14) {
                        DetailHeroMetric(title: "工作区", value: currentTask.workspaceID)
                        DetailHeroMetric(title: "设备", value: currentTask.assignedDeviceID ?? "待分配")
                        DetailHeroMetric(title: "优先级", value: currentTask.priority.displayName)
                        DetailHeroMetric(
                            title: "更新时间",
                            value: currentTask.updatedAt.formatted(date: .omitted, time: .shortened)
                        )
                    }
                }
                .padding(.vertical, 4)
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)
            }

            if let failureSummaryTitle, let failureSummaryMessage {
                Section {
                    NoticeCard(
                        title: failureSummaryTitle,
                        message: failureSummaryMessage,
                        symbolName: "exclamationmark.triangle.fill",
                        tint: .red
                    )
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 6, trailing: 0))
                    .listRowBackground(Color.clear)
                }
            }

            Section {
                LabeledContent("状态") {
                    StatusBadge(title: currentTask.statusTitle, tint: currentTask.stateColor)
                }
                LabeledContent("类型", value: currentTask.kind.displayName)
                LabeledContent("工作区", value: currentTask.workspaceID)
                LabeledContent("设备", value: currentTask.assignedDeviceID ?? "待分配")

                if let relativePath = currentTask.relativePath, !relativePath.isEmpty {
                    LabeledContent("路径", value: relativePath)
                }

                if let summary = currentTask.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.subheadline)
                }
            } header: {
                SectionHeaderLabel(title: "概况")
            }

            Section {
                Text(currentTask.payloadPreview)
                    .font(.subheadline.monospaced())
                    .textSelection(.enabled)
            } header: {
                SectionHeaderLabel(
                    title: "内容",
                    subtitle: currentTask.kind == .shell ? "执行命令" : "任务提示词"
                )
            }

            Section {
                LabeledContent("创建于") {
                    Text(currentTask.createdAt.formatted(date: .abbreviated, time: .shortened))
                }
                LabeledContent("更新于") {
                    Text(currentTask.updatedAt.formatted(date: .abbreviated, time: .shortened))
                }
            } header: {
                SectionHeaderLabel(title: "时间")
            }

            Section {
                if isLoading && detail == nil {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                } else if let logs = detail?.logs, !logs.isEmpty {
                    ForEach(logs) { log in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(log.createdAt.formatted(date: .omitted, time: .standard))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(log.line)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 4)
                    }
                } else {
                    SectionPlaceholder(
                        title: "当前没有日志。",
                        message: "任务开始输出后，这里会显示最近的执行记录。",
                        symbolName: "text.alignleft"
                    )
                }
            } header: {
                SectionHeaderLabel(title: logCountTitle)
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
        .navigationTitle(currentTask.title)
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
                        copyTextToPasteboard(currentTask.id)
                        showToast("已复制任务 ID")
                    } label: {
                        Label("复制任务 ID", systemImage: "number")
                    }

                    Button {
                        copyTextToPasteboard(currentTask.payloadPreview)
                        showToast(currentTask.kind == .shell ? "已复制命令" : "已复制提示词")
                    } label: {
                        Label(currentTask.kind == .shell ? "复制命令" : "复制提示词", systemImage: "doc.on.doc")
                    }

                    if canRetry {
                        Button {
                            Task {
                                await retryTask()
                            }
                        } label: {
                            Label("重试并打开", systemImage: "arrow.clockwise.circle")
                        }
                        .disabled(isRetrying)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let actionTitle {
                VStack(spacing: 0) {
                    Divider()
                    Button(actionTitle) {
                        if actionDisabled {
                            return
                        }
                        isShowingStopConfirmation = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(actionDisabled ? .orange : .red)
                    .disabled(actionDisabled)
                    .padding(.horizontal)
                    .padding(.top, 10)
                    .padding(.bottom, 12)
                }
                .background(.bar)
            }
        }
        .confirmationDialog(
            "确认修改任务状态？",
            isPresented: $isShowingStopConfirmation,
            titleVisibility: .visible
        ) {
            Button(actionTitle ?? "停止任务", role: .destructive) {
                Task {
                    await stopTask()
                }
            }
        } message: {
            Text("这个操作会尝试停止当前任务。")
        }
        .navigationDestination(isPresented: $isShowingRetryTask) {
            if let retryTaskDestination {
                TaskDetailView(model: model, serverURL: serverURL, initialTask: retryTaskDestination)
            }
        }
        .task {
            if detail == nil {
                await loadDetail()
            }
        }
    }

    private func loadDetail() async {
        isLoading = true
        defer { isLoading = false }

        do {
            detail = try await model.fetchTaskDetail(serverURLString: serverURL, taskID: initialTask.id)
            localErrorMessage = nil
        } catch {
            localErrorMessage = error.localizedDescription
        }
    }

    private func stopTask() async {
        do {
            _ = try await model.stopTask(serverURLString: serverURL, taskID: currentTask.id)
            await loadDetail()
            localErrorMessage = nil
            showToast("已提交停止请求")
        } catch {
            localErrorMessage = error.localizedDescription
        }
    }

    private func retryTask() async {
        isRetrying = true
        defer { isRetrying = false }

        let request = CreateTaskRequest(
            title: currentTask.title,
            kind: currentTask.kind,
            workspaceID: currentTask.workspaceID,
            relativePath: currentTask.relativePath,
            priority: currentTask.priority,
            preferredDeviceID: currentTask.preferredDeviceID,
            payload: currentTask.payload
        )

        do {
            let newTask = try await model.createTask(serverURLString: serverURL, request: request)
            localErrorMessage = nil
            showToast("已创建重试任务")
            retryTaskDestination = newTask
            isShowingRetryTask = true
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

#if DEBUG
@MainActor
struct TaskDetailView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            TaskDetailView(
                model: CompanionPreviewData.model,
                serverURL: "http://preview.local/",
                initialTask: CompanionPreviewData.failedTask,
                initialDetail: CompanionPreviewData.failedTaskDetail
            )
        }
    }
}
#endif
