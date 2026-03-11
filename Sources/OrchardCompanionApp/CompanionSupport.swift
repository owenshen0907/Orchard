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

    var onlineDeviceCount: Int {
        devices.filter { $0.status == .online }.count
    }

    var runningTaskCount: Int {
        tasks.filter { $0.status == .running || $0.status == .stopRequested }.count
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

    var onlineDevices: [DeviceRecord] {
        devices
            .filter { $0.status == .online }
            .sorted { lhs, rhs in
                if lhs.metrics.runningTasks != rhs.metrics.runningTasks {
                    return lhs.metrics.runningTasks > rhs.metrics.runningTasks
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
        if failedTaskCount > 0 {
            return "需要处理"
        }
        if runningTaskCount > 0 {
            return "任务进行中"
        }
        if onlineDeviceCount > 0 {
            return "系统稳定"
        }
        return "等待连接"
    }

    var overviewMessage: String {
        if failedTaskCount > 0 {
            return "发现 \(failedTaskCount) 个失败任务，建议优先查看详情。"
        }
        if runningTaskCount > 0 {
            return "当前有 \(runningTaskCount) 个任务正在执行，设备保持在线。"
        }
        if onlineDeviceCount > 0 {
            return "目前没有异常任务，\(onlineDeviceCount) 台设备在线待命。"
        }
        return "还没有在线设备，确认 Agent 和服务地址是否正常。"
    }

    var overviewTint: Color {
        if failedTaskCount > 0 {
            return .red
        }
        if runningTaskCount > 0 {
            return .blue
        }
        if onlineDeviceCount > 0 {
            return .green
        }
        return .secondary
    }

    var overviewSymbolName: String {
        if failedTaskCount > 0 {
            return "exclamationmark.triangle.fill"
        }
        if runningTaskCount > 0 {
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
