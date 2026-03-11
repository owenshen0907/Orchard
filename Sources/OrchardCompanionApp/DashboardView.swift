import OrchardCore
import SwiftUI

struct DashboardView: View {
    @ObservedObject var model: AppModel
    let serverURL: String
    @Binding var isShowingSettings: Bool

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        List {
            Section {
                HeroCard(
                    eyebrow: "控制面",
                    title: model.snapshot.overviewTitle,
                    message: model.snapshot.overviewMessage,
                    symbolName: model.snapshot.overviewSymbolName,
                    tint: model.snapshot.overviewTint
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
                        title: "运行中任务",
                        value: "\(model.snapshot.runningTaskCount)",
                        symbolName: "bolt.horizontal.fill",
                        tint: .blue,
                        detail: "含停止中的任务"
                    )
                    MetricCard(
                        title: "失败任务",
                        value: "\(model.snapshot.failedTaskCount)",
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
            }

            Section {
                if model.snapshot.attentionTasks.isEmpty {
                    SectionPlaceholder(
                        title: "当前没有需要立即介入的任务。",
                        message: "失败、运行中或停止中的任务会优先显示在这里。",
                        symbolName: "checkmark.circle"
                    )
                } else {
                    ForEach(model.snapshot.attentionTasks.prefix(5)) { task in
                        NavigationLink {
                            TaskDetailView(model: model, serverURL: serverURL, initialTask: task)
                        } label: {
                            TaskRow(task: task)
                        }
                    }
                }
            } header: {
                SectionHeaderLabel(
                    title: "需要关注",
                    subtitle: model.snapshot.attentionTasks.isEmpty ? "系统当前比较安静" : "优先处理这些任务"
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
                            DeviceDetailView(device: device)
                        } label: {
                            DeviceRow(device: device)
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
        .toolbar {
            ToolbarItem(placement: CompanionToolbarPlacement.trailing) {
                SettingsToolbarButton(isPresented: $isShowingSettings)
            }
        }
        .refreshable {
            await model.refresh(serverURLString: serverURL)
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
