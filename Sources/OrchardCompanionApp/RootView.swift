import SwiftUI

struct RootView: View {
    @StateObject private var model = AppModel()
    @AppStorage("orchard.serverURL") private var serverURL = "http://127.0.0.1:8080/"

    var body: some View {
        NavigationStack {
            List {
                Section("连接") {
                    TextField("Server URL", text: $serverURL)
                        .textInputAutocapitalization(.never)
#if os(iOS)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
#endif
                    Button("刷新快照") {
                        Task {
                            await model.refresh(serverURLString: serverURL)
                        }
                    }
                }

                Section("设备") {
                    if model.snapshot.devices.isEmpty {
                        Text("还没有设备注册。")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.snapshot.devices) { device in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(device.name)
                                    .font(.headline)
                                Text(device.hostName)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Text("load \(device.metrics.loadAverage ?? 0, specifier: "%.2f") · tasks \(device.metrics.runningTasks)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("任务") {
                    if model.snapshot.tasks.isEmpty {
                        Text("当前没有任务。")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.snapshot.tasks) { task in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(task.title)
                                    .font(.headline)
                                Text(task.command)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                Text(task.status.rawValue)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if let errorMessage = model.errorMessage {
                    Section("错误") {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Orchard")
            .task {
                await model.refresh(serverURLString: serverURL)
            }
        }
    }
}
