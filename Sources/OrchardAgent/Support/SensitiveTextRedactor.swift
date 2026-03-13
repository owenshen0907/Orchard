import Foundation

enum SensitiveTextRedactor {
    static func redact(_ text: String?) -> String? {
        guard let text else {
            return nil
        }
        return redact(text)
    }

    static func redact(_ text: String) -> String {
        patterns.reduce(text) { partial, entry in
            entry.regex.stringByReplacingMatches(
                in: partial,
                options: [],
                range: NSRange(partial.startIndex..., in: partial),
                withTemplate: entry.template
            )
        }
    }

    private static let patterns: [(regex: NSRegularExpression, template: String)] = [
        compile(
            #"(?im)\b([A-Z0-9_]*(?:ACCESS_KEY|API_KEY|TOKEN|SECRET|PASSWORD)[A-Z0-9_]*)\s*=\s*([^\s"'`]+)"#,
            template: "$1=[REDACTED]"
        ),
        compile(
            #"(?im)\b((?:access[_-]?key|api[_-]?key|token|secret|password)\s*[:=]\s*)([^\s,;]+)"#,
            template: "$1[REDACTED]"
        ),
        compile(
            #"(?im)(\"(?:access[_-]?key|api[_-]?key|token|secret|password)\"\s*:\s*\")([^\"]+)(\")"#,
            template: "$1[REDACTED]$3"
        ),
        compile(
            #"(?i)((?:\?|&)(?:access[_-]?key|api[_-]?key|token|secret|password)=)([^&\s]+)"#,
            template: "$1[REDACTED]"
        ),
        compile(
            #"(?im)(authorization\s*:\s*bearer\s+)([^\s]+)"#,
            template: "$1[REDACTED]"
        ),
    ]

    private static func compile(_ pattern: String, template: String) -> (regex: NSRegularExpression, template: String) {
        (try! NSRegularExpression(pattern: pattern, options: []), template)
    }
}
