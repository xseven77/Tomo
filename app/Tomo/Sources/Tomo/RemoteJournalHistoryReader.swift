import Foundation

/// Frozen history pages from one locally registered journal. New streaming
/// revisions do not mutate an older page; a replaced source epoch invalidates it.
actor RemoteJournalHistoryReader {
    nonisolated let journal: RemoteSessionJournal
    nonisolated let ref: RemoteSessionRef
    private struct Cursor {
        let owner: RemoteAccessStore.PagingOwner, snapshot: UInt64, before: UInt64, expires: Date
        let epoch: String
        var recoverySnapshot: UInt64? = nil
        var lastUsed: UInt64
    }
    private var snapshots: [UInt64: RemoteMessageArchive.Snapshot] = [:]
    private var cursors: [String: Cursor] = [:]
    private var cursorAccess: UInt64 = 0
    private let maximumBytes: Int
    private let maximumSnapshots: Int

    init(journal: RemoteSessionJournal, ref: RemoteSessionRef, maximumBytes: Int = 8 * 1024 * 1024,
         maximumSnapshots: Int = 4) {
        self.journal = journal; self.ref = ref
        // Reserve space for the HistoryPage envelope and opaque cursor within
        // the archive page's 8 MiB budget, below the native response ceiling.
        self.maximumBytes = max(1, min(maximumBytes, 8 * 1024 * 1024 - 4096))
        self.maximumSnapshots = max(1, maximumSnapshots)
    }
    private func purge(_ now: Date) {
        snapshots = snapshots.filter {$0.value.expires > now}
        // Keep only bounded position metadata after snapshot expiry. Recovery
        // still requires current authorization and the original journal epoch.
        cursors = cursors.filter {$0.value.expires.addingTimeInterval(86400) > now}
    }
    private func capture(_ value: RemoteMessageArchive.Snapshot, now: Date) throws -> RemoteMessageArchive.Snapshot {
        if let same = snapshots[value.token] {return same}
        while snapshots.count >= maximumSnapshots {
            guard let oldest = snapshots.values.min(by: {$0.expires < $1.expires}) else {throw RemoteReadError.unavailable}
            snapshots.removeValue(forKey: oldest.token)
        }
        purge(now)
        snapshots[value.token] = value
        return value
    }
    /// snapshotBytes is an internal snapshot handle for the adapter protocol;
    /// callers only receive owner-bound opaque cursor strings.
    func window(limit: Int, snapshotBytes: UInt64?, beforeOffset: UInt64?, captured: RemoteJournalSync? = nil,
                retainingTurn: String? = nil, now: Date = Date()) async throws -> RolloutHistoryWindow {
        guard (1...100).contains(limit), now.timeIntervalSince1970.isFinite else {throw RolloutHistoryError.invalidWindow}
        purge(now)
        let snapshot: RemoteMessageArchive.Snapshot
        if let token = snapshotBytes {
            guard let saved = snapshots[token], saved.expires > now else {
                throw RolloutHistoryError.snapshotChanged
            }
            snapshot = saved
        } else {
            if let captured {
                guard captured.ref == ref else {throw RolloutHistoryError.sessionMismatch}
                if let saved = captured.historySnapshot {snapshot = try capture(saved, now: now)}
                else {
                    let saved = try await journal.historySnapshot(ref: ref, epoch: captured.streamEpoch, sequence: captured.sequence, now: now)
                    snapshot = try capture(saved, now: now)
                }
            } else {
                let saved = try await journal.historySnapshot(ref: ref, now: now)
                snapshot = try capture(saved, now: now)
            }
        }
        return try await journal.historyWindow(ref: ref, snapshot: snapshot, before: beforeOffset, limit: limit,
            retainingTurn: retainingTurn, maximumBytes: maximumBytes, now: now)
    }
    func page(principal: RemoteAccessStore.Principal, cursor: String? = nil, limit: Int = 50,
              captured: RemoteJournalSync? = nil, retainingTurn: String? = nil,
              now: Date = Date()) async throws -> RemoteReadService.HistoryPage {
        guard principal.expiresAt > now, principal.permits(agentId: ref.agentId, runtimeId: ref.runtimeId,
            sessionId: ref.sessionId, action: .readHistory) else {throw RemoteAccessError.forbidden}
        purge(now)
        let saved: Cursor?
        if let cursor {
            guard var value = cursors[cursor], value.owner == principal.pagingOwner else {throw RemoteReadError.cursorExpired}
            cursorAccess &+= 1; value.lastUsed = cursorAccess; cursors[cursor] = value
            saved = value
        } else {saved = nil}
        let value: RolloutHistoryWindow
        do {
            value = try await window(limit: limit, snapshotBytes: saved?.snapshot, beforeOffset: saved?.before,
                captured: captured, retainingTurn: cursor == nil ? retainingTurn : nil, now: now)
        } catch RolloutHistoryError.snapshotChanged where saved != nil {
            let saved = saved!
            let snapshot: RemoteMessageArchive.Snapshot
            if let token = saved.recoverySnapshot, let existing = snapshots[token], existing.expires > now {
                snapshot = existing
            } else {
                // An ordinal is stable only within the original journal epoch.
                // Replacement/reset must never continue into a different history.
                let fresh = try await journal.historySnapshot(ref: ref, epoch: saved.epoch, now: now)
                snapshot = try capture(fresh, now: now)
            }
            value = try await window(limit: limit, snapshotBytes: snapshot.token, beforeOffset: saved.before, now: now)
            if let cursor, cursors[cursor]?.owner == principal.pagingOwner {
                cursors[cursor]?.recoverySnapshot = snapshot.token
            }
        }
        guard principal.expiresAt > Date(), snapshots[value.snapshotBytes] != nil else {throw RemoteReadError.cursorExpired}
        var next: String?
        if let before = value.olderBeforeOffset {
            if let existing = cursors.first(where: {$0.value.owner == principal.pagingOwner && $0.value.snapshot == value.snapshotBytes && $0.value.before == before}) {
                cursorAccess &+= 1; cursors[existing.key]?.lastUsed = cursorAccess
                next = existing.key
            } else {
                guard let snapshot = snapshots[value.snapshotBytes] else {throw RemoteReadError.unavailable}
                // Bound metadata without limiting the number of pages in a
                // conversation. Keep recently used cursors available for retry.
                if cursors.count >= 128, let oldest = cursors.min(by: {$0.value.lastUsed < $1.value.lastUsed})?.key {
                    cursors.removeValue(forKey: oldest)
                }
                next = "jh_" + UUID().uuidString
                cursorAccess &+= 1
                cursors[next!] = .init(owner: principal.pagingOwner, snapshot: value.snapshotBytes, before: before,
                    expires: snapshot.expires, epoch: snapshot.epoch, lastUsed: cursorAccess)
            }
        }
        return .init(sessionId: ref.sessionId, messages: value.messages, olderHistoryCursor: next,
            hasOlder: next != nil, unsupportedContentCount: value.unsupportedContentCount)
    }
}
