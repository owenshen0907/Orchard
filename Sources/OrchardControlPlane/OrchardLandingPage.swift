import Foundation
import OrchardCore
import Vapor

enum OrchardLandingPage {
    static func response(
        snapshot: DashboardSnapshot,
        showLogout: Bool = false,
        errorMessage: String? = nil
    ) -> Response {
        let logoutHTML = showLogout ? """
        <form class="logout" method="post" action="/logout">
          <button type="submit">锁定访问</button>
        </form>
        """ : ""

        let onlineDeviceCount = snapshot.devices.filter { $0.status == .online }.count
        let runningTaskCount = snapshot.tasks.filter { $0.status == .running || $0.status == .stopRequested }.count
        let failedTaskCount = snapshot.tasks.filter { $0.status == .failed }.count
        let queuedTaskCount = snapshot.tasks.filter { $0.status == .queued }.count
        let uniqueWorkspaces = uniqueWorkspaces(in: snapshot.devices)
        let focusTasks = snapshot.tasks.sorted(by: compareTasks).prefix(8)
        let onlineDevices = snapshot.devices.filter { $0.status == .online }.sorted(by: compareDevices).prefix(8)

        let errorHTML = errorMessage.map { message in
            """
            <div class="alert">\(escapeHTML(message))</div>
            """
        } ?? ""

        let metricsHTML = [
            renderMetricCard(title: "在线设备", value: "\(onlineDeviceCount)", detail: "当前可接收任务的机器", tone: "green"),
            renderMetricCard(title: "运行中任务", value: "\(runningTaskCount)", detail: "包含停止中的任务", tone: "blue"),
            renderMetricCard(title: "失败任务", value: "\(failedTaskCount)", detail: "建议优先查看摘要与日志", tone: "red"),
            renderMetricCard(title: "排队中任务", value: "\(queuedTaskCount)", detail: "等待可用设备领取", tone: "gold"),
        ].joined(separator: "\n")

        let focusTasksHTML = focusTasks.isEmpty
            ? renderEmptyState(
                title: "当前没有需要立即处理的任务。",
                message: "失败、停止中和运行中的任务会优先出现在这里。"
            )
            : focusTasks.map(renderTaskRow).joined(separator: "\n")

        let devicesHTML = onlineDevices.isEmpty
            ? renderEmptyState(
                title: "当前没有在线设备。",
                message: "设备恢复心跳后，会自动出现在这里。"
            )
            : onlineDevices.map(renderDeviceRow).joined(separator: "\n")

        let workspacesHTML = uniqueWorkspaces.isEmpty
            ? renderEmptyState(
                title: "当前没有工作区数据。",
                message: "设备完成注册并上报工作区后，这里会显示可用范围。"
            )
            : uniqueWorkspaces.map(renderWorkspaceRow).joined(separator: "\n")

        let html = """
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Orchard 控制平面</title>
  <style>
    :root {
      color-scheme: light;
      --bg: #f4efe6;
      --panel: rgba(255, 252, 247, 0.94);
      --panel-strong: rgba(255, 255, 255, 0.82);
      --ink: #1f2933;
      --muted: #5f6c7b;
      --accent: #1a7f5a;
      --accent-soft: rgba(26, 127, 90, 0.12);
      --border: rgba(31, 41, 51, 0.1);
      --shadow: 0 24px 60px rgba(31, 41, 51, 0.12);
      --blue: #1f5ea8;
      --blue-soft: rgba(31, 94, 168, 0.12);
      --red: #b44a3d;
      --red-soft: rgba(180, 74, 61, 0.12);
      --gold: #9a6a1d;
      --gold-soft: rgba(154, 106, 29, 0.12);
      --green: #1a7f5a;
      --green-soft: rgba(26, 127, 90, 0.12);
    }

    * {
      box-sizing: border-box;
    }

    body {
      margin: 0;
      min-height: 100vh;
      font-family: "Iowan Old Style", "Palatino Linotype", "Book Antiqua", Georgia, serif;
      background:
        radial-gradient(circle at top left, rgba(26, 127, 90, 0.14), transparent 32%),
        radial-gradient(circle at top right, rgba(196, 118, 55, 0.16), transparent 28%),
        linear-gradient(180deg, #f8f2e8 0%, var(--bg) 100%);
      color: var(--ink);
      padding: 32px 18px 40px;
    }

    main {
      position: relative;
      width: min(1180px, 100%);
      margin: 0 auto;
      background: var(--panel);
      border: 1px solid var(--border);
      border-radius: 28px;
      box-shadow: var(--shadow);
      padding: 32px;
      backdrop-filter: blur(10px);
    }

    .logout {
      position: absolute;
      top: 24px;
      right: 24px;
      margin: 0;
    }

    .logout button,
    .nav a,
    .link-list a {
      transition: transform 0.16s ease, background 0.16s ease, color 0.16s ease;
    }

    .logout button {
      appearance: none;
      border: 1px solid var(--border);
      border-radius: 999px;
      background: rgba(255, 255, 255, 0.82);
      color: var(--ink);
      padding: 9px 14px;
      font: 600 13px/1.2 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      cursor: pointer;
    }

    .logout button:hover,
    .nav a:hover,
    .link-list a:hover {
      transform: translateY(-1px);
    }

    .badge {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      padding: 8px 12px;
      border-radius: 999px;
      background: var(--accent-soft);
      color: var(--accent);
      font: 600 13px/1.2 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      letter-spacing: 0.04em;
      text-transform: uppercase;
    }

    h1 {
      margin: 18px 0 12px;
      font-size: clamp(34px, 6vw, 56px);
      line-height: 0.98;
      letter-spacing: -0.04em;
    }

    p {
      margin: 0;
      font-size: 18px;
      line-height: 1.6;
      color: var(--muted);
    }

    .intro {
      max-width: 760px;
    }

    .nav {
      display: flex;
      flex-wrap: wrap;
      gap: 10px;
      margin: 24px 0 0;
    }

    .nav a {
      display: inline-flex;
      align-items: center;
      padding: 10px 14px;
      border-radius: 999px;
      border: 1px solid var(--border);
      background: rgba(255, 255, 255, 0.78);
      color: var(--ink);
      text-decoration: none;
      font: 600 14px/1.2 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }

    .alert {
      margin-top: 20px;
      padding: 14px 16px;
      border-radius: 16px;
      background: var(--red-soft);
      color: var(--red);
      border: 1px solid rgba(180, 74, 61, 0.2);
      font: 600 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }

    .metrics {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
      gap: 14px;
      margin: 28px 0 32px;
    }

    .metric {
      border-radius: 20px;
      padding: 18px;
      border: 1px solid var(--border);
      background: var(--panel-strong);
    }

    .metric-title {
      margin: 0 0 10px;
      font: 600 13px/1.2 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      text-transform: uppercase;
      letter-spacing: 0.04em;
    }

    .metric-value {
      margin: 0;
      font-size: 40px;
      line-height: 1;
      letter-spacing: -0.04em;
    }

    .metric-detail {
      margin-top: 10px;
      font-size: 14px;
      line-height: 1.5;
    }

    .metric.green .metric-title,
    .metric.green .metric-value { color: var(--green); }
    .metric.blue .metric-title,
    .metric.blue .metric-value { color: var(--blue); }
    .metric.red .metric-title,
    .metric.red .metric-value { color: var(--red); }
    .metric.gold .metric-title,
    .metric.gold .metric-value { color: var(--gold); }

    .grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(320px, 1fr));
      gap: 16px;
    }

    section.panel {
      border-radius: 22px;
      border: 1px solid var(--border);
      background: rgba(255, 255, 255, 0.74);
      padding: 20px;
    }

    .section-header {
      display: flex;
      flex-wrap: wrap;
      align-items: baseline;
      justify-content: space-between;
      gap: 10px 16px;
      margin-bottom: 16px;
    }

    .section-header h2 {
      margin: 0;
      font: 600 20px/1.2 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }

    .section-header p {
      font-size: 14px;
    }

    .stack {
      display: grid;
      gap: 12px;
    }

    .row {
      border-radius: 18px;
      border: 1px solid var(--border);
      background: rgba(255, 255, 255, 0.78);
      padding: 14px 16px;
    }

    .row-head {
      display: flex;
      justify-content: space-between;
      gap: 10px 14px;
      align-items: flex-start;
      margin-bottom: 10px;
    }

    .row-title {
      margin: 0;
      font: 600 16px/1.4 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }

    .chip {
      display: inline-flex;
      align-items: center;
      border-radius: 999px;
      padding: 6px 10px;
      font: 600 12px/1.1 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      white-space: nowrap;
    }

    .chip.green { background: var(--green-soft); color: var(--green); }
    .chip.blue { background: var(--blue-soft); color: var(--blue); }
    .chip.red { background: var(--red-soft); color: var(--red); }
    .chip.gold { background: var(--gold-soft); color: var(--gold); }
    .chip.gray { background: rgba(31, 41, 51, 0.08); color: var(--ink); }

    .meta,
    .link-list {
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
    }

    .meta span,
    .link-list a,
    .workspace-badge {
      display: inline-flex;
      align-items: center;
      border-radius: 999px;
      padding: 6px 10px;
      background: rgba(31, 41, 51, 0.06);
      color: var(--muted);
      text-decoration: none;
      font: 500 12px/1.2 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }

    .summary {
      margin-top: 10px;
      font-size: 15px;
      line-height: 1.6;
    }

    .workspace-row {
      display: grid;
      gap: 6px;
    }

    .workspace-row code,
    .code-inline {
      font-family: "SFMono-Regular", Menlo, Consolas, monospace;
      font-size: 13px;
      padding: 2px 6px;
      border-radius: 8px;
      background: rgba(31, 41, 51, 0.06);
      color: var(--ink);
    }

    .empty {
      padding: 18px;
      border-radius: 18px;
      border: 1px dashed rgba(31, 41, 51, 0.18);
      background: rgba(255, 255, 255, 0.56);
    }

    .empty strong {
      display: block;
      margin-bottom: 6px;
      font: 600 15px/1.4 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      color: var(--ink);
    }

    .footnote {
      margin-top: 24px;
      font-size: 14px;
      color: var(--muted);
    }

    @media (max-width: 720px) {
      main {
        padding: 24px 18px;
      }

      .logout {
        position: static;
        margin-bottom: 16px;
      }

      .row-head {
        flex-direction: column;
      }
    }
  </style>
</head>
<body>
  <main>
    __LOGOUT__
    <div class="badge">Orchard 控制平面</div>
    <h1>浏览器控制台</h1>
    <p class="intro">
      当前页面直接展示服务概览、关键任务、在线设备与工作区摘要。
      管理接口仍然通过访问密钥保护，Agent 注册与实时会话继续使用 enrollment token。
    </p>
    <nav class="nav">
      <a href="#tasks">任务概览</a>
      <a href="#devices">设备概览</a>
      <a href="#workspaces">工作区</a>
      <a href="#links">常用入口</a>
    </nav>
    __ERROR__

    <section class="metrics">
      __METRICS__
    </section>

    <div class="grid">
      <section class="panel" id="tasks">
        <div class="section-header">
          <h2>需要关注的任务</h2>
          <p>失败、停止中和运行中的任务优先显示。</p>
        </div>
        <div class="stack">
          __TASKS__
        </div>
      </section>

      <section class="panel" id="devices">
        <div class="section-header">
          <h2>在线设备</h2>
          <p>按运行任务数、负载和最近活跃时间排序。</p>
        </div>
        <div class="stack">
          __DEVICES__
        </div>
      </section>
    </div>

    <div class="grid" style="margin-top: 16px;">
      <section class="panel" id="workspaces">
        <div class="section-header">
          <h2>工作区</h2>
          <p>汇总所有已注册设备上报的工作区。</p>
        </div>
        <div class="stack">
          __WORKSPACES__
        </div>
      </section>

      <section class="panel" id="links">
        <div class="section-header">
          <h2>常用入口</h2>
          <p>下面这些地址适合调试、导出或脚本调用。</p>
        </div>
        <div class="link-list">
          <a href="/health">健康检查 /health</a>
          <a href="/api/snapshot">控制台快照 /api/snapshot</a>
          <a href="/api/devices">设备列表 /api/devices</a>
          <a href="/api/tasks">任务列表 /api/tasks</a>
        </div>
        <p class="footnote">
          这是浏览器控制台的第一版摘要页。更细的任务详情、日志操作和任务创建表单可以继续往这里补。
        </p>
      </section>
    </div>
  </main>
</body>
</html>
"""

        let page = html
            .replacingOccurrences(of: "__LOGOUT__", with: logoutHTML)
            .replacingOccurrences(of: "__ERROR__", with: errorHTML)
            .replacingOccurrences(of: "__METRICS__", with: metricsHTML)
            .replacingOccurrences(of: "__TASKS__", with: focusTasksHTML)
            .replacingOccurrences(of: "__DEVICES__", with: devicesHTML)
            .replacingOccurrences(of: "__WORKSPACES__", with: workspacesHTML)

        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "text/html; charset=utf-8")
        return Response(status: .ok, headers: headers, body: .init(string: page))
    }

    private static func renderMetricCard(title: String, value: String, detail: String, tone: String) -> String {
        """
        <article class="metric \(tone)">
          <p class="metric-title">\(escapeHTML(title))</p>
          <p class="metric-value">\(escapeHTML(value))</p>
          <p class="metric-detail">\(escapeHTML(detail))</p>
        </article>
        """
    }

    private static func renderTaskRow(task: TaskRecord) -> String {
        let summary = task.summary?.trimmedOrNil ?? taskPreview(task)
        return """
        <article class="row">
          <div class="row-head">
            <h3 class="row-title">\(escapeHTML(task.title))</h3>
            <span class="chip \(taskStatusTone(task.status))">\(escapeHTML(taskStatusLabel(task.status)))</span>
          </div>
          <div class="meta">
            <span>\(escapeHTML(taskKindLabel(task.kind)))</span>
            <span>优先级 \(escapeHTML(taskPriorityLabel(task.priority)))</span>
            <span>工作区 \(escapeHTML(task.workspaceID))</span>
            <span>设备 \(escapeHTML(task.assignedDeviceID ?? "待分配"))</span>
            <span>更新于 \(escapeHTML(format(task.updatedAt)))</span>
          </div>
          <p class="summary">\(escapeHTML(summary))</p>
        </article>
        """
    }

    private static func renderDeviceRow(device: DeviceRecord) -> String {
        let capabilities = device.capabilities.map(capabilityLabel).joined(separator: " / ")
        let loadValue = device.metrics.loadAverage.map { String(format: "%.2f", $0) } ?? "--"
        let cpuValue = device.metrics.cpuPercentApprox.map { String(format: "%.0f%%", $0) } ?? "--"
        let memoryValue = device.metrics.memoryPercent.map { String(format: "%.0f%%", $0) } ?? "--"
        return """
        <article class="row">
          <div class="row-head">
            <h3 class="row-title">\(escapeHTML(device.name))</h3>
            <span class="chip \(device.status == .online ? "green" : "gray")">\(escapeHTML(device.status == .online ? "在线" : "离线"))</span>
          </div>
          <div class="meta">
            <span>\(escapeHTML(platformLabel(device.platform)))</span>
            <span>主机 \(escapeHTML(device.hostName))</span>
            <span>运行任务 \(device.runningTaskCount)</span>
            <span>负载 \(escapeHTML(loadValue))</span>
            <span>CPU \(escapeHTML(cpuValue))</span>
            <span>内存 \(escapeHTML(memoryValue))</span>
          </div>
          <p class="summary">能力：\(escapeHTML(capabilities.isEmpty ? "暂无上报" : capabilities))；最近活跃于 \(escapeHTML(format(device.lastSeenAt)))。</p>
        </article>
        """
    }

    private static func renderWorkspaceRow(workspace: WorkspaceDefinition) -> String {
        """
        <article class="row workspace-row">
          <div class="meta">
            <span class="workspace-badge">\(escapeHTML(workspace.id))</span>
            <span>\(escapeHTML(workspace.name))</span>
          </div>
          <div><code>\(escapeHTML(workspace.rootPath))</code></div>
        </article>
        """
    }

    private static func renderEmptyState(title: String, message: String) -> String {
        """
        <div class="empty">
          <strong>\(escapeHTML(title))</strong>
          <p>\(escapeHTML(message))</p>
        </div>
        """
    }

    private static func uniqueWorkspaces(in devices: [DeviceRecord]) -> [WorkspaceDefinition] {
        let unique = Dictionary(
            devices
                .flatMap(\.workspaces)
                .map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return unique.values.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func compareTasks(lhs: TaskRecord, rhs: TaskRecord) -> Bool {
        let lhsRank = taskAttentionRank(lhs.status)
        let rhsRank = taskAttentionRank(rhs.status)
        if lhsRank != rhsRank {
            return lhsRank < rhsRank
        }
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        return lhs.createdAt > rhs.createdAt
    }

    private static func compareDevices(lhs: DeviceRecord, rhs: DeviceRecord) -> Bool {
        if lhs.runningTaskCount != rhs.runningTaskCount {
            return lhs.runningTaskCount > rhs.runningTaskCount
        }
        if lhs.metrics.loadAverage != rhs.metrics.loadAverage {
            return (lhs.metrics.loadAverage ?? 0) > (rhs.metrics.loadAverage ?? 0)
        }
        return lhs.lastSeenAt > rhs.lastSeenAt
    }

    private static func taskAttentionRank(_ status: TaskStatus) -> Int {
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

    private static func taskStatusLabel(_ status: TaskStatus) -> String {
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

    private static func taskStatusTone(_ status: TaskStatus) -> String {
        switch status {
        case .queued:
            return "gold"
        case .running:
            return "blue"
        case .succeeded:
            return "green"
        case .failed:
            return "red"
        case .stopRequested:
            return "gold"
        case .cancelled:
            return "gray"
        }
    }

    private static func taskKindLabel(_ kind: TaskKind) -> String {
        switch kind {
        case .shell:
            return "命令"
        case .codex:
            return "Codex"
        }
    }

    private static func taskPriorityLabel(_ priority: TaskPriority) -> String {
        switch priority {
        case .high:
            return "高"
        case .normal:
            return "普通"
        case .low:
            return "低"
        }
    }

    private static func capabilityLabel(_ capability: DeviceCapability) -> String {
        switch capability {
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

    private static func platformLabel(_ platform: DevicePlatform) -> String {
        switch platform {
        case .macOS:
            return "macOS"
        case .iOS:
            return "iOS"
        case .unknown:
            return "未知"
        }
    }

    private static func taskPreview(_ task: TaskRecord) -> String {
        let rawText: String
        switch task.payload {
        case let .shell(payload):
            rawText = payload.command
        case let .codex(payload):
            rawText = payload.prompt
        }
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 120 else {
            return trimmed
        }
        return String(trimmed.prefix(120)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private static func format(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

private extension String {
    var trimmedOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
