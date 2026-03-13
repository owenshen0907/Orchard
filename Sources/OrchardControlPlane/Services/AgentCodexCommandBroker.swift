import Foundation
import OrchardCore

actor AgentCodexCommandBroker {
    private var responses: [String: AgentCodexCommandResponse] = [:]

    func record(_ response: AgentCodexCommandResponse) {
        responses[response.requestID] = response
    }

    func take(requestID: String) -> AgentCodexCommandResponse? {
        responses.removeValue(forKey: requestID)
    }

    func clear(requestID: String) {
        responses.removeValue(forKey: requestID)
    }
}
