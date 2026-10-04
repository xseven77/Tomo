import Foundation
import Network
import Security

/// Immutable Security handle. Keychain mutations/provisioning happen before
/// construction; this transport only reads the identity and signs TLS handshakes.
struct RemoteTLSIdentity: @unchecked Sendable {
    let value: SecIdentity
}

/// Opt-in TLS transport for production authorization. Construction requires a
/// provisioned identity and native platform verifier through the router. It is
/// deliberately never started by the legacy plaintext mobile service.
actor RemoteHTTPSListener {
    enum State: Sendable, Equatable { case stopped, starting, running, failed }
    nonisolated let states: AsyncStream<State>
    private let stateContinuation: AsyncStream<State>.Continuation
    private var onTermination: (@Sendable () async -> Void)?
    func installTerminationHandler(_ handler: @escaping @Sendable () async -> Void) throws {
        guard !started, !stopped, onTermination == nil else { throw RemoteAccessError.invalidConfiguration }
        onTermination = handler
    }
    typealias Handler = @Sendable (RemoteProductionAccessRouter.Request, RemoteAccessStore.Principal) async throws -> RemoteProductionAccessRouter.Response
    private let listener: NWListener
    private let router: RemoteProductionAccessRouter
    private let bindingRouter: RemoteBindingRouter?
    private let handler: Handler
    private let sessionService: RemoteSessionService?
    private let queue = DispatchQueue(label: "tomo.remote.https")
    private var started = false
    private var stopped = false
    private var connections: [UUID: NWConnection] = [:]
    private var deadlines: [UUID: Task<Void, Never>] = [:]
    private var requests: [UUID: Task<Void, Never>] = [:]
    private var streams: [UUID: RemoteSSEConnection] = [:]
    var streamCount: Int { streams.count }
    private let maximumConnections: Int

    deinit {
        stateContinuation.finish()
        listener.cancel()
        for task in deadlines.values { task.cancel() }
        for task in requests.values { task.cancel() }
        for stream in streams.values { stream.stop() }
        for connection in connections.values { connection.cancel() }
    }

    init(identity: RemoteTLSIdentity, router: RemoteProductionAccessRouter,
         bindHost: NWEndpoint.Host? = nil, maximumConnections: Int = 64,
         bindingRouter: RemoteBindingRouter? = nil,
         sessionService: RemoteSessionService? = nil,
         handler: @escaping Handler) throws {
        let stateStream = AsyncStream<State>.makeStream(bufferingPolicy: .bufferingNewest(1))
        states = stateStream.stream; stateContinuation = stateStream.continuation
        let portNumber = router.exchange.endpoint.port ?? 443
        guard bindingRouter == nil || bindingRouter?.endpoint == router.exchange.endpoint else { throw RemoteAccessError.invalidConfiguration }
        guard (1...65535).contains(portNumber), (1...64).contains(maximumConnections),
              let port = NWEndpoint.Port(rawValue: UInt16(portNumber)),
              let localIdentity = sec_identity_create(identity.value) else { throw RemoteAccessError.invalidConfiguration }
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity.value, &certificate) == errSecSuccess, let certificate,
              let hostname = router.exchange.endpoint.host else { throw RemoteAccessError.invalidConfiguration }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, hostname as CFString), &trust) == errSecSuccess,
              let trust, SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else { throw RemoteAccessError.invalidConfiguration }
        SecTrustSetNetworkFetchAllowed(trust, false)
        guard SecTrustEvaluateWithError(trust, nil) else { throw RemoteAccessError.invalidConfiguration }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, localIdentity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        if let bindHost { parameters.requiredLocalEndpoint = .hostPort(host: bindHost, port: port) }
        self.listener = try bindHost == nil ? NWListener(using: parameters, on: port) : NWListener(using: parameters)
        self.router = router; self.handler = handler; self.maximumConnections = maximumConnections
        self.bindingRouter = bindingRouter
        self.sessionService = sessionService
    }

    func start() async throws {
        guard !started, !stopped else { throw RemoteAccessError.invalidConfiguration }
        started = true
        stateContinuation.yield(.starting)
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        let listener = self.listener
        let startupDeadline = Task {
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            listener.cancel()
        }
        defer { startupDeadline.cancel() }
        do {
            try await withTaskCancellationHandler {
              try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Network delivers state events serially on queue. Complete once
                // and replace the setup handler before resuming the caller.
                listener.stateUpdateHandler = { [listener, weak self] state in
                    switch state {
                    case .ready:
                        listener.stateUpdateHandler = { [weak self] state in
                            if case .failed = state { Task { await self?.failed() } }
                        }
                        continuation.resume()
                    case .failed(let error):
                        listener.stateUpdateHandler = nil
                        listener.cancel()
                        continuation.resume(throwing: error)
                    case .cancelled:
                        listener.stateUpdateHandler = nil
                        continuation.resume(throwing: CancellationError())
                    default: break
                    }
                }
                listener.start(queue: queue)
              }
            } onCancel: {
                listener.cancel()
            }
            guard !stopped else { throw CancellationError() }
            stateContinuation.yield(.running)
        } catch { terminate(error is CancellationError ? .stopped : .failed); throw error }
    }

    func stop() { terminate(.stopped) }
    private func failed() { terminate(.failed) }
    private func terminate(_ state: State) {
        guard !stopped else { return }
        stopped = true
        listener.cancel()
        for task in deadlines.values { task.cancel() }
        for task in requests.values { task.cancel() }
        for stream in streams.values { stream.stop() }
        for connection in connections.values { connection.cancel() }
        deadlines.removeAll(); requests.removeAll(); streams.removeAll(); connections.removeAll()
        stateContinuation.yield(state); stateContinuation.finish()
        if let onTermination { Task { await onTermination() } }
    }

    private func accept(_ connection: NWConnection) {
        let occupied = Set(connections.keys).union(requests.keys).count
        guard started, !stopped, occupied < maximumConnections else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { Task { await self?.close(id) } }
            if case .cancelled = state { Task { await self?.close(id) } }
        }
        deadlines[id] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            await self?.close(id)
        }
        connection.start(queue: queue)
        receive(id, buffer: Data())
    }

    private func receive(_ id: UUID, buffer: Data) {
        guard let connection = connections[id] else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            Task { await self?.received(id, buffer: buffer, data: data, complete: complete, failed: error != nil) }
        }
    }
    private func received(_ id: UUID, buffer: Data, data: Data?, complete: Bool, failed: Bool) {
        guard connections[id] != nil else { return }
        if failed { close(id); return }
        var buffer = buffer
        if let data { buffer.append(data) }
        switch HTTPRequestFramer.inspect(buffer) {
        case .incomplete:
            if complete { close(id) } else { receive(id, buffer: buffer) }
        case .rejected(let status): send(id, response: Self.error(status))
        case .complete(let bytes):
            guard let request = try? Self.parse(bytes) else { send(id, response: Self.error(400)); return }
            requests[id] = Task { [weak self, router, bindingRouter, handler] in
                let result: RemoteProductionAccessRouter.Result
                if let bindingRouter, request.path == RemoteBindingRouter.root || request.path.hasPrefix(RemoteBindingRouter.root + "/") {
                    result = .response(await bindingRouter.handle(request))
                } else { result = await router.handle(request) }
                let response: RemoteProductionAccessRouter.Response
                switch result {
                case .response(let value): response = value
                case .authorized(let principal):
                    do {
                        try Task.checkCancellation()
                        try await router.exchange.validate(principal)
                        let segments = request.path.split(separator: "/")
                        if segments.count == 6, segments[3] == "sessions", segments[5] == "events" {
                            guard request.method == "GET", request.body.isEmpty else { throw RemoteReadError.invalidRequest }
                            guard let self else { throw CancellationError() }
                            try await self.startStream(id, sessionId: String(segments[4]), request: request, principal: principal)
                            return
                        }
                        let value: RemoteProductionAccessRouter.Response
                        if segments.count == 6, segments[3] == "sessions", segments[5] == "sync" {
                            guard request.method == "GET", request.body.isEmpty else { throw RemoteReadError.invalidRequest }
                            guard let self else { throw CancellationError() }
                            value = try await self.sync(sessionId: String(segments[4]), request: request, principal: principal)
                        } else { value = try await handler(request, principal) }
                        try Task.checkCancellation()
                        // Reject data prepared while a binding/runtime was revoked.
                        try await router.exchange.validate(principal)
                        response = value
                    } catch { response = Self.failure(error) }
                }
                await self?.finished(id, response: response)
            }
        }
    }

    private func sync(sessionId: String, request: RemoteProductionAccessRouter.Request,
                      principal: RemoteAccessStore.Principal) async throws -> RemoteProductionAccessRouter.Response {
        guard let service = sessionService else { throw RemoteReadError.notImplemented }
        guard service.serverId == router.exchange.serverId else { throw RemoteAccessError.invalidConfiguration }
        return .init(status: 200, headers: ["Content-Type": "application/json"],
                     body: try await service.sync(sessionId: sessionId, query: request.query, principal: principal))
    }

    private func startStream(_ id: UUID, sessionId: String, request: RemoteProductionAccessRouter.Request,
                             principal: RemoteAccessStore.Principal) async throws {
        guard let service = sessionService else { throw RemoteReadError.notImplemented }
        guard service.serverId == router.exchange.serverId else { throw RemoteAccessError.invalidConfiguration }
        var query = request.query
        let after = query.removeValue(forKey: "after")
        let header = request.headers.first { $0.0.lowercased() == "last-event-id" }?.1.trimmingCharacters(in: .whitespaces)
        guard after == nil || header == nil || after == header,
              let cursor = header ?? after, !cursor.isEmpty else { throw RemoteReadError.invalidRequest }
        let feed = try await service.open(sessionId: sessionId, query: query, cursor: cursor, principal: principal)
        do {
            try Task.checkCancellation()
            try await router.exchange.validate(principal)
            guard !stopped, let connection = connections[id], streams.count < 32 else { throw RemoteReadError.unavailable }
            let stream = RemoteSSEConnection(connection: connection, service: service, access: router.exchange,
                principal: principal, feed: feed, allowBrowserOrigin: false, onClose: { [weak self] in
                    Task { await self?.close(id) }
                })
            streams[id] = stream
            deadlines.removeValue(forKey: id)?.cancel()
            requests.removeValue(forKey: id)
            stream.start()
        } catch { await service.close(feed); throw error }
    }

    private func finished(_ id: UUID, response: RemoteProductionAccessRouter.Response) {
        requests.removeValue(forKey: id)
        send(id, response: response)
    }

    private func send(_ id: UUID, response: RemoteProductionAccessRouter.Response) {
        guard let connection = connections[id] else { return }
        // Journal projections admit up to 16 MiB. Reserve bounded space for the
        // flattened sync envelope/cursor so a valid snapshot is not truncated.
        guard (100...599).contains(response.status), response.body.count <= 17 * 1024 * 1024,
              response.headers.allSatisfy({ name, value in
                  name.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil &&
                  !value.utf8.contains(where: { $0 == 0 || $0 == 10 || $0 == 13 })
              }) else { close(id); return }
        var headers = response.headers.filter { !["content-length", "connection", "transfer-encoding", "cache-control", "pragma"].contains($0.key.lowercased()) }
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        headers["Cache-Control"] = "no-store"
        headers["Pragma"] = "no-cache"
        var bytes = Data(("HTTP/1.1 \(response.status) Response\r\n" + headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)\r\n" }.joined() + "\r\n").utf8)
        bytes.append(response.body)
        connection.send(content: bytes, completion: .contentProcessed { [weak self] _ in
            Task { await self?.close(id) }
        })
    }
    private func close(_ id: UUID) {
        streams.removeValue(forKey: id)?.stop()
        deadlines.removeValue(forKey: id)?.cancel()
        // A verifier/handler may ignore cooperative cancellation. Retain its
        // occupied slot until it returns instead of admitting unbounded tasks.
        requests[id]?.cancel()
        connections.removeValue(forKey: id)?.cancel()
    }

    /// Only origin-form targets are accepted; neither Host nor Forwarded can
    /// override the trusted endpoint used for DPoP. Preserve raw header pairs.
    static func parse(_ bytes: Data) throws -> RemoteProductionAccessRouter.Request {
        guard case .complete = HTTPRequestFramer.inspect(bytes),
              let separator = bytes.range(of: Data("\r\n\r\n".utf8)),
              let text = String(data: bytes[..<separator.lowerBound], encoding: .utf8) else { throw RemoteReadError.invalidRequest }
        let lines = text.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").components(separatedBy: " ")
        guard first.count == 3, first[1].hasPrefix("/"), !first[1].hasPrefix("//"),
              let target = URLComponents(string: first[1]), target.scheme == nil, target.host == nil,
              target.fragment == nil, target.percentEncodedPath == target.path,
              !target.path.contains("//"), !target.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw RemoteReadError.invalidRequest }
        var query: [String: String] = [:]
        for item in target.queryItems ?? [] {
            guard query[item.name] == nil, !item.name.isEmpty else { throw RemoteReadError.invalidRequest }
            query[item.name] = item.value ?? ""
        }
        let headers = try lines.dropFirst().map { line -> (String, String) in
            guard let colon = line.firstIndex(of: ":") else { throw RemoteReadError.invalidRequest }
            return (String(line[..<colon]), String(line[line.index(after: colon)...]))
        }
        return .init(method: first[0], path: target.path, query: query, headers: headers,
                     body: Data(bytes[separator.upperBound...]))
    }
    private static func error(_ status: Int) -> RemoteProductionAccessRouter.Response {
        .init(status: status, headers: ["Content-Type": "application/json"], body: Data("{\"error\":\"remote_request_rejected\"}".utf8))
    }
    private static func failure(_ error: Error) -> RemoteProductionAccessRouter.Response {
        switch error {
        case RemoteAccessError.unauthorized: return Self.error(401)
        case RemoteAccessError.forbidden: return Self.error(403)
        case RemoteReadError.invalidRequest, RemoteJournalError.invalidProjection: return Self.error(400)
        case RemoteReadError.cursorExpired, RemoteJournalError.cursorExpired: return Self.error(409)
        case RemoteReadError.notFound, RemoteJournalError.notFound: return Self.error(404)
        case RemoteReadError.notImplemented: return Self.error(501)
        default: return Self.error(503)
        }
    }
}
