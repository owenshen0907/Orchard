import OrchardCore
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

@MainActor
enum CompanionToolbarPlacement {
#if os(iOS)
    static let leading = ToolbarItemPlacement.topBarLeading
    static let trailing = ToolbarItemPlacement.topBarTrailing
#else
    static let leading = ToolbarItemPlacement.cancellationAction
    static let trailing = ToolbarItemPlacement.primaryAction
#endif
}

enum CompanionRefreshPolicy {
    static let overviewInterval: Duration = .seconds(10)
    static let detailInterval: Duration = .seconds(4)
}

struct MetricCard: View {
    let title: String
    let value: String
    let symbolName: String
    let tint: Color
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: symbolName)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(tint)

                Spacer()

                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Text(value)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)

            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(tint.opacity(0.07))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(tint.opacity(0.08), lineWidth: 1)
                }
        }
    }
}

struct HeroCard: View {
    let eyebrow: String
    let title: String
    let message: String
    let symbolName: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(eyebrow)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                Text(title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Image(systemName: symbolName)
                .font(.title2.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(tint.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(20)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            tint.opacity(0.16),
                            Color.secondary.opacity(0.06),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(tint.opacity(0.08), lineWidth: 1)
                }
        }
    }
}

struct MetaCapsule: View {
    let title: String
    var symbolName: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 6) {
            if let symbolName {
                Image(systemName: symbolName)
            }

            Text(title)
                .lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tint.opacity(0.1))
        .clipShape(Capsule())
    }
}

struct DetailHeroMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SectionHeaderLabel: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .textCase(nil)
    }
}

struct SectionPlaceholder: View {
    let title: String
    var message: String? = nil
    var symbolName = "circle.dashed"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbolName)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)

            if let message, !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
    }
}

struct NoticeCard: View {
    let title: String
    let message: String
    let symbolName: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbolName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct CodexDiagnosticsCard: View {
    let summary: String
    let sourceSummary: String
    let turnSummary: String
    let conclusion: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Codex 诊断", systemImage: "stethoscope")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)

            Text(summary)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                diagnosticLine(title: "来源", value: sourceSummary)
                diagnosticLine(title: "轮次", value: turnSummary)
                diagnosticLine(title: "判断", value: conclusion)
            }
        }
        .padding(14)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func diagnosticLine(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SettingsToolbarButton: View {
    @Binding var isPresented: Bool

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "gearshape")
        }
        .accessibilityLabel("设置")
    }
}

struct StatusBadge: View {
    let title: String
    let tint: Color

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.14))
            .foregroundStyle(tint)
            .clipShape(Capsule())
    }
}

struct CompanionToast: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.thinMaterial)
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
    }
}

struct CompanionInlineActions: View {
    let canContinue: Bool
    let canInterrupt: Bool
    let canStop: Bool
    let isStopRequested: Bool
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

    private var actionLayout: some View {
        HStack(spacing: 8) {
            if canContinue {
                Button("继续追问", action: onContinue)
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
            }

            if canInterrupt {
                Button("中断", action: onInterrupt)
                    .buttonStyle(.bordered)
                    .tint(.orange)
            }

            if canStop {
                Button("停止", action: onStop)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
            } else if isStopRequested {
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
            if canContinue {
                Button("继续追问", action: onContinue)
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
            }

            if canInterrupt {
                Button("中断", action: onInterrupt)
                    .buttonStyle(.bordered)
                    .tint(.orange)
            }

            if canStop {
                Button("停止", action: onStop)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
            } else if isStopRequested {
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

struct CompanionContinuePromptSheet: View {
    let title: String
    let message: String
    let subject: String
    @Binding var prompt: String
    let isSubmitting: Bool
    let errorMessage: String?
    var projectCommandSource: ProjectCommandQuickInsertSource? = nil
    let onCancel: () -> Void
    let onSubmit: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(subject)
                        .font(.headline)
                }

                Section("继续追问") {
                    TextEditor(text: $prompt)
                        .frame(minHeight: 180)
                }

                if let projectCommandSource {
                    Section("标准操作命令") {
                        ProjectCommandQuickInsertSection(
                            source: projectCommandSource,
                            intent: .continueConversation,
                            helperText: "点任一命令，会把对应的中文执行指令追加到当前输入框，适合继续追问时让 Codex 按标准动作执行。",
                            actionTitle: "插入"
                        ) { suggestion in
                            prompt = ProjectCommandPromptComposer.appendPrompt(
                                suggestion.suggestedPrompt,
                                to: prompt
                            )
                        }
                    }
                }

                if let errorMessage, !errorMessage.isEmpty {
                    Section("错误") {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(title)
            .companionInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: CompanionToolbarPlacement.leading) {
                    Button("取消", action: onCancel)
                        .disabled(isSubmitting)
                }

                ToolbarItem(placement: CompanionToolbarPlacement.trailing) {
                    Button("发送", action: onSubmit)
                        .disabled(prompt.trimmedOrEmpty.isEmpty || isSubmitting)
                }
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Binding var serverURL: String
    @Binding var accessKey: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("连接") {
                    TextField("服务地址", text: $serverURL)
#if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
#endif

                    SecureField("访问密钥", text: $accessKey)
#if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
#endif

                    Button("立即刷新") {
                        Task {
                            await model.refresh(serverURLString: serverURL)
                        }
                    }
                }

                Section("状态") {
                    LabeledContent("最近刷新") {
                        if let lastRefreshAt = model.lastRefreshAt {
                            Text(lastRefreshAt.formatted(date: .omitted, time: .shortened))
                        } else {
                            Text("未刷新")
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let errorMessage = model.errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("设置")
            .companionInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: CompanionToolbarPlacement.trailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }
}

extension DashboardSnapshot {
    var failedTaskCount: Int {
        tasks.filter { $0.status == .failed }.count
    }

    var failedManagedRunCount: Int {
        managedRuns.filter { $0.status == .failed }.count
    }

    var onlineDeviceCount: Int {
        devices.filter { $0.status == .online }.count
    }

    var runningTaskCount: Int {
        tasks.filter { $0.status == .running || $0.status == .stopRequested }.count
    }

    var runningManagedRunCount: Int {
        managedRuns.filter { $0.status.occupiesSlot }.count
    }

    var queuedManagedRunCount: Int {
        managedRuns.filter { $0.status == .queued }.count
    }

    var attentionTasks: [TaskRecord] {
        tasks
            .filter { task in
                switch task.status {
                case .running, .failed, .stopRequested:
                    return true
                case .queued, .succeeded, .cancelled:
                    return false
                }
            }
            .sorted { lhs, rhs in
                let lhsPriority = lhs.attentionRank
                let rhsPriority = rhs.attentionRank
                if lhsPriority != rhsPriority {
                    return lhsPriority < rhsPriority
                }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    var attentionManagedRuns: [ManagedRunSummary] {
        managedRuns
            .filter { run in
                switch run.status {
                case .failed, .stopRequested, .interrupting, .running, .waitingInput, .launching:
                    return true
                case .queued, .succeeded, .interrupted, .cancelled:
                    return false
                }
            }
            .sorted { lhs, rhs in
                let lhsPriority = lhs.attentionRank
                let rhsPriority = rhs.attentionRank
                if lhsPriority != rhsPriority {
                    return lhsPriority < rhsPriority
                }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    var managedRunCountsByDevice: [String: Int] {
        Dictionary(
            managedRuns.compactMap { run -> (String, Int)? in
                guard run.status.occupiesSlot, let deviceID = run.deviceID else { return nil }
                return (deviceID, 1)
            },
            uniquingKeysWith: +
        )
    }

    var onlineDevices: [DeviceRecord] {
        let runCounts = managedRunCountsByDevice
        return devices
            .filter { $0.status == .online }
            .sorted { lhs, rhs in
                let lhsRunCount = runCounts[lhs.deviceID] ?? 0
                let rhsRunCount = runCounts[rhs.deviceID] ?? 0
                if lhsRunCount != rhsRunCount {
                    return lhsRunCount > rhsRunCount
                }
                if lhs.metrics.loadAverage != rhs.metrics.loadAverage {
                    return (lhs.metrics.loadAverage ?? 0) > (rhs.metrics.loadAverage ?? 0)
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    var workspaces: [WorkspaceDefinition] {
        let unique = Dictionary(
            devices.flatMap { $0.workspaces }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return unique.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var overviewTitle: String {
        if failedManagedRunCount > 0 {
            return "需要处理"
        }
        if runningManagedRunCount > 0 {
            return "运行进行中"
        }
        if onlineDeviceCount > 0 {
            return "系统稳定"
        }
        return "等待连接"
    }

    var overviewMessage: String {
        if failedManagedRunCount > 0 {
            return "发现 \(failedManagedRunCount) 个失败运行，建议优先查看详情。"
        }
        if runningManagedRunCount > 0 {
            return "当前有 \(runningManagedRunCount) 个托管运行正在执行，设备保持在线。"
        }
        if onlineDeviceCount > 0 {
            return "目前没有异常任务，\(onlineDeviceCount) 台设备在线待命。"
        }
        return "还没有在线设备，确认 Agent 和服务地址是否正常。"
    }

    var overviewTint: Color {
        if failedManagedRunCount > 0 {
            return .red
        }
        if runningManagedRunCount > 0 {
            return .blue
        }
        if onlineDeviceCount > 0 {
            return .green
        }
        return .secondary
    }

    var overviewSymbolName: String {
        if failedManagedRunCount > 0 {
            return "exclamationmark.triangle.fill"
        }
        if runningManagedRunCount > 0 {
            return "bolt.horizontal.fill"
        }
        if onlineDeviceCount > 0 {
            return "checkmark.circle.fill"
        }
        return "antenna.radiowaves.left.and.right.slash"
    }
}

extension View {
    @ViewBuilder
    func companionInlineNavigationTitle() -> some View {
#if os(iOS)
        navigationBarTitleDisplayMode(.inline)
#else
        self
#endif
    }

    @ViewBuilder
    func companionListStyle() -> some View {
#if os(iOS)
        listStyle(.insetGrouped)
#else
        listStyle(.automatic)
#endif
    }

    @ViewBuilder
    func companionToast(message: String?) -> some View {
        overlay(alignment: .top) {
            if let message, !message.isEmpty {
                CompanionToast(message: message)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.88), value: message)
    }
}

extension DeviceCapability {
    var displayName: String {
        switch self {
        case .shell:
            return "命令行"
        case .filesystem:
            return "文件系统"
        case .git:
            return "Git"
        case .docker:
            return "Docker"
        case .browser:
            return "浏览器"
        case .codex:
            return "Codex"
        }
    }
}

extension DevicePlatform {
    var displayName: String {
        switch self {
        case .macOS:
            return "macOS"
        case .iOS:
            return "iOS"
        case .unknown:
            return "未知"
        }
    }

    var symbolName: String {
        switch self {
        case .macOS:
            return "laptopcomputer"
        case .iOS:
            return "iphone"
        case .unknown:
            return "desktopcomputer"
        }
    }
}

extension DeviceRecord {
    var statusColor: Color {
        switch status {
        case .online:
            return .green
        case .offline:
            return .secondary
        }
    }

    var statusTitle: String {
        switch status {
        case .online:
            return "在线"
        case .offline:
            return "离线"
        }
    }

    var codexDesktopSnapshotText: String? {
        metrics.codexDesktop?.lastSnapshotAt?.formatted(date: .omitted, time: .shortened)
    }

    var codexDesktopSummaryText: String? {
        guard capabilities.contains(.codex) else {
            return nil
        }

        guard let codexDesktop = metrics.codexDesktop else {
            return "暂未收到 Codex 桌面实时快照。"
        }

        guard let activeThreadCount = codexDesktop.activeThreadCount else {
            if let snapshot = codexDesktopSnapshotText {
                return "Codex 桌面快照已过期（\(snapshot)），等待下一次心跳刷新。"
            }
            return "Codex 桌面快照暂不可用。"
        }

        let inflightThreadCount = codexDesktop.inflightThreadCount ?? 0
        let inflightTurnCount = codexDesktop.inflightTurnCount ?? 0
        return "Codex 活跃线程 \(activeThreadCount) 个，推理中线程 \(inflightThreadCount) 个，进行中轮次 \(inflightTurnCount) 个。"
    }
}

extension TaskKind {
    var displayName: String {
        switch self {
        case .shell:
            return "命令"
        case .codex:
            return "Codex"
        }
    }

    var symbolName: String {
        switch self {
        case .shell:
            return "terminal"
        case .codex:
            return "sparkles"
        }
    }
}

extension TaskPriority {
    var displayName: String {
        switch self {
        case .low:
            return "低"
        case .normal:
            return "普通"
        case .high:
            return "高"
        }
    }
}

extension TaskRecord {
    var attentionRank: Int {
        switch status {
        case .failed:
            return 0
        case .stopRequested:
            return 1
        case .running:
            return 2
        case .queued:
            return 3
        case .succeeded:
            return 4
        case .cancelled:
            return 5
        }
    }

    var payloadPreview: String {
        switch payload {
        case let .shell(shell):
            return shell.command
        case let .codex(codex):
            return codex.prompt
        }
    }

    var stateColor: Color {
        switch status {
        case .queued:
            return .secondary
        case .running:
            return .blue
        case .succeeded:
            return .green
        case .failed:
            return .red
        case .stopRequested:
            return .orange
        case .cancelled:
            return .secondary
        }
    }

    var statusTitle: String {
        switch status {
        case .queued:
            return "排队中"
        case .running:
            return "运行中"
        case .succeeded:
            return "已完成"
        case .failed:
            return "失败"
        case .stopRequested:
            return "停止中"
        case .cancelled:
            return "已取消"
        }
    }

    var statusSymbolName: String {
        switch status {
        case .queued:
            return "clock"
        case .running:
            return "bolt.circle.fill"
        case .succeeded:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.octagon.fill"
        case .stopRequested:
            return "stop.circle.fill"
        case .cancelled:
            return "minus.circle.fill"
        }
    }
}

extension ManagedRunSummary {
    var attentionRank: Int {
        switch status {
        case .failed:
            return 0
        case .stopRequested:
            return 1
        case .interrupting:
            return 2
        case .waitingInput:
            return 3
        case .running:
            return 4
        case .launching:
            return 5
        case .queued:
            return 6
        case .interrupted:
            return 7
        case .succeeded:
            return 8
        case .cancelled:
            return 9
        }
    }

    var promptPreview: String {
        if let prompt = lastUserPrompt?.trimmedOrEmpty, !prompt.isEmpty {
            return prompt
        }
        if let summary = summary?.trimmedOrEmpty, !summary.isEmpty {
            return summary
        }
        return cwd
    }

    var statusTitle: String {
        switch status {
        case .queued:
            return "排队中"
        case .launching:
            return "启动中"
        case .running:
            return "运行中"
        case .waitingInput:
            return "等待继续"
        case .interrupting:
            return "中断中"
        case .stopRequested:
            return "停止中"
        case .succeeded:
            return "已完成"
        case .failed:
            return "失败"
        case .interrupted:
            return "已中断"
        case .cancelled:
            return "已取消"
        }
    }

    var stateColor: Color {
        switch status {
        case .queued:
            return .secondary
        case .launching:
            return .blue
        case .running:
            return .blue
        case .waitingInput:
            return .indigo
        case .interrupting:
            return .orange
        case .stopRequested:
            return .orange
        case .succeeded:
            return .green
        case .failed:
            return .red
        case .interrupted:
            return .orange
        case .cancelled:
            return .secondary
        }
    }

    var statusSymbolName: String {
        switch status {
        case .queued:
            return "clock"
        case .launching:
            return "arrow.triangle.2.circlepath.circle.fill"
        case .running:
            return "bolt.circle.fill"
        case .waitingInput:
            return "text.bubble.fill"
        case .interrupting:
            return "pause.circle.fill"
        case .stopRequested:
            return "stop.circle.fill"
        case .succeeded:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.octagon.fill"
        case .interrupted:
            return "pause.circle.fill"
        case .cancelled:
            return "minus.circle.fill"
        }
    }

    var deviceDisplayName: String {
        if let deviceName = deviceName?.nilIfEmpty {
            return deviceName
        }
        if let deviceID = deviceID?.nilIfEmpty {
            return deviceID
        }
        if let preferredDeviceID = preferredDeviceID?.nilIfEmpty {
            return "待分配 -> \(preferredDeviceID)"
        }
        return "待分配"
    }

    var shortCWD: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }

    var subtitleText: String {
        if let summary = summary?.trimmedOrEmpty, !summary.isEmpty {
            return summary
        }
        if let prompt = lastUserPrompt?.trimmedOrEmpty, !prompt.isEmpty {
            return prompt
        }
        return cwd
    }

    var canContinueRemotely: Bool {
        status == .waitingInput && !(codexSessionID?.isEmpty ?? true)
    }

    var canInterruptRemotely: Bool {
        (status == .running || status == .waitingInput) && !(codexSessionID?.isEmpty ?? true)
    }

    var canStopRemotely: Bool {
        !status.isTerminal && status != .stopRequested
    }

    var isStopRequestedRemotely: Bool {
        status == .stopRequested
    }
}

extension AppModel {
    var localMatchedDeviceIDs: Set<String> {
        Set(localMatchedDevices.map(\.deviceID))
    }

    var localMatchedDevices: [DeviceRecord] {
        let hostIdentity = normalizeDeviceIdentity(ProcessInfo.processInfo.hostName)
        guard !hostIdentity.isEmpty else {
            return []
        }

        return snapshot.devices.filter { device in
            let candidates = [
                device.hostName,
                device.name,
                device.deviceID,
            ]
            return candidates.contains { normalizeDeviceIdentity($0) == hostIdentity }
        }
    }

    var hasLocalMatchedDevice: Bool {
        !localMatchedDevices.isEmpty
    }

    var localMatchedDeviceTitle: String {
        localMatchedDevices.first?.name ?? ProcessInfo.processInfo.hostName
    }

    func isLocalManagedRun(_ run: ManagedRunSummary) -> Bool {
        let localDeviceIDs = localMatchedDeviceIDs
        guard !localDeviceIDs.isEmpty else {
            return false
        }

        if let deviceID = run.deviceID?.nilIfEmpty, localDeviceIDs.contains(deviceID) {
            return true
        }
        if let preferredDeviceID = run.preferredDeviceID?.nilIfEmpty, localDeviceIDs.contains(preferredDeviceID) {
            return true
        }
        return false
    }

    var localManagedRuns: [ManagedRunSummary] {
        guard !localMatchedDeviceIDs.isEmpty else {
            return []
        }

        return snapshot.managedRuns
            .filter(isLocalManagedRun)
            .sorted { lhs, rhs in
                if lhs.attentionRank != rhs.attentionRank {
                    return lhs.attentionRank < rhs.attentionRank
                }
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.id < rhs.id
            }
    }

    var localManagedRunsSummaryText: String {
        let runningCount = localManagedRuns.filter { $0.status.occupiesSlot }.count
        let queuedCount = localManagedRuns.filter { $0.status == .queued }.count
        if runningCount > 0, queuedCount > 0 {
            return "这台宿主机当前有 \(runningCount) 个运行中的托管 run，另有 \(queuedCount) 个已指向本机等待接手。"
        }
        if runningCount > 0 {
            return "这台宿主机当前有 \(runningCount) 个托管 run 正在执行。"
        }
        if queuedCount > 0 {
            return "这台宿主机当前还没有真正开跑，但已有 \(queuedCount) 个托管 run 指向本机。"
        }
        return "这台宿主机已经接入控制面；后续从网页端或手机端下发到本机的托管 run，会优先出现在这里。"
    }

    var shouldShowCodexDiagnostics: Bool {
        !codexSessions.isEmpty || codexDesktopActiveThreadCount > 0 || codexDesktopInflightTurnCount > 0
    }

    var managedTaskIDs: Set<String> {
        Set(
            snapshot.managedRuns.compactMap { run in
                run.taskID?.nilIfEmpty
            }
        )
    }

    private var activeManagedTaskIDs: Set<String> {
        Set(
            snapshot.managedRuns.compactMap { run in
                guard run.status.occupiesSlot else { return nil }
                return run.taskID?.nilIfEmpty
            }
        )
    }

    var unmanagedRunningTaskCount: Int {
        let managedTaskIDs = activeManagedTaskIDs
        return snapshot.tasks.filter { task in
            (task.status == .running || task.status == .stopRequested) && !managedTaskIDs.contains(task.id)
        }.count
    }

    var unmanagedTasks: [TaskRecord] {
        let managedTaskIDs = managedTaskIDs
        return snapshot.tasks.filter { task in
            !managedTaskIDs.contains(task.id)
        }
    }

    var attentionUnmanagedTasks: [TaskRecord] {
        unmanagedTasks
            .filter { task in
                switch task.status {
                case .failed, .stopRequested, .running, .queued:
                    return true
                case .succeeded, .cancelled:
                    return false
                }
            }
            .sorted { lhs, rhs in
                if lhs.attentionRank != rhs.attentionRank {
                    return lhs.attentionRank < rhs.attentionRank
                }
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.id < rhs.id
            }
    }

    var combinedRunningCount: Int {
        snapshot.runningManagedRunCount + unmanagedRunningTaskCount + observedRunningCodexCount
    }

    var observedRunningCodexCount: Int {
        max(runningCodexSessionCount, codexDesktopInflightThreadCount)
    }

    var codexDesktopActiveThreadCount: Int {
        snapshot.devices.reduce(0) { partialResult, device in
            guard device.status == .online else { return partialResult }
            return partialResult + (device.metrics.codexDesktop?.activeThreadCount ?? 0)
        }
    }

    var codexDesktopInflightThreadCount: Int {
        snapshot.devices.reduce(0) { partialResult, device in
            guard device.status == .online else { return partialResult }
            return partialResult + (device.metrics.codexDesktop?.inflightThreadCount ?? 0)
        }
    }

    var codexDesktopInflightTurnCount: Int {
        snapshot.devices.reduce(0) { partialResult, device in
            guard device.status == .online else { return partialResult }
            return partialResult + (device.metrics.codexDesktop?.inflightTurnCount ?? 0)
        }
    }

    var codexDesktopLiveGapCount: Int {
        max(codexDesktopActiveThreadCount - runningCodexSessionCount, 0)
    }

    func mappedRunningCodexSessionCount(for deviceID: String) -> Int {
        codexSessions.filter { $0.deviceID == deviceID && $0.isRunningLike }.count
    }

    func observedRunningCodexCount(for device: DeviceRecord) -> Int {
        max(
            mappedRunningCodexSessionCount(for: device.deviceID),
            device.metrics.codexDesktop?.inflightThreadCount ?? 0
        )
    }

    func runningManagedRunCount(for deviceID: String) -> Int {
        snapshot.managedRunCountsByDevice[deviceID] ?? 0
    }

    func unmanagedRunningTaskCount(for deviceID: String) -> Int {
        let managedTaskIDs = activeManagedTaskIDs
        return snapshot.tasks.filter { task in
            guard task.assignedDeviceID == deviceID else {
                return false
            }
            guard task.status == .running || task.status == .stopRequested else {
                return false
            }
            return !managedTaskIDs.contains(task.id)
        }.count
    }

    func combinedRunningCount(for device: DeviceRecord) -> Int {
        unmanagedRunningTaskCount(for: device.deviceID)
            + runningManagedRunCount(for: device.deviceID)
            + observedRunningCodexCount(for: device)
    }

    func codexDesktopLiveGapCount(for device: DeviceRecord) -> Int {
        max((device.metrics.codexDesktop?.activeThreadCount ?? 0) - mappedRunningCodexSessionCount(for: device.deviceID), 0)
    }

    func codexDesktopGapSummary(for device: DeviceRecord) -> String? {
        guard device.capabilities.contains(.codex) else {
            return nil
        }

        guard let activeThreadCount = device.metrics.codexDesktop?.activeThreadCount else {
            return nil
        }

        let mappedRunning = mappedRunningCodexSessionCount(for: device.deviceID)
        let gap = max(activeThreadCount - mappedRunning, 0)
        guard gap > 0 else {
            return nil
        }

        let inflightTurnCount = device.metrics.codexDesktop?.inflightTurnCount ?? 0
        return "桌面快照还有 \(gap) 个活跃线程未映射到会话列表；当前仅精确映射出 \(mappedRunning) 个 running 会话，进行中轮次 \(inflightTurnCount) 个。"
    }

    var runningCodexSessionCount: Int {
        codexSessions.filter(\.isRunningLike).count
    }

    var standbyCodexSessionCount: Int {
        codexSessions.filter(\.isStandbyLike).count
    }

    var lightweightCodexSessionCount: Int {
        codexSessions.filter(\.isLightweightSummary).count
    }

    var finishedCodexSessionCount: Int {
        codexSessions.filter(\.isFinishedLike).count
    }

    var codexAttentionSessions: [CodexSessionSummary] {
        codexSessions.sorted { lhs, rhs in
            if lhs.attentionRank != rhs.attentionRank {
                return lhs.attentionRank < rhs.attentionRank
            }
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.id < rhs.id
        }
    }

    var overviewTitle: String {
        if snapshot.failedManagedRunCount > 0 {
            return "需要处理"
        }
        if combinedRunningCount > 0 {
            return "任务进行中"
        }
        if standbyCodexSessionCount > 0 {
            return "会话待命"
        }
        if snapshot.onlineDeviceCount > 0 {
            return "系统稳定"
        }
        return "等待连接"
    }

    var overviewMessage: String {
        if snapshot.failedManagedRunCount > 0 {
            return "发现 \(snapshot.failedManagedRunCount) 个失败运行，建议优先查看详情。"
        }
        if combinedRunningCount > 0 {
            var parts: [String] = []
            if snapshot.runningManagedRunCount > 0 {
                parts.append("\(snapshot.runningManagedRunCount) 个托管运行")
            }
            if unmanagedRunningTaskCount > 0 {
                parts.append("\(unmanagedRunningTaskCount) 个独立任务")
            }
            if observedRunningCodexCount > 0 {
                if observedRunningCodexCount > runningCodexSessionCount {
                    parts.append("Codex 侧观测到 \(observedRunningCodexCount) 个推理中线程（已精确映射 \(runningCodexSessionCount) 个会话）")
                } else {
                    parts.append("\(runningCodexSessionCount) 个 Codex 会话")
                }
            }

            let suffix: String
            if observedRunningCodexCount > 0, standbyCodexSessionCount > 0 {
                suffix = "；另有 \(standbyCodexSessionCount) 个待命线程可继续追问。"
            } else {
                suffix = "。"
            }
            return "当前共有 \(combinedRunningCount) 个运行项，其中 " + parts.joined(separator: "，") + suffix
        }
        if standbyCodexSessionCount > 0 {
            if lightweightCodexSessionCount > 0 {
                return "当前没有推理中的 Codex 会话，但有 \(standbyCodexSessionCount) 个待命线程，其中 \(lightweightCodexSessionCount) 个仍是轻摘要。"
            }
            return "当前没有推理中的 Codex 会话，但有 \(standbyCodexSessionCount) 个待命线程可继续接管。"
        }
        if snapshot.onlineDeviceCount > 0 {
            return "目前没有异常任务，\(snapshot.onlineDeviceCount) 台设备在线待命。"
        }
        return "还没有在线设备，确认 Agent 和服务地址是否正常。"
    }

    var overviewTint: Color {
        if snapshot.failedManagedRunCount > 0 {
            return .red
        }
        if combinedRunningCount > 0 {
            return .blue
        }
        if standbyCodexSessionCount > 0 {
            return .indigo
        }
        if snapshot.onlineDeviceCount > 0 {
            return .green
        }
        return .secondary
    }

    var overviewSymbolName: String {
        if snapshot.failedManagedRunCount > 0 {
            return "exclamationmark.triangle.fill"
        }
        if observedRunningCodexCount > 0 {
            return "sparkles.rectangle.stack.fill"
        }
        if standbyCodexSessionCount > 0 {
            return "pause.circle.fill"
        }
        if snapshot.runningManagedRunCount > 0 || unmanagedRunningTaskCount > 0 {
            return "bolt.horizontal.fill"
        }
        if snapshot.onlineDeviceCount > 0 {
            return "checkmark.circle.fill"
        }
        return "antenna.radiowaves.left.and.right.slash"
    }

    var codexDiagnosticsSummaryText: String {
        "当前共 \(codexSessions.count) 个 Codex 会话：会话推理中 \(runningCodexSessionCount)，设备观测推理中 \(observedRunningCodexCount)，待命 \(standbyCodexSessionCount)，已结束 \(finishedCodexSessionCount)；桌面端活跃线程 \(codexDesktopActiveThreadCount)，进行中轮次 \(codexDesktopInflightTurnCount)。"
    }

    var codexSourceSummaryText: String {
        summarizeCounts(codexSessions.map { $0.source.trimmedOrEmpty.nilIfEmpty ?? "未知" })
    }

    var codexTurnSummaryText: String {
        summarizeCounts(codexSessions.map(\.turnDiagnosticsLabel))
    }

    var codexConclusionText: String {
        if codexDesktopLiveGapCount > 0 {
            return "桌面端实时快照显示 \(codexDesktopActiveThreadCount) 个活跃线程、\(codexDesktopInflightTurnCount) 个进行中轮次，当前至少观测到 \(observedRunningCodexCount) 个推理中线程；但会话桥只精确映射出 \(runningCodexSessionCount) 个 running 会话，仍有 \(codexDesktopLiveGapCount) 个线程只能先做设备级观测。"
        }
        if observedRunningCodexCount > 0 {
            if observedRunningCodexCount > runningCodexSessionCount {
                return "当前存在真正推理中的线程，虽然会话桥还没全部命中，但顶部“总运行中”已经按桌面 inflight 线程兜底统计。"
            }
            return "当前存在真正推理中的线程，顶部“总运行中”会把这些线程算进去。"
        }
        if standbyCodexSessionCount > 0 {
            if lightweightCodexSessionCount > 0 {
                return "当前主要是待命线程；其中 \(lightweightCodexSessionCount) 个只拿到轻摘要，点进详情后才会补拉完整轮次。"
            }
            return "当前没有推理中的线程，所以“总运行中”为 0 是正常的；这些待命会话仍可继续追问。"
        }
        if finishedCodexSessionCount > 0 {
            return "当前列表以已结束线程为主，适合复盘或继续追问。"
        }
        return "还没有从 Agent 读到可展示的会话。"
    }

    var codexLiveGapNoticeText: String? {
        guard codexDesktopLiveGapCount > 0 else {
            return nil
        }

        return "Codex 桌面端当前仍有 \(codexDesktopLiveGapCount) 个活跃线程没有进入会话级精确映射。现在可以先通过设备快照看见它们在忙，后续再继续补原生会话桥的细粒度操控。"
    }

    var codexDiagnosticsTint: Color {
        if codexDesktopLiveGapCount > 0 {
            return .orange
        }
        if runningCodexSessionCount > 0 {
            return .blue
        }
        if standbyCodexSessionCount > 0 {
            return .indigo
        }
        if finishedCodexSessionCount > 0 {
            return .orange
        }
        return .secondary
    }

    private func summarizeCounts(_ values: [String]) -> String {
        let counts = Dictionary(values.map { ($0, 1) }, uniquingKeysWith: +)
        guard !counts.isEmpty else {
            return "暂无"
        }
        return counts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value {
                    return lhs.value > rhs.value
                }
                return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
            }
            .prefix(3)
            .map { "\($0.key) \($0.value)" }
            .joined(separator: " · ")
    }

    private func normalizeDeviceIdentity(_ value: String?) -> String {
        var candidate = value?.trimmedOrEmpty.lowercased() ?? ""
        if candidate.hasSuffix(".local") {
            candidate.removeLast(".local".count)
        }
        return candidate
    }
}

extension CodexSessionState {
    var displayName: String {
        switch self {
        case .running:
            return "运行中"
        case .idle:
            return "待命"
        case .completed:
            return "已完成"
        case .failed:
            return "失败"
        case .interrupted:
            return "已中断"
        case .unknown:
            return "未知"
        }
    }

    var color: Color {
        switch self {
        case .running:
            return .blue
        case .idle:
            return .secondary
        case .completed:
            return .green
        case .failed:
            return .red
        case .interrupted:
            return .orange
        case .unknown:
            return .secondary
        }
    }

    var symbolName: String {
        switch self {
        case .running:
            return "waveform.circle.fill"
        case .idle:
            return "pause.circle.fill"
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.octagon.fill"
        case .interrupted:
            return "stop.circle.fill"
        case .unknown:
            return "questionmark.circle.fill"
        }
    }
}

extension CodexSessionSummary {
    var isRunningLike: Bool {
        state == .running || lastTurnStatus == "inProgress"
    }

    var isStandbyLike: Bool {
        !isRunningLike && (state == .idle || state == .unknown)
    }

    var isFinishedLike: Bool {
        state == .completed || state == .failed || state == .interrupted
    }

    var isLightweightSummary: Bool {
        guard isStandbyLike else {
            return false
        }
        return lastTurnStatus?.trimmedOrEmpty.nilIfEmpty == nil
            && lastUserMessage?.trimmedOrEmpty.nilIfEmpty == nil
            && lastAssistantMessage?.trimmedOrEmpty.nilIfEmpty == nil
    }

    var derivedStatusTitle: String {
        if isRunningLike {
            return "推理中"
        }
        if isStandbyLike {
            return isLightweightSummary ? "待命（轻摘要）" : "待命"
        }
        return state.displayName
    }

    var derivedStatusColor: Color {
        if isRunningLike {
            return .blue
        }
        if isStandbyLike {
            return .indigo
        }
        return state.color
    }

    var derivedStatusSymbolName: String {
        if isRunningLike {
            return "sparkles.rectangle.stack.fill"
        }
        if isStandbyLike {
            return isLightweightSummary ? "doc.text.magnifyingglass" : "pause.circle.fill"
        }
        return state.symbolName
    }

    var turnDiagnosticsLabel: String {
        if isLightweightSummary {
            return "轻摘要"
        }
        return lastTurnStatusDisplayName
    }

    var lastTurnStatusDisplayName: String {
        switch lastTurnStatus {
        case "inProgress":
            return "推理中"
        case "completed":
            return "已完成"
        case "interrupted":
            return "已中断"
        case "failed":
            return "失败"
        case .some(let value) where !value.trimmedOrEmpty.isEmpty:
            return value
        default:
            return "无轮次"
        }
    }

    var statusExplanationText: String {
        if isRunningLike {
            return "当前线程最近轮次仍在执行，计入“总运行中”。"
        }
        if isStandbyLike {
            if isLightweightSummary {
                return "当前只拿到列表轻摘要，说明线程还在，但轮次细节需要打开详情再读取。"
            }
            return "当前线程没有继续推理，但上下文仍然保留，可直接继续追问。"
        }
        switch state {
        case .completed:
            return "最近一次轮次已完成，可以继续追问开启下一轮。"
        case .failed:
            return "最近一次轮次失败，建议先查看详情和错误。"
        case .interrupted:
            return "最近一次轮次被中断，可继续追问恢复。"
        case .running, .idle, .unknown:
            return "当前状态仍在同步中。"
        }
    }

    var attentionRank: Int {
        if isRunningLike {
            return 0
        }
        switch state {
        case .failed:
            return 1
        case .interrupted:
            return 2
        case .idle, .unknown:
            return isLightweightSummary ? 3 : 4
        case .completed:
            return 5
        case .running:
            return 0
        }
    }

    var titleText: String {
        if let name = name?.trimmedOrEmpty, !name.isEmpty {
            return name
        }
        if let lastUserMessage = lastUserMessage?.trimmedOrEmpty, !lastUserMessage.isEmpty {
            return lastUserMessage.displaySnippet(limit: 48)
        }
        return preview.displaySnippet(limit: 48)
    }

    var subtitleText: String {
        if let lastAssistantMessage = lastAssistantMessage?.trimmedOrEmpty, !lastAssistantMessage.isEmpty {
            return lastAssistantMessage.displaySnippet(limit: 80)
        }
        return preview.displaySnippet(limit: 80)
    }

    var locationText: String {
        if let workspaceID = workspaceID?.trimmedOrEmpty, !workspaceID.isEmpty {
            return "\(deviceName) · \(workspaceID) · \(URL(fileURLWithPath: cwd).lastPathComponent)"
        }
        return "\(deviceName) · \(URL(fileURLWithPath: cwd).lastPathComponent)"
    }

    var canContinueRemotely: Bool {
        true
    }

    var canInterruptRemotely: Bool {
        isRunningLike
    }
}

extension CodexSessionItemKind {
    var displayName: String {
        switch self {
        case .userMessage:
            return "用户"
        case .agentMessage:
            return "Codex"
        case .plan:
            return "计划"
        case .reasoning:
            return "推理"
        case .commandExecution:
            return "命令"
        case .fileChange:
            return "文件"
        case .webSearch:
            return "网页"
        case .other:
            return "事件"
        }
    }
}

extension String {
    func displaySnippet(limit: Int) -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else {
            return trimmed
        }
        return String(trimmed.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    var trimmedOrEmpty: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

@MainActor
func copyTextToPasteboard(_ text: String) {
#if canImport(UIKit)
    UIPasteboard.general.string = text
#elseif canImport(AppKit)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
#endif
}
