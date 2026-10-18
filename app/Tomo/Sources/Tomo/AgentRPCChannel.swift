import Foundation

/// Internal vendor wire data. Never forward this unfiltered to Remote API consumers.
indirect enum AgentJSON: Codable, Sendable, Equatable {
    case null, bool(Bool), integer(Int64), number(Double), string(String)
    case array([AgentJSON]), object([String: AgentJSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = .integer(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([AgentJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: AgentJSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

enum AgentRPCID: Hashable, Sendable {
    case string(String), integer(Int64)
    init(_ value: AgentJSON) throws {
        switch value {
        case .string(let v): self = .string(v)
        case .integer(let v): self = .integer(v)
        default: throw AgentRPCError.invalidFrame
        }
    }
    var json: AgentJSON {
        switch self { case .string(let v): .string(v); case .integer(let v): .integer(v) }
    }
}

enum AgentRPCError: Error, Sendable, Equatable {
    case invalidFrame, frameTooLarge, disconnected, timedOut, overloaded, duplicateRequest, unknownRequest, staleRequest
    case vendor(code: Int64, message: String)
}

enum AgentRPCEvent: Sendable, Equatable {
    case notification(method: String, params: AgentJSON)
    case request(id: AgentRPCID, method: String, params: AgentJSON)
    /// Local-only ordering marker. Never encoded to the vendor or Remote API.
    case checkpoint(UUID)
}

/// A single-consumer channel. Its transport must feed every committed JSONL frame,
/// even when no client request is pending. Overflow closes the channel: dropping an
/// approval or delta silently would leave the session projection inconsistent.
actor AgentRPCChannel {
    typealias Writer = @Sendable (Data) async throws -> Void
    nonisolated let events: AsyncThrowingStream<AgentRPCEvent, Error>
    private let continuation: AsyncThrowingStream<AgentRPCEvent, Error>.Continuation
    private let writer: Writer
    private var pending: [AgentRPCID: CheckedContinuation<AgentJSON, Error>] = [:]
    private var deadlines: [AgentRPCID: Task<Void, Never>] = [:]
    private struct IncomingRequest {
        let threadId: String?
        var replied = false
    }
    private var incomingRequests: [AgentRPCID: IncomingRequest] = [:]
    private var eventRevision: UInt64 = 0
    private var buffer = Data()
    private var terminal: AgentRPCError?
    private let frameLimit: Int
    private let pendingLimit: Int

    init(frameLimit: Int = 16 * 1024 * 1024, pendingLimit: Int = 128,
         eventLimit: Int = 256, writer: @escaping Writer) {
        self.frameLimit = max(1, frameLimit)
        self.pendingLimit = max(1, pendingLimit)
        self.writer = writer
        let pair = AsyncThrowingStream<AgentRPCEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(max(1, eventLimit)))
        events = pair.stream
        continuation = pair.continuation
    }

    func request(method: String, params: AgentJSON = .null, timeout: Duration = .seconds(15)) async throws -> AgentJSON {
        guard !method.isEmpty else { throw AgentRPCError.invalidFrame }
        if let terminal { throw terminal }
        guard pending.count < pendingLimit else { throw AgentRPCError.overloaded }
        try Task.checkCancellation()
        let id = AgentRPCID.string(UUID().uuidString)
        let data = try encode(["id": id.json, "method": .string(method), "params": params])
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { reply in
                pending[id] = reply
                deadlines[id] = Task {
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self.finish(id, result: .failure(AgentRPCError.timedOut))
                }
                Task {
                    guard self.pending[id] != nil else { return }
                    do { try await self.writer(data) }
                    catch { self.close(.disconnected) }
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func notify(method: String, params: AgentJSON = .null) async throws {
        if let terminal { throw terminal }
        guard !method.isEmpty else { throw AgentRPCError.invalidFrame }
        do { try await writer(encode(["method": .string(method), "params": params])) }
        catch { close(.disconnected); throw error }
    }

    @discardableResult
    func checkpoint(_ id: UUID) throws -> UInt64 {
        if let terminal { throw terminal }
        switch continuation.yield(.checkpoint(id)) {
        case .enqueued: return eventRevision
        case .dropped: close(.overloaded); throw AgentRPCError.overloaded
        case .terminated: throw AgentRPCError.disconnected
        @unknown default: throw AgentRPCError.disconnected
        }
    }

    /// The owner may supply the revision from its processed checkpoint. Any new
    /// upstream event invalidates that preflight before the callback is claimed.
    /// A scoped replied ID stays reserved until upstream resolves it, preventing
    /// ID reuse from mistaking an old resolution for a newer callback.
    func reply(id: AgentRPCID, result: AgentJSON, expectedEventRevision: UInt64? = nil) async throws {
        if let terminal { throw terminal }
        guard let request = incomingRequests[id], !request.replied else { throw AgentRPCError.unknownRequest }
        guard expectedEventRevision.map({ $0 == eventRevision }) ?? true else { throw AgentRPCError.staleRequest }
        let data = try encode(["id": id.json, "result": result])
        if request.threadId == nil { incomingRequests.removeValue(forKey: id) }
        else { incomingRequests[id]?.replied = true }
        do { try await writer(data) }
        catch { close(.disconnected); throw error }
    }

    func receive(_ bytes: Data) throws {
        if let terminal { throw terminal }
        // Split before appending so a transport read containing many valid frames
        // does not artificially exceed the limit of one unfinished frame.
        var start = bytes.startIndex
        while start < bytes.endIndex {
            let newline = bytes[start...].firstIndex(of: 10)
            let end = newline ?? bytes.endIndex
            guard buffer.count + bytes.distance(from: start, to: end) <= frameLimit else {
                close(.frameTooLarge); throw AgentRPCError.frameTooLarge
            }
            buffer.append(contentsOf: bytes[start..<end])
            if let newline {
                do { try dispatch(buffer) } catch {
                    let failure = (error as? AgentRPCError) ?? .invalidFrame
                    close(failure); throw failure
                }
                buffer.removeAll(keepingCapacity: true)
                start = bytes.index(after: newline)
            } else { break }
        }
    }

    func close(_ error: AgentRPCError = .disconnected) {
        guard terminal == nil else { return }
        terminal = error
        buffer.removeAll(); incomingRequests.removeAll()
        for id in Array(pending.keys) { finish(id, result: .failure(error)) }
        continuation.finish(throwing: error)
    }

    private func cancel(_ id: AgentRPCID) { finish(id, result: .failure(CancellationError())) }
    private func finish(_ id: AgentRPCID, result: Result<AgentJSON, Error>) {
        deadlines.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }
    private func encode(_ object: [String: AgentJSON]) throws -> Data {
        var data = try JSONEncoder().encode(AgentJSON.object(object))
        guard data.count <= frameLimit else { throw AgentRPCError.frameTooLarge }
        data.append(10); return data
    }
    private func dispatch(_ data: Data) throws {
        guard String(data: data, encoding: .utf8) != nil,
              case .object(let object) = try JSONDecoder().decode(AgentJSON.self, from: data) else {
            throw AgentRPCError.invalidFrame
        }
        if let methodValue = object["method"] {
            guard case .string(let method) = methodValue, !method.isEmpty,
                  object["result"] == nil, object["error"] == nil else { throw AgentRPCError.invalidFrame }
            let event: AgentRPCEvent
            if let value = object["id"] {
                let id = try AgentRPCID(value)
                guard incomingRequests[id] == nil else { throw AgentRPCError.duplicateRequest }
                guard incomingRequests.count < pendingLimit else { throw AgentRPCError.overloaded }
                let threadId: String?
                if case .object(let params) = object["params"], case .string(let thread) = params["threadId"] { threadId = thread }
                else { threadId = nil }
                incomingRequests[id] = .init(threadId: threadId)
                event = .request(id: id, method: method, params: object["params"] ?? .null)
            } else {
                if method == "serverRequest/resolved" {
                    guard case .object(let params) = object["params"], case .string(let thread) = params["threadId"],
                          !thread.isEmpty, let rawId = params["requestId"] else { throw AgentRPCError.invalidFrame }
                    let id = try AgentRPCID(rawId)
                    if incomingRequests[id]?.threadId == thread { incomingRequests.removeValue(forKey: id) }
                }
                event = .notification(method: method, params: object["params"] ?? .null)
            }
            guard eventRevision < UInt64.max else { throw AgentRPCError.overloaded }
            eventRevision += 1
            switch continuation.yield(event) {
            case .enqueued: break
            case .dropped: throw AgentRPCError.overloaded
            case .terminated: throw AgentRPCError.disconnected
            @unknown default: throw AgentRPCError.disconnected
            }
        } else {
            guard let value = object["id"], (object["result"] != nil) != (object["error"] != nil) else {
                throw AgentRPCError.invalidFrame
            }
            let id = try AgentRPCID(value)
            if let error = object["error"] {
                guard case .object(let fields) = error, case .integer(let code) = fields["code"],
                      case .string(let message) = fields["message"] else { throw AgentRPCError.invalidFrame }
                finish(id, result: .failure(AgentRPCError.vendor(code: code, message: message)))
            } else { finish(id, result: .success(object["result"]!)) }
            // Valid late replies after timeout/cancel are ignored, never published as events.
        }
    }
}
