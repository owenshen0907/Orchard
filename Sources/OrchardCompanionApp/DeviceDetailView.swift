import OrchardCore
import SwiftUI

struct DeviceDetailView: View {
    @ObservedObject var model: AppModel
    let device: DeviceRecord

    @State private var toastMessage: String?

    private let metricColumns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
    ]

    private var workspacePaths: String {
        device.workspaces.map(\.rootPath).joined(separator: "\n")
    }

    private var codexDesktopMetrics: CodexDesktopMetrics? {
        device.metrics.codexDesktop
    }

    private var combinedRunningCount: Int {
        model.combinedRunningCount(for: device)
    }

    private var runningManagedRunCount: Int {
        model.runningManagedRunCount(for: device.deviceID)
    }

    private var unmanagedRunningTaskCount: Int {
        model.unmanagedRunningTaskCount(for: device.deviceID)
    }

    private var observedRunningCodexCount: Int {
        model.observedRunningCodexCount(for: device)
    }

    private var mappedRunningCodexSessionCount: Int {
        model.mappedRunningCodexSessionCount(for: device.deviceID)
    }

    private var codexLiveGapCount: Int {
        model.codexDesktopLiveGapCount(for: device)
    }

    private var codexGapSummary: String? {
        model.codexDesktopGapSummary(for: device)
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    HeroCard(
                        eyebrow: device.platform.displayName,
                        title: device.statusTitle,
                        message: "\(device.name) 当前处于\(device.statusTitle)状态，最近一次活跃于 \(device.lastSeenAt.formatted(date: .abbreviated, time: .shortened))。",
                        symbolName: device.platform.symbolName,
                        tint: device.statusColor
                    )

                    LazyVGrid(columns: metricColumns, spacing: 14) {
                        DetailHeroMetric(title: "总运行数", value: "\(combinedRunningCount)")
                        DetailHeroMetric(title: "独立任务", value: "\(unmanagedRunningTaskCount)")
                        DetailHeroMetric(title: "Codex 推理", value: "\(observedRunningCodexCount)")
                        DetailHeroMetric(title: "负载", value: device.metrics.loadAverage.map { String(format: "%.2f", $0) } ?? "--")
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
                LabeledContent("负载", value: device.metrics.loadAverage.map { String(format: "%.2f", $0) } ?? "--")
                LabeledContent("总运行数", value: "\(combinedRunningCount)")
                LabeledContent("独立任务数", value: "\(unmanagedRunningTaskCount)")
                LabeledContent("托管运行数", value: "\(runningManagedRunCount)")
                LabeledContent("Agent 活动 task 数", value: "\(device.metrics.runningTasks)")
                LabeledContent("Codex 推理数", value: "\(observedRunningCodexCount)")
                LabeledContent("最大并行", value: "\(device.maxParallelTasks)")
                Text("Agent 活动 task 数包含托管 run 落地后的底层 task；“独立任务数”只统计未归属托管 run 的直接任务。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                SectionHeaderLabel(title: "负载")
            }

            if device.capabilities.contains(.codex) {
                Section {
                    LabeledContent("观测推理中", value: "\(observedRunningCodexCount)")
                    LabeledContent("活跃线程", value: codexDesktopMetrics?.activeThreadCount.map(String.init) ?? "--")
                    LabeledContent("推理中线程", value: codexDesktopMetrics?.inflightThreadCount.map(String.init) ?? "--")
                    LabeledContent("进行中轮次", value: codexDesktopMetrics?.inflightTurnCount.map(String.init) ?? "--")
                    LabeledContent("已加载线程", value: codexDesktopMetrics?.loadedThreadCount.map(String.init) ?? "--")
                    LabeledContent("线程总数", value: codexDesktopMetrics?.totalThreadCount.map(String.init) ?? "--")
                    LabeledContent("最近快照", value: device.codexDesktopSnapshotText ?? "--")

                    if let summary = device.codexDesktopSummaryText {
                        Text(summary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }

                    if codexDesktopMetrics?.activeThreadCount != nil {
                        LabeledContent("已映射 running 会话", value: "\(mappedRunningCodexSessionCount)")
                        LabeledContent("未映射活跃线程", value: "\(codexLiveGapCount)")
                    }

                    if let codexGapSummary, !codexGapSummary.isEmpty {
                        Text(codexGapSummary)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .padding(.top, 2)
                    } else if codexDesktopMetrics?.activeThreadCount != nil {
                        Text("当前桌面活跃线程都已被会话桥覆盖。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                } header: {
                    SectionHeaderLabel(title: "Codex 实时状态")
                }
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
                SectionHeaderLabel(title: "工作区")
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
            DeviceDetailView(model: CompanionPreviewData.model, device: CompanionPreviewData.onlineDevice)
        }
    }
}
#endif
