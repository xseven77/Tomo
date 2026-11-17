import Foundation
import Network

/// Dedicated read-only HTTP/1 listener. It never owns desktop Tokens, credentials,
/// proxy routes or remote session services. Binding defaults to IPv4 loopback.
@MainActor
final class ApiDocsServer {
    enum Status: Equatable { case starting, running, stopped, failed(String) }
    private let assets: ApiDocsAssets
    private let listener: NWListener
    private let queue = DispatchQueue(label: "tomo.api-docs")
    private var connections: [UUID: NWConnection] = [:]
    private var deadlines: [UUID: Task<Void, Never>] = [:]
    private var active = false
    private var startupDeadline: Task<Void, Never>?
    var onStatus: ((Status) -> Void)?

    init(directory: URL, port: UInt16 = 58351, allowLAN: Bool = false) throws {
        guard port != 0, let port = NWEndpoint.Port(rawValue: port) else { throw ApiDocsAssets.Failure.invalidSite }
        assets = try ApiDocsAssets(directory: directory)
        let parameters = NWParameters.tcp
        if !allowLAN { parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port) }
        listener = try allowLAN ? NWListener(using: parameters, on: port) : NWListener(using: parameters)
    }
    func start() {
        guard !active else { return }
        active = true; onStatus?(.starting)
        listener.stateUpdateHandler = { [weak self] state in Task { @MainActor in
            guard let self, self.active else { return }
            switch state {
            case .ready: self.startupDeadline?.cancel(); self.startupDeadline = nil; self.onStatus?(.running)
            case .failed(let error): self.stop(); self.onStatus?(.failed(error.localizedDescription))
            case .cancelled: self.stop()
            default: break
            }
        }}
        listener.newConnectionHandler = { [weak self] connection in Task { @MainActor in
            guard let self else { connection.cancel(); return }; self.accept(connection)
        } }
        startupDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard let self, self.active else { return }
            self.stop(); self.onStatus?(.failed("文档端口启动超时，请检查端口占用。"))
        }
        listener.start(queue: queue)
    }
    func stop() {
        active = false; startupDeadline?.cancel(); startupDeadline = nil; listener.cancel()
        for deadline in deadlines.values { deadline.cancel() }
        for connection in connections.values { connection.cancel() }
        deadlines.removeAll(); connections.removeAll(); onStatus?(.stopped)
    }
    private func accept(_ connection: NWConnection) {
        guard active, connections.count < 32 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { Task { @MainActor in self?.close(id) } }
            if case .cancelled = state { Task { @MainActor in self?.close(id) } }
        }
        deadlines[id] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            self?.close(id)
        }
        connection.start(queue: queue); receive(id, buffer: Data())
    }
    private func receive(_ id: UUID, buffer: Data) {
        guard let connection = connections[id] else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { return }
                var next = buffer; if let data { next.append(data) }
                if error != nil { self.close(id); return }
                guard next.count <= 16_384 else { self.send(id, status: 431); return }
                switch HTTPRequestFramer.inspect(next) {
                case .incomplete: if complete { self.close(id) } else { self.receive(id, buffer: next) }
                case .rejected(let status): self.send(id, status: status)
                case .complete: self.respond(id, request: next)
                }
            }
        }
    }
    private func respond(_ id: UUID, request: Data) {
        guard let text = String(data: request, encoding: .utf8), let separator = text.range(of: "\r\n\r\n"),
              separator.upperBound == text.endIndex, let line = text.components(separatedBy: "\r\n").first else { send(id, status: 400); return }
        let parts = line.split(separator: " ")
        guard parts.count == 3 else { send(id, status: 400); return }
        let method = String(parts[0])
        guard method == "GET" || method == "HEAD" else { send(id, status: 405); return }
        guard let asset = assets.asset(for: String(parts[1])) else { send(id, status: 404, head: method == "HEAD"); return }
        send(id, status: 200, asset: asset, head: method == "HEAD")
    }
    private func send(_ id: UUID, status: Int, asset: ApiDocsAssets.Asset? = nil, head: Bool = false) {
        guard let connection = connections[id] else { return }
        let data = asset?.data ?? Data("Documentation resource unavailable.\n".utf8)
        let cache = asset?.immutable == true ? "public, max-age=31536000, immutable" : "no-store"
        var header = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: \(asset?.mime ?? "text/plain; charset=utf-8")\r\nContent-Length: \(data.count)\r\nConnection: close\r\nCache-Control: \(cache)\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\n"
        if status == 405 { header += "Allow: GET, HEAD\r\n" }
        header += "\r\n"
        var response = Data(header.utf8); if !head { response.append(data) }
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in Task { @MainActor in self?.close(id) } })
    }
    private func close(_ id: UUID) {
        deadlines.removeValue(forKey: id)?.cancel()
        connections.removeValue(forKey: id)?.cancel()
    }
}
