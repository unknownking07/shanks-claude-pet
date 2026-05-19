import Network
import Foundation

/// Minimal HTTP server that receives POST events from Claude Code hooks.
/// Listens on localhost:7772. Runs on a background queue; callbacks are dispatched to main.
class HookServer {
    static let port: UInt16 = 7772
    private static let maxBufferSize = 65_536  // 64 KB — reject oversized payloads
    private static let hookQueue = DispatchQueue(label: "com.petclawd.hookserver", qos: .utility)

    var onNotification: (([String: Any]) -> Void)?
    var onPermissionRequest: (([String: Any]) -> Void)?
    var onPostToolUse: (([String: Any]) -> Void)?
    var onStop: (([String: Any]) -> Void)?

    private var listener: NWListener?

    func start() {
        guard let nwPort = NWEndpoint.Port(rawValue: Self.port) else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        do {
            listener = try NWListener(using: params, on: nwPort)
        } catch {
            NSLog("[HookServer] Failed to create listener: %@", error.localizedDescription)
            return
        }

        listener?.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        listener?.stateUpdateHandler = { state in
            if case .failed(let err) = state {
                NSLog("[HookServer] Listener error: %@", err.localizedDescription)
            }
        }
        listener?.start(queue: Self.hookQueue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func handle(_ connection: NWConnection) {
        connection.start(queue: Self.hookQueue)
        receive(connection: connection, buffer: Data())
    }

    private static let headerTerminator = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n

    private func receive(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] chunk, _, isDone, _ in
            guard let self else { connection.cancel(); return }
            var buf = buffer
            if let chunk { buf.append(chunk) }

            // Reject oversized payloads
            if buf.count > Self.maxBufferSize {
                connection.cancel()
                return
            }

            guard let splitRange = buf.range(of: Self.headerTerminator) else {
                if isDone { connection.cancel() } else { self.receive(connection: connection, buffer: buf) }
                return
            }

            let headerBytes = buf[..<splitRange.lowerBound]
            let headerText = String(data: headerBytes, encoding: .utf8) ?? ""
            let requestLine = headerText.components(separatedBy: "\r\n").first ?? ""
            let path = requestLine.components(separatedBy: " ").dropFirst().first ?? "/"

            let bodyData = buf[splitRange.upperBound...]
            let body = (try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]) ?? [:]

            // Respond immediately
            let response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })

            // Dispatch callbacks to main thread
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch path {
                case "/notification":       self.onNotification?(body)
                case "/permission-request": self.onPermissionRequest?(body)
                case "/post-tool-use":      self.onPostToolUse?(body)
                case "/stop":               self.onStop?(body)
                default:                    break
                }
            }
        }
    }
}
