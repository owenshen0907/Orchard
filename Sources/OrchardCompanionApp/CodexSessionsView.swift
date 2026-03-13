import OrchardCore
import SwiftUI

private enum CodexSessionFilter: String, CaseIterable, Identifiable {
    case running
    case standby
    case finished

    var id: String { rawValue }

    var title: String {
        switch self {
        case .running:
            return "推理中"
        case .standby:
            return "待命"
        case .finished:
            return "已结束"
        }
    }

    func matches(_ session: CodexSessionSummary) -> Bool {
        switch self {
        case .running:
            return session.isRunningLike
        case .standby:
            return session.isStandbyLike
        case .finished:
            return session.isFinishedLike
        }
    }
}

struct CodexSessionsView: View {
    @ObservedObject var model: AppModel
    let serverURL: String
    @Binding var isShowingSettings: Bool

    @AppStorage("orchard.codexSessions.filter") private var filterStorage = CodexSessionFilter.running.rawValue
    @AppStorage("orchard.codexSessions.deviceFilterID") private var deviceFilterID = ""
    @AppStorage("orchard.codexSessions.searchText") private var searchText = ""
    @State private var continueTarget: CodexSessionSummary?
    @State private var continuePrompt = ""
    @State private var isSubmittingPrompt = false
    @State private var actionSessionID: String?
    @State private var actionErrorMessage: String?
    @State private var toastMessage: String?

    private let unassignedDeviceFilterID = "__unassigned__"

    private var filter: CodexSessionFilter {
        CodexSessionFilter(rawValue: filterStorage) ?? .running
    }

    private var filterBinding: Binding<CodexSessionFilter> {
        Binding(
            get: { filter },
            set: { filterStorage = $0.rawValue }
        )
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

    private var filteredSessions: [CodexSessionSummary] {
        model.codexSessions
            .filter { filter.matches($0) }
            .filter(matchesDeviceFilter)
            .filter(matchesSearch)
            .sorted(by: sortSessions)
    }

    var body: some View {
        List {
            Section {
                HeroCard(
                    eyebrow: "Codex 会话",
                    title: filteredSessions.isEmpty ? "\(filter.title)为空" : "\(filteredSessions.count) 个\(filter.title)",
                    message: filterMessage,
                    symbolName: "sparkles.rectangle.stack.fill",
                    tint: filter == .running ? .blue : filter == .standby ? .indigo : .orange
                )
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 10, trailing: 0))
                .listRowBackground(Color.clear)

                if !model.codexSessions.isEmpty {
                    CodexDiagnosticsCard(
                        summary: model.codexDiagnosticsSummaryText,
                        sourceSummary: model.codexSourceSummaryText,
                        turnSummary: model.codexTurnSummaryText,
                        conclusion: model.codexConclusionText,
                        tint: model.codexDiagnosticsTint
                    )
                    .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 8, trailing: 0))
                    .listRowBackground(Color.clear)
                }

                Picker("筛选", selection: filterBinding) {
                    ForEach(CodexSessionFilter.allCases) { item in
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

                if filteredSessions.isEmpty {
                    SectionPlaceholder(
                        title: placeholderTitle,
                        message: placeholderMessage,
                        symbolName: "sparkles.tv"
                    )
                } else {
                    ForEach(filteredSessions) { session in
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
                                    isPerformingAction: actionSessionID == actionID(for: session),
                                    onContinue: {
                                        actionErrorMessage = nil
                                        continuePrompt = ""
                                        continueTarget = session
                                    },
                                    onInterrupt: {
                                        Task {
                                            await interruptSession(session)
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
                    title: filter.title,
                    subtitle: sectionSubtitle
                )
            }
        }
        .companionListStyle()
        .navigationTitle("Codex")
        .companionToast(message: toastMessage)
        .searchable(text: $searchText, prompt: "搜索标题、路径、设备")
        .toolbar {
            ToolbarItem(placement: CompanionToolbarPlacement.trailing) {
                SettingsToolbarButton(isPresented: $isShowingSettings)
            }
        }
        .sheet(item: $continueTarget) { session in
            CompanionContinuePromptSheet(
                title: "继续会话",
                message: "继续追问会直接发到当前 Codex 会话。",
                subject: session.titleText,
                prompt: $continuePrompt,
                isSubmitting: isSubmittingPrompt,
                errorMessage: actionErrorMessage,
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
                    continueTarget = nil
                },
                onSubmit: {
                    Task {
                        await continueSession(session)
                    }
                }
            )
        }
        .refreshable {
            actionErrorMessage = nil
            await model.refresh(serverURLString: serverURL)
        }
    }

    private var filterMessage: String {
        switch filter {
        case .running:
            return "这里只展示最近轮次仍在执行的线程，它们会计入“总运行中”。"
        case .standby:
            return "这些线程当前没在推理，但上下文还在；轻摘要线程点进详情后会补拉轮次。"
        case .finished:
            return "查看已经结束的会话，便于继续追问或复盘。"
        }
    }

    private var placeholderTitle: String {
        switch filter {
        case .running:
            return "当前没有推理中的 Codex 会话。"
        case .standby:
            return "当前没有待命中的 Codex 会话。"
        case .finished:
            return "还没有已结束的 Codex 会话。"
        }
    }

    private var placeholderMessage: String {
        switch filter {
        case .running:
            return "你在桌面端继续发起任务后，这里会出现可远程观察的会话。"
        case .standby:
            return "确认 Agent 已在线，并且本机确实保留了可继续追问的线程。"
        case .finished:
            return "完成、失败或中断的会话会归档在这里。"
        }
    }

    private var sectionSubtitle: String {
        var parts: [String] = []
        if let deviceTitle = deviceFilterOptions.first(where: { $0.id == deviceFilterID })?.title, !deviceFilterID.isEmpty {
            parts.append(deviceTitle)
        }
        if !searchText.trimmedOrEmpty.isEmpty {
            parts.append("“\(searchText.trimmedOrEmpty)” 的搜索结果")
        }
        if parts.isEmpty {
            return "按最近更新时间排序"
        }
        return parts.joined(separator: " · ")
    }

    private func matchesDeviceFilter(_ session: CodexSessionSummary) -> Bool {
        guard !deviceFilterID.isEmpty else {
            return true
        }
        if deviceFilterID == unassignedDeviceFilterID {
            return session.deviceID.isEmpty
        }
        return session.deviceID == deviceFilterID
    }

    private func matchesSearch(_ session: CodexSessionSummary) -> Bool {
        let query = searchText.trimmedOrEmpty
        guard !query.isEmpty else {
            return true
        }

        return [
            session.titleText,
            session.subtitleText,
            session.workspaceID ?? "",
            session.cwd,
            session.deviceName,
            session.source,
            session.derivedStatusTitle,
        ].contains { $0.localizedCaseInsensitiveContains(query) }
    }

    private func sortSessions(lhs: CodexSessionSummary, rhs: CodexSessionSummary) -> Bool {
        if lhs.attentionRank != rhs.attentionRank {
            return lhs.attentionRank < rhs.attentionRank
        }
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        return lhs.id < rhs.id
    }

    private func actionID(for session: CodexSessionSummary) -> String {
        "\(session.deviceID):\(session.id)"
    }

    private func continueSession(_ session: CodexSessionSummary) async {
        let prompt = continuePrompt.trimmedOrEmpty
        guard !prompt.isEmpty else {
            return
        }

        let sessionActionID = actionID(for: session)
        isSubmittingPrompt = true
        actionSessionID = sessionActionID
        actionErrorMessage = nil
        defer {
            isSubmittingPrompt = false
            if actionSessionID == sessionActionID {
                actionSessionID = nil
            }
        }

        do {
            _ = try await model.continueCodexSession(
                serverURLString: serverURL,
                deviceID: session.deviceID,
                sessionID: session.id,
                prompt: prompt
            )
            continuePrompt = ""
            continueTarget = nil
            showToast("已发送继续指令")
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    private func interruptSession(_ session: CodexSessionSummary) async {
        guard session.canInterruptRemotely else {
            return
        }

        let sessionActionID = actionID(for: session)
        actionSessionID = sessionActionID
        actionErrorMessage = nil
        defer {
            if actionSessionID == sessionActionID {
                actionSessionID = nil
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

struct CodexSessionRow: View {
    let session: CodexSessionSummary

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(session.derivedStatusColor.opacity(0.12))
                .frame(width: 42, height: 42)
                .overlay {
                    Image(systemName: session.derivedStatusSymbolName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(session.derivedStatusColor)
                }

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.titleText)
                            .font(.headline)
                            .foregroundStyle(.primary)

                        Text(session.subtitleText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 12)

                    StatusBadge(title: session.derivedStatusTitle, tint: session.derivedStatusColor)
                }

                HStack(spacing: 8) {
                    MetaCapsule(title: session.deviceName, symbolName: "desktopcomputer", tint: .secondary)
                    if let workspaceID = session.workspaceID?.nilIfEmpty {
                        MetaCapsule(title: workspaceID, symbolName: "shippingbox", tint: .secondary)
                    }
                    MetaCapsule(title: session.source, symbolName: "point.3.connected.trianglepath.dotted", tint: .secondary)
                    if session.isLightweightSummary {
                        MetaCapsule(title: "轻摘要", symbolName: "doc.text.magnifyingglass", tint: .indigo)
                    }

                    Spacer(minLength: 8)

                    Text(session.updatedAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
    }
}
