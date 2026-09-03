import Darwin
import Foundation
import PerchCore

enum LocalEventServerState: Sendable {
    case ready
    case unavailable
}

enum LocalEventServerError: Error {
    case systemCall(name: String, code: Int32)
    case invalidToken
}

final class LocalEventServer: @unchecked Sendable {
    static let port: UInt16 = 7534

    private let onEvent: @Sendable (AgentEvent) -> Void
    private let onStateChange: @Sendable (LocalEventServerState) -> Void
    private let expectedToken: String
    private let acceptQueue = DispatchQueue(label: "app.sleepwing.local-events.accept")
    private let connectionQueue = DispatchQueue(
        label: "app.sleepwing.local-events.connections",
        attributes: .concurrent
    )
    private let connectionSlots = DispatchSemaphore(value: 16)
    private let lock = NSLock()
    private var listeningSocket: Int32 = -1
    private var stopping = false

    init(
        onEvent: @escaping @Sendable (AgentEvent) -> Void,
        onStateChange: @escaping @Sendable (LocalEventServerState) -> Void,
        expectedToken: String
    ) {
        self.onEvent = onEvent
        self.onStateChange = onStateChange
        self.expectedToken = expectedToken
    }

    func start() throws {
        guard IntegrationTokenPolicy.isValid(expectedToken) else {
            throw LocalEventServerError.invalidToken
        }
        let socketDescriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else {
            throw systemCallError("socket")
        }

        do {
            var reuseAddress: Int32 = 1
            guard Darwin.setsockopt(
                socketDescriptor,
                SOL_SOCKET,
                SO_REUSEADDR,
                &reuseAddress,
                socklen_t(MemoryLayout.size(ofValue: reuseAddress))
            ) == 0 else {
                throw systemCallError("setsockopt")
            }

            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = Self.port.bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(
                        socketDescriptor,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
            guard bindResult == 0 else {
                throw systemCallError("bind")
            }
            guard Darwin.listen(socketDescriptor, SOMAXCONN) == 0 else {
                throw systemCallError("listen")
            }
        } catch {
            Darwin.close(socketDescriptor)
            throw error
        }

        lock.lock()
        listeningSocket = socketDescriptor
        stopping = false
        lock.unlock()

        acceptQueue.async { [weak self] in
            self?.acceptConnections(on: socketDescriptor)
        }
    }

    func stop() {
        lock.lock()
        stopping = true
        let socketDescriptor = listeningSocket
        listeningSocket = -1
        lock.unlock()

        guard socketDescriptor >= 0 else { return }
        Darwin.shutdown(socketDescriptor, SHUT_RDWR)
        Darwin.close(socketDescriptor)
    }

    private func acceptConnections(on socketDescriptor: Int32) {
        lock.lock()
        let shouldRun = !stopping && listeningSocket == socketDescriptor
        lock.unlock()
        guard shouldRun else { return }

        onStateChange(.ready)
        while true {
            let connection = Darwin.accept(socketDescriptor, nil, nil)
            if connection >= 0 {
                guard connectionSlots.wait(timeout: .now()) == .success else {
                    Darwin.close(connection)
                    continue
                }
                let slots = connectionSlots
                connectionQueue.async { [weak self] in
                    defer { slots.signal() }
                    guard let self else {
                        Darwin.close(connection)
                        return
                    }
                    self.receive(connection)
                }
                continue
            }
            if errno == EINTR { continue }

            lock.lock()
            let wasStopped = stopping || listeningSocket != socketDescriptor
            if listeningSocket == socketDescriptor {
                listeningSocket = -1
            }
            lock.unlock()
            if !wasStopped {
                Darwin.close(socketDescriptor)
                onStateChange(.unavailable)
            }
            return
        }
    }

    private func receive(_ connection: Int32) {
        defer { Darwin.close(connection) }

        var noSignal: Int32 = 1
        _ = Darwin.setsockopt(
            connection,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout.size(ofValue: noSignal))
        )
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = Darwin.setsockopt(
            connection,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout.size(ofValue: timeout))
        )

        var accumulated = Data()
        var chunk = [UInt8](repeating: 0, count: 8 * 1024)
        while accumulated.count <= HTTPEventRequestParser.maximumHeaderBytes
            + HTTPEventRequestParser.maximumBodyBytes {
            let byteCount = Darwin.recv(connection, &chunk, chunk.count, 0)
            if byteCount > 0 {
                accumulated.append(chunk, count: byteCount)
                switch HTTPEventRequestParser.parse(accumulated) {
                case let .complete(provider, body, token):
                    guard IntegrationTokenPolicy.securelyMatches(
                        token,
                        expected: expectedToken
                    ) else {
                        respond(connection, status: "403 Forbidden", body: "{\"ok\":false}")
                        return
                    }
                    guard let event = try? HookPayloadSanitizer.decodeCanonical(
                        expectedProvider: provider,
                        data: body
                    ) else {
                        respond(connection, status: "400 Bad Request", body: "{\"ok\":false}")
                        return
                    }
                    onEvent(event)
                    respond(connection, status: "202 Accepted", body: "{\"ok\":true}")
                    return
                case let .rejected(status):
                    respond(connection, status: statusText(status), body: "{\"ok\":false}")
                    return
                case .incomplete:
                    continue
                }
            }
            if byteCount < 0 && errno == EINTR { continue }
            respond(connection, status: "400 Bad Request", body: "{\"ok\":false}")
            return
        }
        respond(connection, status: "413 Content Too Large", body: "{\"ok\":false}")
    }

    private func respond(_ connection: Int32, status: String, body: String) {
        let response = Data(
            "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8
        )
        response.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let sent = Darwin.send(connection, pointer, remaining, 0)
                guard sent > 0 else { return }
                remaining -= sent
                pointer = pointer.advanced(by: sent)
            }
        }
    }

    private func statusText(_ status: Int) -> String {
        switch status {
        case 404: "404 Not Found"
        case 405: "405 Method Not Allowed"
        case 411: "411 Length Required"
        case 413: "413 Content Too Large"
        case 431: "431 Request Header Fields Too Large"
        default: "400 Bad Request"
        }
    }

    private func systemCallError(_ name: String) -> LocalEventServerError {
        LocalEventServerError.systemCall(name: name, code: errno)
    }
}
