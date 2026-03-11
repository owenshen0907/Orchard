import Vapor

enum OrchardUnlockPage {
    static func response(status: HTTPStatus = .ok, errorMessage: String? = nil) -> Response {
        let messageHTML = errorMessage.map {
            """
            <p class="error">\($0)</p>
            """
        } ?? ""

        let html = #"""
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Unlock Orchard</title>
  <style>
    :root {
      color-scheme: light;
      --bg: #f4efe6;
      --panel: rgba(255, 252, 247, 0.94);
      --ink: #1f2933;
      --muted: #5f6c7b;
      --accent: #1a7f5a;
      --accent-soft: rgba(26, 127, 90, 0.12);
      --danger: #b2432f;
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
      width: min(560px, 100%);
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
      font-size: clamp(34px, 6vw, 48px);
      line-height: 0.98;
      letter-spacing: -0.04em;
    }

    p {
      margin: 0;
      font-size: 18px;
      line-height: 1.6;
      color: var(--muted);
    }

    form {
      margin-top: 28px;
      display: grid;
      gap: 14px;
    }

    label {
      display: grid;
      gap: 8px;
      font: 600 14px/1.3 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      color: var(--ink);
    }

    input {
      width: 100%;
      border: 1px solid var(--border);
      border-radius: 16px;
      padding: 14px 16px;
      font: 500 16px/1.2 "SFMono-Regular", Menlo, Consolas, monospace;
      background: rgba(255, 255, 255, 0.82);
      color: var(--ink);
    }

    button {
      appearance: none;
      border: 0;
      border-radius: 16px;
      padding: 14px 18px;
      background: var(--accent);
      color: white;
      font: 600 16px/1.2 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      cursor: pointer;
    }

    button:hover {
      filter: brightness(1.05);
    }

    .error {
      margin-top: 18px;
      padding: 12px 14px;
      border-radius: 14px;
      background: rgba(178, 67, 47, 0.08);
      border: 1px solid rgba(178, 67, 47, 0.18);
      color: var(--danger);
      font-size: 15px;
    }

    .footnote {
      margin-top: 22px;
      font-size: 14px;
      color: var(--muted);
    }
  </style>
</head>
<body>
  <main>
    <div class="badge">Protected Control Plane</div>
    <h1>Enter access key.</h1>
    <p>
      This Orchard control plane is public on the network, but the operator surface is locked behind
      a shared access key.
    </p>
    __MESSAGE__
    <form method="post" action="/unlock">
      <label>
        Access key
        <input type="password" name="accessKey" placeholder="Paste the shared key" autocomplete="current-password" required>
      </label>
      <button type="submit">Unlock</button>
    </form>
    <p class="footnote">
      Health checks stay on <code>/health</code>. Agent registration and live sessions still use the enrollment token.
    </p>
  </main>
</body>
</html>
"""#

        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "text/html; charset=utf-8")
        headers.add(name: .cacheControl, value: "no-store")
        return Response(status: status, headers: headers, body: .init(string: html.replacingOccurrences(of: "__MESSAGE__", with: messageHTML)))
    }
}
