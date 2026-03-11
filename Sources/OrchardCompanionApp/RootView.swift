import SwiftUI

struct RootView: View {
    @StateObject private var model = AppModel()
    @AppStorage("orchard.serverURL") private var serverURL = "http://127.0.0.1:8080/"
    @AppStorage("orchard.accessKey") private var accessKey = ""
    @State private var isShowingSettings = false

    var body: some View {
        TabView {
            NavigationStack {
                DashboardView(
                    model: model,
                    serverURL: serverURL,
                    isShowingSettings: $isShowingSettings
                )
            }
            .tabItem {
                Label("概览", systemImage: "square.grid.2x2")
            }

            NavigationStack {
                TasksView(
                    model: model,
                    serverURL: serverURL,
                    isShowingSettings: $isShowingSettings
                )
            }
            .tabItem {
                Label("任务", systemImage: "checklist")
            }

            NavigationStack {
                DevicesView(
                    model: model,
                    serverURL: serverURL,
                    isShowingSettings: $isShowingSettings
                )
            }
            .tabItem {
                Label("设备", systemImage: "desktopcomputer")
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(model: model, serverURL: $serverURL, accessKey: $accessKey)
        }
        .task {
            await model.refresh(serverURLString: serverURL)
        }
    }
}
