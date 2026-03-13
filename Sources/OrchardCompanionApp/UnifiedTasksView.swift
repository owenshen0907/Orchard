import OrchardCore
import SwiftUI

private enum UnifiedTaskStateFilter: String, CaseIterable, Identifiable {
    case attention
    case active
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .attention:
            return "需处理"
        case .active:
            return "未结束"
        case .all:
            return "全部"
        }
    }
}

private enum UnifiedTaskSourceFilter: String, CaseIterable, Identifiable {
    case all
    case managed
    case task
    case codex

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "全部来源"
        case .managed:
            return "托管运行"
        case .task:
            return "独立任务"
        case .codex:
            return "Codex 会话"
        }
    }
}

private enum UnifiedTaskKind {
    case managed(ManagedRunSummary)
    case task(TaskRecord)
    case codex(CodexSessionSummary)
}

private struct UnifiedTaskContinueTarget: Identifiable {
    let item: UnifiedTaskItem

    var id: String { item.id }

    var navigationTitle: String {
        switch item.kind {
        case .managed:
            return "继续 run"
        case .task:
            return "继续任务"
        case .codex:
            return "继续会话"
        }
    }

    var detailTitle: String {
        switch item.kind {
        case .managed:
            return "继续追问会直接发到当前托管运行。"
        case .task:
            return "独立任务不支持继续追问。"
        case .codex:
            return "继续追问会直接发到当前 Codex 会话。"
        }
    }

    func projectCommandSource(model: AppModel, serverURL: String) -> ProjectCommandQuickInsertSource? {
        switch item.kind {
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
        case .task:
            return nil
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

private struct UnifiedTaskItem: Identifiable {
    let id: String
    let kind: UnifiedTaskKind
    let title: String
    let subtitle: String
    let statusTitle: String
    let statusColor: Color
    let statusSymbolName: String
    let sourceTitle: String
    let sourceSymbolName: String
    let deviceTitle: String
    let pathTitle: String
    let workspaceTitle: String?
    let updatedAt: Date
    let deviceID: String?
    let isTerminal: Bool
    let attentionRank: Int
    let searchIndex: String

    init(run: ManagedRunSummary) {
        id = "managed:\(run.id)"
        kind = .managed(run)
        title = run.title
        subtitle = run.subtitleText.displaySnippet(limit: 88)
        statusTitle = run.statusTitle
        statusColor = run.stateColor
        statusSymbolName = run.statusSymbolName
        sourceTitle = "托管运行"
        sourceSymbolName = "shippingbox.fill"
        deviceTitle = run.deviceDisplayName
        pathTitle = run.shortCWD
        workspaceTitle = run.workspaceID
        updatedAt = run.updatedAt
        deviceID = run.deviceID ?? run.preferredDeviceID
        isTerminal = run.status.isTerminal
        attentionRank = run.attentionRank
        searchIndex = [
            run.title,
            run.subtitleText,
            run.promptPreview,
            run.deviceDisplayName,
            run.preferredDeviceID ?? "",
            run.workspaceID,
            run.cwd,
            run.summary ?? "",
            run.lastUserPrompt ?? "",
            sourceTitle,
        ].joined(separator: "\n")
    }

    init(task: TaskRecord) {
        id = "task:\(task.id)"
        kind = .task(task)
        title = task.title
        subtitle = (task.summary?.trimmedOrEmpty.nilIfEmpty ?? task.payloadPreview).displaySnippet(limit: 88)
        statusTitle = task.statusTitle
        statusColor = task.stateColor
        statusSymbolName = task.statusSymbolName
        sourceTitle = "独立任务"
        sourceSymbolName = "terminal.fill"
        deviceTitle = task.assignedDeviceID ?? task.preferredDeviceID ?? "待分配"
        if let relativePath = task.relativePath?.trimmedOrEmpty.nilIfEmpty {
            pathTitle = URL(fileURLWithPath: relativePath).lastPathComponent
        } else {
            pathTitle = task.workspaceID
        }
        workspaceTitle = task.workspaceID
        updatedAt = task.updatedAt
        deviceID = task.assignedDeviceID ?? task.preferredDeviceID
        isTerminal = task.status.isTerminal
        attentionRank = task.attentionRank
        searchIndex = [
            task.id,
            task.title,
            task.payloadPreview,
            task.workspaceID,
            task.relativePath ?? "",
            task.assignedDeviceID ?? "",
            task.preferredDeviceID ?? "",
            task.summary ?? "",
            task.statusTitle,
            sourceTitle,
        ].joined(separator: "\n")
    }

    init(session: CodexSessionSummary) {
        id = "codex:\(session.deviceID):\(session.id)"
        kind = .codex(session)
        title = session.titleText
        subtitle = session.subtitleText.displaySnippet(limit: 88)
        statusTitle = session.derivedStatusTitle
        statusColor = session.derivedStatusColor
        statusSymbolName = session.derivedStatusSymbolName
        sourceTitle = "Codex 会话"
        sourceSymbolName = "sparkles.rectangle.stack.fill"
        deviceTitle = session.deviceName
        pathTitle = URL(fileURLWithPath: session.cwd).lastPathComponent
        workspaceTitle = session.workspaceID
        updatedAt = session.updatedAt
        deviceID = session.deviceID
        isTerminal = session.isFinishedLike
        attentionRank = session.attentionRank
        searchIndex = [
            session.titleText,
            session.subtitleText,
            session.preview,
            session.deviceName,
            session.workspaceID ?? "",
            session.cwd,
            session.source,
            session.derivedStatusTitle,
            sourceTitle,
        ].joined(separator: "\n")
    }

    var canContinue: Bool {
        switch kind {
        case let .managed(run):
            return run.status == .waitingInput && !(run.codexSessionID?.isEmpty ?? true)
        case .task:
            return false
        case .codex:
            return true
        }
    }

    var canInterrupt: Bool {
        switch kind {
        case let .managed(run):
            return (run.status == .running || run.status == .waitingInput) && !(run.codexSessionID?.isEmpty ?? true)
        case .task:
            return false
        case let .codex(session):
            return session.isRunningLike
        }
    }

    var canStop: Bool {
        switch kind {
        case let .managed(run):
            return !run.status.isTerminal && run.status != .stopRequested
        case let .task(task):
            return !task.status.isTerminal && task.status != .stopRequested
        case .codex:
            return false
        }
    }

    var isStopRequested: Bool {
        switch kind {
        case let .managed(run):
            return run.status == .stopRequested
        case let .task(task):
            return task.status == .stopRequested
        case .codex:
            return false
        }
    }

    var quickActionMessage: String {
        switch kind {
        case .managed:
            return "托管运行"
        case .task:
            return "独立任务"
        case .codex:
            return "Codex 会话"
        }
    }
}

struct UnifiedTasksView: View {
    @ObservedObject var model: AppModel
    let serverURL: String
    @Binding var isShowingSettings: Bool

    @AppStorage("orchard.unifiedTasks.stateFilter") private var stateFilterStorage = UnifiedTaskStateFilter.attention.rawValue
    @AppStorage("orchard.unifiedTasks.sourceFilter") private var sourceFilterStorage = UnifiedTaskSourceFilter.all.rawValue
    @AppStorage("orchard.unifiedTasks.deviceFilterID") private var deviceFilterID = ""
    @AppStorage("orchard.unifiedTasks.searchText") private var searchText = ""

    @State private var continueTarget: UnifiedTaskContinueTarget?
    @State private var continuePrompt = ""
    @State private var isSubmittingContinue = false
    @State private var actionInFlightID: String?
    @State private var actionErrorMessage: String?
    @State private var toastMessage: String?
    @State private var isShowingCreateSheet = false
    @State private var createdRunForNavigation: ManagedRunSummary?
    @State private var isShowingCreatedRunDetail = false

    private let unassignedDeviceFilterID = "__unassigned__"

    private var stateFilter: UnifiedTaskStateFilter {
        UnifiedTaskStateFilter(rawValue: stateFilterStorage) ?? .attention
    }

    private var sourceFilter: UnifiedTaskSourceFilter {
        UnifiedTaskSourceFilter(rawValue: sourceFilterStorage) ?? .all
    }

    private var stateFilterBinding: Binding<UnifiedTaskStateFilter> {
        Binding(
            get: { stateFilter },
            set: { stateFilterStorage = $0.rawValue }
        )
    }

    private var sourceFilterBinding: Binding<UnifiedTaskSourceFilter> {
        Binding(
            get: { sourceFilter },
            set: { sourceFilterStorage = $0.rawValue }
        )
    }

    private var allItems: [UnifiedTaskItem] {
        let managed = model.snapshot.managedRuns.map(UnifiedTaskItem.init(run:))
        let tasks = model.unmanagedTasks.map(UnifiedTaskItem.init(task:))
        let codex = model.codexSessions.map(UnifiedTaskItem.init(session:))
        return managed + tasks + codex
    }

    private var filteredItems: [UnifiedTaskItem] {
        allItems
            .filter(matchesStateFilter)
            .filter(matchesSourceFilter)
            .filter(matchesDeviceFilter)
            .filter(matchesSearch)
            .sorted(by: sortItems)
    }

    private var deviceFilterOptions: [(id: String, title: String)] {
        var seen: [String: String] = [:]
        for device in model.snapshot.devices {
            seen[device.deviceID] = device.name
        }
        for session in model.codexSessions where seen[session.deviceID] == nil {
            seen[session.deviceID] = session.deviceName
        }

        let devices = seen
            .map { (id: $0.key, title: $0.value) }
            .sorted { lhs, rhs in
                lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }

        return [("", "全部设备"), (unassignedDeviceFilterID, "待分配")] + devices
    }

    private var heroTitle: String {
        filteredItems.isEmpty ? "\(stateFilter.title)为空" : "\(filteredItems.count) 个\(stateFilter.title)项目"
    }

    private var heroMessage: String {
        switch stateFilter {
        case .attention:
            return "把托管运行、独立任务和 Codex 会话放在同一张列表里，优先处理等待继续、失败和活跃线程，也可以直接新建托管运行。"
        case .active:
            return "这里只看还没结束的项目，包含托管运行、独立任务和 Codex 会话，适合远程盯执行状态。"
        case .all:
            return "统一回看全部托管运行、独立任务和 Codex 会话，便于跨来源搜索。"
        }
    }

    private var sectionSubtitle: String? {
        var parts: [String] = []
        if sourceFilter != .all {
            parts.append(sourceFilter.title)
        }
        if let deviceTitle = deviceFilterOptions.first(where: { $0.id == deviceFilterID })?.title, !deviceFilterID.isEmpty {
            parts.append(deviceTitle)
        }
        if !searchText.trimmedOrEmpty.isEmpty {
            parts.append("“\(searchText.trimmedOrEmpty)”")
        }
        if parts.isEmpty {
            return "按优先级和更新时间排序"
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        List {
            Section {
                HeroCard(
                    eyebrow: "统一任务视图",
                    title: heroTitle,
                    message: heroMessage,
                    symbolName: "point.3.connected.trianglepath.dotted",
                    tint: stateFilter == .attention ? .blue : .indigo
                )
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 10, trailing: 0))
                .listRowBackground(Color.clear)

                Picker("状态", selection: stateFilterBinding) {
                    ForEach(UnifiedTaskStateFilter.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)

                Picker("来源", selection: sourceFilterBinding) {
                    ForEach(UnifiedTaskSourceFilter.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)

                Picker("设备", selection: $deviceFilterID) {
                    ForEach(deviceFilterOptions, id: \.id) { option in
                        Text(option.title).tag(option.id)
                    }
                }
                .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)
            }

            Section {
                Button {
                    isShowingCreateSheet = true
                } label: {
                    NoticeCard(
                        title: "新建 Codex 托管运行",
                        message: "直接从指挥页下发新任务，创建后自动打开详情。",
                        symbolName: "plus.circle.fill",
                        tint: .blue
                    )
                }
                .buttonStyle(.plain)
            } header: {
                SectionHeaderLabel(
                    title: "快速动作",
                    subtitle: "远程发起新的 Codex 托管运行"
                )
            }

            if let actionErrorMessage, !actionErrorMessage.isEmpty {
                Section {
                    NoticeCard(
                        title: "操作失败",
                        message: actionErrorMessage,
                        symbolName: "exclamationmark.triangle.fill",
                        tint: .red
                    )
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                    .listRowBackground(Color.clear)
                }
            }

            Section {
                if filteredItems.isEmpty {
                    SectionPlaceholder(
                        title: "当前筛选下没有任务。",
                        message: "可以切换来源、设备或搜索词，查看更多运行和会话。",
                        symbolName: "point.3.connected.trianglepath.dotted"
                    )
                } else {
                    ForEach(filteredItems) { item in
                        VStack(alignment: .leading, spacing: 10) {
                            NavigationLink {
                                destination(for: item)
                            } label: {
                                UnifiedTaskRow(item: item)
                            }

                            if item.canContinue || item.canInterrupt || item.canStop || item.isStopRequested {
                                UnifiedTaskQuickActions(
                                    item: item,
                                    isPerformingAction: isPerformingAction(for: item),
                                    onContinue: {
                                        beginContinue(for: item)
                                    },
                                    onInterrupt: {
                                        Task {
                                            await interrupt(item)
                                        }
                                    },
                                    onStop: {
                                        Task {
                                            await stop(item)
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
                    title: stateFilter.title,
                    subtitle: sectionSubtitle
                )
            }
        }
        .companionListStyle()
        .navigationTitle("指挥")
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
        .searchable(text: $searchText, prompt: "搜索标题、设备、路径、工作区")
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
        .refreshable {
            actionErrorMessage = nil
            await model.refresh(serverURLString: serverURL)
        }
        .sheet(item: $continueTarget) { target in
            CompanionContinuePromptSheet(
                title: target.navigationTitle,
                message: target.detailTitle,
                subject: target.item.title,
                prompt: $continuePrompt,
                isSubmitting: isSubmittingContinue,
                errorMessage: actionErrorMessage,
                projectCommandSource: target.projectCommandSource(model: model, serverURL: serverURL),
                onCancel: {
                    continueTarget = nil
                },
                onSubmit: {
                    Task {
                        await continueItem(target)
                    }
                }
            )
        }
    }

    @ViewBuilder
    private func destination(for item: UnifiedTaskItem) -> some View {
        switch item.kind {
        case let .managed(run):
            ManagedRunDetailView(model: model, serverURL: serverURL, initialRun: run)
        case let .task(task):
            TaskDetailView(model: model, serverURL: serverURL, initialTask: task)
        case let .codex(session):
            CodexSessionDetailView(model: model, serverURL: serverURL, initialSession: session)
        }
    }

    private func matchesStateFilter(_ item: UnifiedTaskItem) -> Bool {
        switch stateFilter {
        case .attention:
            switch item.kind {
            case let .managed(run):
                switch run.status {
                case .failed, .waitingInput, .interrupting, .stopRequested, .running, .launching:
                    return true
                case .queued, .succeeded, .interrupted, .cancelled:
                    return false
                }
            case let .task(task):
                switch task.status {
                case .failed, .stopRequested, .running, .queued:
                    return true
                case .succeeded, .cancelled:
                    return false
                }
            case let .codex(session):
                return session.isRunningLike || session.isStandbyLike || session.state == .failed || session.state == .interrupted
            }
        case .active:
            return !item.isTerminal
        case .all:
            return true
        }
    }

    private func matchesSourceFilter(_ item: UnifiedTaskItem) -> Bool {
        switch sourceFilter {
        case .all:
            return true
        case .managed:
            if case .managed = item.kind { return true }
            return false
        case .task:
            if case .task = item.kind { return true }
            return false
        case .codex:
            if case .codex = item.kind { return true }
            return false
        }
    }

    private func matchesDeviceFilter(_ item: UnifiedTaskItem) -> Bool {
        guard !deviceFilterID.isEmpty else {
            return true
        }
        if deviceFilterID == unassignedDeviceFilterID {
            return item.deviceID == nil
        }
        return item.deviceID == deviceFilterID
    }

    private func matchesSearch(_ item: UnifiedTaskItem) -> Bool {
        let query = searchText.trimmedOrEmpty
        guard !query.isEmpty else {
            return true
        }
        return item.searchIndex.localizedCaseInsensitiveContains(query)
    }

    private func sortItems(lhs: UnifiedTaskItem, rhs: UnifiedTaskItem) -> Bool {
        if stateFilter != .all, lhs.attentionRank != rhs.attentionRank {
            return lhs.attentionRank < rhs.attentionRank
        }
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        return lhs.id < rhs.id
    }

    private func isPerformingAction(for item: UnifiedTaskItem) -> Bool {
        actionInFlightID == item.id
    }

    private func beginContinue(for item: UnifiedTaskItem) {
        actionErrorMessage = nil
        continuePrompt = ""
        continueTarget = UnifiedTaskContinueTarget(item: item)
    }

    private func continueItem(_ target: UnifiedTaskContinueTarget) async {
        let prompt = continuePrompt.trimmedOrEmpty
        guard !prompt.isEmpty else {
            return
        }

        isSubmittingContinue = true
        actionInFlightID = target.id
        actionErrorMessage = nil
        defer {
            isSubmittingContinue = false
            if actionInFlightID == target.id {
                actionInFlightID = nil
            }
        }

        do {
            switch target.item.kind {
            case let .managed(run):
                _ = try await model.continueManagedRun(
                    serverURLString: serverURL,
                    runID: run.id,
                    prompt: prompt
                )
            case .task:
                return
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
            showToast("已向\(target.item.quickActionMessage)发送继续指令")
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    private func interrupt(_ item: UnifiedTaskItem) async {
        guard item.canInterrupt else {
            return
        }

        actionInFlightID = item.id
        actionErrorMessage = nil
        defer {
            if actionInFlightID == item.id {
                actionInFlightID = nil
            }
        }

        do {
            switch item.kind {
            case let .managed(run):
                _ = try await model.interruptManagedRun(
                    serverURLString: serverURL,
                    runID: run.id
                )
            case .task:
                return
            case let .codex(session):
                _ = try await model.interruptCodexSession(
                    serverURLString: serverURL,
                    deviceID: session.deviceID,
                    sessionID: session.id
                )
            }
            showToast("已向\(item.quickActionMessage)发送中断指令")
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    private func stop(_ item: UnifiedTaskItem) async {
        guard item.canStop else {
            return
        }

        actionInFlightID = item.id
        actionErrorMessage = nil
        defer {
            if actionInFlightID == item.id {
                actionInFlightID = nil
            }
        }

        do {
            switch item.kind {
            case let .managed(run):
                _ = try await model.stopManagedRun(
                    serverURLString: serverURL,
                    runID: run.id,
                    reason: "移动端请求停止"
                )
                showToast("已向托管运行发送停止指令")
            case let .task(task):
                _ = try await model.stopTask(
                    serverURLString: serverURL,
                    taskID: task.id,
                    reason: "移动端请求停止"
                )
                showToast("已向独立任务发送停止指令")
            case .codex:
                return
            }
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

private struct UnifiedTaskRow: View {
    let item: UnifiedTaskItem

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(item.statusColor.opacity(0.12))
                .frame(width: 42, height: 42)
                .overlay {
                    Image(systemName: item.statusSymbolName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(item.statusColor)
                }

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.headline)
                            .foregroundStyle(.primary)

                        Text(item.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 12)

                    StatusBadge(title: item.statusTitle, tint: item.statusColor)
                }

                HStack(spacing: 8) {
                    MetaCapsule(title: item.sourceTitle, symbolName: item.sourceSymbolName, tint: .secondary)
                    MetaCapsule(title: item.deviceTitle, symbolName: "desktopcomputer", tint: .secondary)
                    MetaCapsule(title: item.pathTitle, symbolName: "folder", tint: .secondary)

                    Spacer(minLength: 8)

                    Text(item.updatedAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let workspaceTitle = item.workspaceTitle, !workspaceTitle.isEmpty {
                    Text(workspaceTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

private struct UnifiedTaskQuickActions: View {
    let item: UnifiedTaskItem
    let isPerformingAction: Bool
    let onContinue: () -> Void
    let onInterrupt: () -> Void
    let onStop: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            actionLayout
            stackedActionLayout
        }
    }

    private var stopButtonTitle: String {
        switch item.kind {
        case let .task(task):
            return task.status == .queued ? "取消" : "停止"
        case .managed, .codex:
            return "停止"
        }
    }

    private var actionLayout: some View {
        HStack(spacing: 8) {
            if item.canContinue {
                Button("继续追问", action: onContinue)
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
            }

            if item.canInterrupt {
                Button("中断", action: onInterrupt)
                    .buttonStyle(.bordered)
                    .tint(.orange)
            }

            if item.canStop {
                Button(stopButtonTitle, action: onStop)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
            } else if item.isStopRequested {
                Button("停止中") {}
                    .buttonStyle(.bordered)
                    .disabled(true)
            }

            Spacer(minLength: 0)

            if isPerformingAction {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .font(.caption.weight(.semibold))
        .controlSize(.small)
        .disabled(isPerformingAction)
    }

    private var stackedActionLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            if item.canContinue {
                Button("继续追问", action: onContinue)
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
            }

            if item.canInterrupt {
                Button("中断", action: onInterrupt)
                    .buttonStyle(.bordered)
                    .tint(.orange)
            }

            if item.canStop {
                Button(stopButtonTitle, action: onStop)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
            } else if item.isStopRequested {
                Button("停止中") {}
                    .buttonStyle(.bordered)
                    .disabled(true)
            }

            if isPerformingAction {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .font(.caption.weight(.semibold))
        .controlSize(.small)
        .disabled(isPerformingAction)
    }
}

#if DEBUG
@MainActor
struct UnifiedTasksView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            UnifiedTasksView(
                model: CompanionPreviewData.model,
                serverURL: "http://preview.local/",
                isShowingSettings: .constant(false)
            )
        }
    }
}
#endif
