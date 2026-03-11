import OrchardCore
import SwiftUI

private enum TaskFilter: String, CaseIterable, Identifiable {
    case running
    case queued
    case finished
    case failed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .running:
            return "运行中"
        case .queued:
            return "排队中"
        case .finished:
            return "已完成"
        case .failed:
            return "失败"
        }
    }

    func matches(_ task: TaskRecord) -> Bool {
        switch self {
        case .running:
            return task.status == .running || task.status == .stopRequested
        case .queued:
            return task.status == .queued
        case .finished:
            return task.status == .succeeded || task.status == .cancelled
        case .failed:
            return task.status == .failed
        }
    }
}

struct TasksView: View {
    @ObservedObject var model: AppModel
    let serverURL: String
    @Binding var isShowingSettings: Bool

    @State private var filter: TaskFilter = .running
    @State private var isShowingCreateSheet = false
    @State private var searchText = ""

    private var filteredTasks: [TaskRecord] {
        model.snapshot.tasks
            .filter { filter.matches($0) }
            .filter(matchesSearch)
            .sorted(by: sortTasks)
    }

    private var summaryTitle: String {
        filteredTasks.isEmpty ? "\(filter.title)为空" : "\(filteredTasks.count) 个\(filter.title)"
    }

    private var summaryMessage: String {
        switch filter {
        case .running:
            return "优先关注运行中和停止中的任务。"
        case .queued:
            return "这些任务还在等待可用设备领取。"
        case .finished:
            return "已完成和已取消的任务会归档在这里。"
        case .failed:
            return "失败任务建议优先查看日志和摘要。"
        }
    }

    private var summaryTint: Color {
        switch filter {
        case .running:
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
        case .running:
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
        if filteredTasks.isEmpty {
            return nil
        }
        if searchText.trimmedOrEmpty.isEmpty {
            return "按最近更新时间排序"
        }
        return "“\(searchText.trimmedOrEmpty)” 的搜索结果"
    }

    var body: some View {
        List {
            Section {
                HeroCard(
                    eyebrow: "任务中心",
                    title: summaryTitle,
                    message: summaryMessage,
                    symbolName: summarySymbolName,
                    tint: summaryTint
                )
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 10, trailing: 0))
                .listRowBackground(Color.clear)

                Picker("筛选", selection: $filter) {
                    ForEach(TaskFilter.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)
            }

            Section {
                if filteredTasks.isEmpty {
                    SectionPlaceholder(
                        title: "\(filter.title)暂无任务。",
                        message: "切换顶部筛选可查看其他状态的任务。",
                        symbolName: "list.bullet.rectangle"
                    )
                } else {
                    ForEach(filteredTasks) { task in
                        NavigationLink {
                            TaskDetailView(model: model, serverURL: serverURL, initialTask: task)
                        } label: {
                            TaskRow(task: task)
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
        .navigationTitle("任务")
        .searchable(text: $searchText, prompt: "搜索标题、命令、设备")
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
            CreateTaskSheet(model: model, serverURL: serverURL)
        }
        .refreshable {
            await model.refresh(serverURLString: serverURL)
        }
    }

    private func matchesSearch(_ task: TaskRecord) -> Bool {
        let query = searchText.trimmedOrEmpty
        guard !query.isEmpty else {
            return true
        }

        let candidates = [
            task.title,
            task.payloadPreview,
            task.assignedDeviceID ?? "",
            task.workspaceID,
            task.summary ?? "",
        ]

        return candidates.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    private func sortTasks(lhs: TaskRecord, rhs: TaskRecord) -> Bool {
        switch filter {
        case .running:
            if lhs.attentionRank != rhs.attentionRank {
                return lhs.attentionRank < rhs.attentionRank
            }
            if lhs.priority != rhs.priority {
                return priorityRank(lhs.priority) > priorityRank(rhs.priority)
            }
            return lhs.updatedAt > rhs.updatedAt
        case .queued:
            if lhs.priority != rhs.priority {
                return priorityRank(lhs.priority) > priorityRank(rhs.priority)
            }
            return lhs.createdAt > rhs.createdAt
        case .finished, .failed:
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private func priorityRank(_ priority: TaskPriority) -> Int {
        switch priority {
        case .high:
            return 2
        case .normal:
            return 1
        case .low:
            return 0
        }
    }
}

struct TaskRow: View {
    let task: TaskRecord

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(task.stateColor.opacity(0.12))
                .frame(width: 42, height: 42)
                .overlay {
                    Image(systemName: task.kind.symbolName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(task.stateColor)
                }

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(task.title)
                            .font(.headline)
                            .foregroundStyle(.primary)

                        Text(task.payloadPreview)
                            .font(.subheadline.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 12)

                    StatusBadge(title: task.statusTitle, tint: task.stateColor)
                }

                HStack(spacing: 8) {
                    MetaCapsule(
                        title: task.kind.displayName,
                        symbolName: task.kind.symbolName,
                        tint: task.stateColor
                    )
                    MetaCapsule(
                        title: task.assignedDeviceID ?? "待分配",
                        symbolName: "desktopcomputer",
                        tint: .secondary
                    )

                    Spacer(minLength: 8)

                    Text(task.updatedAt, style: .relative)
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
struct TasksView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            TasksView(
                model: CompanionPreviewData.model,
                serverURL: "http://preview.local/",
                isShowingSettings: .constant(false)
            )
        }
    }
}
#endif
