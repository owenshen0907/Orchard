import OrchardCore
import SwiftUI

struct CreateTaskSheet: View {
    @ObservedObject var model: AppModel
    let serverURL: String

    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var kind: TaskKind = .shell
    @State private var workspaceID = ""
    @State private var relativePath = ""
    @State private var priority: TaskPriority = .normal
    @State private var preferredDeviceID = ""
    @State private var payloadText = ""
    @State private var localErrorMessage: String?
    @State private var isSubmitting = false

    private var availableWorkspaces: [WorkspaceDefinition] {
        model.snapshot.workspaces
    }

    private var availableDevices: [DeviceRecord] {
        model.snapshot.devices.filter { device in
            device.capabilities.contains(kind.requiredCapability)
        }
    }

    private var canSubmit: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !workspaceID.isEmpty &&
            !payloadText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HeroCard(
                        eyebrow: "快速创建",
                        title: kind == .shell ? "命令任务" : "Codex 任务",
                        message: "手机端适合提交短命令和明确目标，复杂配置建议回到桌面处理。",
                        symbolName: kind.symbolName,
                        tint: kind == .shell ? .indigo : .blue
                    )
                }

                Section("基本信息") {
                    TextField("标题", text: $title)

                    Picker("类型", selection: $kind) {
                        ForEach(TaskKind.allCases, id: \.rawValue) { value in
                            Text(value.displayName).tag(value)
                        }
                    }

                    Picker("工作区", selection: $workspaceID) {
                        Text("请选择").tag("")
                        ForEach(availableWorkspaces) { workspace in
                            Text(workspace.name).tag(workspace.id)
                        }
                    }

                    Picker("优先级", selection: $priority) {
                        ForEach(TaskPriority.allCases, id: \.rawValue) { value in
                            Text(value.displayName).tag(value)
                        }
                    }

                    Picker("指定设备", selection: $preferredDeviceID) {
                        Text("自动分配").tag("")
                        ForEach(availableDevices) { device in
                            Text(device.name).tag(device.deviceID)
                        }
                    }

                    TextField("相对路径（可选）", text: $relativePath)
                }

                Section(kind == .shell ? "命令" : "提示词") {
                    TextEditor(text: $payloadText)
                        .frame(minHeight: 140)
                }

                if let localErrorMessage {
                    Section("错误") {
                        Text(localErrorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("新建任务")
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
                if workspaceID.isEmpty, let workspace = availableWorkspaces.first {
                    workspaceID = workspace.id
                }
            }
        }
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }

        let payload: TaskPayload
        switch kind {
        case .shell:
            payload = .shell(ShellTaskPayload(command: payloadText))
        case .codex:
            payload = .codex(CodexTaskPayload(prompt: payloadText))
        }

        let request = CreateTaskRequest(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: kind,
            workspaceID: workspaceID,
            relativePath: relativePath.nilIfEmpty,
            priority: priority,
            preferredDeviceID: preferredDeviceID.nilIfEmpty,
            payload: payload
        )

        do {
            _ = try await model.createTask(serverURLString: serverURL, request: request)
            localErrorMessage = nil
            dismiss()
        } catch {
            localErrorMessage = error.localizedDescription
        }
    }
}

#if DEBUG
@MainActor
struct CreateTaskSheet_Previews: PreviewProvider {
    static var previews: some View {
        CreateTaskSheet(
            model: CompanionPreviewData.model,
            serverURL: "http://preview.local/"
        )
    }
}
#endif
