import Foundation
import Network

/// Independent from the legacy task-status stream/relay. Sends one bounded
/// journal record at a time and checks current authorization before every frame.
final class RemoteSSEConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let service: RemoteSessionService
    private let access: any RemotePrincipalValidator
    private let principal: RemoteAccessStore.Principal
    private let feed: RemoteSessionService.Feed
    private let onClose: @Sendable () -> Void
    private let allowBrowserOrigin: Bool
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var stopped = false

    init(connection: NWConnection, service: RemoteSessionService, access: any RemotePrincipalValidator,
         principal: RemoteAccessStore.Principal, feed: RemoteSessionService.Feed,
         allowBrowserOrigin: Bool = true, onClose: @escaping @Sendable () -> Void) {
        self.connection = connection; self.service = service; self.access = access
        self.principal = principal; self.feed = feed; self.onClose = onClose; self.allowBrowserOrigin = allowBrowserOrigin
    }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { self?.stop() }
            if case .failed = state { self?.stop() }
        }
        let shouldMonitor = lock.withLock { () -> Bool in
            guard task == nil else { return false }
            if stopped {
                task = Task { await self.service.close(self.feed); self.onClose() }
                return false
            }
            task = Task { await self.run() }
            return true
        }
        if shouldMonitor { monitorPeerClose() }
    }
    private func monitorPeerClose() {
        // GET SSE has no subsequent client frames. Keep a receive pending so an
        // idle browser abort releases the feed immediately, without waiting for
        // a heartbeat write to discover FIN/RST. Extra/pipelined data is rejected.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] data, _, complete, error in
            guard let self else { return }
            if complete || error != nil || data?.isEmpty == false { self.stop() }
            else if !self.lock.withLock({ self.stopped }) { self.monitorPeerClose() }
        }
    }
    func stop() {
        let running = lock.withLock { () -> Task<Void, Never>? in
            guard !stopped else { return nil }
            stopped = true; return task
        }
        running?.cancel(); connection.cancel()
    }
    private func run() async {
        var cursor = feed.cursor
        var sequence = feed.initial.afterSequence
        let epoch = feed.initial.streamEpoch
        var headersSent = false
        var heartbeat = ContinuousClock.now
        do {
            try await access.validate(principal)
            let cors = allowBrowserOrigin ? "Access-Control-Allow-Origin: *\r\n" : ""
            let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store, no-transform\r\n" + cors + "X-Accel-Buffering: no\r\nConnection: close\r\n\r\n: remote ready\n\n"
            try await send(Data(headers.utf8))
            headersSent = true
            stream: for await _ in feed.wakeups {
                try Task.checkCancellation()
                try await access.validate(principal)
                let batch = try await service.replay(feed, after: cursor, principal: principal)
                guard batch.streamEpoch == epoch, batch.afterSequence == sequence else { throw RemoteJournalError.cursorExpired }
                for record in batch.records {
                    let data = try await service.frame(record, feed: feed, principal: principal)
                    try await access.validate(principal)
                    try await send(data)
                    sequence = record.event.sequence; cursor = record.cursor
                    if record.event.type == "sync.required" || record.event.type.hasPrefix("approval.") || record.event.type.hasPrefix("question.") { break stream }
                }
                if batch.records.count == 128 { await service.nudge(feed) }
                for id in try await service.operationIDs(feed, principal: principal) {
                    let data = try await service.operationFrame(id: id, feed: feed, principal: principal)
                    try await access.validate(principal)
                    try await send(data)
                }
                if heartbeat.duration(to: ContinuousClock.now) >= .seconds(15) {
                    // A comment has no id/sequence and cannot advance replay state.
                    try await send(Data(": heartbeat\n\n".utf8)); heartbeat = ContinuousClock.now
                }
            }
        } catch RemoteAccessError.unauthorized {
            if headersSent {
                try? await send(RemoteSessionService.signalFrame(type: "access.revoked", ref: feed.ref, epoch: epoch,
                    sequence: sequence + 1, reason: "remote_access_expired_or_revoked"))
            } else { try? await send(Data("HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)) }
        } catch is CancellationError {
            // Closing the screen/server cancels the stream without inventing an event.
        } catch {
            if headersSent {
                if (try? await access.validate(principal)) != nil {
                    try? await send(RemoteSessionService.signalFrame(type: "sync.required", ref: feed.ref, epoch: epoch,
                        sequence: sequence + 1, reason: "remote_stream_resync_required"))
                }
            }
        }
        await service.close(feed)
        connection.cancel()
        onClose()
    }

    private func send(_ data: Data) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
                let completion = Completion(reply)
                DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
                    if completion.finish(AgentRPCError.timedOut) { self.connection.cancel() }
                }
                connection.send(content: data, completion: .contentProcessed { error in _ = completion.finish(error) })
            }
        } onCancel: { self.connection.cancel() }
    }
    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var reply: CheckedContinuation<Void, Error>?
        init(_ reply: CheckedContinuation<Void, Error>) { self.reply = reply }
        func finish(_ error: Error?) -> Bool {
            let value = lock.withLock { let value = reply; reply = nil; return value }
            guard let value else { return false }
            if let error { value.resume(throwing: error) } else { value.resume() }
            return true
        }
    }
}
