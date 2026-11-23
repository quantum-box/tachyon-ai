import Foundation
import Network

/// Receives the OAuth redirect on a loopback port (RFC 8252), like `tachyon auth login`.
///
/// The ports are the ones registered as callback URLs on the Cognito client.
/// Mutable state is only touched on `queue`.
final class LoopbackCallback: @unchecked Sendable {
    static let ports: [UInt16] = [42813, 42814, 42815]

    let redirectURI: String
    private let listener: NWListener
    private let queue = DispatchQueue(label: "one.tachy.ai.oauth-callback")
    private var onCallback: (([String: String]) -> Void)?
    private var expectedState: String?

    /// Picks a registered port. A port already in use is reported by `waitForCallback`.
    init?() {
        for port in Self.ports {
            let parameters = NWParameters.tcp
            // Bound to 127.0.0.1 itself, so it is never reachable from other machines.
            parameters.requiredInterfaceType = .loopback
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            parameters.allowLocalEndpointReuse = true
            guard let listener = try? NWListener(using: parameters) else {
                continue
            }
            self.listener = listener
            self.redirectURI = "http://localhost:\(port)/callback"
            return
        }
        return nil
    }

    /// Waits for the browser to land on `/callback` with this login's `state` and returns
    /// the query parameters. Requests carrying any other `state` are refused and ignored.
    func waitForCallback(state: String) async throws -> [String: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: String], Error>) in
                queue.async {
                    var resumed = false
                    self.expectedState = state
                    self.onCallback = { query in
                        guard !resumed else { return }
                        resumed = true
                        continuation.resume(returning: query)
                    }
                    self.listener.stateUpdateHandler = { state in
                        switch state {
                        case .failed(let error):
                            guard !resumed else { return }
                            resumed = true
                            continuation.resume(throwing: error)
                        case .cancelled:
                            guard !resumed else { return }
                            resumed = true
                            continuation.resume(throwing: CancellationError())
                        default:
                            break
                        }
                    }
                    self.listener.newConnectionHandler = { connection in
                        self.serve(connection)
                    }
                    self.listener.start(queue: self.queue)
                }
            }
        } onCancel: {
            stop()
        }
    }

    func stop() {
        listener.cancel()
        // The handlers hold `self`; drop them so the listener does not keep it alive.
        queue.async {
            self.onCallback = nil
            self.listener.newConnectionHandler = nil
        }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self,
                  let data,
                  let requestLine = String(data: data, encoding: .utf8)?.components(separatedBy: "\r\n").first,
                  let target = requestLine.split(separator: " ").dropFirst().first,
                  let components = URLComponents(string: "http://localhost\(target)"),
                  components.path == "/callback" else {
                self?.respond(connection, status: "404 Not Found", body: "Not found")
                return
            }
            var query: [String: String] = [:]
            for item in components.queryItems ?? [] {
                query[item.name] = item.value
            }
            guard let expected = self.expectedState, query["state"] == expected else {
                self.respond(connection, status: "400 Bad Request", body: "このログインは無効です。")
                return
            }
            let succeeded = query["code"] != nil
            self.respond(
                connection,
                status: "200 OK",
                body: succeeded
                    ? "ログインしました。このウインドウは自動で閉じます。"
                    : "ログインに失敗しました。アプリからやり直してください。")
            self.onCallback?(query)
        }
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let html = """
            <!DOCTYPE html><html><head><meta charset="utf-8"><title>Tachyon AI</title></head>\
            <body style="font-family:-apple-system,sans-serif;text-align:center;margin-top:80px">\
            <p>\(body)</p></body></html>
            """
        let payload = Data(html.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(payload.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
