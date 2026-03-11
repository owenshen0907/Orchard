import OrchardCore
import SwiftUI

struct DeviceDetailView: View {
    let device: DeviceRecord

    @State private var toastMessage: String?

    private let metricColumns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
    ]

    private var workspacePaths: String {
        device.workspaces.map(\.rootPath).joined(separator: "\n")
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    HeroCard(
                        eyebrow: device.platform.displayName,
                        title: device.statusTitle,
                        message: "\(device.name) 当前 \(device.statusTitle.lowercased())，最近一次活跃于 \(device.lastSeenAt.formatted(date: .abbreviated, time: .shortened))。",
                        symbolName: device.platform.symbolName,
                        tint: device.statusColor
                    )

                    LazyVGrid(columns: metricColumns, spacing: 14) {
                        DetailHeroMetric(title: "Load", value: device.metrics.loadAverage.map { String(format: "%.2f", $0) } ?? "--")
                        DetailHeroMetric(title: "运行任务数", value: "\(device.metrics.runningTasks)")
                        DetailHeroMetric(title: "CPU", value: device.metrics.cpuPercentApprox.map { String(format: "%.0f%%", $0) } ?? "--")
                        DetailHeroMetric(title: "内存", value: device.metrics.memoryPercent.map { String(format: "%.0f%%", $0) } ?? "--")
                    }
                }
                .padding(.vertical, 4)
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)
            }

            Section {
                LabeledContent("设备名", value: device.name)
                LabeledContent("主机名", value: device.hostName)
                LabeledContent("平台", value: device.platform.displayName)
                LabeledContent("状态") {
                    StatusBadge(title: device.statusTitle, tint: device.statusColor)
                }
                LabeledContent("最近活跃") {
                    Text(device.lastSeenAt.formatted(date: .abbreviated, time: .shortened))
                }
            } header: {
                SectionHeaderLabel(title: "概况")
            }

            Section {
                LabeledContent("CPU", value: device.metrics.cpuPercentApprox.map { String(format: "%.0f%%", $0) } ?? "--")
                LabeledContent("内存", value: device.metrics.memoryPercent.map { String(format: "%.0f%%", $0) } ?? "--")
                LabeledContent("Load", value: device.metrics.loadAverage.map { String(format: "%.2f", $0) } ?? "--")
                LabeledContent("运行任务数", value: "\(device.metrics.runningTasks)")
                LabeledContent("最大并行", value: "\(device.maxParallelTasks)")
            } header: {
                SectionHeaderLabel(title: "负载")
            }

            Section {
                if device.capabilities.isEmpty {
                    SectionPlaceholder(
                        title: "当前没有上报能力信息。",
                        message: "Agent 完整上报后，这里会列出可用能力。",
                        symbolName: "slider.horizontal.3"
                    )
                } else {
                    ForEach(device.capabilities, id: \.rawValue) { capability in
                        Text(capability.displayName)
                    }
                }
            } header: {
                SectionHeaderLabel(title: "能力")
            }

            Section {
                if device.workspaces.isEmpty {
                    SectionPlaceholder(
                        title: "当前没有可用工作区。",
                        message: "Agent 注册工作区后，这里会展示路径。",
                        symbolName: "folder"
                    )
                } else {
                    ForEach(device.workspaces) { workspace in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(workspace.name)
                            Text(workspace.rootPath)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                SectionHeaderLabel(title: "Workspace")
            }
        }
        .companionListStyle()
        .navigationTitle(device.name)
        .companionInlineNavigationTitle()
        .companionToast(message: toastMessage)
        .toolbar {
            ToolbarItem(placement: CompanionToolbarPlacement.trailing) {
                Menu {
                    Button {
                        copyTextToPasteboard(device.deviceID)
                        showToast("已复制设备 ID")
                    } label: {
                        Label("复制设备 ID", systemImage: "number")
                    }

                    Button {
                        copyTextToPasteboard(device.hostName)
                        showToast("已复制主机名")
                    } label: {
                        Label("复制主机名", systemImage: "desktopcomputer")
                    }

                    if !workspacePaths.isEmpty {
                        Button {
                            copyTextToPasteboard(workspacePaths)
                            showToast("已复制工作区路径")
                        } label: {
                            Label("复制工作区路径", systemImage: "folder")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
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
struct DeviceDetailView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            DeviceDetailView(device: CompanionPreviewData.onlineDevice)
        }
    }
}
#endif
