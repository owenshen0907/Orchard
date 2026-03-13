import Foundation
import NIOCore
import OrchardCore
import Vapor

final class AgentConnectionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var sockets: [String: WebSocket] = [:]

    func connect(deviceID: String, socket: WebSocket) {
        let previous = lock.withLock {
            sockets.updateValue(socket, forKey: deviceID)
        }
        if let previous {
            previous.eventLoop.execute {
                previous.close(promise: nil)
            }
        }
    }

    func disconnect(deviceID: String, socket: WebSocket? = nil) {
        lock.withLock {
            guard let existing = sockets[deviceID] else {
                return
            }
            if let socket, existing !== socket {
                return
            }
            sockets.removeValue(forKey: deviceID)
        }
    }

    func connectedDeviceIDs() -> Set<String> {
        lock.withLock {
            Set(sockets.keys)
        }
    }

    @discardableResult
    func send(_ message: ServerSocketMessage, to deviceID: String) async -> Bool {
        let socket = lock.withLock {
            sockets[deviceID]
        }
        guard let socket else {
            return false
        }
        guard !socket.isClosed else {
            disconnect(deviceID: deviceID, socket: socket)
            return false
        }
        guard let data = try? OrchardJSON.encoder.encode(message), let text = String(data: data, encoding: .utf8) else {
            return false
        }

        let promise = socket.eventLoop.makePromise(of: Void.self)
        socket.send(text, promise: promise)

        do {
            try await promise.futureResult.get()
            return true
        } catch {
            disconnect(deviceID: deviceID, socket: socket)
            return false
        }
    }
}
