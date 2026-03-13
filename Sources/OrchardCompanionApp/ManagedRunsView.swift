import OrchardCore
import SwiftUI

private enum ManagedRunFilter: String, CaseIterable, Identifiable {
    case active
    case queued
    case finished
    case failed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .active:
            return "运行中"
        case .queued:
            return "排队中"
        case .finished:
            return "已结束"
        case .failed:
            return "失败"
        }
    }

    func matches(_ run: ManagedRunSummary) -> Bool {
        switch self {
        case .active:
            return run.status.occupiesSlot
        case .queued:
            return run.status == .queued
        case .finished:
            switch run.status {
            case .succeeded, .interrupted, .cancelled:
                return true
            case .queued, .launching, .running, .waitingInput, .interrupting, .stopRequested, .failed:
                return false
            }
        case .failed:
            return run.status == .failed
        }
    }
}

struct ManagedRunsView: View {
    @ObservedObject var model: AppModel
    let serverURL: String
    @Binding var isShowingSettings: Bool

    @AppStorage("orchard.managedRuns.filter") private var filterStorage = ManagedRunFilter.active.rawValue
    @AppStorage("orchard.managedRuns.deviceFilterID") private var deviceFilterID = ""
    @AppStorage("orchard.managedRuns.searchText") private var searchText = ""
    @State private var isShowingCreateSheet = false
    @State private var createdRunForNavigation: ManagedRunSummary?
    @State private var isShowingCreatedRunDetail = false
    @State private var continueTarget: ManagedRunSummary?
    @State private var continuePrompt = ""
    @State private var isSubmittingPrompt = false
    @State private var actionRunID: String?
    @State private var actionErrorMessage: String?
    @State private var toastMessage: String?

    private let localDeviceFilterID = "__local__"
    private let unassignedDeviceFilterID = "__unassigned__"

    private var filter: ManagedRunFilter {
        ManagedRunFilter(rawValue: filterStorage) ?? .active
    }

    private var filterBinding: Binding<ManagedRunFilter> {
        Binding(
            get: { filter },
            set: { filterStorage = $0.rawValue }
        )
    }

    private var deviceFilterOptions: [(id: String, title: String)] {
        let devices = model.snapshot.devices
            .sorted { lhs, rhs in
                if lhs.status != rhs.status {
                    return lhs.status == .online
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .map { ($0.deviceID, $0.name) }

        var options: [(id: String, title: String)] = [("", "全部设备")]
        if model.hasLocalMatchedDevice {
            options.append((localDeviceFilterID, "本机宿主"))
        }
        options.append((unassignedDeviceFilterID, "待分配"))
        options.append(contentsOf: devices)
        return options
    }

    private var filteredRuns: [ManagedRunSummary] {
        model.snapshot.managedRuns
            .filter { filter.matches($0) }
            .filter(matchesDeviceFilter)
            .filter(matchesSearch)
            .sorted(by: sortRuns)
    }

    private var summaryTitle: String {
        filteredRuns.isEmpty ? "\(filter.title)为空" : "\(filteredRuns.count) 个\(filter.title)"
    }

    private var summaryMessage: String {
        switch filter {
        case .active:
            return "这里是当前真正占用执行槽位的托管运行。"
        case .queued:
            return "这些运行已经创建，但还没有被设备真正接手。"
        case .finished:
            return "已完成、已取消和已中断的运行会归档在这里。"
        case .failed:
            return "失败运行建议优先查看事件和日志。"
        }
    }

    private var summaryTint: Color {
        switch filter {
        case .active:
            return .blue
        case .queued:
            return .secondary
        case .finished:
            return .green
        case .failed:
            return .red
        }
    }

    private var summarySymbolName: String {
        switch filter {
        case .active:
            return "bolt.circle.fill"
        case .queued:
            return "clock.fill"
        case .finished:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.octagon.fill"
        }
    }

    private var sectionSubtitle: String? {
        if filteredRuns.isEmpty {
            return nil
        }
        var parts: [String] = []
        if !searchText.trimmedOrEmpty.isEmpty {
            parts.append("“\(searchText.trimmedOrEmpty)” 的搜索结果")
        }
        if let deviceTitle = currentDeviceFilterTitle {
            parts.append(deviceTitle)
        }
        if parts.isEmpty {
            return "按最近更新时间排序"
        }
        return parts.joined(separator: " · ")
    }

    private var currentDeviceFilterTitle: String? {
        guard !deviceFilterID.isEmpty else { return nil }
        return deviceFilterOptions.first(where: { $0.id == deviceFilterID })?.title
    }

    var body: some View {
        List {
            Section {
                HeroCard(
                    eyebrow: "托管运行",
                    title: summaryTitle,
                    message: summaryMessage,
                    symbolName: summarySymbolName,
                    tint: summaryTint
                )
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 10, trailing: 0))
                .listRowBackground(Color.clear)

                Picker("筛选", selection: filterBinding) {
                    ForEach(ManagedRunFilter.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
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

                if filteredRuns.isEmpty {
                    SectionPlaceholder(
                        title: "\(filter.title)暂无托管运行。",
                        message: "切换顶部筛选可查看其他状态的运行。",
                        symbolName: "sparkles.rectangle.stack"
                    )
                } else {
                    ForEach(filteredRuns) { run in
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
                                    isPerformingAction: actionRunID == run.id,
                                    onContinue: {
                                        actionErrorMessage = nil
                                        continuePrompt = ""
                                        continueTarget = run
                                    },
                                    onInterrupt: {
                                        Task {
                                            await interruptRun(run)
                                        }
                                    },
                                    onStop: {
                                        Task {
                                            await stopRun(run)
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
                    title: filter.title,
                    subtitle: sectionSubtitle
                )
            }
        }
        .companionListStyle()
        .navigationTitle("运行")
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
        .searchable(text: $searchText, prompt: "搜索标题、目录、设备")
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
                filterStorage = preferredFilter(for: run).rawValue
                if model.isLocalManagedRun(run) {
                    deviceFilterID = localDeviceFilterID
                } else {
                    deviceFilterID = run.deviceID ?? run.preferredDeviceID ?? ""
                }
                createdRunForNavigation = run
                isShowingCreatedRunDetail = true
            }
        }
        .sheet(item: $continueTarget) { run in
            CompanionContinuePromptSheet(
                title: "继续 run",
                message: "继续追问会直接发到当前托管运行。",
                subject: run.title,
                prompt: $continuePrompt,
                isSubmitting: isSubmittingPrompt,
                errorMessage: actionErrorMessage,
                projectCommandSource: run.deviceID?.nilIfEmpty.map { deviceID in
                    ProjectCommandQuickInsertSource(
                        model: model,
                        serverURL: serverURL,
                        context: ProjectCommandQuickInsertContext(
                            deviceID: deviceID,
                            workspaceID: run.workspaceID
                        )
                    )
                },
                onCancel: {
                    continueTarget = nil
                },
                onSubmit: {
                    Task {
                        await continueRun(run)
                    }
                }
            )
        }
        .refreshable {
            actionErrorMessage = nil
            await model.refresh(serverURLString: serverURL)
        }
        .onAppear {
            sanitizeDeviceFilterSelection()
        }
        .onChange(of: model.snapshot.devices.map(\.deviceID)) { _, _ in
            sanitizeDeviceFilterSelection()
        }
    }

    private func matchesDeviceFilter(_ run: ManagedRunSummary) -> Bool {
        guard !deviceFilterID.isEmpty else {
            return true
        }
        if deviceFilterID == localDeviceFilterID {
            return model.isLocalManagedRun(run)
        }
        if deviceFilterID == unassignedDeviceFilterID {
            return run.deviceID == nil && run.preferredDeviceID == nil
        }
        return run.deviceID == deviceFilterID || run.preferredDeviceID == deviceFilterID
    }

    private func matchesSearch(_ run: ManagedRunSummary) -> Bool {
        let query = searchText.trimmedOrEmpty
        guard !query.isEmpty else {
            return true
        }

        let candidates = [
            run.title,
            run.promptPreview,
            run.deviceDisplayName,
            run.preferredDeviceID ?? "",
            run.workspaceID,
            run.cwd,
            run.summary ?? "",
        ]

        return candidates.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    private func sortRuns(lhs: ManagedRunSummary, rhs: ManagedRunSummary) -> Bool {
        switch filter {
        case .active:
            if lhs.attentionRank != rhs.attentionRank {
                return lhs.attentionRank < rhs.attentionRank
            }
            return lhs.updatedAt > rhs.updatedAt
        case .queued:
            return lhs.createdAt > rhs.createdAt
        case .finished, .failed:
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private func preferredFilter(for run: ManagedRunSummary) -> ManagedRunFilter {
        switch run.status {
        case .queued:
            return .queued
        case .failed:
            return .failed
        case .launching, .running, .waitingInput, .interrupting, .stopRequested:
            return .active
        case .succeeded, .interrupted, .cancelled:
            return .finished
        }
    }

    private func continueRun(_ run: ManagedRunSummary) async {
        let prompt = continuePrompt.trimmedOrEmpty
        guard !prompt.isEmpty else {
            return
        }

        isSubmittingPrompt = true
        actionRunID = run.id
        actionErrorMessage = nil
        defer {
            isSubmittingPrompt = false
            if actionRunID == run.id {
                actionRunID = nil
            }
        }

        do {
            _ = try await model.continueManagedRun(
                serverURLString: serverURL,
                runID: run.id,
                prompt: prompt
            )
            continuePrompt = ""
            continueTarget = nil
            showToast("已发送继续指令")
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    private func interruptRun(_ run: ManagedRunSummary) async {
        guard run.canInterruptRemotely else {
            return
        }

        actionRunID = run.id
        actionErrorMessage = nil
        defer {
            if actionRunID == run.id {
                actionRunID = nil
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

    private func stopRun(_ run: ManagedRunSummary) async {
        guard run.canStopRemotely else {
            return
        }

        actionRunID = run.id
        actionErrorMessage = nil
        defer {
            if actionRunID == run.id {
                actionRunID = nil
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

    private func showToast(_ message: String) {
        toastMessage = message
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if toastMessage == message {
                toastMessage = nil
            }
        }
    }

    private func sanitizeDeviceFilterSelection() {
        let validIDs = Set(deviceFilterOptions.map(\.id))
        if !validIDs.contains(deviceFilterID) {
            deviceFilterID = ""
        }
    }
}

struct ManagedRunRow: View {
    let run: ManagedRunSummary

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(run.stateColor.opacity(0.12))
                .frame(width: 42, height: 42)
                .overlay {
                    Image(systemName: run.statusSymbolName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(run.stateColor)
                }

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(run.title)
                            .font(.headline)
                            .foregroundStyle(.primary)

                        Text(run.promptPreview)
                            .font(.subheadline.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 12)

                    StatusBadge(title: run.statusTitle, tint: run.stateColor)
                }

                HStack(spacing: 8) {
                    MetaCapsule(
                        title: run.deviceDisplayName,
                        symbolName: "desktopcomputer",
                        tint: run.stateColor
                    )
                    MetaCapsule(
                        title: run.shortCWD,
                        symbolName: "folder",
                        tint: .secondary
                    )

                    Spacer(minLength: 8)

                    Text(run.updatedAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

#if DEBUG
@MainActor
struct ManagedRunsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            ManagedRunsView(
                model: CompanionPreviewData.model,
                serverURL: "http://preview.local/",
                isShowingSettings: .constant(false)
            )
        }
    }
}
#endif
