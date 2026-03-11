import Foundation
import OrchardCore
import Vapor

final class AgentConnectionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var sockets: [String: WebSocket] = [:]

    func connect(deviceID: String, socket: WebSocket) {
        lock.lock()
        let previous = sockets.updateValue(socket, forKey: deviceID)
        lock.unlock()
        if let previous {
            previous.eventLoop.execute {
                previous.close(promise: nil)
            }
        }
    }

    func disconnect(deviceID: String, socket: WebSocket? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard let existing = sockets[deviceID] else {
            return
        }
        if let socket, existing !== socket {
            return
        }
        sockets.removeValue(forKey: deviceID)
    }

    func connectedDeviceIDs() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(sockets.keys)
    }

    @discardableResult
    func send(_ message: ServerSocketMessage, to deviceID: String) -> Bool {
        lock.lock()
        let socket = sockets[deviceID]
        lock.unlock()
        guard let socket else {
            return false
        }
        guard let data = try? OrchardJSON.encoder.encode(message), let text = String(data: data, encoding: .utf8) else {
            return false
        }
        socket.eventLoop.execute {
            socket.send(text)
        }
        return true
    }
}
