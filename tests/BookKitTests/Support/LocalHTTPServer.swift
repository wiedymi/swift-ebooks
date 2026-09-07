import Foundation
import Network

@MainActor
final class LocalHTTPServer {
    private let listener: NWListener
    private let response: Data
    private let keepsOpen: Bool
    private var connections: [NWConnection] = []
    private(set) var requests: [String] = []
    var onRequest: (() -> Void)?

    init(response: Data, keepsOpen: Bool = false) throws {
        listener = try NWListener(using: .tcp, on: .any)
        self.response = response
        self.keepsOpen = keepsOpen
    }

    func start() async throws -> URL {
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.listener.stateUpdateHandler != nil else { return }
                    switch state {
                    case .ready:
                        self.listener.stateUpdateHandler = nil
                        continuation.resume()
                    case .failed(let error):
                        self.listener.stateUpdateHandler = nil
                        continuation.resume(throwing: error)
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
        }
        guard let port = listener.port,
              let url = URL(string: "http://127.0.0.1:\(port.rawValue)/test") else {
            throw URLError(.badURL)
        }
        return url
    }

    func stop() {
        listener.cancel()
        for connection in connections { connection.cancel() }
        connections.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: .main)
        receiveRequest(on: connection, data: Data())
    }

    private func receiveRequest(on connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] chunk, _, complete, error in
            Task { @MainActor in
                guard let self, error == nil else { connection.cancel(); return }
                var request = data
                request.append(chunk ?? Data())
                guard request.count <= 64 * 1024 else { connection.cancel(); return }
                if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                    self.requests.append(String(decoding: request, as: UTF8.self))
                    self.onRequest?()
                    let keepsOpen = self.keepsOpen
                    connection.send(content: self.response, completion: .contentProcessed { _ in
                        if !keepsOpen { connection.cancel() }
                    })
                } else if !complete {
                    self.receiveRequest(on: connection, data: request)
                } else {
                    connection.cancel()
                }
            }
        }
    }
}
