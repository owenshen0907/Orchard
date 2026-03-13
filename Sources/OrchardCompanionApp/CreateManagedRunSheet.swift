import OrchardCore
import SwiftUI

private struct RelativePathSuggestion: Identifiable, Hashable {
    let value: String
    let label: String

    var id: String { value }
}

private struct RelativePathCandidate {
    let value: String
    var score: Double
    var sources: Set<String>
}

struct CreateManagedRunSheet: View {
    @ObservedObject var model: AppModel
    let serverURL: String
    var onCreated: (ManagedRunSummary) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var workspaceID = ""
    @State private var relativePath = ""
    @State private var relativePathSelection = Self.relativePathRootValue
    @State private var preferredDeviceID = ""
    @State private var prompt = ""
    @State private var localErrorMessage: String?
    @State private var isSubmitting = false
    @State private var projectContextSummary: AgentProjectContextCommandResponse?
    @State private var isLoadingProjectContext = false
    @State private var isShowingProjectContextSheet = false

    private static let relativePathRootValue = "__workspace_root__"
    private static let relativePathCustomValue = "__workspace_custom__"

    private var codexDevices: [DeviceRecord] {
        model.snapshot.devices
            .filter { $0.capabilities.contains(.codex) }
            .sorted { lhs, rhs in
                if lhs.status != rhs.status {
                    return lhs.status == .online
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private var availableWorkspaces: [WorkspaceDefinition] {
        let unique = Dictionary(
            codexDevices
                .flatMap(\.workspaces)
                .map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return unique.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var selectedWorkspace: WorkspaceDefinition? {
        availableWorkspaces.first { $0.id == workspaceID }
    }

    private var availableDevices: [DeviceRecord] {
        codexDevices.filter { device in
            guard !workspaceID.isEmpty else { return true }
            return device.workspaces.contains { $0.id == workspaceID }
        }
    }

    private var projectContextPreviewDevice: DeviceRecord? {
        if let preferredDeviceID = preferredDeviceID.nilIfEmpty,
           let preferred = availableDevices.first(where: { $0.deviceID == preferredDeviceID }) {
            return preferred
        }

        return availableDevices.first(where: { $0.status == .online }) ?? availableDevices.first
    }

    private var projectContextTaskID: String {
        "\(workspaceID)|\(projectContextPreviewDevice?.deviceID ?? "none")"
    }

    private var canSubmit: Bool {
        !workspaceID.isEmpty &&
            !prompt.trimmedOrEmpty.isEmpty
    }

    private var relativePathSuggestions: [RelativePathSuggestion] {
        var options: [RelativePathSuggestion] = [
            RelativePathSuggestion(value: Self.relativePathRootValue, label: "工作区根目录")
        ]

        options.append(contentsOf: relativePathCandidates().map { candidate in
            let sourceSummary = candidate.sources.sorted().joined(separator: " / ")
            if sourceSummary.isEmpty {
                return RelativePathSuggestion(value: candidate.value, label: candidate.value)
            }
            return RelativePathSuggestion(
                value: candidate.value,
                label: "\(candidate.value) · \(sourceSummary)"
            )
        })

        let normalizedCurrent = normalizedRelativePath(relativePath)
        if normalizedCurrent.isEmpty {
            options.append(RelativePathSuggestion(value: Self.relativePathCustomValue, label: "手动输入其他路径"))
        } else if options.contains(where: { $0.value == normalizedCurrent }) {
            options.append(RelativePathSuggestion(value: Self.relativePathCustomValue, label: "手动输入其他路径"))
        } else {
            options.append(RelativePathSuggestion(
                value: Self.relativePathCustomValue,
                label: "手动输入：\(normalizedCurrent)"
            ))
        }

        return options
    }

    private var pathPreview: String {
        guard let selectedWorkspace else {
            return "请先选择工作区"
        }
        let normalizedRelativePath = normalizedRelativePath(relativePath)
        guard !normalizedRelativePath.isEmpty else {
            return selectedWorkspace.rootPath
        }
        return selectedWorkspace.rootPath + "/" + normalizedRelativePath
    }

    private var helperMessage: String {
        if availableWorkspaces.isEmpty {
            return "当前没有上报 Codex 能力的工作区，先确认 OrchardAgent 已在线并带上 Codex capability。"
        }
        let deviceCount = availableDevices.count
        if preferredDeviceID.nilIfEmpty != nil {
            return "将优先发到指定设备，若设备暂时离线会继续保留在队列里。"
        }
        return "当前工作区可由 \(deviceCount) 台 Codex 设备接手；不指定设备时由控制面自动分配。"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HeroCard(
                        eyebrow: "手机端发起",
                        title: "新建托管 run",
                        message: "适合直接提交明确的 Codex 目标；复杂编排仍建议回到桌面端。",
                        symbolName: "sparkles.rectangle.stack.fill",
                        tint: .blue
                    )
                }

                if availableWorkspaces.isEmpty {
                    Section {
                        NoticeCard(
                            title: "当前还不能创建",
                            message: "没有发现可接 Codex 任务的工作区。先让本机 OrchardAgent 连上控制面，再回来重试。",
                            symbolName: "exclamationmark.triangle.fill",
                            tint: .orange
                        )
                    }
                } else {
                    Section("基本信息") {
                        TextField("标题（可留空）", text: $title)

                        Picker("工作区", selection: $workspaceID) {
                            Text("请选择").tag("")
                            ForEach(availableWorkspaces) { workspace in
                                Text(workspace.name).tag(workspace.id)
                            }
                        }

                        Picker("指定设备", selection: $preferredDeviceID) {
                            Text("自动分配").tag("")
                            ForEach(availableDevices) { device in
                                Text(device.name).tag(device.deviceID)
                            }
                        }

                        Picker("常用路径", selection: $relativePathSelection) {
                            ForEach(relativePathSuggestions) { suggestion in
                                Text(suggestion.label).tag(suggestion.value)
                            }
                        }

                        TextField("相对路径（可选）", text: $relativePath)
                        Text("可以直接选历史常用目录，也可以继续手动输入其他相对路径。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Section("提示词") {
                        TextEditor(text: $prompt)
                            .frame(minHeight: 180)
                    }

                    Section("执行位置") {
                        LabeledContent("预计目录", value: pathPreview)
                        Text(helperMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Section("项目上下文") {
                        if let previewDevice = projectContextPreviewDevice {
                            LabeledContent("预览设备", value: previewDevice.name)

                            if isLoadingProjectContext && projectContextSummary == nil {
                                ProgressView("正在检查项目上下文…")
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.vertical, 8)
                            } else if let response = projectContextSummary {
                                projectContextPreview(response: response)
                            } else {
                                SectionPlaceholder(
                                    title: "还没有检测结果。",
                                    message: "稍后会自动从当前预览设备读取工作区 project-context。",
                                    symbolName: "books.vertical"
                                )
                            }

                            Button("查看项目上下文") {
                                isShowingProjectContextSheet = true
                            }
                        } else {
                            SectionPlaceholder(
                                title: "先确定一个可用设备。",
                                message: "选择工作区后，系统会按当前预览设备检查是否已配置项目上下文。",
                                symbolName: "desktopcomputer"
                            )
                        }
                    }

                    Section("标准操作命令") {
                        if let previewDevice = projectContextPreviewDevice, !workspaceID.isEmpty {
                            ProjectCommandQuickInsertSection(
                                source: ProjectCommandQuickInsertSource(
                                    model: model,
                                    serverURL: serverURL,
                                    context: ProjectCommandQuickInsertContext(
                                        deviceID: previewDevice.deviceID,
                                        workspaceID: workspaceID
                                    )
                                ),
                                intent: .createManagedRun,
                                helperText: "点击后会自动填充标题和中文提示词，不会直接裸跑 shell；更适合把部署、健康检查、日志等动作标准化。",
                                actionTitle: "填充"
                            ) { suggestion in
                                title = suggestion.suggestedTitle
                                prompt = suggestion.suggestedPrompt
                            }
                        } else {
                            SectionPlaceholder(
                                title: "先确定一个可用设备。",
                                message: "选择工作区并确定预览设备后，才能读取当前项目登记的标准操作命令。",
                                symbolName: "terminal"
                            )
                        }
                    }
                }

                if let localErrorMessage {
                    Section("错误") {
                        Text(localErrorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("新建运行")
            .companionInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: CompanionToolbarPlacement.leading) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: CompanionToolbarPlacement.trailing) {
                    Button("创建") {
                        Task {
                            await submit()
                        }
                    }
                    .disabled(!canSubmit || isSubmitting)
                }
            }
            .onAppear {
                syncSelectionIfNeeded()
            }
            .onChange(of: workspaceID) { _, _ in
                if !availableDevices.contains(where: { $0.deviceID == preferredDeviceID }) {
                    preferredDeviceID = ""
                }
                syncRelativePathSelection()
            }
            .onChange(of: relativePathSelection) { _, newValue in
                applyRelativePathSelection(newValue)
            }
            .onChange(of: relativePath) { _, newValue in
                let normalized = normalizedRelativePath(newValue)
                if normalized != newValue {
                    relativePath = normalized
                    return
                }
                syncRelativePathSelection()
            }
            .task(id: projectContextTaskID) {
                await loadProjectContextSummary()
            }
            .sheet(isPresented: $isShowingProjectContextSheet) {
                if let previewDevice = projectContextPreviewDevice, !workspaceID.isEmpty {
                    ProjectContextInspectorSheet(
                        model: model,
                        serverURL: serverURL,
                        deviceID: previewDevice.deviceID,
                        deviceName: previewDevice.name,
                        workspaceID: workspaceID
                    )
                }
            }
        }
    }

    private func syncSelectionIfNeeded() {
        if workspaceID.isEmpty, let workspace = availableWorkspaces.first {
            workspaceID = workspace.id
        }
        if !availableDevices.contains(where: { $0.deviceID == preferredDeviceID }) {
            preferredDeviceID = ""
        }
        relativePath = normalizedRelativePath(relativePath)
        syncRelativePathSelection()
    }

    private func syncRelativePathSelection(preferredValue: String? = nil) {
        let options = relativePathSuggestions
        let normalizedCurrent = normalizedRelativePath(relativePath)
        let nextValue: String

        if let preferredValue, options.contains(where: { $0.value == preferredValue }) {
            nextValue = preferredValue
        } else if normalizedCurrent.isEmpty {
            nextValue = Self.relativePathRootValue
        } else if options.contains(where: { $0.value == normalizedCurrent }) {
            nextValue = normalizedCurrent
        } else {
            nextValue = Self.relativePathCustomValue
        }

        if relativePathSelection != nextValue {
            relativePathSelection = nextValue
        }
    }

    private func applyRelativePathSelection(_ selection: String) {
        switch selection {
        case Self.relativePathRootValue:
            if !relativePath.isEmpty {
                relativePath = ""
            }
        case Self.relativePathCustomValue:
            break
        default:
            if relativePath != selection {
                relativePath = selection
            }
        }
    }

    private func normalizedRelativePath(_ value: String) -> String {
        value
            .trimmedOrEmpty
            .replacingOccurrences(of: "^/+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    }

    private func relativePathFromWorkspaceRoot(rootPath: String, absolutePath: String) -> String {
        let normalizedRoot = rootPath.trimmedOrEmpty.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        let normalizedAbsolute = absolutePath.trimmedOrEmpty.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard !normalizedRoot.isEmpty, !normalizedAbsolute.isEmpty else {
            return ""
        }
        guard normalizedAbsolute != normalizedRoot else {
            return ""
        }
        guard normalizedAbsolute.hasPrefix(normalizedRoot + "/") else {
            return ""
        }
        return normalizedRelativePath(String(normalizedAbsolute.dropFirst(normalizedRoot.count + 1)))
    }

    private func relativePathCandidates() -> [RelativePathCandidate] {
        guard let selectedWorkspace else {
            return []
        }

        var bucket: [String: RelativePathCandidate] = [:]

        for run in model.snapshot.managedRuns where run.workspaceID == selectedWorkspace.id {
            addRelativePathCandidate(
                bucket: &bucket,
                rawValue: run.relativePath,
                sourceLabel: "托管 run",
                score: 1.3
            )
            addRelativePathCandidate(
                bucket: &bucket,
                rawValue: relativePathFromWorkspaceRoot(rootPath: selectedWorkspace.rootPath, absolutePath: run.cwd),
                sourceLabel: "托管 run",
                score: 1
            )
        }

        for session in model.codexSessions where session.workspaceID == selectedWorkspace.id {
            addRelativePathCandidate(
                bucket: &bucket,
                rawValue: relativePathFromWorkspaceRoot(rootPath: selectedWorkspace.rootPath, absolutePath: session.cwd),
                sourceLabel: "Codex 会话",
                score: 1.1
            )
        }

        return bucket.values
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                let lhsDepth = lhs.value.split(separator: "/").count
                let rhsDepth = rhs.value.split(separator: "/").count
                if lhsDepth != rhsDepth {
                    return lhsDepth < rhsDepth
                }
                return lhs.value.localizedCaseInsensitiveCompare(rhs.value) == .orderedAscending
            }
            .prefix(12)
            .map { $0 }
    }

    private func addRelativePathCandidate(
        bucket: inout [String: RelativePathCandidate],
        rawValue: String?,
        sourceLabel: String,
        score: Double
    ) {
        let value = normalizedRelativePath(rawValue ?? "")
        guard !value.isEmpty else {
            return
        }

        var candidate = bucket[value] ?? RelativePathCandidate(value: value, score: 0, sources: [])
        candidate.score += score
        candidate.sources.insert(sourceLabel)
        bucket[value] = candidate

        let parts = value.split(separator: "/").map(String.init)
        guard parts.count > 1 else {
            return
        }

        for index in 1..<parts.count {
            let parent = parts.prefix(index).joined(separator: "/")
            var parentCandidate = bucket[parent] ?? RelativePathCandidate(value: parent, score: 0, sources: [])
            parentCandidate.score += max(score * 0.35, 0.35)
            parentCandidate.sources.insert(sourceLabel)
            bucket[parent] = parentCandidate
        }
    }

    @ViewBuilder
    private func projectContextPreview(response: AgentProjectContextCommandResponse) -> some View {
        if let errorMessage = response.errorMessage?.nilIfEmpty {
            NoticeCard(
                title: "检测到项目上下文，但读取失败",
                message: errorMessage,
                symbolName: "exclamationmark.triangle.fill",
                tint: .orange
            )
        } else if response.available, let summary = response.summary {
            NoticeCard(
                title: "已检测到项目上下文",
                message: summary.localSecretsPresent
                    ? "创建 run 时会自动注入非敏感项目事实，当前预览设备也已发现本机密钥文件。"
                    : "创建 run 时会自动注入非敏感项目事实，但当前预览设备还没发现本机 local secrets。",
                symbolName: "books.vertical.fill",
                tint: summary.localSecretsPresent ? .green : .orange
            )

            if let summaryText = summary.summary?.nilIfEmpty {
                Text(summaryText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else if !response.available {
            NoticeCard(
                title: "当前工作区没有项目上下文",
                message: "这次 run 仍能执行，但不会自动注入部署、主机、数据库等项目事实。",
                symbolName: "tray.fill",
                tint: .secondary
            )
        }
    }

    private func loadProjectContextSummary() async {
        guard let previewDevice = projectContextPreviewDevice, !workspaceID.isEmpty else {
            projectContextSummary = nil
            return
        }

        isLoadingProjectContext = true
        defer { isLoadingProjectContext = false }

        do {
            projectContextSummary = try await model.fetchProjectContextSummary(
                serverURLString: serverURL,
                deviceID: previewDevice.deviceID,
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

    private func submit() async {
        guard canSubmit else { return }

        isSubmitting = true
        defer { isSubmitting = false }

        let finalPrompt = prompt.trimmedOrEmpty
        let finalTitle = title.trimmedOrEmpty.isEmpty ? defaultTitle(from: finalPrompt) : title.trimmedOrEmpty
        let request = CreateManagedRunRequest(
            title: finalTitle,
            workspaceID: workspaceID,
            relativePath: normalizedRelativePath(relativePath).nilIfEmpty,
            preferredDeviceID: preferredDeviceID.nilIfEmpty,
            driver: .codexCLI,
            prompt: finalPrompt
        )

        do {
            let run = try await model.createManagedRun(serverURLString: serverURL, request: request)
            localErrorMessage = nil
            onCreated(run)
            dismiss()
        } catch {
            localErrorMessage = error.localizedDescription
        }
    }

    private func defaultTitle(from prompt: String) -> String {
        let firstLine = prompt
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmedOrEmpty }
            .first { !$0.isEmpty } ?? "新的托管 run"
        if firstLine.count <= 28 {
            return firstLine
        }
        return String(firstLine.prefix(28)) + "..."
    }
}

#if DEBUG
@MainActor
struct CreateManagedRunSheet_Previews: PreviewProvider {
    static var previews: some View {
        CreateManagedRunSheet(
            model: CompanionPreviewData.model,
            serverURL: "http://preview.local/"
        )
    }
}
#endif
