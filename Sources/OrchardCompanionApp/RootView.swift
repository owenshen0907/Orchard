import SwiftUI

private enum RootTab: String {
    case dashboard
    case command
    case runs
    case codex
    case devices
}

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = AppModel()
    @AppStorage("orchard.serverURL") private var serverURL = "http://127.0.0.1:8080/"
    @AppStorage("orchard.accessKey") private var accessKey = ""
    @AppStorage("orchard.root.selectedTab") private var selectedTabStorage = RootTab.dashboard.rawValue
    @State private var isShowingSettings = false

    private var autoRefreshTaskID: String {
        "\(serverURL)|\(accessKey)|\(scenePhase == .active ? "active" : "inactive")"
    }

    private var selectedTabBinding: Binding<RootTab> {
        Binding(
            get: { RootTab(rawValue: selectedTabStorage) ?? .dashboard },
            set: { selectedTabStorage = $0.rawValue }
        )
    }

    private var commandBadgeText: String? {
        let codexAttentionCount = model.codexSessions.filter {
            $0.isRunningLike || $0.isStandbyLike || $0.state == .failed || $0.state == .interrupted
        }.count
        let count = model.snapshot.attentionManagedRuns.count + model.attentionUnmanagedTasks.count + codexAttentionCount
        return count > 0 ? "\(count)" : nil
    }

    private var runsBadgeText: String? {
        let count = model.snapshot.failedManagedRunCount > 0
            ? model.snapshot.failedManagedRunCount
            : model.snapshot.runningManagedRunCount
        return count > 0 ? "\(count)" : nil
    }

    private var codexBadgeText: String? {
        let count = model.runningCodexSessionCount + model.standbyCodexSessionCount
        return count > 0 ? "\(count)" : nil
    }

    var body: some View {
        TabView(selection: selectedTabBinding) {
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
            .tag(RootTab.dashboard)

            NavigationStack {
                UnifiedTasksView(
                    model: model,
                    serverURL: serverURL,
                    isShowingSettings: $isShowingSettings
                )
            }
            .tabItem {
                Label("指挥", systemImage: "point.3.connected.trianglepath.dotted")
            }
            .tag(RootTab.command)
            .badge(commandBadgeText)

            NavigationStack {
                ManagedRunsView(
                    model: model,
                    serverURL: serverURL,
                    isShowingSettings: $isShowingSettings
                )
            }
            .tabItem {
                Label("运行", systemImage: "bolt.horizontal.circle")
            }
            .tag(RootTab.runs)
            .badge(runsBadgeText)

            NavigationStack {
                CodexSessionsView(
                    model: model,
                    serverURL: serverURL,
                    isShowingSettings: $isShowingSettings
                )
            }
            .tabItem {
                Label("Codex", systemImage: "sparkles.rectangle.stack")
            }
            .tag(RootTab.codex)
            .badge(codexBadgeText)

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
            .tag(RootTab.devices)
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(model: model, serverURL: $serverURL, accessKey: $accessKey)
        }
        .task(id: autoRefreshTaskID) {
            guard scenePhase == .active else {
                return
            }
            await model.refresh(serverURLString: serverURL)

            while !Task.isCancelled {
                try? await Task.sleep(for: CompanionRefreshPolicy.overviewInterval)
                guard scenePhase == .active else {
                    return
                }
                await model.refresh(serverURLString: serverURL)
            }
        }
    }
}
