import Foundation
@preconcurrency import Vapor

struct OrchardAccessControl: Sendable {
    static let cookieName = "orchard_access"
    static let headerName = "X-Orchard-Access-Key"

    let accessKey: String?

    init(accessKey: String?) {
        let trimmed = accessKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.accessKey = trimmed?.isEmpty == false ? trimmed : nil
    }

    var isEnabled: Bool {
        accessKey != nil
    }

    func isAuthorized(_ request: Request) -> Bool {
        guard let accessKey else {
            return true
        }

        if request.headers.first(name: Self.headerName) == accessKey {
            return true
        }

        return request.cookies[Self.cookieName]?.string == accessKey
    }

    func makeUnlockCookie() -> HTTPCookies.Value? {
        guard let accessKey else {
            return nil
        }

        return HTTPCookies.Value(
            string: accessKey,
            maxAge: 60 * 60 * 24 * 30,
            path: "/",
            isSecure: true,
            isHTTPOnly: true,
            sameSite: .strict
        )
    }

    static func makeExpiredCookie() -> HTTPCookies.Value {
        HTTPCookies.Value(
            string: "",
            expires: Date(timeIntervalSince1970: 0),
            maxAge: 0,
            path: "/",
            isSecure: true,
            isHTTPOnly: true,
            sameSite: .strict
        )
    }
}

struct OrchardAccessKeyMiddleware: AsyncMiddleware {
    let accessControl: OrchardAccessControl

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard accessControl.isAuthorized(request) else {
            throw Abort(.unauthorized, reason: "缺少访问密钥或访问密钥无效。")
        }
        return try await next.respond(to: request)
    }
}
