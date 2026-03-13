import Foundation
import OrchardCore
import Vapor

enum OrchardLandingPage {
    private struct BootstrapPayload: Encodable {
        let snapshot: DashboardSnapshot
        let codexSessions: [CodexSessionSummary]
        let errorMessage: String?
    }

    static func response(
        snapshot: DashboardSnapshot,
        codexSessions: [CodexSessionSummary] = [],
        showLogout: Bool = false,
        errorMessage: String? = nil
    ) -> Response {
        let logoutHTML = showLogout ? """
        <form class=\"logout\" method=\"post\" action=\"/logout\">
          <button type=\"submit\">锁定访问</button>
        </form>
        """ : ""

        let bootstrapJSON = encodeBootstrap(BootstrapPayload(
            snapshot: snapshot,
            codexSessions: codexSessions,
            errorMessage: errorMessage
        ))

        let html = #"""
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
      --panel-soft: rgba(255, 255, 255, 0.78);
      --panel-strong: rgba(255, 255, 255, 0.88);
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
      --gray-soft: rgba(31, 41, 51, 0.08);
    }

    * { box-sizing: border-box; }

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
      width: min(1320px, 100%);
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

    .intro { max-width: 860px; }

    .nav,
    .status-strip,
    .meta,
    .row-actions,
    .detail-actions,
    .detail-meta,
    .link-list,
    .dialog-actions {
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
    }

    .nav { margin-top: 24px; }
    .status-strip { margin-top: 16px; align-items: center; }

    .nav a,
    .nav button,
    .logout button,
    .action-button,
    .detail-action,
    .dialog-actions button {
      appearance: none;
      border: 1px solid var(--border);
      border-radius: 999px;
      background: rgba(255, 255, 255, 0.82);
      color: var(--ink);
      text-decoration: none;
      padding: 10px 14px;
      font: 600 14px/1.2 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      cursor: pointer;
      transition: transform 0.16s ease, background 0.16s ease, color 0.16s ease, border-color 0.16s ease;
    }

    .action-button,
    .detail-action,
    .dialog-actions button {
      padding: 8px 12px;
      font-size: 13px;
    }

    .nav a:hover,
    .nav button:hover,
    .logout button:hover,
    .action-button:hover,
    .detail-action:hover,
    .dialog-actions button:hover {
      transform: translateY(-1px);
    }

    .nav button.primary,
    .action-button.primary,
    .detail-action.primary,
    .dialog-actions button.primary {
      background: var(--blue);
      color: #fff;
      border-color: rgba(31, 94, 168, 0.28);
    }

    .action-button.warn,
    .detail-action.warn {
      background: rgba(154, 106, 29, 0.1);
      color: var(--gold);
      border-color: rgba(154, 106, 29, 0.22);
    }

    .action-button.danger,
    .detail-action.danger {
      background: rgba(180, 74, 61, 0.1);
      color: var(--red);
      border-color: rgba(180, 74, 61, 0.22);
    }

    button:disabled {
      opacity: 0.5;
      transform: none;
      cursor: default;
    }

    .status-pill,
    .meta span,
    .detail-meta span,
    .link-list a,
    .workspace-badge {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      padding: 6px 10px;
      border-radius: 999px;
      background: rgba(31, 41, 51, 0.06);
      color: var(--muted);
      text-decoration: none;
      font: 500 12px/1.2 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }

    .alert {
      margin-top: 18px;
      padding: 14px 16px;
      border-radius: 16px;
      background: var(--red-soft);
      color: var(--red);
      border: 1px solid rgba(180, 74, 61, 0.2);
      font: 600 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }

    .metrics,
    .grid,
    .stack,
    .detail-shell,
    .detail-block,
    .detail-list,
    .workspace-row,
    .dialog-shell,
    .row-title-group,
    .form-grid {
      display: grid;
      gap: 12px;
    }

    .metrics {
      grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
      margin: 28px 0 32px;
      gap: 14px;
    }

    .metric,
    .row,
    section.panel,
    aside.panel,
    .detail-card,
    .detail-list-item,
    .empty {
      border: 1px solid var(--border);
      background: var(--panel-soft);
    }

    .metric {
      border-radius: 20px;
      padding: 18px;
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

    .grid { gap: 16px; }
    .control-grid { grid-template-columns: minmax(0, 1.6fr) minmax(320px, 1fr); align-items: start; }
    .toolbar-grid { margin-bottom: 16px; grid-template-columns: minmax(0, 1.35fr) minmax(320px, 0.95fr); }
    .section-grid { margin-top: 16px; grid-template-columns: repeat(auto-fit, minmax(320px, 1fr)); }

    section.panel,
    aside.panel {
      border-radius: 22px;
      padding: 20px;
      background: rgba(255, 255, 255, 0.74);
    }

    .detail-panel {
      position: sticky;
      top: 18px;
      min-height: 320px;
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

    .section-header p { font-size: 14px; }

    .row {
      border-radius: 18px;
      padding: 14px 16px;
      background: rgba(255, 255, 255, 0.78);
    }

    .form-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }

    .field {
      display: grid;
      gap: 8px;
    }

    .field.span-2 { grid-column: span 2; }

    .field span,
    .toggle-row label {
      color: var(--ink);
      font: 600 13px/1.3 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }

    .field small {
      color: var(--muted);
      font: 500 12px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }

    .field input,
    .field select,
    .field textarea {
      width: 100%;
      border: 1px solid var(--border);
      border-radius: 14px;
      background: rgba(255, 255, 255, 0.86);
      color: var(--ink);
      padding: 12px 14px;
      font: 500 14px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }

    .field textarea {
      min-height: 180px;
      resize: vertical;
    }

    .field input::placeholder,
    .field textarea::placeholder {
      color: rgba(95, 108, 123, 0.9);
    }

    .field select:disabled,
    .field input:disabled,
    .field textarea:disabled {
      opacity: 0.7;
      cursor: default;
    }

    .toggle-row,
    .panel-actions {
      display: flex;
      flex-wrap: wrap;
      gap: 10px 12px;
      align-items: center;
      justify-content: space-between;
    }

    .toggle-row {
      padding: 12px 14px;
      border-radius: 16px;
      border: 1px solid var(--border);
      background: rgba(255, 255, 255, 0.66);
    }

    .toggle-row label {
      display: inline-flex;
      align-items: center;
      gap: 10px;
    }

    .toggle-row input[type="checkbox"] {
      width: 16px;
      height: 16px;
      accent-color: var(--blue);
    }

    .panel-note {
      font-size: 13px;
      line-height: 1.6;
      color: var(--muted);
    }

    .row.selected {
      border-color: rgba(31, 94, 168, 0.26);
      box-shadow: inset 0 0 0 1px rgba(31, 94, 168, 0.08);
      background: rgba(247, 251, 255, 0.88);
    }

    .row-head,
    .detail-list-item-head {
      display: flex;
      justify-content: space-between;
      align-items: flex-start;
      gap: 10px 14px;
    }

    .row-kicker {
      color: var(--muted);
      font: 600 12px/1.2 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      letter-spacing: 0.04em;
      text-transform: uppercase;
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
    .chip.gray { background: var(--gray-soft); color: var(--ink); }

    .summary {
      margin-top: 10px;
      font-size: 15px;
      line-height: 1.6;
    }
    .empty {
      padding: 18px;
      border-radius: 18px;
      border-style: dashed;
      background: rgba(255, 255, 255, 0.56);
    }

    .empty strong {
      display: block;
      margin-bottom: 6px;
      font: 600 15px/1.4 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      color: var(--ink);
    }

    .detail-header h3 {
      margin: 0;
      font: 600 22px/1.25 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }

    .detail-subtitle,
    .detail-list-item-body,
    .footnote,
    .dialog-hint {
      color: var(--muted);
      font-size: 14px;
      line-height: 1.55;
    }

    .detail-card,
    .detail-list-item {
      border-radius: 16px;
      padding: 14px;
      background: var(--panel-strong);
      gap: 10px;
    }

    .detail-card h4,
    .detail-block h4 {
      margin: 0;
      font: 600 15px/1.3 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      color: var(--ink);
    }

    .detail-card pre,
    .detail-card code,
    textarea.prompt-box {
      margin: 0;
      font: 500 12px/1.55 "SFMono-Regular", Menlo, Consolas, monospace;
      white-space: pre-wrap;
      word-break: break-word;
      color: var(--ink);
    }

    .detail-list-item-title {
      font: 600 14px/1.35 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      color: var(--ink);
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

    .prompt-project-context,
    .project-command-list,
    .project-command-title-group,
    .project-context-lines {
      display: grid;
      gap: 10px;
    }

    .prompt-project-context {
      margin-top: 4px;
    }

    .project-command-card {
      display: grid;
      gap: 10px;
      padding: 14px;
      border-radius: 16px;
      border: 1px solid var(--border);
      background: rgba(255, 255, 255, 0.82);
    }

    .project-command-card.warn {
      border-color: rgba(154, 106, 29, 0.22);
      background: rgba(154, 106, 29, 0.08);
    }

    .project-command-head {
      display: flex;
      flex-wrap: wrap;
      align-items: flex-start;
      justify-content: space-between;
      gap: 10px 12px;
    }

    .project-command-title {
      margin: 0;
      font: 600 15px/1.35 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      color: var(--ink);
    }

    .project-command-id {
      color: var(--muted);
      font: 500 12px/1.3 "SFMono-Regular", Menlo, Consolas, monospace;
    }

    .project-command-card pre {
      margin: 0;
      padding: 10px 12px;
      border-radius: 12px;
      background: rgba(31, 41, 51, 0.05);
      color: var(--ink);
      font: 500 12px/1.55 "SFMono-Regular", Menlo, Consolas, monospace;
      white-space: pre-wrap;
      word-break: break-word;
    }

    .project-command-meta,
    .project-context-meta {
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
    }

    .project-context-lines code {
      display: block;
      font-family: "SFMono-Regular", Menlo, Consolas, monospace;
      font-size: 12px;
      line-height: 1.55;
      padding: 10px 12px;
      border-radius: 12px;
      background: rgba(31, 41, 51, 0.05);
      color: var(--ink);
      white-space: pre-wrap;
      word-break: break-word;
    }

    .section-label {
      margin: 0;
      color: var(--ink);
      font: 600 13px/1.3 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      letter-spacing: 0.02em;
    }

    .guide-grid {
      grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
      gap: 14px;
    }

    .guide-card {
      display: grid;
      gap: 12px;
      padding: 16px;
      border-radius: 18px;
      border: 1px solid var(--border);
      background: rgba(255, 255, 255, 0.82);
    }

    .guide-card h3 {
      margin: 0;
      font: 600 16px/1.35 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      color: var(--ink);
    }

    .guide-card p {
      font-size: 14px;
      line-height: 1.6;
    }

    .guide-note {
      color: var(--muted);
      font: 500 12px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }

    dialog {
      width: min(680px, calc(100vw - 24px));
      border: 1px solid var(--border);
      border-radius: 24px;
      background: rgba(255, 252, 247, 0.98);
      box-shadow: 0 28px 60px rgba(31, 41, 51, 0.18);
      padding: 0;
    }

    dialog::backdrop {
      background: rgba(31, 41, 51, 0.26);
      backdrop-filter: blur(2px);
    }

    .dialog-shell { padding: 20px; }
    .dialog-shell h3 {
      margin: 0;
      font: 600 22px/1.25 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }

    textarea.prompt-box {
      width: 100%;
      min-height: 180px;
      resize: vertical;
      border-radius: 18px;
      border: 1px solid var(--border);
      background: rgba(255, 255, 255, 0.82);
      padding: 14px;
      font-size: 15px;
      line-height: 1.6;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }

    .dialog-actions { justify-content: flex-end; }

    .toast {
      position: fixed;
      right: 20px;
      bottom: 20px;
      z-index: 1000;
      display: none;
      max-width: min(360px, calc(100vw - 32px));
      border-radius: 16px;
      padding: 14px 16px;
      box-shadow: 0 20px 40px rgba(31, 41, 51, 0.18);
      font: 600 14px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      color: #fff;
      background: rgba(31, 41, 51, 0.9);
    }

    .toast.error { background: rgba(180, 74, 61, 0.96); }

    @media (max-width: 980px) {
      .control-grid { grid-template-columns: 1fr; }
      .toolbar-grid { grid-template-columns: 1fr; }
      .detail-panel { position: static; }
    }

    @media (max-width: 720px) {
      body { padding: 18px 12px 28px; }
      main { padding: 24px 18px; }
      .logout { position: static; margin-bottom: 16px; }
      .form-grid { grid-template-columns: 1fr; }
      .field.span-2 { grid-column: auto; }
      .row-head,
      .detail-list-item-head { flex-direction: column; align-items: flex-start; }
      .toggle-row,
      .panel-actions { align-items: stretch; }
      .dialog-actions { flex-direction: column-reverse; }
      .dialog-actions button { width: 100%; }
    }
  </style>
</head>
<body>
  <main>
    \#(logoutHTML)
    <div class="badge">Orchard 控制平面</div>
    <h1>远程任务控制台</h1>
    <p class="intro">
      你可以把这页先当成一个“远程遥控台”：发起任务、看进度、补一句继续、终止任务，都在这里完成。
      如果你只是想验证主链路，优先看“发起新任务”“现在最需要处理”和右侧“详情与操作”这三块就够了。
      页面里偶尔会出现 run / session 这些术语：你可以先简单理解为“通过 Orchard 发起的任务”和“宿主机上现有的 Codex 对话”。
      如果你想核对宿主机真相，现在也可以从这页直接跳到对应电脑的“宿主机控制台”。
    </p>

    <nav class="nav">
      <a href="#launch">发起任务</a>
      <a href="#quickstart">怎么走一遍</a>
      <a href="#guide">我现在想做什么</a>
      <a href="#filters">筛选</a>
      <a href="#control">当前最需要处理</a>
      <a href="#runs">Orchard 任务</a>
      <a href="#tasks">兼容任务</a>
      <a href="#codex">Codex 对话</a>
      <a href="#devices">在线电脑</a>
      <a href="#workspaces">项目目录</a>
      <a href="#links">调试接口</a>
      <button type="button" id="refresh-button" class="primary">立即刷新</button>
    </nav>

    <div class="status-strip">
      <span class="status-pill" id="refresh-meta">等待首次渲染</span>
      <span class="status-pill" id="codex-meta">Codex 对话待同步</span>
      <span class="status-pill">自动刷新 15 秒</span>
    </div>

    <div id="error-root"></div>

    <div class="grid section-grid">
      <section class="panel" id="quickstart">
        <div class="section-header">
          <h2>第一次用？先这样走一遍</h2>
          <p>如果你只是想验证“发起任务 / 观察 / 追问 / 终止”，按下面 4 步走最省脑力。</p>
        </div>
        <div class="grid section-grid">
          <article class="row">
            <div class="row-title-group">
              <span class="row-kicker">第 1 步</span>
              <h3 class="row-title">发起一个任务</h3>
            </div>
            <p class="summary">去“发起新任务”，选项目和目录，写一句你想让 Codex 做什么，然后点“发起任务”。</p>
          </article>
          <article class="row">
            <div class="row-title-group">
              <span class="row-kicker">第 2 步</span>
              <h3 class="row-title">看它有没有跑起来</h3>
            </div>
            <p class="summary">新任务会先出现在“现在最需要处理”，也会同步出现在“通过 Orchard 发起的任务”列表里。</p>
          </article>
          <article class="row">
            <div class="row-title-group">
              <span class="row-kicker">第 3 步</span>
              <h3 class="row-title">继续追问或终止</h3>
            </div>
            <p class="summary">点开任务后，在右侧“详情与操作”里直接点“继续追问”“中断”或“停止”。</p>
          </article>
          <article class="row">
            <div class="row-title-group">
              <span class="row-kicker">第 4 步</span>
              <h3 class="row-title">观察结果</h3>
            </div>
            <p class="summary">右侧会展示最近输入、状态变化和输出日志；如果要核对宿主机真相，就去“在线电脑”或详情卡片里打开“宿主机控制台”。</p>
          </article>
        </div>
        <p class="footnote">名词先这样理解就行：Orchard 任务 = 你从这个页面发起的主链路；Codex 对话 = 宿主机上已经存在、可继续接上的桌面对话；兼容任务 = 旧接口任务。</p>
      </section>

      <section class="panel" id="guide">
        <div class="section-header">
          <h2>我现在想做什么</h2>
          <p>不记字段和术语也没关系，直接按你的目的点；发起、观察、追问、终止、看宿主机真相都能从这里进。</p>
        </div>
        <div class="guide-grid" id="guide-root"></div>
      </section>
    </div>

    <section class="metrics" id="metrics-root">
      <div class="empty"><strong>正在加载统计...</strong><p>浏览器正在整理当前在线电脑、任务和 Codex 对话。</p></div>
    </section>

    <div class="grid toolbar-grid">
      <section class="panel" id="launch">
        <div class="section-header">
          <h2>发起新任务</h2>
          <p>这是最推荐的主链路：从网页端直接发给 Orchard，由在线电脑上的 Codex 接手执行。</p>
        </div>
        <div class="detail-card">
          <h4>别被这些字段吓到</h4>
          <p class="footnote">真正必填只有 2 项：在哪个项目里做、你想让 Codex 做什么。其余字段只是为了帮你更快锁定电脑、目录和后续追踪。</p>
          <div class="detail-meta">
            <span>任务名称 = 方便你自己认</span>
            <span>执行电脑 = 不选就自动分配</span>
            <span>具体目录 = 留空就是项目根目录</span>
          </div>
        </div>
        <form id="create-run-form" class="stack">
          <div class="form-grid">
            <label class="field">
              <span>任务名称（可不填）</span>
              <input id="create-title-input" type="text" placeholder="不填就自动取你输入内容的前一句">
            </label>
            <label class="field">
              <span>在哪个项目里做</span>
              <select id="create-workspace-select"></select>
            </label>
            <label class="field">
              <span>让哪台电脑执行（可不填）</span>
              <select id="create-device-select"></select>
            </label>
            <label class="field">
              <span>先选一个常用目录</span>
              <select id="create-relative-path-select"></select>
            </label>
            <label class="field">
              <span>具体目录（可不填）</span>
              <input id="create-relative-path-input" type="text" placeholder="例如：Sources/OrchardControlPlane；留空表示项目根目录">
              <small>一般先选上面的常用目录；如果没有合适项，再改成你想要的目录。</small>
            </label>
            <label class="field span-2">
              <span>你想让 Codex 做什么</span>
              <textarea id="create-prompt-input" placeholder="例如：继续把控制平面的发起 / 终止 / 追问链路补齐，并把页面文案改得更容易看懂。"></textarea>
            </label>
          </div>
          <div class="panel-actions">
            <p class="panel-note" id="create-hint">这会创建一条通过 Orchard 管理的 Codex 任务；后续你可以继续追问、停止或重试。</p>
            <button type="submit" class="action-button primary" id="create-submit">发起任务</button>
          </div>
        </form>
      </section>

      <section class="panel" id="filters">
        <div class="section-header">
          <h2>筛选</h2>
          <p>快速只看某台电脑、某个项目，或者只看正在执行 / 等你处理的项。</p>
        </div>
        <div class="stack">
          <div class="form-grid">
            <label class="field span-2">
              <span>搜索</span>
              <input id="filter-query-input" type="search" placeholder="按任务名、摘要、电脑名、目录或项目搜索">
            </label>
            <label class="field span-2">
              <span>电脑</span>
              <select id="filter-device-select"></select>
            </label>
          </div>
          <div class="toggle-row">
            <label><input id="filter-running-only" type="checkbox">只看活跃项（正在执行 / 等你补一句 / 可继续）</label>
            <button type="button" class="action-button" id="filter-reset">清空筛选</button>
          </div>
          <p class="footnote" id="filter-summary">当前展示全部任务和对话。</p>
        </div>
      </section>
    </div>

    <div class="grid control-grid">
      <section class="panel" id="control">
        <div class="section-header">
          <h2>现在最需要处理</h2>
          <p>把最值得你先看的任务和对话排在最前面，方便你直接继续、停止或排查。</p>
        </div>
        <div class="stack" id="control-root"></div>
      </section>

      <aside class="panel detail-panel" id="detail">
        <div class="section-header">
          <h2>详情与操作</h2>
          <p>这里能看最近输入、状态变化和日志，也能直接继续追问、中断或停止。</p>
        </div>
        <div id="detail-root"></div>
      </aside>
    </div>

    <div class="grid section-grid">
      <section class="panel" id="runs">
        <div class="section-header">
          <h2>通过 Orchard 发起的任务</h2>
          <p>这是最推荐的主链路；如果你要测试发起、观察、追问和终止，优先看这里。</p>
        </div>
        <div class="stack" id="runs-root"></div>
      </section>

      <section class="panel" id="tasks">
        <div class="section-header">
          <h2>兼容任务（旧接口）</h2>
          <p>这是直接走 `/api/tasks` 的旧链路；除非你在测兼容行为，否则可以先忽略这一栏。</p>
        </div>
        <div class="stack" id="tasks-root"></div>
      </section>

      <section class="panel" id="codex">
        <div class="section-header">
          <h2>本机 Codex 对话</h2>
          <p>这里展示宿主机桌面端实际存在的 Codex 对话，适合观察或继续接着问；主统计仍以上面的 Orchard 任务为准。</p>
        </div>
        <div class="stack">
          <div id="codex-diagnostics"></div>
          <div class="stack" id="codex-root"></div>
        </div>
      </section>
    </div>

    <div class="grid section-grid">
      <section class="panel" id="devices">
        <div class="section-header">
          <h2>在线电脑</h2>
          <p>看现在有哪些电脑在线、负载如何、最近有没有心跳；如果这台机器公开了宿主机控制台，也会直接给你入口。</p>
        </div>
        <div class="stack" id="devices-root"></div>
      </section>

      <section class="panel" id="workspaces">
        <div class="section-header">
          <h2>可执行的项目目录</h2>
          <p>这里列出当前在线电脑已经上报、可以接任务的项目目录。</p>
        </div>
        <div class="stack" id="workspaces-root"></div>
      </section>

      <section class="panel" id="links">
        <div class="section-header">
          <h2>调试接口</h2>
          <p>适合脚本调用、排查问题，或者和移动端 / 自动化接线。</p>
        </div>
        <div class="link-list">
          <a href="/health">健康检查 /health</a>
          <a href="/api/snapshot">控制台快照 /api/snapshot</a>
          <a href="/api/devices">设备列表 /api/devices</a>
          <a href="/api/runs">Orchard 任务 /api/runs</a>
          <a href="/api/codex/sessions">Codex 对话 /api/codex/sessions</a>
        </div>
        <p class="footnote">
          如果你只想测主链路，优先用 `/api/runs`；`/api/codex/sessions` 更适合观察宿主机桌面上已经存在的 Codex 对话。
        </p>
      </section>
    </div>
  </main>

  <dialog id="prompt-dialog">
    <form method="dialog" class="dialog-shell" id="prompt-form">
      <h3 id="prompt-title">继续追问</h3>
      <p class="dialog-hint" id="prompt-hint">把下一句发给当前任务或对话。</p>
      <textarea id="prompt-input" class="prompt-box" placeholder="例如：继续把移动端的远程控制链路补齐，并把关键接口说明写清楚。"></textarea>
      <div id="prompt-project-context" class="prompt-project-context"></div>
      <div class="dialog-actions">
        <button type="button" id="prompt-cancel">取消</button>
        <button type="submit" class="primary" id="prompt-submit">发送</button>
      </div>
    </form>
  </dialog>

  <div id="toast" class="toast"></div>
  <script id="orchard-bootstrap" type="application/json">\#(bootstrapJSON)</script>
  <script>
    (() => {
      const bootstrap = JSON.parse(document.getElementById('orchard-bootstrap').textContent || '{}');
      const state = {
        snapshot: bootstrap.snapshot || { devices: [], tasks: [], managedRuns: [] },
        codexSessions: normalizeCodexSessions(bootstrap.codexSessions || []),
        errorMessage: bootstrap.errorMessage || null,
        filters: readFiltersFromQuery(),
        selected: readSelectionFromHash(),
        detailType: null,
        detail: null,
        detailError: null,
        detailLoading: false,
        actionPending: false,
        promptAction: null,
        projectContext: {
          summaries: {},
          commands: {}
        },
        lastUpdatedAt: new Date()
      };

      const refreshButton = document.getElementById('refresh-button');
      const metricsRoot = document.getElementById('metrics-root');
      const controlRoot = document.getElementById('control-root');
      const guideRoot = document.getElementById('guide-root');
      const runsRoot = document.getElementById('runs-root');
      const tasksRoot = document.getElementById('tasks-root');
      const codexRoot = document.getElementById('codex-root');
      const codexDiagnosticsRoot = document.getElementById('codex-diagnostics');
      const devicesRoot = document.getElementById('devices-root');
      const workspacesRoot = document.getElementById('workspaces-root');
      const detailRoot = document.getElementById('detail-root');
      const errorRoot = document.getElementById('error-root');
      const refreshMeta = document.getElementById('refresh-meta');
      const codexMeta = document.getElementById('codex-meta');
      const createRunForm = document.getElementById('create-run-form');
      const createTitleInput = document.getElementById('create-title-input');
      const createWorkspaceSelect = document.getElementById('create-workspace-select');
      const createDeviceSelect = document.getElementById('create-device-select');
      const createRelativePathSelect = document.getElementById('create-relative-path-select');
      const createRelativePathInput = document.getElementById('create-relative-path-input');
      const createPromptInput = document.getElementById('create-prompt-input');
      const createHint = document.getElementById('create-hint');
      const createSubmit = document.getElementById('create-submit');
      const filterQueryInput = document.getElementById('filter-query-input');
      const filterDeviceSelect = document.getElementById('filter-device-select');
      const filterRunningOnly = document.getElementById('filter-running-only');
      const filterReset = document.getElementById('filter-reset');
      const filterSummary = document.getElementById('filter-summary');
      const promptDialog = document.getElementById('prompt-dialog');
      const promptForm = document.getElementById('prompt-form');
      const promptTitle = document.getElementById('prompt-title');
      const promptHint = document.getElementById('prompt-hint');
      const promptInput = document.getElementById('prompt-input');
      const promptProjectContext = document.getElementById('prompt-project-context');
      const promptCancel = document.getElementById('prompt-cancel');
      const promptSubmit = document.getElementById('prompt-submit');
      const toast = document.getElementById('toast');
      const createRelativePathRootValue = '__root__';
      const createRelativePathCustomValue = '__custom__';

      function normalizeCodexSessions(value) {
        if (Array.isArray(value)) return value;
        if (value && Array.isArray(value.sessions)) return value.sessions;
        return [];
      }

      function escapeHTML(value) {
        return String(value ?? '')
          .replaceAll('&', '&amp;')
          .replaceAll('<', '&lt;')
          .replaceAll('>', '&gt;')
          .replaceAll('"', '&quot;')
          .replaceAll("'", '&#39;');
      }

      function renderEmpty(title, message) {
        return `<div class="empty"><strong>${escapeHTML(title)}</strong><p>${escapeHTML(message)}</p></div>`;
      }

      function readFiltersFromQuery() {
        const params = new URLSearchParams(window.location.search);
        return {
          query: params.get('q') || '',
          deviceID: params.get('device') || '',
          runningOnly: params.get('active') === '1'
        };
      }

      function writeFiltersQuery() {
        const params = new URLSearchParams(window.location.search);
        if (state.filters.query) {
          params.set('q', state.filters.query);
        } else {
          params.delete('q');
        }
        if (state.filters.deviceID) {
          params.set('device', state.filters.deviceID);
        } else {
          params.delete('device');
        }
        if (state.filters.runningOnly) {
          params.set('active', '1');
        } else {
          params.delete('active');
        }
        const nextQuery = params.toString();
        const nextURL = `${window.location.pathname}${nextQuery ? `?${nextQuery}` : ''}${window.location.hash}`;
        history.replaceState(null, '', nextURL);
      }

      function formatTime(value) {
        if (!value) return '—';
        const date = new Date(value);
        if (Number.isNaN(date.getTime())) return '—';
        return new Intl.DateTimeFormat('zh-CN', { month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' }).format(date);
      }

      function shortPath(path) {
        if (!path) return '—';
        const parts = String(path).split('/').filter(Boolean);
        return parts.length ? parts[parts.length - 1] : path;
      }

      function projectContextKey(deviceID, workspaceID) {
        const device = String(deviceID || '').trim();
        const workspace = String(workspaceID || '').trim();
        if (!device || !workspace) return '';
        return `${device}::${workspace}`;
      }

      function projectContextSummaryState(deviceID, workspaceID) {
        const key = projectContextKey(deviceID, workspaceID);
        if (!key) return null;
        if (!state.projectContext.summaries[key]) {
          state.projectContext.summaries[key] = {
            status: 'idle',
            response: null,
            errorMessage: null
          };
        }
        return state.projectContext.summaries[key];
      }

      function projectContextCommandState(deviceID, workspaceID) {
        const key = projectContextKey(deviceID, workspaceID);
        if (!key) return null;
        if (!state.projectContext.commands[key]) {
          state.projectContext.commands[key] = {
            status: 'idle',
            response: null,
            items: [],
            available: false,
            errorMessage: null
          };
        }
        return state.projectContext.commands[key];
      }

      async function ensureProjectContextSummary(deviceID, workspaceID) {
        const entry = projectContextSummaryState(deviceID, workspaceID);
        if (!entry) return null;
        if (entry.status === 'loading' || entry.status === 'ready') return entry;

        entry.status = 'loading';
        entry.errorMessage = null;
        renderAll();

        try {
          const response = await requestJSON(projectContextSummaryURL(deviceID, workspaceID));
          entry.status = 'ready';
          entry.response = response;
          entry.errorMessage = response?.errorMessage || null;
        } catch (error) {
          entry.status = 'error';
          entry.response = null;
          entry.errorMessage = error.message || '项目上下文读取失败';
        }

        renderAll();
        return entry;
      }

      async function ensureProjectContextCommands(deviceID, workspaceID) {
        const entry = projectContextCommandState(deviceID, workspaceID);
        if (!entry) return null;
        if (entry.status === 'loading' || entry.status === 'ready') return entry;

        entry.status = 'loading';
        entry.errorMessage = null;
        renderAll();

        try {
          const response = await requestJSON(projectContextLookupURL(deviceID, workspaceID, 'command'));
          entry.status = 'ready';
          entry.response = response;
          entry.available = Boolean(response?.available);
          entry.errorMessage = response?.errorMessage || null;
          entry.items = decodeProjectContextCommandItems(response);
        } catch (error) {
          entry.status = 'error';
          entry.response = null;
          entry.items = [];
          entry.available = false;
          entry.errorMessage = error.message || '标准操作命令读取失败';
        }

        renderAll();
        return entry;
      }

      function projectContextSummaryURL(deviceID, workspaceID) {
        return `/api/devices/${encodeURIComponent(deviceID)}/workspaces/${encodeURIComponent(workspaceID)}/project-context`;
      }

      function projectContextLookupURL(deviceID, workspaceID, subject, selector = null) {
        const params = new URLSearchParams();
        params.set('subject', subject);
        if (selector) params.set('selector', selector);
        return `${projectContextSummaryURL(deviceID, workspaceID)}/lookup?${params.toString()}`;
      }

      function decodeProjectContextCommandItems(response) {
        if (!response?.available) return [];
        const payloadJSON = response?.lookup?.payloadJSON;
        if (!payloadJSON) return [];
        try {
          const payload = JSON.parse(payloadJSON);
          return Array.isArray(payload?.items) ? payload.items : [];
        } catch {
          throw new Error('控制面返回了命令查询结果，但 payloadJSON 不是有效 JSON。');
        }
      }

      function projectContextTargetForManagedRun(run) {
        if (!run?.deviceID || !run?.workspaceID) return null;
        return { deviceID: run.deviceID, workspaceID: run.workspaceID };
      }

      function projectContextTargetForCodexSession(session) {
        if (!session?.deviceID || !session?.workspaceID) return null;
        return { deviceID: session.deviceID, workspaceID: session.workspaceID };
      }

      function projectContextSummaryBadge(response) {
        if (!response?.available) return '当前工作区没有 project-context';
        if (!response?.summary?.localSecretsPresent) return '本机密钥文件缺失';
        return 'project-context 已就绪';
      }

      function formatProjectReference(reference) {
        const id = String(reference?.id || '').trim();
        const name = String(reference?.name || '').trim();
        if (!name || name === id) return id || name;
        return `${id}（${name}）`;
      }

      function projectContextListSummary(items, formatter) {
        const values = (items || [])
          .map((item) => String(formatter(item) || '').trim())
          .filter(Boolean);
        return values.length ? values.join('、') : '';
      }

      function projectCommandRunnerLabel(runner) {
        const value = String(runner || '').trim().toLowerCase();
        if (value === 'local-shell') return '本机 Shell';
        if (value === 'ssh') return 'SSH';
        return runner || '未知执行器';
      }

      function projectCommandScopeSummary(item) {
        const parts = [
          projectContextListSummary(item?.environments, (environment) => environment?.name),
          String(item?.host?.name || '').trim(),
          projectContextListSummary(item?.services, (service) => service?.name),
          projectContextListSummary(item?.databases, (database) => database?.name)
        ].filter(Boolean);
        return parts.length ? parts.join(' · ') : '';
      }

      function projectCommandHasMissingCredentials(item) {
        return (item?.credentials || []).some((credential) => !credential?.configured);
      }

      function projectCommandCredentialSummary(credentials) {
        const list = Array.isArray(credentials) ? credentials : [];
        if (!list.length) return '无额外凭据';
        const missing = list.filter((credential) => !credential?.configured);
        if (!missing.length) {
          return `${list.map((credential) => credential.id).filter(Boolean).join('；')} 已配置`;
        }
        return missing.map((credential) => {
          const fields = Array.isArray(credential?.missingRequiredFields)
            ? credential.missingRequiredFields.map((field) => String(field || '').trim()).filter(Boolean)
            : [];
          return fields.length ? `${credential.id}: ${fields.join(', ')}` : credential.id;
        }).join('；');
      }

      function buildProjectCommandPrompt(item, intent = 'continueConversation') {
        const command = item?.command || {};
        const lines = [];
        lines.push(intent === 'createManagedRun'
          ? `请基于当前工作区的 project-context 执行标准操作命令 \`${command.id}\`（${command.name}）。`
          : `继续当前任务，并执行项目上下文中的标准操作命令 \`${command.id}\`（${command.name}）。`
        );
        lines.push('');
        lines.push('已知命令事实：');
        lines.push(`- 执行器：${projectCommandRunnerLabel(command.runner)}`);
        lines.push(`- 命令模板：${command.command || '—'}`);

        const workingDirectory = String(command.workingDirectory || '').trim();
        if (workingDirectory) lines.push(`- 工作目录：${workingDirectory}`);

        const environments = projectContextListSummary(item?.environments, formatProjectReference);
        if (environments) lines.push(`- 环境：${environments}`);

        const host = formatProjectReference(item?.host);
        if (host) lines.push(`- 主机：${host}`);

        const services = projectContextListSummary(item?.services, formatProjectReference);
        if (services) lines.push(`- 服务：${services}`);

        const databases = projectContextListSummary(item?.databases, formatProjectReference);
        if (databases) lines.push(`- 数据库：${databases}`);

        const credentials = Array.isArray(item?.credentials) ? item.credentials : [];
        if (!credentials.length) {
          lines.push('- 凭据：未声明额外凭据');
        } else {
          lines.push(`- 凭据：${credentials.map((credential) => {
            if (credential?.configured) return `${credential.id}（已配置）`;
            const fields = Array.isArray(credential?.missingRequiredFields)
              ? credential.missingRequiredFields.map((field) => String(field || '').trim()).filter(Boolean)
              : [];
            return fields.length ? `${credential.id}（缺少 ${fields.join(', ')}）` : `${credential.id}（未配置）`;
          }).join('；')}`);
        }

        const notes = Array.isArray(command.notes)
          ? command.notes.map((note) => String(note || '').trim()).filter(Boolean)
          : [];
        if (notes.length) lines.push(`- 备注：${notes.join('；')}`);

        lines.push('');
        lines.push('执行要求：');
        lines.push('1. 先核对关联环境、主机、服务、数据库和凭据状态是否满足。');
        lines.push('2. 如果命令模板包含 `{{credential...}}` 占位符，优先根据 project-context 与本机 local secrets 补齐；不要输出敏感值。');
        lines.push('3. 在合适的工作目录执行该命令；如果需要做等效调整，先说明原因，再继续执行。');
        lines.push(intent === 'createManagedRun'
          ? '4. 完成后汇报执行结果、关键输出、健康检查结论，以及建议的下一步。'
          : '4. 完成后汇报执行结果、关键输出，以及是否还需要继续做健康检查、查看日志或回滚处理。'
        );
        return lines.join('\n');
      }

      function appendPromptBlock(promptBlock, existingPrompt) {
        const existing = String(existingPrompt || '').trim();
        if (!existing) return promptBlock;
        return `${existing}\n\n${promptBlock}`;
      }

      function lookupProjectCommandItem(deviceID, workspaceID, commandID) {
        const entry = projectContextCommandState(deviceID, workspaceID);
        if (!entry?.items?.length) return null;
        return entry.items.find((item) => item?.command?.id === commandID) || null;
      }

      function hasCapability(device, capability) {
        return Array.isArray(device?.capabilities) && device.capabilities.includes(capability);
      }

      function allKnownDevices() {
        const devices = new Map();
        for (const device of state.snapshot.devices || []) {
          devices.set(device.deviceID, device);
        }
        for (const session of state.codexSessions || []) {
          if (!devices.has(session.deviceID)) {
            devices.set(session.deviceID, {
              deviceID: session.deviceID,
              name: session.deviceName || session.deviceID,
              hostName: session.deviceID,
              status: 'unknown',
              platform: 'unknown',
              capabilities: [],
              workspaces: [],
              metrics: {},
              runningTaskCount: 0,
              registeredAt: null,
              lastSeenAt: session.updatedAt || null,
              localStatusPageHost: null,
              localStatusPagePort: null
            });
          }
        }
        return [...devices.values()].sort((lhs, rhs) => {
          const lhsOnline = lhs.status === 'online' ? 0 : 1;
          const rhsOnline = rhs.status === 'online' ? 0 : 1;
          if (lhsOnline !== rhsOnline) return lhsOnline - rhsOnline;
          return String(lhs.name || lhs.deviceID || '').localeCompare(String(rhs.name || rhs.deviceID || ''), 'zh-CN');
        });
      }

      function codexCapableDevices() {
        return allKnownDevices().filter((device) => hasCapability(device, 'codex'));
      }

      function workspaceCatalog() {
        const workspaces = new Map();
        for (const device of codexCapableDevices()) {
          for (const workspace of device.workspaces || []) {
            const existing = workspaces.get(workspace.id) || {
              id: workspace.id,
              name: workspace.name || workspace.id,
              rootPath: workspace.rootPath || '',
              deviceIDs: [],
              onlineCount: 0
            };
            if (!existing.deviceIDs.includes(device.deviceID)) {
              existing.deviceIDs.push(device.deviceID);
              if (device.status === 'online') existing.onlineCount += 1;
            }
            if (!existing.rootPath && workspace.rootPath) existing.rootPath = workspace.rootPath;
            workspaces.set(workspace.id, existing);
          }
        }
        return [...workspaces.values()].sort((lhs, rhs) => String(lhs.name || lhs.id).localeCompare(String(rhs.name || rhs.id), 'zh-CN'));
      }

      function deviceLabel(device) {
        const status = device?.status === 'online' ? '在线' : device?.status === 'offline' ? '离线' : '未知';
        return `${device?.name || device?.deviceID || '未知设备'} · ${status}`;
      }

      function deviceByID(deviceID) {
        return allKnownDevices().find((device) => device.deviceID === deviceID) || null;
      }

      function deviceLocalConsoleInfo(device) {
        if (!device) return null;
        const rawHost = String(device.localStatusPageHost || '').trim();
        const port = Number(device.localStatusPagePort || 0);
        if (!rawHost || !Number.isFinite(port) || port <= 0) return null;

        let host = rawHost;
        let note = '如果浏览器能访问这台宿主机，可以直接打开这个地址。';
        if (host === '0.0.0.0' || host === '::') {
          host = String(device.hostName || '').trim();
          if (!host) return null;
          note = '状态页监听的是全部网卡地址；如果当前浏览器能访问这台宿主机，就可以直接打开。';
        } else if (host === '127.0.0.1' || host === 'localhost' || host === '::1') {
          note = '这个地址只适合在宿主机本机浏览器打开；如果你是远端看控制平面，需要切到那台机器上打开。';
        }

        return {
          url: `http://${host}:${port}`,
          note
        };
      }

      function hostConsoleLink(deviceID, label = '打开宿主机控制台', tone = '') {
        const info = deviceLocalConsoleInfo(deviceByID(deviceID));
        if (!info) return '';
        const toneClass = tone ? ` ${tone}` : '';
        return `<a class="action-button${toneClass}" href="${escapeHTML(info.url)}" target="_blank" rel="noreferrer">${escapeHTML(label)}</a>`;
      }

      function filterDeviceOptions() {
        return [
          { value: '', label: '全部设备' },
          ...allKnownDevices().map((device) => ({ value: device.deviceID, label: deviceLabel(device) }))
        ];
      }

      function createWorkspaceOptions() {
        const workspaces = workspaceCatalog();
        if (!workspaces.length) {
          return [{ value: '', label: '当前没有可用工作区', disabled: true }];
        }
        return workspaces.map((workspace) => ({
          value: workspace.id,
          label: `${workspace.name || workspace.id} · ${workspace.deviceIDs.length} 台 Codex 设备`
        }));
      }

      function createDeviceOptions(workspaceID) {
        const candidates = codexCapableDevices().filter((device) => {
          if (!workspaceID) return true;
          return (device.workspaces || []).some((workspace) => workspace.id === workspaceID);
        });
        return [
          { value: '', label: '自动分配（推荐）' },
          ...candidates.map((device) => ({ value: device.deviceID, label: deviceLabel(device) }))
        ];
      }

      function setSelectOptions(select, options, preferredValue) {
        const previous = preferredValue === undefined ? select.value : preferredValue;
        select.innerHTML = options.map((option) => `
          <option value="${escapeHTML(option.value)}"${option.disabled ? ' disabled' : ''}>${escapeHTML(option.label)}</option>
        `).join('');
        const firstEnabled = options.find((option) => !option.disabled)?.value ?? '';
        const nextValue = options.some((option) => option.value === previous && !option.disabled) ? previous : firstEnabled;
        select.value = nextValue;
        return nextValue;
      }

      function selectedWorkspaceRecord() {
        const workspaceID = createWorkspaceSelect.value;
        return workspaceCatalog().find((workspace) => workspace.id === workspaceID) || null;
      }

      function joinedPath(rootPath, relativePath) {
        if (!rootPath) return relativePath || '—';
        if (!relativePath) return rootPath;
        return `${rootPath.replace(/\/+$/, '')}/${relativePath.replace(/^\/+/, '')}`;
      }

      function normalizeRelativePath(value) {
        return String(value || '')
          .trim()
          .replace(/^\/+/, '')
          .replace(/\/+$/, '');
      }

      function relativePathFromWorkspaceRoot(rootPath, absolutePath) {
        const normalizedRoot = String(rootPath || '').trim().replace(/\/+$/, '');
        const normalizedAbsolute = String(absolutePath || '').trim().replace(/\/+$/, '');
        if (!normalizedRoot || !normalizedAbsolute) return '';
        if (normalizedAbsolute === normalizedRoot) return '';
        if (!normalizedAbsolute.startsWith(`${normalizedRoot}/`)) return '';
        return normalizeRelativePath(normalizedAbsolute.slice(normalizedRoot.length + 1));
      }

      function addRelativePathCandidate(bucket, rawValue, sourceLabel, score = 1) {
        const value = normalizeRelativePath(rawValue);
        if (!value) return;

        const existing = bucket.get(value) || { value, score: 0, sources: new Set() };
        existing.score += score;
        if (sourceLabel) existing.sources.add(sourceLabel);
        bucket.set(value, existing);

        const parts = value.split('/').filter(Boolean);
        for (let index = 1; index < parts.length; index += 1) {
          const parent = parts.slice(0, index).join('/');
          const parentExisting = bucket.get(parent) || { value: parent, score: 0, sources: new Set() };
          parentExisting.score += Math.max(score * 0.35, 0.35);
          if (sourceLabel) parentExisting.sources.add(sourceLabel);
          bucket.set(parent, parentExisting);
        }
      }

      function relativePathCandidatesForWorkspace(workspaceID) {
        const workspace = workspaceCatalog().find((item) => item.id === workspaceID);
        if (!workspace) return [];

        const bucket = new Map();

        for (const run of state.snapshot.managedRuns || []) {
          if (run.workspaceID !== workspaceID) continue;
          addRelativePathCandidate(bucket, run.relativePath, 'Orchard 任务', 1.3);
          addRelativePathCandidate(bucket, relativePathFromWorkspaceRoot(workspace.rootPath, run.cwd), 'Orchard 任务', 1);
        }

        for (const session of state.codexSessions || []) {
          if (session.workspaceID !== workspaceID) continue;
          addRelativePathCandidate(bucket, relativePathFromWorkspaceRoot(workspace.rootPath, session.cwd), 'Codex 对话', 1.1);
        }

        return [...bucket.values()]
          .sort((lhs, rhs) => {
            if (lhs.score !== rhs.score) return rhs.score - lhs.score;
            const lhsDepth = lhs.value.split('/').length;
            const rhsDepth = rhs.value.split('/').length;
            if (lhsDepth !== rhsDepth) return lhsDepth - rhsDepth;
            return lhs.value.localeCompare(rhs.value, 'zh-CN');
          })
          .slice(0, 12);
      }

      function createRelativePathOptions(workspaceID, currentInput = '') {
        const options = [
          { value: createRelativePathRootValue, label: '工作区根目录' }
        ];

        for (const item of relativePathCandidatesForWorkspace(workspaceID)) {
          const sourceLabel = [...item.sources].join(' / ');
          options.push({
            value: item.value,
            label: sourceLabel ? `${item.value} · ${sourceLabel}` : item.value
          });
        }

        const normalizedCurrent = normalizeRelativePath(currentInput);
        if (!normalizedCurrent) {
          options.push({ value: createRelativePathCustomValue, label: '手动输入其他路径' });
          return options;
        }

        if (!options.some((option) => option.value === normalizedCurrent)) {
          options.push({ value: createRelativePathCustomValue, label: `手动输入：${normalizedCurrent}` });
        } else {
          options.push({ value: createRelativePathCustomValue, label: '手动输入其他路径' });
        }

        return options;
      }

      function syncCreateRelativePathSelect(preferredValue) {
        const options = createRelativePathOptions(createWorkspaceSelect.value, createRelativePathInput.value);
        const normalizedCurrent = normalizeRelativePath(createRelativePathInput.value);
        let nextValue = preferredValue;

        if (!nextValue) {
          if (!normalizedCurrent) {
            nextValue = createRelativePathRootValue;
          } else if (options.some((option) => option.value === normalizedCurrent)) {
            nextValue = normalizedCurrent;
          } else {
            nextValue = createRelativePathCustomValue;
          }
        }

        setSelectOptions(createRelativePathSelect, options, nextValue);
      }

      function defaultRunTitle(prompt) {
        const firstLine = String(prompt || '').split('\n').map((line) => line.trim()).find(Boolean) || '新的 Orchard 任务';
        return firstLine.length > 36 ? `${firstLine.slice(0, 36)}...` : firstLine;
      }

      function syncFilterStateFromControls() {
        state.filters.query = filterQueryInput.value.trim();
        state.filters.deviceID = filterDeviceSelect.value || '';
        state.filters.runningOnly = Boolean(filterRunningOnly.checked);
      }

      function updateCreateHint() {
        const workspace = selectedWorkspaceRecord();
        const relativePath = normalizeRelativePath(createRelativePathInput.value);
        if (!workspace) {
          createHint.textContent = '当前还没有可执行 Codex 的项目目录；先确认 Agent 已连接控制面并上报工作区。';
          return;
        }
        const cwd = joinedPath(workspace.rootPath, relativePath);
        const onlineCount = workspace.onlineCount ? `，当前在线 ${workspace.onlineCount} 台` : '，当前在线设备 0 台';
        createHint.textContent = `预计会在 ${cwd} 执行${onlineCount}；如果不指定电脑，控制面会自动挑一台在线设备。`;
      }

      function updateToolbarControls() {
        const previousFilterDeviceID = state.filters.deviceID;
        filterQueryInput.value = state.filters.query;
        filterRunningOnly.checked = state.filters.runningOnly;
        const selectedFilterDevice = setSelectOptions(filterDeviceSelect, filterDeviceOptions(), state.filters.deviceID);
        state.filters.deviceID = selectedFilterDevice;
        if (previousFilterDeviceID !== state.filters.deviceID) {
          writeFiltersQuery();
        }

        const workspaceOptions = createWorkspaceOptions();
        const selectedWorkspace = setSelectOptions(createWorkspaceSelect, workspaceOptions, createWorkspaceSelect.value);
        const deviceOptions = createDeviceOptions(selectedWorkspace);
        const selectedDevice = setSelectOptions(createDeviceSelect, deviceOptions, createDeviceSelect.value);
        syncCreateRelativePathSelect();

        const hasWorkspace = Boolean(selectedWorkspace);
        createWorkspaceSelect.disabled = state.actionPending || !hasWorkspace;
        createDeviceSelect.disabled = state.actionPending || !hasWorkspace;
        createRelativePathSelect.disabled = state.actionPending || !hasWorkspace;
        createTitleInput.disabled = state.actionPending || !hasWorkspace;
        createRelativePathInput.disabled = state.actionPending || !hasWorkspace;
        createPromptInput.disabled = state.actionPending || !hasWorkspace;
        createSubmit.disabled = state.actionPending || !hasWorkspace;

        if (!deviceOptions.some((option) => option.value === selectedDevice)) {
          createDeviceSelect.value = '';
        }

        updateCreateHint();
        renderFilterSummary();
      }

      function isCodexRunning(session) {
        return session.state === 'running' || session.lastTurnStatus === 'inProgress';
      }

      function hasCodexTimelineData(session) {
        return Boolean(
          String(session.lastTurnStatus || '').trim()
          || String(session.lastUserMessage || '').trim()
          || String(session.lastAssistantMessage || '').trim()
        );
      }

      function isCodexStandby(session) {
        return !isCodexRunning(session) && ['idle', 'unknown'].includes(session.state);
      }

      function isCodexRecent(session) {
        return isCodexRunning(session) || isCodexStandby(session);
      }

      function isCodexFinished(session) {
        return ['completed', 'failed', 'interrupted'].includes(session.state);
      }

      function isCodexLightweight(session) {
        return isCodexStandby(session) && !hasCodexTimelineData(session);
      }

      function codexDisplayStateLabel(session) {
        if (isCodexRunning(session)) return '推理中';
        if (isCodexStandby(session)) return isCodexLightweight(session) ? '待命（轻摘要）' : '待命';
        return codexStateLabel(session.state);
      }

      function codexDisplayStateTone(session) {
        if (isCodexRunning(session)) return 'blue';
        if (isCodexStandby(session)) return 'gold';
        return codexStateTone(session.state);
      }

      function codexTurnStatusLabel(status) {
        return {
          inProgress: '推理中',
          completed: '已完成',
          interrupted: '已中断',
          failed: '失败'
        }[status] || status || '无轮次';
      }

      function codexLastTurnLabel(session) {
        if (isCodexLightweight(session)) return '轻摘要';
        return codexTurnStatusLabel(session.lastTurnStatus);
      }

      function codexStatusExplanation(session) {
        if (isCodexRunning(session)) return '最近轮次仍在执行，所以会计入“总运行中”。';
        if (isCodexStandby(session)) {
          return isCodexLightweight(session)
            ? '当前只拿到列表轻摘要，打开详情后会再读取完整轮次。'
            : '当前没有继续推理，但上下文仍保留，可直接继续追问。';
        }
        if (session.state === 'completed') return '最近一轮已经完成，可继续追问开启下一轮。';
        if (session.state === 'failed') return '最近一轮失败，建议先查看详情和报错。';
        if (session.state === 'interrupted') return '最近一轮被中断，可继续追问恢复。';
        return '当前状态仍在同步中。';
      }

      function codexAttentionRank(session) {
        if (isCodexRunning(session)) return 0;
        if (session.state === 'failed') return 1;
        if (session.state === 'interrupted') return 2;
        if (isCodexStandby(session)) return isCodexLightweight(session) ? 3 : 4;
        if (session.state === 'completed') return 5;
        return 6;
      }

      function summarizeCounts(values) {
        const counts = new Map();
        for (const value of values) {
          const key = String(value || '未知').trim() || '未知';
          counts.set(key, (counts.get(key) || 0) + 1);
        }
        return [...counts.entries()]
          .sort((lhs, rhs) => rhs[1] - lhs[1] || lhs[0].localeCompare(rhs[0], 'zh-CN'))
          .slice(0, 3)
          .map(([label, count]) => `${label} ${count}`)
          .join(' · ') || '暂无';
      }

      function buildCodexDiagnostics(sessions, metrics = currentMetrics()) {
        const running = sessions.filter(isCodexRunning).length;
        const standby = sessions.filter(isCodexStandby).length;
        const finished = sessions.filter(isCodexFinished).length;
        const lightweight = sessions.filter(isCodexLightweight).length;
        const sourceSummary = summarizeCounts(sessions.map((session) => session.source || '未知'));
        const turnSummary = summarizeCounts(sessions.map((session) => codexLastTurnLabel(session)));
        let conclusion = '还没有从 Agent 读到可展示的会话。';
        if (metrics.desktopCodexLiveGap > 0) {
          conclusion = `桌面端实时快照显示 ${metrics.desktopCodexActiveThreads} 个活跃对话、${metrics.desktopCodexInflightTurns} 个进行中轮次，当前至少观测到 ${metrics.observedRunningCodex} 个执行中线程；但会话桥只精确映射出 ${running} 个执行中的对话，仍有 ${metrics.desktopCodexLiveGap} 个线程只能先做设备级观测。`;
        } else if (metrics.observedRunningCodex > 0) {
          conclusion = running > 0
            ? '当前存在真正推理中的线程，顶部“总运行中”会把这些线程算进去。'
            : '当前存在真正推理中的线程，虽然会话桥还没全部命中，但顶部“总运行中”已经按桌面 inflight 线程兜底统计。';
        } else if (standby > 0) {
          conclusion = lightweight > 0
            ? `当前主要是待命线程；其中 ${lightweight} 个只拿到轻摘要，点进详情后才会补拉轮次。`
            : '当前没有推理中的线程，所以“总运行中”为 0 是正常的；这些待命会话仍可继续追问。';
        } else if (finished > 0) {
          conclusion = '当前列表以已结束线程为主，适合复盘或继续追问。';
        }
        return {
          summary: `当前共 ${sessions.length} 个 Codex 对话：对话里显示执行中 ${running}，设备侧观测执行中 ${metrics.observedRunningCodex}，待命 ${standby}，已结束 ${finished}；桌面端活跃对话 ${metrics.desktopCodexActiveThreads}，进行中回答轮次 ${metrics.desktopCodexInflightTurns}。`,
          sourceSummary,
          turnSummary,
          conclusion
        };
      }

      function filtersApplied() {
        return Boolean(state.filters.query || state.filters.deviceID || state.filters.runningOnly);
      }

      function searchableText(parts) {
        return parts
          .flatMap((part) => Array.isArray(part) ? part : [part])
          .filter(Boolean)
          .join(' ')
          .toLowerCase();
      }

      function managedMatchesFilters(run) {
        if (state.filters.deviceID && run.deviceID !== state.filters.deviceID && run.preferredDeviceID !== state.filters.deviceID) return false;
        if (state.filters.runningOnly && !occupiesManagedSlot(run.status)) return false;
        if (!state.filters.query) return true;
        const haystack = searchableText([
          run.id,
          run.title,
          run.workspaceID,
          run.relativePath,
          run.cwd,
          run.deviceID,
          run.preferredDeviceID,
          run.deviceName,
          run.summary,
          run.lastUserPrompt,
          run.lastAssistantPreview,
          managedStatusLabel(run.status)
        ]);
        return haystack.includes(state.filters.query.toLowerCase());
      }

      function codexMatchesFilters(session) {
        if (state.filters.deviceID && session.deviceID !== state.filters.deviceID) return false;
        if (state.filters.runningOnly && !isCodexRecent(session)) return false;
        if (!state.filters.query) return true;
        const haystack = searchableText([
          session.id,
          session.name,
          session.preview,
          session.workspaceID,
          session.cwd,
          session.deviceID,
          session.deviceName,
          session.source,
          session.lastUserMessage,
          session.lastAssistantMessage,
          codexDisplayStateLabel(session),
          codexLastTurnLabel(session),
          isCodexLightweight(session) ? '轻摘要' : ''
        ]);
        return haystack.includes(state.filters.query.toLowerCase());
      }

      function taskMatchesFilters(task) {
        if (state.filters.deviceID && task.assignedDeviceID !== state.filters.deviceID && task.preferredDeviceID !== state.filters.deviceID) return false;
        if (state.filters.runningOnly && !isActiveTask(task)) return false;
        if (!state.filters.query) return true;
        const haystack = searchableText([
          task.id,
          task.title,
          task.workspaceID,
          task.relativePath,
          task.assignedDeviceID,
          task.preferredDeviceID,
          task.summary,
          taskPayloadPreview(task),
          taskStatusLabel(task.status),
          taskKindLabel(task.kind)
        ]);
        return haystack.includes(state.filters.query.toLowerCase());
      }

      function filteredManagedRuns() {
        return (state.snapshot.managedRuns || []).filter(managedMatchesFilters);
      }

      function filteredIndependentTasks() {
        const managedTaskIDs = allManagedTaskIDs();
        return (state.snapshot.tasks || [])
          .filter((task) => !managedTaskIDs.has(task.id))
          .filter(taskMatchesFilters);
      }

      function filteredCodexSessions() {
        return (state.codexSessions || []).filter(codexMatchesFilters);
      }

      function managedRunByID(runID) {
        return (state.snapshot.managedRuns || []).find((run) => run.id === runID) || null;
      }

      function independentTaskByID(taskID) {
        if (state.detailType === 'task' && state.detail?.task?.id === taskID) {
          return state.detail.task;
        }
        const managedTaskIDs = allManagedTaskIDs();
        return (state.snapshot.tasks || []).find((task) => task.id === taskID && !managedTaskIDs.has(task.id)) || null;
      }

      function codexSessionByID(deviceID, sessionID) {
        if (state.detailType === 'codex' && state.detail?.session?.deviceID === deviceID && state.detail?.session?.id === sessionID) {
          return state.detail.session;
        }
        return (state.codexSessions || []).find((session) => session.deviceID === deviceID && session.id === sessionID) || null;
      }

      function filteredDevices() {
        return (state.snapshot.devices || []).filter((device) => {
          if (state.filters.deviceID && device.deviceID !== state.filters.deviceID) return false;
          if (!state.filters.query) return true;
          const haystack = searchableText([
            device.deviceID,
            device.name,
            device.hostName,
            device.platform,
            (device.capabilities || []).map(capabilityLabel),
            (device.workspaces || []).map((workspace) => [workspace.id, workspace.name, workspace.rootPath])
          ]);
          return haystack.includes(state.filters.query.toLowerCase());
        });
      }

      function filteredWorkspaces() {
        const seen = new Map();
        for (const device of filteredDevices()) {
          for (const workspace of device.workspaces || []) {
            const existing = seen.get(workspace.id) || {
              id: workspace.id,
              name: workspace.name || workspace.id,
              rootPath: workspace.rootPath || '',
              deviceNames: []
            };
            const deviceName = device.name || device.deviceID;
            if (!existing.deviceNames.includes(deviceName)) existing.deviceNames.push(deviceName);
            seen.set(workspace.id, existing);
          }
        }
        return [...seen.values()].filter((workspace) => {
          if (!state.filters.query) return true;
          const haystack = searchableText([workspace.id, workspace.name, workspace.rootPath, workspace.deviceNames]);
          return haystack.includes(state.filters.query.toLowerCase());
        }).sort((lhs, rhs) => String(lhs.name || lhs.id).localeCompare(String(rhs.name || rhs.id), 'zh-CN'));
      }

      function renderFilterSummary() {
        const managedCount = filteredManagedRuns().length;
        const taskCount = filteredIndependentTasks().length;
        const codexCount = filteredCodexSessions().length;
        const codexRunningCount = filteredCodexSessions().filter(isCodexRunning).length;
        const codexStandbyCount = filteredCodexSessions().filter(isCodexStandby).length;
        const notes = [];
        if (state.filters.query) notes.push(`搜索“${state.filters.query}”`);
        if (state.filters.deviceID) {
          const device = allKnownDevices().find((item) => item.deviceID === state.filters.deviceID);
          notes.push(`设备 ${device ? device.name || device.deviceID : state.filters.deviceID}`);
        }
        if (state.filters.runningOnly) notes.push('只看活跃项');
        filterSummary.textContent = notes.length
          ? `当前筛选：${notes.join('，')}；展示 ${managedCount} 个 Orchard 任务、${taskCount} 个兼容任务、${codexCount} 个 Codex 对话（其中执行中 ${codexRunningCount}，待命 ${codexStandbyCount}）。`
          : `当前展示全部内容，共 ${managedCount} 个 Orchard 任务、${taskCount} 个兼容任务、${codexCount} 个 Codex 对话（其中执行中 ${codexRunningCount}，待命 ${codexStandbyCount}）。`;
      }

      function managedSummary(run) {
        return run.summary || run.lastAssistantPreview || run.lastUserPrompt || run.cwd || '暂无摘要';
      }

      function managedDeviceLabel(run) {
        if (run.deviceName) return run.deviceName;
        if (run.deviceID) return run.deviceID;
        if (run.preferredDeviceID) return `待分配 -> ${run.preferredDeviceID}`;
        return '待分配';
      }

      function codexSummary(session) {
        return session.lastAssistantMessage || session.lastUserMessage || session.preview || session.cwd || '暂无摘要';
      }

      function taskPayloadPreview(task) {
        const payload = task?.payload || {};
        if (payload.type === 'shell') return payload.command || '';
        if (payload.type === 'codex') return payload.prompt || '';
        return '';
      }

      function taskSummary(task) {
        return task.summary || taskPayloadPreview(task) || task.relativePath || task.workspaceID || '暂无摘要';
      }

      function taskDeviceLabel(task) {
        if (task.assignedDeviceID) return task.assignedDeviceID;
        if (task.preferredDeviceID) return `待分配 -> ${task.preferredDeviceID}`;
        return '待分配';
      }

      function taskStopLabel(task) {
        return task.status === 'queued' ? '取消任务' : '停止任务';
      }

      function taskKindLabel(kind) {
        return {
          shell: 'Shell',
          codex: 'Codex'
        }[kind] || kind || '未知';
      }

      function taskPriorityLabel(priority) {
        return {
          low: '低',
          normal: '普通',
          high: '高'
        }[priority] || priority || '普通';
      }

      function taskAttentionRank(task) {
        switch (task.status) {
          case 'failed': return 0;
          case 'stopRequested': return 1;
          case 'running': return 2;
          case 'queued': return 3;
          case 'succeeded': return 4;
          case 'cancelled': return 5;
          default: return 6;
        }
      }

      function taskStatusLabel(status) {
        return {
          queued: '排队中',
          running: '运行中',
          stopRequested: '停止中',
          succeeded: '已完成',
          failed: '失败',
          cancelled: '已取消'
        }[status] || status || '未知';
      }

      function taskStatusTone(status) {
        return {
          queued: 'gold',
          running: 'blue',
          stopRequested: 'gold',
          succeeded: 'green',
          failed: 'red',
          cancelled: 'gray'
        }[status] || 'gray';
      }

      function canStopTask(task) {
        return task && !['succeeded', 'failed', 'cancelled', 'stopRequested'].includes(task.status);
      }

      function managedStatusLabel(status) {
        return {
          queued: '排队中',
          launching: '启动中',
          running: '运行中',
          waitingInput: '等待继续',
          interrupting: '中断中',
          stopRequested: '停止中',
          succeeded: '已完成',
          failed: '失败',
          interrupted: '已中断',
          cancelled: '已取消'
        }[status] || status || '未知';
      }

      function managedStatusTone(status) {
        return {
          queued: 'gold',
          launching: 'blue',
          running: 'blue',
          waitingInput: 'blue',
          interrupting: 'gold',
          stopRequested: 'gold',
          succeeded: 'green',
          failed: 'red',
          interrupted: 'gold',
          cancelled: 'gray'
        }[status] || 'gray';
      }

      function codexStateLabel(status) {
        return {
          running: '运行中',
          idle: '待命',
          completed: '已完成',
          failed: '失败',
          interrupted: '已中断',
          unknown: '未知'
        }[status] || status || '未知';
      }

      function codexStateTone(status) {
        return {
          running: 'blue',
          idle: 'gray',
          completed: 'green',
          failed: 'red',
          interrupted: 'gold',
          unknown: 'gray'
        }[status] || 'gray';
      }

      function capabilityLabel(capability) {
        return {
          shell: '命令行',
          filesystem: '文件系统',
          git: 'Git',
          docker: 'Docker',
          browser: '浏览器',
          codex: 'Codex'
        }[capability] || capability;
      }

      function platformLabel(platform) {
        return {
          macOS: 'macOS',
          iOS: 'iOS',
          unknown: '未知'
        }[platform] || platform || '未知';
      }

      function codexItemKindLabel(kind) {
        return {
          userMessage: '用户输入',
          agentMessage: '助手回复',
          plan: '计划',
          reasoning: '推理',
          commandExecution: '命令执行',
          fileChange: '文件改动',
          webSearch: '网页搜索',
          other: '其他'
        }[kind] || kind || '其他';
      }

      function managedAttentionRank(status) {
        return {
          failed: 0,
          waitingInput: 1,
          running: 2,
          launching: 3,
          interrupting: 4,
          stopRequested: 5,
          queued: 6,
          interrupted: 7,
          succeeded: 8,
          cancelled: 9
        }[status] ?? 10;
      }

      function codexAttentionRank(session) {
        return {
          running: 0,
          interrupted: 1,
          failed: 2,
          completed: 3,
          idle: 4,
          unknown: 5
        }[session.state] ?? 6;
      }

      function compareManagedRuns(lhs, rhs) {
        const lhsRank = managedAttentionRank(lhs.status);
        const rhsRank = managedAttentionRank(rhs.status);
        if (lhsRank !== rhsRank) return lhsRank - rhsRank;
        return new Date(rhs.updatedAt) - new Date(lhs.updatedAt);
      }

      function compareTasks(lhs, rhs) {
        const lhsRank = taskAttentionRank(lhs);
        const rhsRank = taskAttentionRank(rhs);
        if (lhsRank !== rhsRank) return lhsRank - rhsRank;
        return new Date(rhs.updatedAt) - new Date(lhs.updatedAt);
      }

      function compareCodexSessions(lhs, rhs) {
        const lhsRank = codexAttentionRank(lhs);
        const rhsRank = codexAttentionRank(rhs);
        if (lhsRank !== rhsRank) return lhsRank - rhsRank;
        return new Date(rhs.updatedAt) - new Date(lhs.updatedAt);
      }

      function occupiesManagedSlot(status) {
        return ['launching', 'running', 'waitingInput', 'interrupting', 'stopRequested'].includes(status);
      }

      function isManagedTerminal(status) {
        return ['succeeded', 'failed', 'interrupted', 'cancelled'].includes(status);
      }

      function canContinueManaged(run) {
        return run.status === 'waitingInput' && Boolean(run.codexSessionID);
      }

      function canInterruptManaged(run) {
        return ['running', 'waitingInput'].includes(run.status) && Boolean(run.codexSessionID);
      }

      function canStopManaged(run) {
        return !isManagedTerminal(run.status) && run.status !== 'stopRequested';
      }

      function canRetryManaged(run) {
        return isManagedTerminal(run.status);
      }

      function isSelectedManaged(runID) {
        return state.selected && state.selected.type === 'managed' && state.selected.runID === runID;
      }

      function isSelectedTask(taskID) {
        return state.selected && state.selected.type === 'task' && state.selected.taskID === taskID;
      }

      function isSelectedCodex(deviceID, sessionID) {
        return state.selected && state.selected.type === 'codex' && state.selected.deviceID === deviceID && state.selected.sessionID === sessionID;
      }

      function deviceCodexMetricValue(device, key) {
        const value = device?.metrics?.codexDesktop?.[key];
        return Number.isFinite(value) ? value : 0;
      }

      function deviceCodexMetricDisplay(device, key) {
        const value = device?.metrics?.codexDesktop?.[key];
        return Number.isFinite(value) ? String(value) : '--';
      }

      function deviceCodexSnapshotText(device) {
        const value = device?.metrics?.codexDesktop?.lastSnapshotAt;
        return value ? formatTime(value) : '—';
      }

      function mappedRunningCodexSessionsForDevice(deviceID) {
        if (!deviceID) return 0;
        return state.codexSessions.filter((session) => session.deviceID === deviceID && isCodexRunning(session)).length;
      }

      function observedRunningCodexSessionsForDevice(device) {
        return Math.max(
          mappedRunningCodexSessionsForDevice(device?.deviceID),
          deviceCodexMetricValue(device, 'inflightThreadCount')
        );
      }

      function isActiveTask(task) {
        return task && (task.status === 'running' || task.status === 'stopRequested');
      }

      function allManagedTaskIDs() {
        return new Set(
          (state.snapshot.managedRuns || [])
            .map((run) => run.taskID)
            .filter(Boolean)
        );
      }

      function activeManagedTaskIDs() {
        return new Set(
          (state.snapshot.managedRuns || [])
            .filter((run) => occupiesManagedSlot(run.status))
            .map((run) => run.taskID)
            .filter(Boolean)
        );
      }

      function unmanagedRunningTaskCount() {
        const managedTaskIDs = activeManagedTaskIDs();
        return (state.snapshot.tasks || []).filter((task) => isActiveTask(task) && !managedTaskIDs.has(task.id)).length;
      }

      function unmanagedRunningTaskCountForDevice(deviceID) {
        if (!deviceID) return 0;
        const managedTaskIDs = activeManagedTaskIDs();
        return (state.snapshot.tasks || []).filter((task) => {
          if (task.assignedDeviceID !== deviceID) return false;
          if (!isActiveTask(task)) return false;
          return !managedTaskIDs.has(task.id);
        }).length;
      }

      function deviceCodexLiveGap(device) {
        return Math.max(deviceCodexMetricValue(device, 'activeThreadCount') - mappedRunningCodexSessionsForDevice(device?.deviceID), 0);
      }

      function deviceCodexGapSummary(device) {
        const gap = deviceCodexLiveGap(device);
        if (gap <= 0) {
          return '';
        }
        const mappedRunning = mappedRunningCodexSessionsForDevice(device?.deviceID);
        return `仍有 ${gap} 个活跃线程只做设备级观测；当前仅精确映射出 ${mappedRunning} 个执行中的对话。`;
      }

      function deviceCodexSummary(device) {
        const metrics = device?.metrics?.codexDesktop;
        if (!device?.capabilities?.includes('codex')) {
          return '当前设备未声明 Codex 能力。';
        }
        if (!metrics) {
          return '暂未收到 Codex 桌面实时快照。';
        }
        if (!Number.isFinite(metrics.activeThreadCount)) {
          return `Codex 桌面快照已过期，最近一次更新时间 ${deviceCodexSnapshotText(device)}。`;
        }
        return `Codex 活跃线程 ${metrics.activeThreadCount} 个，推理中线程 ${deviceCodexMetricValue(device, 'inflightThreadCount')} 个，进行中轮次 ${deviceCodexMetricValue(device, 'inflightTurnCount')} 个。`;
      }

      function currentMetrics() {
        const runningManaged = state.snapshot.managedRuns.filter((run) => occupiesManagedSlot(run.status)).length;
        const unmanagedTasks = unmanagedRunningTaskCount();
        const waitingInput = state.snapshot.managedRuns.filter((run) => run.status === 'waitingInput').length;
        const failedManaged = state.snapshot.managedRuns.filter((run) => run.status === 'failed').length;
        const queuedManaged = state.snapshot.managedRuns.filter((run) => run.status === 'queued').length;
        const runningCodex = state.codexSessions.filter(isCodexRunning).length;
        const standbyCodex = state.codexSessions.filter(isCodexStandby).length;
        const finishedCodex = state.codexSessions.filter(isCodexFinished).length;
        const lightweightCodex = state.codexSessions.filter(isCodexLightweight).length;
        const onlineDevicesList = state.snapshot.devices.filter((device) => device.status === 'online');
        const onlineDevices = onlineDevicesList.length;
        const desktopCodexActiveThreads = onlineDevicesList.reduce((result, device) => result + deviceCodexMetricValue(device, 'activeThreadCount'), 0);
        const desktopCodexInflightThreads = onlineDevicesList.reduce((result, device) => result + deviceCodexMetricValue(device, 'inflightThreadCount'), 0);
        const desktopCodexInflightTurns = onlineDevicesList.reduce((result, device) => result + deviceCodexMetricValue(device, 'inflightTurnCount'), 0);
        const desktopCodexLiveGap = Math.max(desktopCodexActiveThreads - runningCodex, 0);
        const observedRunningCodex = Math.max(runningCodex, desktopCodexInflightThreads);
        return {
          runningManaged,
          unmanagedTasks,
          waitingInput,
          failedManaged,
          queuedManaged,
          runningCodex,
          observedRunningCodex,
          standbyCodex,
          finishedCodex,
          lightweightCodex,
          onlineDevices,
          desktopCodexActiveThreads,
          desktopCodexInflightThreads,
          desktopCodexInflightTurns,
          desktopCodexLiveGap,
          combined: runningManaged + unmanagedTasks + observedRunningCodex
        };
      }

      function prioritizedControlItems(limit = 8) {
        const managed = filteredManagedRuns().sort(compareManagedRuns).slice(0, 5).map((run) => ({ type: 'managed', rank: managedAttentionRank(run.status), run }));
        const tasks = filteredIndependentTasks().sort(compareTasks).slice(0, 5).map((task) => ({ type: 'task', rank: taskAttentionRank(task), task }));
        const codex = filteredCodexSessions().sort(compareCodexSessions).slice(0, 5).map((session) => ({ type: 'codex', rank: codexAttentionRank(session), session }));
        return [...managed, ...tasks, ...codex]
          .sort((lhs, rhs) => lhs.rank - rhs.rank || (rhs.run?.updatedAt || rhs.task?.updatedAt || rhs.session?.updatedAt).localeCompare(lhs.run?.updatedAt || lhs.task?.updatedAt || lhs.session?.updatedAt || ''))
          .slice(0, limit);
      }

      function guideTargetTitle(target) {
        if (!target) return '';
        if (target.type === 'managed') return target.run?.title || target.run?.id || '当前 Orchard 任务';
        if (target.type === 'task') return target.task?.title || target.task?.id || '当前兼容任务';
        return target.session?.name || target.session?.preview || target.session?.id || '当前 Codex 对话';
      }

      function guideTargetSummary(target) {
        if (!target) return '';
        if (target.type === 'managed') return managedSummary(target.run);
        if (target.type === 'task') return taskSummary(target.task);
        return codexSummary(target.session);
      }

      function guideTargetDeviceID(target) {
        if (!target) return '';
        if (target.type === 'managed') return target.run?.deviceID || '';
        if (target.type === 'task') return target.task?.assignedDeviceID || '';
        return target.session?.deviceID || '';
      }

      function selectedDeviceID() {
        if (!state.selected) return '';
        if (state.selected.type === 'managed') {
          return state.detailType === 'managed'
            ? state.detail?.run?.deviceID || ''
            : managedRunByID(state.selected.runID)?.deviceID || '';
        }
        if (state.selected.type === 'task') {
          return state.detailType === 'task'
            ? state.detail?.task?.assignedDeviceID || ''
            : independentTaskByID(state.selected.taskID)?.assignedDeviceID || '';
        }
        return state.selected.deviceID || '';
      }

      function topObserveTarget() {
        return prioritizedControlItems(1)[0] || null;
      }

      function topContinueTarget() {
        const run = filteredManagedRuns().sort(compareManagedRuns).find((item) => canContinueManaged(item));
        if (run) return { type: 'managed', run };
        const session = filteredCodexSessions().sort(compareCodexSessions).find((item) => isCodexStandby(item));
        if (session) return { type: 'codex', session };
        return null;
      }

      function topStopTarget() {
        const run = filteredManagedRuns().sort(compareManagedRuns).find((item) => canInterruptManaged(item) || canStopManaged(item));
        if (run) return { type: 'managed', run };
        const task = filteredIndependentTasks().sort(compareTasks).find((item) => canStopTask(item));
        if (task) return { type: 'task', task };
        const session = filteredCodexSessions().sort(compareCodexSessions).find((item) => isCodexRunning(item));
        if (session) return { type: 'codex', session };
        return null;
      }

      function preferredHostConsoleDevice() {
        const selectedDevice = deviceByID(selectedDeviceID());
        if (deviceLocalConsoleInfo(selectedDevice)) return selectedDevice;

        const observeTarget = topObserveTarget();
        const observeDevice = deviceByID(guideTargetDeviceID(observeTarget));
        if (deviceLocalConsoleInfo(observeDevice)) return observeDevice;

        return (state.snapshot.devices || [])
          .filter((device) => device.status === 'online')
          .find((device) => deviceLocalConsoleInfo(device)) || null;
      }

      function renderMetrics() {
        const metrics = currentMetrics();
        const cards = [
          ['在线电脑', metrics.onlineDevices, '当前可接收任务的机器', 'green'],
          ['现在正在执行', metrics.combined, 'Orchard 任务 + 兼容任务 + Codex 对话综合统计', 'blue'],
          ['Orchard 任务', metrics.runningManaged, '你从这个页面发起的主链路任务', 'blue'],
          ['兼容任务', metrics.unmanagedTasks, '旧接口 /api/tasks 下发的任务', 'gold'],
          ['Codex 正在执行', metrics.observedRunningCodex, '对话 running + 桌面进行中线程兜底', 'blue'],
          ['桌面活跃对话', metrics.desktopCodexActiveThreads, '直接来自宿主机 Codex 桌面快照', 'blue'],
          ['尚未映射到控制面', metrics.desktopCodexLiveGap, '桌面端活跃，但会话桥还没精确对上', 'red'],
          ['可继续的 Codex 对话', metrics.standbyCodex, '当前没在执行，但上下文还保留着', 'gold'],
          ['进行中的回答轮次', metrics.desktopCodexInflightTurns, '即使会话桥没完全命中，也会在设备级显示', 'gold'],
          ['仅有简略摘要的对话', metrics.lightweightCodex, '只拿到列表摘要，点详情后会补更多内容', 'gold'],
          ['等你补一句', metrics.waitingInput, '这些 Orchard 任务正等你继续追问', 'gold'],
          ['失败任务', metrics.failedManaged, '建议优先打开日志和状态变化', 'red']
        ];
        metricsRoot.innerHTML = cards.map(([title, value, detail, tone]) => `
          <article class="metric ${tone}">
            <p class="metric-title">${escapeHTML(title)}</p>
            <p class="metric-value">${escapeHTML(value)}</p>
            <p class="metric-detail">${escapeHTML(detail)}</p>
          </article>`).join('');
      }

      function renderGuideCard(title, summary, note, buttonHTML, tags = []) {
        return `
          <article class="guide-card">
            <h3>${escapeHTML(title)}</h3>
            <p>${escapeHTML(summary)}</p>
            ${tags.length ? `<div class="detail-meta">${tags.map((tag) => `<span>${escapeHTML(tag)}</span>`).join('')}</div>` : ''}
            <div class="guide-note">${escapeHTML(note)}</div>
            <div class="row-actions">${buttonHTML}</div>
          </article>`;
      }

      function renderGuide() {
        const observeTarget = topObserveTarget();
        const continueTarget = topContinueTarget();
        const stopTarget = topStopTarget();
        const hostConsoleDevice = preferredHostConsoleDevice();
        const hostConsoleInfo = deviceLocalConsoleInfo(hostConsoleDevice);

        const cards = [];
        cards.push(renderGuideCard(
          '我想发起一个任务',
          '从网页端直接下发给 Orchard。最少只要选项目，再写一句你想让 Codex 做什么。',
          '如果不选电脑，控制面会自动挑一台当前在线、能接这个项目的宿主机。',
          '<button type="button" class="action-button primary" data-action="focus-section" data-target-id="launch">去发起新任务</button>',
          ['主链路', '最推荐']
        ));

        if (observeTarget) {
          const buttonHTML = observeTarget.type === 'managed'
            ? `<button type="button" class="action-button primary" data-action="select-managed" data-run-id="${escapeHTML(observeTarget.run.id)}" data-scroll-target="detail">去看这个任务</button>`
            : observeTarget.type === 'task'
              ? `<button type="button" class="action-button primary" data-action="select-task" data-task-id="${escapeHTML(observeTarget.task.id)}" data-scroll-target="detail">去看这个任务</button>`
              : `<button type="button" class="action-button primary" data-action="select-codex" data-device-id="${escapeHTML(observeTarget.session.deviceID)}" data-session-id="${escapeHTML(observeTarget.session.id)}" data-scroll-target="detail">去看这个对话</button>`;
          cards.push(renderGuideCard(
            '我想先观察进度',
            `当前最值得先看的是「${guideTargetTitle(observeTarget)}」。`,
            guideTargetSummary(observeTarget) || '点开后右侧会展示状态变化、日志和可操作按钮。',
            buttonHTML,
            ['观察', observeTarget.type === 'managed' ? 'Orchard 任务' : observeTarget.type === 'task' ? '兼容任务' : 'Codex 对话']
          ));
        } else {
          cards.push(renderGuideCard(
            '我想先观察进度',
            '当前还没有明显需要你立刻处理的执行项。',
            '新的 Orchard 任务、兼容任务或宿主机 Codex 对话出现后，这里会自动变成可点的入口。',
            '<button type="button" class="action-button" data-action="focus-section" data-target-id="control">去看总览</button>',
            ['观察']
          ));
        }

        if (continueTarget?.type === 'managed') {
          cards.push(renderGuideCard(
            '我想补一句继续追问',
            `最适合直接继续的是「${guideTargetTitle(continueTarget)}」。`,
            '点下去会直接弹出输入框，把你的下一句补充说明发给当前任务。',
            `<button type="button" class="action-button primary" data-action="continue-managed" data-run-id="${escapeHTML(continueTarget.run.id)}">继续这个 Orchard 任务</button>`,
            ['追问', '等待输入']
          ));
        } else if (continueTarget?.type === 'codex') {
          cards.push(renderGuideCard(
            '我想补一句继续追问',
            `最适合直接继续的是「${guideTargetTitle(continueTarget)}」。`,
            '点下去会直接把下一句发送到宿主机上已经存在的 Codex 对话。',
            `<button type="button" class="action-button primary" data-action="continue-codex" data-device-id="${escapeHTML(continueTarget.session.deviceID)}" data-session-id="${escapeHTML(continueTarget.session.id)}">继续这个 Codex 对话</button>`,
            ['追问', '宿主机对话']
          ));
        } else {
          cards.push(renderGuideCard(
            '我想补一句继续追问',
            '当前没有明显在等你回复的任务或对话。',
            '如果你只是想开始新的工作，直接发起新任务最快；如果要接着以前的上下文，去看 Codex 对话列表。',
            '<button type="button" class="action-button" data-action="focus-section" data-target-id="codex">去看可继续的对话</button>',
            ['追问']
          ));
        }

        if (stopTarget) {
          const buttonHTML = stopTarget.type === 'managed'
            ? `<button type="button" class="action-button warn" data-action="select-managed" data-run-id="${escapeHTML(stopTarget.run.id)}" data-scroll-target="detail">去处理中断 / 停止</button>`
            : stopTarget.type === 'task'
              ? `<button type="button" class="action-button warn" data-action="select-task" data-task-id="${escapeHTML(stopTarget.task.id)}" data-scroll-target="detail">去处理停止</button>`
              : `<button type="button" class="action-button warn" data-action="select-codex" data-device-id="${escapeHTML(stopTarget.session.deviceID)}" data-session-id="${escapeHTML(stopTarget.session.id)}" data-scroll-target="detail">去处理中断</button>`;
          cards.push(renderGuideCard(
            '我想终止 / 中断当前执行',
            `建议先定位到「${guideTargetTitle(stopTarget)}」，再决定是中断还是停止。`,
            '这里不会替你直接做破坏性动作，只会先把最相关的对象打开，避免误操作。',
            buttonHTML,
            ['终止', '先确认再执行']
          ));
        } else {
          cards.push(renderGuideCard(
            '我想终止 / 中断当前执行',
            '当前没有明显需要立刻中断或停止的执行项。',
            '如果你想确认有没有漏掉的运行中对象，可以去“现在最需要处理”里再看一眼。',
            '<button type="button" class="action-button" data-action="focus-section" data-target-id="control">去看当前最需要处理</button>',
            ['终止']
          ));
        }

        if (hostConsoleInfo && hostConsoleDevice) {
          cards.push(renderGuideCard(
            '我想看宿主机真相',
            `可以直接打开 ${hostConsoleDevice.name || hostConsoleDevice.deviceID} 的宿主机控制台。`,
            hostConsoleInfo.note,
            `<a class="action-button primary" href="${escapeHTML(hostConsoleInfo.url)}" target="_blank" rel="noreferrer">打开宿主机控制台</a>`,
            ['宿主机', hostConsoleDevice.name || hostConsoleDevice.deviceID]
          ));
        } else {
          cards.push(renderGuideCard(
            '我想看宿主机真相',
            '当前还没有可直接打开的宿主机控制台入口。',
            '等某台在线宿主机公开本地状态页后，这里会自动变成可点链接；现在也可以先去“在线电脑”看有哪些机器在线。',
            '<button type="button" class="action-button" data-action="focus-section" data-target-id="devices">去看在线电脑</button>',
            ['宿主机']
          ));
        }

        guideRoot.innerHTML = cards.join('');
      }

      function renderStatusStrip() {
        const metrics = currentMetrics();
        refreshMeta.textContent = `最近同步 ${formatTime(state.lastUpdatedAt.toISOString())}`;
        codexMeta.textContent = `现在执行中：总 ${metrics.combined} · Orchard 任务 ${metrics.runningManaged} · 兼容任务 ${metrics.unmanagedTasks} · Codex 观测 ${metrics.observedRunningCodex} · 已映射对话 ${metrics.runningCodex} · 桌面活跃对话 ${metrics.desktopCodexActiveThreads} · 未映射 ${metrics.desktopCodexLiveGap} · 进行中轮次 ${metrics.desktopCodexInflightTurns}`;
      }

      function renderManagedRow(run, options = {}) {
        const selected = isSelectedManaged(run.id) ? ' selected' : '';
        const actions = options.withActions ? renderManagedActions(run) : `<div class="row-actions"><button type="button" class="action-button primary" data-action="select-managed" data-run-id="${escapeHTML(run.id)}">查看详情</button></div>`;
        return `
          <article class="row${selected}">
            <div class="row-head">
              <div class="row-title-group">
                <span class="row-kicker">Orchard 任务</span>
                <h3 class="row-title">${escapeHTML(run.title || run.id)}</h3>
              </div>
              <span class="chip ${managedStatusTone(run.status)}">${escapeHTML(managedStatusLabel(run.status))}</span>
            </div>
            <div class="meta">
              <span>电脑 ${escapeHTML(managedDeviceLabel(run))}</span>
              <span>项目 ${escapeHTML(run.workspaceID || '—')}</span>
              <span>执行目录 ${escapeHTML(shortPath(run.cwd))}</span>
              <span>更新于 ${escapeHTML(formatTime(run.updatedAt))}</span>
            </div>
            <p class="summary">${escapeHTML(managedSummary(run))}</p>
            ${actions}
          </article>`;
      }

      function renderManagedActions(run) {
        const buttons = [
          `<button type="button" class="action-button primary" data-action="select-managed" data-run-id="${escapeHTML(run.id)}">查看详情</button>`
        ];
        if (run.deviceID) {
          const hostLink = hostConsoleLink(run.deviceID, '宿主机控制台');
          if (hostLink) buttons.push(hostLink);
        }
        if (canContinueManaged(run)) {
          buttons.push(`<button type="button" class="action-button" data-action="continue-managed" data-run-id="${escapeHTML(run.id)}">继续追问</button>`);
        }
        if (canInterruptManaged(run)) {
          buttons.push(`<button type="button" class="action-button warn" data-action="interrupt-managed" data-run-id="${escapeHTML(run.id)}">中断</button>`);
        }
        if (canStopManaged(run)) {
          buttons.push(`<button type="button" class="action-button danger" data-action="stop-managed" data-run-id="${escapeHTML(run.id)}">停止</button>`);
        }
        if (canRetryManaged(run)) {
          buttons.push(`<button type="button" class="action-button" data-action="retry-managed" data-run-id="${escapeHTML(run.id)}">重试</button>`);
        }
        return `<div class="row-actions">${buttons.join('')}</div>`;
      }

      function renderTaskRow(task, options = {}) {
        const selected = isSelectedTask(task.id) ? ' selected' : '';
        const summary = taskSummary(task);
        const pathTitle = shortPath(task.relativePath || task.workspaceID || '—');
        const actions = options.withActions
          ? renderTaskActions(task)
          : `<div class="row-actions"><button type="button" class="action-button primary" data-action="select-task" data-task-id="${escapeHTML(task.id)}">查看详情</button></div>`;
        return `
          <article class="row${selected}">
            <div class="row-head">
              <div class="row-title-group">
                <span class="row-kicker">兼容任务</span>
                <h3 class="row-title">${escapeHTML(task.title || task.id)}</h3>
              </div>
              <span class="chip ${taskStatusTone(task.status)}">${escapeHTML(taskStatusLabel(task.status))}</span>
            </div>
            <div class="meta">
              <span>电脑 ${escapeHTML(taskDeviceLabel(task))}</span>
              <span>项目 ${escapeHTML(task.workspaceID || '—')}</span>
              <span>执行目录 ${escapeHTML(pathTitle)}</span>
              <span>执行方式 ${escapeHTML(taskKindLabel(task.kind))}</span>
              <span>更新于 ${escapeHTML(formatTime(task.updatedAt))}</span>
            </div>
            <p class="summary">${escapeHTML(summary)}</p>
            ${actions}
          </article>`;
      }

      function renderTaskActions(task) {
        const buttons = [
          `<button type="button" class="action-button primary" data-action="select-task" data-task-id="${escapeHTML(task.id)}">查看详情</button>`
        ];
        if (canStopTask(task)) {
          buttons.push(`<button type="button" class="action-button danger" data-action="stop-task" data-task-id="${escapeHTML(task.id)}">${escapeHTML(taskStopLabel(task))}</button>`);
        } else if (task.status === 'stopRequested') {
          buttons.push('<button type="button" class="action-button" disabled>停止中</button>');
        }
        return `<div class="row-actions">${buttons.join('')}</div>`;
      }

      function renderCodexRow(session, options = {}) {
        const selected = isSelectedCodex(session.deviceID, session.id) ? ' selected' : '';
        const summary = codexSummary(session);
        const actions = options.withActions ? renderCodexActions(session) : `<div class="row-actions"><button type="button" class="action-button primary" data-action="select-codex" data-device-id="${escapeHTML(session.deviceID)}" data-session-id="${escapeHTML(session.id)}">查看详情</button></div>`;
        return `
          <article class="row${selected}">
            <div class="row-head">
              <div class="row-title-group">
                <span class="row-kicker">本机 Codex 对话</span>
                <h3 class="row-title">${escapeHTML(session.name || session.preview || session.id)}</h3>
              </div>
              <span class="chip ${codexDisplayStateTone(session)}">${escapeHTML(codexDisplayStateLabel(session))}</span>
            </div>
            <div class="meta">
              <span>电脑 ${escapeHTML(session.deviceName || session.deviceID)}</span>
              <span>项目 ${escapeHTML(session.workspaceID || '—')}</span>
              <span>来自 ${escapeHTML(session.source || '未知')}</span>
              <span>最近状态 ${escapeHTML(codexLastTurnLabel(session))}</span>
              <span>目录 ${escapeHTML(shortPath(session.cwd))}</span>
              <span>更新于 ${escapeHTML(formatTime(session.updatedAt))}</span>
            </div>
            <p class="summary">${escapeHTML(summary)}</p>
            ${actions}
          </article>`;
      }

      function renderCodexActions(session) {
        const buttons = [
          `<button type="button" class="action-button primary" data-action="select-codex" data-device-id="${escapeHTML(session.deviceID)}" data-session-id="${escapeHTML(session.id)}">查看详情</button>`,
          `<button type="button" class="action-button" data-action="continue-codex" data-device-id="${escapeHTML(session.deviceID)}" data-session-id="${escapeHTML(session.id)}">继续追问</button>`
        ];
        const hostLink = hostConsoleLink(session.deviceID, '宿主机控制台');
        if (hostLink) buttons.push(hostLink);
        if (isCodexRunning(session)) {
          buttons.push(`<button type="button" class="action-button warn" data-action="interrupt-codex" data-device-id="${escapeHTML(session.deviceID)}" data-session-id="${escapeHTML(session.id)}">中断</button>`);
        }
        return `<div class="row-actions">${buttons.join('')}</div>`;
      }

      function renderCodexDiagnostics() {
        const sessions = filteredCodexSessions().sort(compareCodexSessions);
        const metrics = currentMetrics();
        if (!sessions.length && metrics.desktopCodexActiveThreads <= 0 && metrics.desktopCodexInflightTurns <= 0) {
          codexDiagnosticsRoot.innerHTML = '';
          return;
        }
        const diagnostics = buildCodexDiagnostics(sessions, metrics);
        codexDiagnosticsRoot.innerHTML = `
          <div class="detail-card diagnostic-card">
            <h4>诊断视图</h4>
            <p class="footnote">${escapeHTML(diagnostics.summary)}</p>
            <div class="detail-meta">
              <span>来源 ${escapeHTML(diagnostics.sourceSummary)}</span>
              <span>轮次 ${escapeHTML(diagnostics.turnSummary)}</span>
              <span>判断 ${escapeHTML(diagnostics.conclusion)}</span>
            </div>
          </div>`;
      }

      function renderControl() {
        const combined = prioritizedControlItems(8);

        if (!combined.length) {
          controlRoot.innerHTML = filtersApplied()
            ? renderEmpty('当前筛选下没有可处理项目。', '你可以放宽搜索词、切回全部设备，或取消“只看活跃项”。')
            : renderEmpty('当前没有需要你立即处理的内容。', '新的 Orchard 任务、兼容任务或宿主机 Codex 对话出现后，这里会自动刷新。');
          return;
        }

        controlRoot.innerHTML = combined.map((item) => item.type === 'managed'
          ? renderManagedRow(item.run, { withActions: true })
          : item.type === 'task'
            ? renderTaskRow(item.task, { withActions: true })
          : renderCodexRow(item.session, { withActions: true })
        ).join('');
      }

      function renderRuns() {
        const runs = filteredManagedRuns().sort(compareManagedRuns).slice(0, 24);
        runsRoot.innerHTML = runs.length
          ? runs.map((run) => renderManagedRow(run)).join('')
          : filtersApplied()
            ? renderEmpty('当前筛选下没有 Orchard 任务。', '你可以清空筛选，或切到别的电脑继续查看。')
            : renderEmpty('当前还没有通过 Orchard 发起的任务。', '你从网页端或移动端创建新任务后，这里会出现执行记录。');
      }

      function renderTasks() {
        const tasks = filteredIndependentTasks().sort(compareTasks).slice(0, 24);
        tasksRoot.innerHTML = tasks.length
          ? tasks.map((task) => renderTaskRow(task)).join('')
          : filtersApplied()
            ? renderEmpty('当前筛选下没有兼容任务。', '你可以清空筛选，或切到别的电脑继续查看。')
            : renderEmpty('当前没有兼容任务。', '只有直接通过 /api/tasks 下发的旧链路任务会显示在这里。');
      }

      function renderCodex() {
        const sessions = filteredCodexSessions().sort(compareCodexSessions).slice(0, 24);
        codexRoot.innerHTML = sessions.length
          ? sessions.map((session) => renderCodexRow(session)).join('')
          : filtersApplied()
            ? renderEmpty('当前筛选下没有 Codex 对话。', '你可以取消电脑限制，或关闭“只看活跃项”。')
            : renderEmpty('当前没有可读取的本机 Codex 对话。', '确认 OrchardAgent 已在线，并且宿主机桌面端存在可读取的 Codex 对话；若只看到轻摘要，打开详情后会继续补内容。');
      }

      function renderDevices() {
        const runCounts = (state.snapshot.managedRuns || []).reduce((result, run) => {
          if (occupiesManagedSlot(run.status) && run.deviceID) {
            result[run.deviceID] = (result[run.deviceID] || 0) + 1;
          }
          return result;
        }, {});
        const deviceCombinedRunningCount = (device) =>
          (runCounts[device.deviceID] || 0)
          + unmanagedRunningTaskCountForDevice(device.deviceID)
          + observedRunningCodexSessionsForDevice(device);

        const devices = filteredDevices()
          .filter((device) => device.status === 'online')
          .sort((lhs, rhs) => {
            const lhsCount = deviceCombinedRunningCount(lhs);
            const rhsCount = deviceCombinedRunningCount(rhs);
            if (lhsCount !== rhsCount) return rhsCount - lhsCount;
            return (rhs.metrics?.loadAverage || 0) - (lhs.metrics?.loadAverage || 0);
          })
          .slice(0, 10);

        devicesRoot.innerHTML = devices.length
          ? devices.map((device) => {
            const codexSummary = device.capabilities?.includes('codex')
              ? `${deviceCodexSummary(device)} 最近快照 ${deviceCodexSnapshotText(device)}；`
              : '';
            const codexGapSummary = device.capabilities?.includes('codex')
              ? deviceCodexGapSummary(device)
              : '';
            const codexGapMeta = device.capabilities?.includes('codex') && deviceCodexLiveGap(device) > 0
              ? `<span>未映射 ${escapeHTML(deviceCodexLiveGap(device))}</span>`
              : '';
            const localConsole = deviceLocalConsoleInfo(device);
            return `
            <article class="row">
              <div class="row-head">
                <div class="row-title-group">
                  <span class="row-kicker">${escapeHTML(platformLabel(device.platform))}</span>
                  <h3 class="row-title">${escapeHTML(device.name || device.deviceID)}</h3>
                </div>
                <span class="chip ${device.status === 'online' ? 'green' : 'gray'}">${escapeHTML(device.status === 'online' ? '在线' : '离线')}</span>
              </div>
              <div class="meta">
                <span>主机 ${escapeHTML(device.hostName || '—')}</span>
                <span>总运行 ${escapeHTML(deviceCombinedRunningCount(device))}</span>
                <span>Orchard 任务 ${escapeHTML(runCounts[device.deviceID] || 0)}</span>
                <span>兼容任务 ${escapeHTML(unmanagedRunningTaskCountForDevice(device.deviceID))}</span>
                <span>Codex 执行中 ${escapeHTML(observedRunningCodexSessionsForDevice(device))}</span>
                <span>负载 ${escapeHTML(device.metrics?.loadAverage?.toFixed(2) || '--')}</span>
                <span>CPU ${escapeHTML(device.metrics?.cpuPercentApprox ? Math.round(device.metrics.cpuPercentApprox) + '%' : '--')}</span>
                <span>内存 ${escapeHTML(device.metrics?.memoryPercent ? Math.round(device.metrics.memoryPercent) + '%' : '--')}</span>
                <span>Codex 活跃 ${escapeHTML(deviceCodexMetricDisplay(device, 'activeThreadCount'))}</span>
                <span>轮次 ${escapeHTML(deviceCodexMetricDisplay(device, 'inflightTurnCount'))}</span>
                ${codexGapMeta}
              </div>
              <p class="summary">能力：${escapeHTML((device.capabilities || []).map(capabilityLabel).join(' / ') || '暂无上报')}；${escapeHTML(codexSummary)}${codexGapSummary ? `${escapeHTML(codexGapSummary)}；` : ''}${localConsole ? `宿主机控制台已开启；` : ''}设备心跳更新于 ${escapeHTML(formatTime(device.lastSeenAt))}。</p>
              ${localConsole ? `
              <div class="row-actions">
                ${hostConsoleLink(device.deviceID)}
                <span class="status-pill">${escapeHTML(localConsole.note)}</span>
              </div>` : ''}
            </article>`;
          }).join('')
          : filtersApplied()
            ? renderEmpty('当前筛选下没有在线设备。', '你可以切回全部设备，或放宽搜索词。')
            : renderEmpty('当前没有在线设备。', '设备恢复心跳后，会自动出现在这里。');
      }

      function renderWorkspaces() {
        const workspaces = filteredWorkspaces();
        workspacesRoot.innerHTML = workspaces.length
          ? workspaces.map((workspace) => `
            <article class="row workspace-row">
              <div class="meta">
                <span class="workspace-badge">${escapeHTML(workspace.id)}</span>
                <span>${escapeHTML(workspace.name || workspace.id)}</span>
              </div>
              <div><code>${escapeHTML(workspace.rootPath || '')}</code></div>
            </article>`).join('')
          : filtersApplied()
            ? renderEmpty('当前筛选下没有工作区。', '你可以清空设备筛选或改搜别的目录。')
            : renderEmpty('当前没有工作区数据。', '设备完成注册并上报工作区后，这里会显示可用范围。');
      }

      function renderProjectContextDetailCard(deviceID, workspaceID, options = {}) {
        if (!deviceID) {
          return `
            <div class="detail-card">
              <h4>项目上下文</h4>
              <p class="footnote">${escapeHTML(options.missingDeviceMessage || '运行还没有分配设备，暂时无法读取项目上下文。')}</p>
            </div>`;
        }
        if (!workspaceID) {
          return `
            <div class="detail-card">
              <h4>项目上下文</h4>
              <p class="footnote">${escapeHTML(options.missingWorkspaceMessage || '当前会话还没有匹配到 Orchard 工作区，所以暂时没有 project-context。')}</p>
            </div>`;
        }

        const entry = projectContextSummaryState(deviceID, workspaceID);
        if (!entry || entry.status === 'idle' || entry.status === 'loading') {
          return `
            <div class="detail-card">
              <h4>项目上下文</h4>
              <p class="footnote">正在读取项目上下文…</p>
            </div>`;
        }

        if (entry.status === 'error' || entry.errorMessage) {
          return `
            <div class="detail-card">
              <h4>项目上下文</h4>
              <p class="footnote">${escapeHTML(entry.errorMessage || '项目上下文读取失败')}</p>
            </div>`;
        }

        const response = entry.response || {};
        if (!response.available) {
          return `
            <div class="detail-card">
              <h4>项目上下文</h4>
              <div class="detail-meta">
                <span>工作区 ${escapeHTML(workspaceID)}</span>
                <span>当前未配置</span>
              </div>
              <p class="footnote">${escapeHTML(options.unavailableMessage || '当前工作区没有项目上下文，Codex 仍可继续执行，但不会自动注入部署、主机、数据库等项目事实。')}</p>
            </div>`;
        }

        const summary = response.summary || {};
        const lines = Array.isArray(summary.renderedLines) ? summary.renderedLines.slice(0, 4) : [];
        const projectName = summary.projectName || summary.projectID || workspaceID;
        return `
          <div class="detail-card">
            <h4>项目上下文</h4>
            <div class="detail-meta">
              <span>工作区 ${escapeHTML(workspaceID)}</span>
              <span>项目 ${escapeHTML(projectName)}</span>
              <span>${escapeHTML(projectContextSummaryBadge(response))}</span>
            </div>
            ${summary.summary ? `<p class="footnote">${escapeHTML(summary.summary)}</p>` : ''}
            ${lines.length ? `
              <div class="project-context-lines">
                ${lines.map((line) => `<code>${escapeHTML(line)}</code>`).join('')}
              </div>` : ''
            }
            <div class="row-actions">
              <a class="action-button" href="${escapeHTML(projectContextSummaryURL(deviceID, workspaceID))}" target="_blank" rel="noreferrer">查看 JSON</a>
            </div>
          </div>`;
      }

      function renderHostConsoleDetailCard(deviceID, options = {}) {
        if (!deviceID) {
          return `
            <div class="detail-card">
              <h4>宿主机控制台</h4>
              <p class="footnote">${escapeHTML(options.missingDeviceMessage || '当前还没有落到具体设备，所以暂时不能跳到宿主机控制台。')}</p>
            </div>`;
        }

        const device = deviceByID(deviceID);
        if (!device) {
          return `
            <div class="detail-card">
              <h4>宿主机控制台</h4>
              <p class="footnote">控制面还没拿到这台机器的最新地址，刷新后再试。</p>
            </div>`;
        }

        const localConsole = deviceLocalConsoleInfo(device);
        if (!localConsole) {
          return `
            <div class="detail-card">
              <h4>宿主机控制台</h4>
              <p class="footnote">${escapeHTML(options.unavailableMessage || '这台机器还没有公开宿主机控制台地址，所以当前只能通过控制面侧观察。')}</p>
            </div>`;
        }

        return `
          <div class="detail-card">
            <h4>宿主机控制台</h4>
            <p class="footnote">${escapeHTML(options.availableMessage || '如果你想看宿主机真实日志、确认是不是在等待输入，或者直接从宿主机侧补充说明 / 中断 / 终止，就打开这台机器的宿主机控制台。')}</p>
            <div class="row-actions">
              ${hostConsoleLink(deviceID)}
            </div>
            <p class="footnote">${escapeHTML(localConsole.note)}</p>
          </div>`;
      }

      function renderPromptProjectContextSummary(deviceID, workspaceID) {
        const entry = projectContextSummaryState(deviceID, workspaceID);
        if (!entry || entry.status === 'idle' || entry.status === 'loading') {
          return `
            <div class="detail-card">
              <h4>项目上下文</h4>
              <p class="footnote">正在读取当前工作区的项目摘要…</p>
            </div>`;
        }

        if (entry.status === 'error' || entry.errorMessage) {
          return `
            <div class="detail-card">
              <h4>项目上下文</h4>
              <p class="footnote">${escapeHTML(entry.errorMessage || '项目上下文读取失败')}</p>
            </div>`;
        }

        const response = entry.response || {};
        if (!response.available) {
          return `
            <div class="detail-card">
              <h4>项目上下文</h4>
              <div class="detail-meta">
                <span>工作区 ${escapeHTML(workspaceID)}</span>
                <span>当前未配置</span>
              </div>
              <p class="footnote">当前工作区还没有 project-context，所以这里只能发送自由文本。</p>
            </div>`;
        }

        const summary = response.summary || {};
        return `
          <div class="detail-card">
            <h4>项目上下文</h4>
            <div class="detail-meta">
              <span>工作区 ${escapeHTML(workspaceID)}</span>
              <span>项目 ${escapeHTML(summary.projectName || summary.projectID || workspaceID)}</span>
              <span>${escapeHTML(projectContextSummaryBadge(response))}</span>
            </div>
            ${summary.summary ? `<p class="footnote">${escapeHTML(summary.summary)}</p>` : ''}
          </div>`;
      }

      function renderPromptProjectCommandCards(deviceID, workspaceID, intent = 'continueConversation') {
        const entry = projectContextCommandState(deviceID, workspaceID);
        if (!entry || entry.status === 'idle' || entry.status === 'loading') {
          return `
            <div class="detail-card">
              <h4>标准操作命令</h4>
              <p class="footnote">正在读取当前工作区的标准操作命令…</p>
            </div>`;
        }

        if (entry.status === 'error' || entry.errorMessage) {
          return `
            <div class="detail-card">
              <h4>标准操作命令</h4>
              <p class="footnote">${escapeHTML(entry.errorMessage || '标准操作命令读取失败')}</p>
            </div>`;
        }

        if (!entry.available) {
          return `
            <div class="detail-card">
              <h4>标准操作命令</h4>
              <p class="footnote">当前工作区还没有 project-context，暂时不能快捷插入标准命令。</p>
            </div>`;
        }

        if (!entry.items.length) {
          return `
            <div class="detail-card">
              <h4>标准操作命令</h4>
              <p class="footnote">当前项目还没有登记标准操作命令；可以继续输入自由文本，或先把常用动作维护到 project-context.commands。</p>
            </div>`;
        }

        return `
          <div class="detail-card">
            <h4>标准操作命令</h4>
            <p class="footnote">点击即可把结构化执行提示词插入输入框，交给 Codex 继续完成。</p>
            <div class="project-command-list">
              ${entry.items.slice(0, 4).map((item) => {
                const scopeSummary = projectCommandScopeSummary(item);
                const hasMissingCredentials = projectCommandHasMissingCredentials(item);
                return `
                  <article class="project-command-card ${hasMissingCredentials ? 'warn' : ''}">
                    <div class="project-command-head">
                      <div class="project-command-title-group">
                        <h5 class="project-command-title">${escapeHTML(item?.command?.name || item?.command?.id || '未命名命令')}</h5>
                        <div class="project-command-id">${escapeHTML(item?.command?.id || 'unknown')}</div>
                      </div>
                      <span class="chip ${hasMissingCredentials ? 'gold' : 'blue'}">${escapeHTML(projectCommandRunnerLabel(item?.command?.runner))}</span>
                    </div>
                    ${scopeSummary ? `<p class="footnote">${escapeHTML(scopeSummary)}</p>` : ''}
                    <pre>${escapeHTML(item?.command?.command || '')}</pre>
                    <div class="detail-meta">
                      <span>凭据 ${escapeHTML(projectCommandCredentialSummary(item?.credentials))}</span>
                    </div>
                    <div class="row-actions">
                      <button
                        type="button"
                        class="action-button ${hasMissingCredentials ? 'warn' : 'primary'}"
                        data-action="insert-project-command"
                        data-device-id="${escapeHTML(deviceID)}"
                        data-workspace-id="${escapeHTML(workspaceID)}"
                        data-command-id="${escapeHTML(item?.command?.id || '')}"
                        data-intent="${escapeHTML(intent)}"
                      >插入到提示词</button>
                    </div>
                  </article>`;
              }).join('')}
            </div>
            ${entry.items.length > 4 ? `<p class="footnote">已显示前 4 条，共 ${escapeHTML(entry.items.length)} 条；完整列表可通过项目上下文接口继续查询。</p>` : ''}
          </div>`;
      }

      function renderPromptProjectContext() {
        if (!promptProjectContext) return;

        const action = state.promptAction;
        if (!action) {
          promptProjectContext.innerHTML = '';
          return;
        }

        if (!action.deviceID) {
          promptProjectContext.innerHTML = `
            <div class="detail-card">
              <h4>标准操作命令</h4>
              <p class="footnote">当前 run 还没有落到具体设备，所以暂时不能读取项目上下文和标准操作命令。</p>
            </div>`;
          return;
        }

        if (!action.workspaceID) {
          promptProjectContext.innerHTML = `
            <div class="detail-card">
              <h4>标准操作命令</h4>
              <p class="footnote">当前会话还没有匹配到 Orchard 工作区，所以这里只能发送自由文本继续追问。</p>
            </div>`;
          return;
        }

        promptProjectContext.innerHTML = [
          renderPromptProjectContextSummary(action.deviceID, action.workspaceID),
          renderPromptProjectCommandCards(action.deviceID, action.workspaceID, action.intent || 'continueConversation')
        ].join('');
      }

      function renderError() {
        errorRoot.innerHTML = state.errorMessage ? `<div class="alert">${escapeHTML(state.errorMessage)}</div>` : '';
      }

      function renderDetail() {
        if (!state.selected) {
          detailRoot.innerHTML = renderEmpty('先选一个任务或对话。', '如果你只是测试主链路，优先点“现在最需要处理”或“通过 Orchard 发起的任务”里的条目。');
          return;
        }
        if (state.detailLoading) {
          detailRoot.innerHTML = renderEmpty('正在加载详情...', '浏览器正在读取状态变化、日志和可操作按钮。');
          return;
        }
        if (state.detailError) {
          detailRoot.innerHTML = `<div class="alert">${escapeHTML(state.detailError)}</div>`;
          return;
        }
        if (state.detailType === 'managed' && state.detail) {
          detailRoot.innerHTML = renderManagedDetail(state.detail);
          return;
        }
        if (state.detailType === 'task' && state.detail) {
          detailRoot.innerHTML = renderTaskDetail(state.detail);
          return;
        }
        if (state.detailType === 'codex' && state.detail) {
          detailRoot.innerHTML = renderCodexDetail(state.detail);
          return;
        }
        detailRoot.innerHTML = renderEmpty('暂无详情。', '当前选择项还没有可展示的更多内容。');
      }

      function renderActionCoachCard(title, summary, tags = []) {
        return `
          <div class="detail-card">
            <h4>${escapeHTML(title)}</h4>
            <p class="footnote">${escapeHTML(summary)}</p>
            ${tags.length ? `<div class="detail-meta">${tags.map((tag) => `<span>${escapeHTML(tag)}</span>`).join('')}</div>` : ''}
          </div>`;
      }

      function managedCoachCard(run) {
        let summary = '先看状态变化和日志，再决定要继续追问、重试还是打开宿主机控制台核对真实情况。';
        const tags = [managedStatusLabel(run.status)];
        if (run.deviceID) tags.push(managedDeviceLabel(run));

        if (run.status === 'waitingInput') {
          summary = '这个 Orchard 任务正在等你补一句，最直接的下一步就是点“继续追问”；如果你不想让它继续跑，也可以点“中断”或“停止”。';
          tags.push('推荐：继续追问');
        } else if (run.status === 'running') {
          summary = '这个 Orchard 任务正在执行，先看输出日志和状态变化；如果你想补充约束，可以继续追问，感觉卡住时再中断。';
          tags.push('推荐：先看日志');
        } else if (run.status === 'queued' || run.status === 'launching') {
          summary = '这个 Orchard 任务还在排队或刚启动，先观察即可；真正落到宿主机之后，这里会出现更明确的宿主机控制台入口。';
          tags.push('推荐：先观察');
        } else if (run.status === 'failed') {
          summary = '这次运行失败了，建议先看状态变化和输出日志确认原因；如果只是偶发问题，可以直接点“重试”。';
          tags.push('推荐：先排查');
        } else if (run.status === 'succeeded') {
          summary = '这一轮已经完成，适合先复盘结果和日志；如果你要再来一轮，可以直接点“重试”。';
          tags.push('推荐：复盘或重试');
        } else if (run.status === 'interrupted' || run.status === 'cancelled') {
          summary = '这一轮已经被中断或停止；如果还想继续推进，最稳妥的方式是点“重试”重新拉起一轮。';
          tags.push('推荐：重试');
        } else if (run.status === 'stopRequested') {
          summary = '停止请求已经发出，先观察状态变化和日志，等宿主机确认停下来。';
          tags.push('推荐：等待停止');
        }

        return renderActionCoachCard('现在最建议怎么做', summary, tags);
      }

      function taskCoachCard(task) {
        let summary = '这是旧接口任务，优先看日志和状态变化；如需终止，直接点“停止”即可。';
        const tags = [taskStatusLabel(task.status), taskKindLabel(task.kind)];
        if (task.assignedDeviceID) tags.push(taskDeviceLabel(task));

        if (task.status === 'queued') {
          summary = '这个旧接口任务还在排队，先观察即可；一旦落到宿主机并开始输出，日志会自动刷新。';
          tags.push('推荐：先观察');
        } else if (task.status === 'running') {
          summary = '这个旧接口任务正在执行，先看日志判断是否正常推进；如果想终止，就直接点“停止”。';
          tags.push('推荐：看日志或停止');
        } else if (task.status === 'stopRequested') {
          summary = '停止请求已经发出，先等宿主机确认收敛；日志里通常会先出现最后一批输出。';
          tags.push('推荐：等待停止');
        } else if (['succeeded', 'failed', 'cancelled'].includes(task.status)) {
          summary = '这个旧接口任务已经结束，适合先看执行内容和输出日志做复盘。';
          tags.push('推荐：复盘');
        }

        return renderActionCoachCard('现在最建议怎么做', summary, tags);
      }

      function codexCoachCard(session) {
        let summary = '这是宿主机上真实存在的 Codex 对话；适合先看时间线，再决定要不要继续追问或打开宿主机控制台。';
        const tags = [codexDisplayStateLabel(session), session.deviceName || session.deviceID];

        if (isCodexRunning(session)) {
          summary = '这个 Codex 对话正在执行，先看时间线和轮次；如果你要临时打断它，可以点“中断”。';
          tags.push('推荐：先观察');
        } else if (isCodexStandby(session)) {
          summary = '这个 Codex 对话当前不在执行，但上下文还在，最直接的下一步就是点“继续追问”。';
          tags.push('推荐：继续追问');
        } else if (isCodexFinished(session)) {
          summary = '这个 Codex 对话最近一轮已经结束，适合先复盘时间线；如果还想接着问，也可以继续追问开下一轮。';
          tags.push('推荐：复盘或继续');
        }

        return renderActionCoachCard('现在最建议怎么做', summary, tags);
      }

      function renderManagedDetail(detail) {
        const run = detail.run;
        const events = [...(detail.events || [])].sort((lhs, rhs) => new Date(rhs.createdAt) - new Date(lhs.createdAt)).slice(0, 30);
        const logs = [...(detail.logs || [])].sort((lhs, rhs) => new Date(rhs.createdAt) - new Date(lhs.createdAt)).slice(0, 120);
        const actions = [`<button type="button" class="detail-action primary" data-action="select-managed" data-run-id="${escapeHTML(run.id)}">保持选中</button>`];
        if (canContinueManaged(run)) actions.push(`<button type="button" class="detail-action" data-action="continue-managed" data-run-id="${escapeHTML(run.id)}">继续追问</button>`);
        if (canInterruptManaged(run)) actions.push(`<button type="button" class="detail-action warn" data-action="interrupt-managed" data-run-id="${escapeHTML(run.id)}">中断</button>`);
        if (canStopManaged(run)) actions.push(`<button type="button" class="detail-action danger" data-action="stop-managed" data-run-id="${escapeHTML(run.id)}">停止</button>`);
        if (canRetryManaged(run)) actions.push(`<button type="button" class="detail-action" data-action="retry-managed" data-run-id="${escapeHTML(run.id)}">重试</button>`);
        return `
          <div class="detail-shell">
            <div class="detail-header">
              <div class="detail-meta">
                <span>通过 Orchard 发起</span>
                <span>${escapeHTML(managedStatusLabel(run.status))}</span>
                <span>${escapeHTML(managedDeviceLabel(run))}</span>
              </div>
              <h3>${escapeHTML(run.title || run.id)}</h3>
              <p class="detail-subtitle">${escapeHTML(managedSummary(run))}</p>
              <div class="detail-actions">${actions.join('')}</div>
            </div>
            ${managedCoachCard(run)}
            <div class="detail-card">
              <h4>基础信息</h4>
              <div class="detail-meta">
                <span>运行 ID ${escapeHTML(run.id)}</span>
                <span>内部 task ID ${escapeHTML(run.taskID || '—')}</span>
                <span>关联 Codex 对话 ${escapeHTML(run.codexSessionID || '—')}</span>
                <span>项目 ${escapeHTML(run.workspaceID || '—')}</span>
                <span>执行目录 ${escapeHTML(run.cwd || '—')}</span>
              </div>
            </div>
            ${renderHostConsoleDetailCard(run.deviceID, {
              missingDeviceMessage: '运行还没有分配设备。等它真正落到某台宿主机后，这里会出现宿主机控制台入口。'
            })}
            ${renderProjectContextDetailCard(run.deviceID, run.workspaceID, {
              missingDeviceMessage: '运行还没有分配设备。等控制面把任务落到具体设备后，这里会自动显示项目上下文。'
            })}
            ${run.lastUserPrompt ? `<div class="detail-card"><h4>你最近发给它的话</h4><pre>${escapeHTML(run.lastUserPrompt)}</pre></div>` : ''}
            <div class="detail-block">
              <h4>状态变化</h4>
              <div class="detail-list">
                ${events.length ? events.map((event) => `
                  <article class="detail-list-item">
                    <div class="detail-list-item-head">
                      <div class="detail-list-item-title">${escapeHTML(event.title || event.kind)}</div>
                      <span class="chip ${managedStatusTone(run.status)}">${escapeHTML(formatTime(event.createdAt))}</span>
                    </div>
                    ${event.body ? `<div class="detail-list-item-body">${escapeHTML(event.body)}</div>` : ''}
                  </article>`).join('') : renderEmpty('当前没有状态变化记录。', '刷新后会重新读取控制面的运行时间线。')}
              </div>
            </div>
            <div class="detail-block">
              <h4>输出日志</h4>
              <div class="detail-list">
                ${logs.length ? logs.map((log) => `
                  <article class="detail-list-item">
                    <div class="detail-list-item-head">
                      <div class="detail-list-item-title">${escapeHTML(formatTime(log.createdAt))}</div>
                    </div>
                    <div class="detail-list-item-body">${escapeHTML(log.line || '')}</div>
                  </article>`).join('') : renderEmpty('当前还没有输出日志。', '当 Agent 把运行输出同步到控制面后，这里会自动更新。')}
              </div>
            </div>
          </div>`;
      }

      function renderTaskDetail(detail) {
        const task = detail.task;
        const logs = [...(detail.logs || [])].sort((lhs, rhs) => new Date(rhs.createdAt) - new Date(lhs.createdAt)).slice(0, 120);
        const actions = [`<button type="button" class="detail-action primary" data-action="select-task" data-task-id="${escapeHTML(task.id)}">保持选中</button>`];
        if (canStopTask(task)) actions.push(`<button type="button" class="detail-action danger" data-action="stop-task" data-task-id="${escapeHTML(task.id)}">${escapeHTML(taskStopLabel(task))}</button>`);
        return `
          <div class="detail-shell">
            <div class="detail-header">
              <div class="detail-meta">
                <span>兼容任务</span>
                <span>${escapeHTML(taskStatusLabel(task.status))}</span>
                <span>${escapeHTML(taskDeviceLabel(task))}</span>
              </div>
              <h3>${escapeHTML(task.title || task.id)}</h3>
              <p class="detail-subtitle">${escapeHTML(taskSummary(task))}</p>
              <div class="detail-actions">${actions.join('')}</div>
            </div>
            ${taskCoachCard(task)}
            <div class="detail-card">
              <h4>基础信息</h4>
              <div class="detail-meta">
                <span>任务 ID ${escapeHTML(task.id)}</span>
                <span>执行方式 ${escapeHTML(taskKindLabel(task.kind))}</span>
                <span>项目 ${escapeHTML(task.workspaceID || '—')}</span>
                <span>执行目录 ${escapeHTML(task.relativePath || '工作区根目录')}</span>
                <span>优先级 ${escapeHTML(taskPriorityLabel(task.priority))}</span>
                <span>退出码 ${escapeHTML(task.exitCode ?? '—')}</span>
              </div>
              ${task.summary ? `<p class="footnote">${escapeHTML(task.summary)}</p>` : ''}
            </div>
            ${renderHostConsoleDetailCard(task.assignedDeviceID, {
              missingDeviceMessage: '当前兼容任务还没有落到具体设备，所以这里暂时没有宿主机控制台入口。'
            })}
            <div class="detail-card">
              <h4>执行内容</h4>
              <pre>${escapeHTML(taskPayloadPreview(task) || '暂无内容')}</pre>
            </div>
            <div class="detail-card">
              <h4>时间</h4>
              <div class="detail-meta">
                <span>创建于 ${escapeHTML(formatTime(task.createdAt))}</span>
                <span>更新于 ${escapeHTML(formatTime(task.updatedAt))}</span>
                <span>开始于 ${escapeHTML(task.startedAt ? formatTime(task.startedAt) : '—')}</span>
                <span>结束于 ${escapeHTML(task.finishedAt ? formatTime(task.finishedAt) : '—')}</span>
              </div>
            </div>
            <div class="detail-block">
              <h4>输出日志</h4>
              <div class="detail-list">
                ${logs.length ? logs.map((log) => `
                  <article class="detail-list-item">
                    <div class="detail-list-item-head">
                      <div class="detail-list-item-title">${escapeHTML(formatTime(log.createdAt))}</div>
                      <span class="chip gray">${escapeHTML(log.deviceID || '—')}</span>
                    </div>
                    <div class="detail-list-item-body">${escapeHTML(log.line || '')}</div>
                  </article>`).join('') : renderEmpty('当前还没有输出日志。', '任务开始输出后，这里会自动刷新。')}
              </div>
            </div>
          </div>`;
      }

      function renderCodexDetail(detail) {
        const session = detail.session;
        const items = [...(detail.items || [])].sort((lhs, rhs) => lhs.sequence - rhs.sequence).slice(-80);
        const turns = [...(detail.turns || [])].sort((lhs, rhs) => String(rhs.id).localeCompare(String(lhs.id))).slice(0, 20);
        const actions = [
          `<button type="button" class="detail-action primary" data-action="select-codex" data-device-id="${escapeHTML(session.deviceID)}" data-session-id="${escapeHTML(session.id)}">保持选中</button>`,
          `<button type="button" class="detail-action" data-action="continue-codex" data-device-id="${escapeHTML(session.deviceID)}" data-session-id="${escapeHTML(session.id)}">继续追问</button>`
        ];
        if (isCodexRunning(session)) actions.push(`<button type="button" class="detail-action warn" data-action="interrupt-codex" data-device-id="${escapeHTML(session.deviceID)}" data-session-id="${escapeHTML(session.id)}">中断</button>`);
        return `
          <div class="detail-shell">
            <div class="detail-header">
              <div class="detail-meta">
                <span>本机 Codex 对话</span>
                <span>${escapeHTML(codexDisplayStateLabel(session))}</span>
                <span>${escapeHTML(session.deviceName || session.deviceID)}</span>
              </div>
              <h3>${escapeHTML(session.name || session.preview || session.id)}</h3>
              <p class="detail-subtitle">${escapeHTML(codexSummary(session))}</p>
              <div class="detail-actions">${actions.join('')}</div>
            </div>
            ${codexCoachCard(session)}
            <div class="detail-card">
              <h4>基础信息</h4>
              <div class="detail-meta">
                <span>对话 ID ${escapeHTML(session.id)}</span>
                <span>当前状态 ${escapeHTML(codexDisplayStateLabel(session))}</span>
                <span>最近一轮 ${escapeHTML(codexLastTurnLabel(session))}</span>
                <span>来源 ${escapeHTML(session.source || '—')}</span>
                <span>项目 ${escapeHTML(session.workspaceID || '—')}</span>
                <span>目录 ${escapeHTML(session.cwd || '—')}</span>
              </div>
            </div>
            ${renderHostConsoleDetailCard(session.deviceID)}
            ${renderProjectContextDetailCard(session.deviceID, session.workspaceID, {
              missingWorkspaceMessage: '当前会话还没有匹配到 Orchard 工作区；只要 cwd 落在某个已注册 workspace 根路径内，控制面就会自动补齐关联。'
            })}
            <div class="detail-card">
              <h4>状态说明</h4>
              <p class="footnote">${escapeHTML(codexStatusExplanation(session))}</p>
            </div>
            <div class="detail-card">
              <h4>一开始的问题</h4>
              <pre>${escapeHTML(session.preview || '暂无')}</pre>
            </div>
            <div class="detail-block">
              <h4>轮次</h4>
              <div class="detail-list">
                ${turns.length ? turns.map((turn) => `
                  <article class="detail-list-item">
                    <div class="detail-list-item-head">
                      <div class="detail-list-item-title">${escapeHTML(turn.id)}</div>
                      <span class="chip ${turn.status === 'completed' ? 'green' : turn.status === 'failed' ? 'red' : turn.status === 'interrupted' ? 'gold' : 'blue'}">${escapeHTML(turn.status)}</span>
                    </div>
                    ${turn.errorMessage ? `<div class="detail-list-item-body">${escapeHTML(turn.errorMessage)}</div>` : ''}
                  </article>`).join('') : renderEmpty('当前没有轮次记录。', '刷新后会重新读取本机的 Codex 线程详情。')}
              </div>
            </div>
            <div class="detail-block">
              <h4>时间线</h4>
              <div class="detail-list">
                ${items.length ? items.map((item) => `
                  <article class="detail-list-item">
                    <div class="detail-list-item-head">
                      <div class="detail-list-item-title">${escapeHTML(codexItemKindLabel(item.kind))} · ${escapeHTML(item.title || '')}</div>
                      ${item.status ? `<span class="chip gray">${escapeHTML(item.status)}</span>` : ''}
                    </div>
                    ${item.body ? `<div class="detail-list-item-body">${escapeHTML(item.body)}</div>` : ''}
                  </article>`).join('') : renderEmpty('当前没有可展示的会话内容。', '刷新后会重新读取本机的 Codex 线程详情。')}
              </div>
            </div>
          </div>`;
      }

      function renderAll() {
        updateToolbarControls();
        renderError();
        renderMetrics();
        renderGuide();
        renderControl();
        renderRuns();
        renderTasks();
        renderCodexDiagnostics();
        renderCodex();
        renderDevices();
        renderWorkspaces();
        renderDetail();
        renderPromptProjectContext();
        renderStatusStrip();
        refreshButton.disabled = state.actionPending;
        promptSubmit.disabled = state.actionPending;
      }

      function readSelectionFromHash() {
        const hash = window.location.hash.startsWith('#') ? window.location.hash.slice(1) : '';
        const params = new URLSearchParams(hash);
        const type = params.get('type');
        if (type === 'managed' && params.get('runID')) {
          return { type: 'managed', runID: params.get('runID') };
        }
        if (type === 'task' && params.get('taskID')) {
          return { type: 'task', taskID: params.get('taskID') };
        }
        if (type === 'codex' && params.get('deviceID') && params.get('sessionID')) {
          return { type: 'codex', deviceID: params.get('deviceID'), sessionID: params.get('sessionID') };
        }
        return null;
      }

      function writeSelectionHash() {
        if (!state.selected) {
          history.replaceState(null, '', `${window.location.pathname}${window.location.search}`);
          return;
        }
        const params = new URLSearchParams();
        params.set('type', state.selected.type);
        if (state.selected.type === 'managed') {
          params.set('runID', state.selected.runID);
        } else if (state.selected.type === 'task') {
          params.set('taskID', state.selected.taskID);
        } else {
          params.set('deviceID', state.selected.deviceID);
          params.set('sessionID', state.selected.sessionID);
        }
        window.location.hash = params.toString();
      }

      async function requestJSON(url, init = {}) {
        const headers = new Headers(init.headers || {});
        const body = init.body === undefined ? undefined : JSON.stringify(init.body);
        if (body && !headers.has('Content-Type')) headers.set('Content-Type', 'application/json');
        const response = await fetch(url, { credentials: 'same-origin', ...init, headers, body });
        const text = await response.text();
        let data = null;
        if (text) {
          try { data = JSON.parse(text); } catch { data = text; }
        }
        if (!response.ok) {
          const message = typeof data === 'string'
            ? data
            : data?.reason || data?.errorMessage || data?.message || `请求失败（${response.status}）`;
          throw new Error(message);
        }
        return data;
      }

      async function refreshData(options = {}) {
        try {
          const [snapshot, sessions] = await Promise.all([
            requestJSON('/api/snapshot'),
            requestJSON('/api/codex/sessions?limit=20')
          ]);
          state.snapshot = snapshot || { devices: [], tasks: [], managedRuns: [] };
          state.codexSessions = normalizeCodexSessions(sessions);
          state.errorMessage = null;
          state.lastUpdatedAt = new Date();
          renderAll();
          if (options.refreshDetail && state.selected) await refreshSelectedDetail();
        } catch (error) {
          state.errorMessage = error.message || '刷新失败';
          renderAll();
          if (!options.silent) showToast(state.errorMessage, true);
        }
      }

      async function refreshSelectedDetail() {
        if (!state.selected) return;
        state.detailLoading = true;
        state.detailError = null;
        renderDetail();
        try {
          if (state.selected.type === 'managed') {
            state.detail = await requestJSON(`/api/runs/${encodeURIComponent(state.selected.runID)}`);
            state.detailType = 'managed';
            const target = projectContextTargetForManagedRun(state.detail?.run);
            if (target) {
              void ensureProjectContextSummary(target.deviceID, target.workspaceID);
            }
          } else if (state.selected.type === 'task') {
            state.detail = await requestJSON(`/api/tasks/${encodeURIComponent(state.selected.taskID)}`);
            state.detailType = 'task';
          } else {
            state.detail = await requestJSON(`/api/devices/${encodeURIComponent(state.selected.deviceID)}/codex/sessions/${encodeURIComponent(state.selected.sessionID)}`);
            state.detailType = 'codex';
            const target = projectContextTargetForCodexSession(state.detail?.session);
            if (target) {
              void ensureProjectContextSummary(target.deviceID, target.workspaceID);
            }
          }
        } catch (error) {
          state.detail = null;
          state.detailError = error.message || '详情加载失败';
        } finally {
          state.detailLoading = false;
          renderDetail();
        }
      }

      function openPromptDialog(action) {
        state.promptAction = action;
        promptTitle.textContent = action.title;
        promptHint.textContent = action.hint;
        promptInput.value = action.initialPrompt || '';
        renderPromptProjectContext();
        if (action.deviceID && action.workspaceID) {
          void ensureProjectContextSummary(action.deviceID, action.workspaceID);
          void ensureProjectContextCommands(action.deviceID, action.workspaceID);
        }
        if (typeof promptDialog.showModal === 'function') {
          promptDialog.showModal();
        } else {
          promptDialog.setAttribute('open', 'true');
        }
        promptInput.focus();
      }

      function closePromptDialog() {
        state.promptAction = null;
        promptProjectContext.innerHTML = '';
        if (typeof promptDialog.close === 'function') {
          promptDialog.close();
        } else {
          promptDialog.removeAttribute('open');
        }
      }

      async function runAction(task) {
        if (state.actionPending) return;
        state.actionPending = true;
        renderAll();
        try {
          await task();
        } finally {
          state.actionPending = false;
          renderAll();
        }
      }

      async function continueManaged(runID, prompt) {
        await requestJSON(`/api/runs/${encodeURIComponent(runID)}/continue`, { method: 'POST', body: { prompt } });
        showToast('已发送继续指令');
        await refreshData({ refreshDetail: true, silent: true });
      }

      async function interruptManaged(runID) {
        await requestJSON(`/api/runs/${encodeURIComponent(runID)}/interrupt`, { method: 'POST', body: {} });
        showToast('已发送中断指令');
        await refreshData({ refreshDetail: true, silent: true });
      }

      async function stopManaged(runID) {
        await requestJSON(`/api/runs/${encodeURIComponent(runID)}/stop`, { method: 'POST', body: { reason: '网页端请求停止' } });
        showToast('已发送停止指令');
        await refreshData({ refreshDetail: true, silent: true });
      }

      async function stopTask(taskID) {
        await requestJSON(`/api/tasks/${encodeURIComponent(taskID)}/stop`, { method: 'POST', body: { reason: '网页端请求停止' } });
        showToast('已发送任务停止指令');
        await refreshData({ refreshDetail: true, silent: true });
      }

      async function retryManaged(runID) {
        const result = await requestJSON(`/api/runs/${encodeURIComponent(runID)}/retry`, { method: 'POST', body: {} });
        state.selected = { type: 'managed', runID: result.id };
        writeSelectionHash();
        showToast('已创建重试 run');
        await refreshData({ refreshDetail: true, silent: true });
      }

      async function createManagedRun() {
        const prompt = createPromptInput.value.trim();
        const workspaceID = createWorkspaceSelect.value;
        const relativePath = normalizeRelativePath(createRelativePathInput.value);
        const preferredDeviceID = createDeviceSelect.value;
        const title = (createTitleInput.value.trim() || defaultRunTitle(prompt)).trim();

        if (!workspaceID) {
          throw new Error('请先选择工作区。');
        }
        if (!prompt) {
          throw new Error('请先输入提示词。');
        }

        createTitleInput.value = title;
        const result = await requestJSON('/api/runs', {
          method: 'POST',
          body: {
            title,
            workspaceID,
            relativePath: relativePath || null,
            preferredDeviceID: preferredDeviceID || null,
            driver: 'codexCLI',
            prompt
          }
        });
        state.selected = { type: 'managed', runID: result.id };
        writeSelectionHash();
        createTitleInput.value = '';
        createRelativePathInput.value = '';
        createPromptInput.value = '';
        updateCreateHint();
        showToast('已发起任务');
        await refreshData({ refreshDetail: true, silent: true });
      }

      async function continueCodex(deviceID, sessionID, prompt) {
        await requestJSON(`/api/devices/${encodeURIComponent(deviceID)}/codex/sessions/${encodeURIComponent(sessionID)}/continue`, { method: 'POST', body: { prompt } });
        showToast('已发送继续指令');
        await refreshData({ refreshDetail: true, silent: true });
      }

      async function interruptCodex(deviceID, sessionID) {
        await requestJSON(`/api/devices/${encodeURIComponent(deviceID)}/codex/sessions/${encodeURIComponent(sessionID)}/interrupt`, { method: 'POST', body: {} });
        showToast('已发送中断指令');
        await refreshData({ refreshDetail: true, silent: true });
      }

      function showToast(message, isError = false) {
        toast.textContent = message;
        toast.className = isError ? 'toast error' : 'toast';
        toast.style.display = 'block';
        clearTimeout(showToast.timer);
        showToast.timer = setTimeout(() => {
          toast.style.display = 'none';
        }, 2200);
      }

      function scrollToSection(targetID) {
        if (!targetID) return;
        const element = document.getElementById(targetID);
        if (!element) return;
        element.scrollIntoView({ behavior: 'smooth', block: 'start' });
      }

      document.addEventListener('click', (event) => {
        const button = event.target.closest('button[data-action]');
        if (!button) return;
        const action = button.dataset.action;
        if (action === 'focus-section') {
          scrollToSection(button.dataset.targetId);
          return;
        }
        if (action === 'insert-project-command') {
          const item = lookupProjectCommandItem(button.dataset.deviceId, button.dataset.workspaceId, button.dataset.commandId);
          if (!item) {
            showToast('标准操作命令已失效，请刷新后重试', true);
            return;
          }
          promptInput.value = appendPromptBlock(
            buildProjectCommandPrompt(item, button.dataset.intent || state.promptAction?.intent || 'continueConversation'),
            promptInput.value
          );
          promptInput.focus();
          promptInput.setSelectionRange(promptInput.value.length, promptInput.value.length);
          showToast(`已插入标准命令：${item.command?.name || item.command?.id || button.dataset.commandId}`);
          return;
        }
        if (action === 'select-managed') {
          state.selected = { type: 'managed', runID: button.dataset.runId };
          writeSelectionHash();
          refreshSelectedDetail();
          renderAll();
          scrollToSection(button.dataset.scrollTarget);
          return;
        }
        if (action === 'select-task') {
          state.selected = { type: 'task', taskID: button.dataset.taskId };
          writeSelectionHash();
          refreshSelectedDetail();
          renderAll();
          scrollToSection(button.dataset.scrollTarget);
          return;
        }
        if (action === 'select-codex') {
          state.selected = { type: 'codex', deviceID: button.dataset.deviceId, sessionID: button.dataset.sessionId };
          writeSelectionHash();
          refreshSelectedDetail();
          renderAll();
          scrollToSection(button.dataset.scrollTarget);
          return;
        }
        if (action === 'continue-managed') {
          const run = managedRunByID(button.dataset.runId) || state.detail?.run || null;
          openPromptDialog({
            type: action,
            intent: 'continueConversation',
            runID: button.dataset.runId,
            deviceID: run?.deviceID || '',
            workspaceID: run?.workspaceID || '',
            title: '继续这个 Orchard 任务',
            hint: '这一句会继续发给当前等待中的 Orchard 任务。'
          });
          return;
        }
        if (action === 'continue-codex') {
          const session = codexSessionByID(button.dataset.deviceId, button.dataset.sessionId) || null;
          openPromptDialog({
            type: action,
            intent: 'continueConversation',
            deviceID: button.dataset.deviceId,
            workspaceID: session?.workspaceID || '',
            sessionID: button.dataset.sessionId,
            title: '继续这个 Codex 对话',
            hint: '这一句会发送到宿主机上对应的 Codex 对话。'
          });
          return;
        }
        if (action === 'interrupt-managed') {
          runAction(() => interruptManaged(button.dataset.runId)).catch((error) => showToast(error.message || '中断失败', true));
          return;
        }
        if (action === 'interrupt-codex') {
          runAction(() => interruptCodex(button.dataset.deviceId, button.dataset.sessionId)).catch((error) => showToast(error.message || '中断失败', true));
          return;
        }
        if (action === 'stop-managed') {
          runAction(() => stopManaged(button.dataset.runId)).catch((error) => showToast(error.message || '停止失败', true));
          return;
        }
        if (action === 'stop-task') {
          runAction(() => stopTask(button.dataset.taskId)).catch((error) => showToast(error.message || '停止失败', true));
          return;
        }
        if (action === 'retry-managed') {
          runAction(() => retryManaged(button.dataset.runId)).catch((error) => showToast(error.message || '重试失败', true));
        }
      });

      createRunForm.addEventListener('submit', (event) => {
        event.preventDefault();
        runAction(() => createManagedRun()).catch((error) => showToast(error.message || '创建失败', true));
      });

      createWorkspaceSelect.addEventListener('change', () => {
        updateToolbarControls();
      });
      createRelativePathSelect.addEventListener('change', () => {
        const selectedValue = createRelativePathSelect.value;
        if (selectedValue === createRelativePathRootValue) {
          createRelativePathInput.value = '';
        } else if (selectedValue && selectedValue !== createRelativePathCustomValue) {
          createRelativePathInput.value = selectedValue;
        }
        updateCreateHint();
      });
      createRelativePathInput.addEventListener('input', () => {
        syncCreateRelativePathSelect();
        updateCreateHint();
      });

      function applyFilters() {
        syncFilterStateFromControls();
        writeFiltersQuery();
        renderAll();
      }

      filterQueryInput.addEventListener('input', () => applyFilters());
      filterDeviceSelect.addEventListener('change', () => applyFilters());
      filterRunningOnly.addEventListener('change', () => applyFilters());
      filterReset.addEventListener('click', () => {
        state.filters = { query: '', deviceID: '', runningOnly: false };
        writeFiltersQuery();
        renderAll();
      });

      promptForm.addEventListener('submit', (event) => {
        event.preventDefault();
        const prompt = promptInput.value.trim();
        if (!prompt || !state.promptAction) return;
        const action = state.promptAction;
        runAction(async () => {
          if (action.type === 'continue-managed') {
            await continueManaged(action.runID, prompt);
          } else if (action.type === 'continue-codex') {
            await continueCodex(action.deviceID, action.sessionID, prompt);
          }
          closePromptDialog();
        }).catch((error) => showToast(error.message || '发送失败', true));
      });

      promptCancel.addEventListener('click', () => closePromptDialog());
      refreshButton.addEventListener('click', () => refreshData({ refreshDetail: true }));
      window.addEventListener('hashchange', () => {
        state.selected = readSelectionFromHash();
        state.detail = null;
        state.detailType = null;
        state.detailError = null;
        renderAll();
        if (state.selected) refreshSelectedDetail();
      });

      renderAll();
      if (state.selected) refreshSelectedDetail();
      setInterval(() => {
        if (!state.actionPending && !promptDialog.open) {
          refreshData({ refreshDetail: true, silent: true });
        }
      }, 15000);
    })();
  </script>
</body>
</html>
"""#

        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "text/html; charset=utf-8")
        return Response(status: .ok, headers: headers, body: .init(string: html))
    }

    private static func encodeBootstrap(_ value: BootstrapPayload) -> String {
        guard let data = try? OrchardJSON.encoder.encode(value), var text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        text = text
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
            .replacingOccurrences(of: "&", with: "\\u0026")
            .replacingOccurrences(of: "</", with: "<\\/")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return text
    }
}
