import Vapor

enum OrchardLandingPage {
    static let html = #"""
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Orchard Control Plane</title>
  <style>
    :root {
      color-scheme: light;
      --bg: #f4efe6;
      --panel: rgba(255, 252, 247, 0.92);
      --ink: #1f2933;
      --muted: #5f6c7b;
      --accent: #1a7f5a;
      --accent-soft: rgba(26, 127, 90, 0.12);
      --border: rgba(31, 41, 51, 0.1);
      --shadow: 0 24px 60px rgba(31, 41, 51, 0.12);
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
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 32px 18px;
    }

    main {
      width: min(760px, 100%);
      background: var(--panel);
      border: 1px solid var(--border);
      border-radius: 28px;
      box-shadow: var(--shadow);
      padding: 32px;
      backdrop-filter: blur(10px);
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
      font-size: clamp(34px, 6vw, 52px);
      line-height: 0.98;
      letter-spacing: -0.04em;
    }

    p {
      margin: 0;
      font-size: 18px;
      line-height: 1.6;
      color: var(--muted);
    }

    .grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
      gap: 14px;
      margin: 28px 0;
    }

    .card {
      border-radius: 18px;
      padding: 18px;
      border: 1px solid var(--border);
      background: rgba(255, 255, 255, 0.7);
    }

    .card h2 {
      margin: 0 0 10px;
      font: 600 15px/1.3 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      letter-spacing: 0.01em;
    }

    .card p {
      font-size: 15px;
      line-height: 1.5;
    }

    ul {
      margin: 24px 0 0;
      padding: 0;
      list-style: none;
      display: grid;
      gap: 12px;
    }

    li {
      padding: 14px 16px;
      border-radius: 16px;
      background: rgba(255, 255, 255, 0.76);
      border: 1px solid var(--border);
      display: flex;
      flex-wrap: wrap;
      align-items: center;
      justify-content: space-between;
      gap: 10px 14px;
    }

    a {
      color: var(--accent);
      text-decoration: none;
      font-weight: 600;
    }

    a:hover {
      text-decoration: underline;
    }

    code {
      font-family: "SFMono-Regular", Menlo, Consolas, monospace;
      font-size: 14px;
      padding: 2px 6px;
      border-radius: 8px;
      background: rgba(31, 41, 51, 0.06);
    }

    .footnote {
      margin-top: 24px;
      font-size: 14px;
      color: var(--muted);
    }
  </style>
</head>
<body>
  <main>
    <div class="badge">Orchard Control Plane</div>
    <h1>Service is online.</h1>
    <p>
      This host exposes Orchard's API and agent session endpoints. It is not a browser console yet,
      so the root page is only a lightweight status and routing surface.
    </p>

    <section class="grid">
      <article class="card">
        <h2>Primary use</h2>
        <p>Accept agent registration, heartbeats, task dispatch, task logs, and stop requests.</p>
      </article>
      <article class="card">
        <h2>Agent base URL</h2>
        <p><code>https://orchard.owenshen.top</code></p>
      </article>
      <article class="card">
        <h2>Transport</h2>
        <p>REST endpoints over HTTPS, plus WebSocket sessions for live agent communication.</p>
      </article>
    </section>

    <ul>
      <li>
        <span>Health check</span>
        <a href="/health">/health</a>
      </li>
      <li>
        <span>Registered devices</span>
        <a href="/api/devices">/api/devices</a>
      </li>
      <li>
        <span>Task list</span>
        <a href="/api/tasks">/api/tasks</a>
      </li>
      <li>
        <span>Dashboard snapshot</span>
        <a href="/api/snapshot">/api/snapshot</a>
      </li>
    </ul>

    <p class="footnote">
      If you want a browser-facing control UI here later, it needs a separate frontend deployment.
    </p>
  </main>
</body>
</html>
"""#

    static func response() -> Response {
        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "text/html; charset=utf-8")
        return Response(status: .ok, headers: headers, body: .init(string: html))
    }
}
