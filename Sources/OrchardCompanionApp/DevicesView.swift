import OrchardCore
import SwiftUI

private enum DeviceFilter: String, CaseIterable, Identifiable {
    case all
    case online
    case offline

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "全部"
        case .online:
            return "在线"
        case .offline:
            return "离线"
        }
    }

    func matches(_ device: DeviceRecord) -> Bool {
        switch self {
        case .all:
            return true
        case .online:
            return device.status == .online
        case .offline:
            return device.status == .offline
        }
    }
}

struct DevicesView: View {
    @ObservedObject var model: AppModel
    let serverURL: String
    @Binding var isShowingSettings: Bool

    @State private var filter: DeviceFilter = .all
    @State private var searchText = ""

    private var filteredDevices: [DeviceRecord] {
        model.snapshot.devices
            .filter { filter.matches($0) }
            .filter(matchesSearch)
            .sorted { lhs, rhs in
                sortDevices(lhs: lhs, rhs: rhs)
            }
    }

    private var summaryTitle: String {
        if filter == .all {
            return "\(model.snapshot.onlineDeviceCount)/\(model.snapshot.devices.count) 在线"
        }
        return filteredDevices.isEmpty ? "\(filter.title)设备为空" : "\(filteredDevices.count) 台\(filter.title)设备"
    }

    private var summaryMessage: String {
        switch filter {
        case .all:
            return "关注在线率、总运行数和当前负载。"
        case .online:
            return "这些设备当前可以接收任务或正在执行。"
        case .offline:
            return "离线设备不会参与调度，建议检查 Agent 状态。"
        }
    }

    private var summaryTint: Color {
        switch filter {
        case .all:
            return .indigo
        case .online:
            return .green
        case .offline:
            return .orange
        }
    }

    private var summarySymbolName: String {
        switch filter {
        case .all:
            return "desktopcomputer.and.arrow.down"
        case .online:
            return "checkmark.circle.fill"
        case .offline:
            return "wifi.slash"
        }
    }

    private var sectionSubtitle: String? {
        if filteredDevices.isEmpty {
            return nil
        }
        if searchText.trimmedOrEmpty.isEmpty {
            return "按总运行数和当前负载排序"
        }
        return "“\(searchText.trimmedOrEmpty)” 的搜索结果"
    }

    var body: some View {
        List {
            Section {
                HeroCard(
                    eyebrow: "设备中心",
                    title: summaryTitle,
                    message: summaryMessage,
                    symbolName: summarySymbolName,
                    tint: summaryTint
                )
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 10, trailing: 0))
                .listRowBackground(Color.clear)

                Picker("筛选", selection: $filter) {
                    ForEach(DeviceFilter.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)
            }

            Section {
                if filteredDevices.isEmpty {
                    SectionPlaceholder(
                        title: "\(filter.title)设备为空。",
                        message: "设备注册并上报心跳后，会出现在这里。",
                        symbolName: "desktopcomputer.trianglebadge.exclamationmark"
                    )
                } else {
                    ForEach(filteredDevices) { device in
                        NavigationLink {
                            DeviceDetailView(model: model, device: device)
                        } label: {
                            DeviceRow(
                                device: device,
                                combinedRunningCount: model.combinedRunningCount(for: device),
                                codexGapSummary: model.codexDesktopGapSummary(for: device)
                            )
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
        .navigationTitle("设备")
        .searchable(text: $searchText, prompt: "搜索设备、主机、能力")
        .toolbar {
            ToolbarItem(placement: CompanionToolbarPlacement.trailing) {
                SettingsToolbarButton(isPresented: $isShowingSettings)
            }
        }
        .refreshable {
            await model.refresh(serverURLString: serverURL)
        }
    }

    private func matchesSearch(_ device: DeviceRecord) -> Bool {
        let query = searchText.trimmedOrEmpty
        guard !query.isEmpty else {
            return true
        }

        let candidates = [
            device.name,
            device.hostName,
            device.platform.displayName,
            device.capabilities.map(\.displayName).joined(separator: " "),
            device.workspaces.map(\.name).joined(separator: " "),
        ]

        return candidates.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    private func sortDevices(lhs: DeviceRecord, rhs: DeviceRecord) -> Bool {
        if lhs.status != rhs.status {
            return lhs.status == .online
        }
        let lhsRunning = model.combinedRunningCount(for: lhs)
        let rhsRunning = model.combinedRunningCount(for: rhs)
        if lhsRunning != rhsRunning {
            return lhsRunning > rhsRunning
        }
        if lhs.metrics.loadAverage != rhs.metrics.loadAverage {
            return (lhs.metrics.loadAverage ?? 0) > (rhs.metrics.loadAverage ?? 0)
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}

struct DeviceRow: View {
    let device: DeviceRecord
    let combinedRunningCount: Int
    var codexGapSummary: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(device.statusColor.opacity(0.12))
                .frame(width: 42, height: 42)
                .overlay {
                    Image(systemName: device.platform.symbolName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(device.statusColor)
                }

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(device.name)
                            .font(.headline)
                        Text(device.hostName)
                            .font(.subheadline.monospaced())
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 12)

                    StatusBadge(title: device.statusTitle, tint: device.statusColor)
                }

                HStack(spacing: 8) {
                    MetaCapsule(
                        title: device.platform.displayName,
                        symbolName: device.platform.symbolName,
                        tint: .secondary
                    )
                    MetaCapsule(
                        title: "负载 \(String(format: "%.2f", device.metrics.loadAverage ?? 0))",
                        symbolName: "speedometer",
                        tint: device.statusColor
                    )
                    MetaCapsule(
                        title: "总运行 \(combinedRunningCount)",
                        symbolName: "bolt.horizontal",
                        tint: .secondary
                    )
                }

                if let codexSummary = device.codexDesktopSummaryText {
                    Text(codexSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let codexGapSummary, !codexGapSummary.isEmpty {
                    Text(codexGapSummary)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

#if DEBUG
@MainActor
struct DevicesView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            DevicesView(
                model: CompanionPreviewData.model,
                serverURL: "http://preview.local/",
                isShowingSettings: .constant(false)
            )
        }
    }
}
#endif
