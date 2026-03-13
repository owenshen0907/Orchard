import Foundation
import OrchardCore

actor AgentProjectContextCommandBroker {
    private var responses: [String: AgentProjectContextCommandResponse] = [:]

    func record(_ response: AgentProjectContextCommandResponse) {
        responses[response.requestID] = response
    }

    func take(requestID: String) -> AgentProjectContextCommandResponse? {
        responses.removeValue(forKey: requestID)
    }

    func clear(requestID: String) {
        responses.removeValue(forKey: requestID)
    }
}
