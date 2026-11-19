import Foundation

public final class CacheEngine {
    public let config: CacheConfig
    public let limits: CacheLimits
    private let store: any TailStore
    private var updatesTail: LineTail?
    private var updatesPath: String?
    private var vertexTail: LineTail?
    private var fingerTail: LineTail?
    private var siwcTail: LineTail?
    private var sessionID: String?
    private var sessionUpdated: Date?
    private var sessionNote: String?
    private var turns: [TurnKey: SessionTurn] = [:]
    private var order: [TurnKey] = []
    private var pendingRewind: Set<Int> = []
    private var reopenIndex: Set<Int> = []
    private var vertex: [ObserveRec] = []
    private var fingerprints: [ObserveRec] = []
    private var siwc: [SIWCRow] = []
    private var sequence = 0
    private var rejected = 0
    private var sawTruncate = false
    private var openedAtTail = false
    private var updatesUnreadable = false
    private var updatesMissing = false
    private var vertexMissing = false
    private var vertexUnreadable = false
    private var fingerMissing = false
    private var fingerUnreadable = false
    private var siwcMissing = false
    private var siwcUnreadable = false
    private var orphans: [CompletionRecord] = []

    public init(config: CacheConfig, limits: CacheLimits = CacheLimits()) {
        self.config = config
        self.limits = limits
        self.store = LiveTailStore()
    }

    init(config: CacheConfig, limits: CacheLimits = CacheLimits(), store: any TailStore) {
        self.config = config
        self.limits = limits
        self.store = store
    }

    public func poll(now: Date = Date()) -> CacheSnapshot {
        if config.synthetic {
            return syntheticSnapshot(now: now, zone: config.timeZone)
        }
        guard let root = config.runtimeRoot?.trimmingCharacters(in: .whitespacesAndNewlines), !root.isEmpty else {
            return CacheSnapshot.empty(phase: .notConfigured, summary: "未配置", status: "未配置运行目录")
        }
        loadSession(root: root)
        if let updatesTail {
            let batch = updatesTail.poll(maxBytes: limits.maxBytes)
            if batch.reset {
                turns.removeAll()
                order.removeAll()
                pendingRewind.removeAll()
                reopenIndex.removeAll()
                orphans.removeAll()
            }
            if batch.truncated { sawTruncate = true }
            if batch.openedAtTail { openedAtTail = true }
            updatesUnreadable = batch.unreadable
            updatesMissing = batch.missing
            ingestUpdates(batch.lines)
        }
        ingestObserve(
            tail: &vertexTail,
            path: config.vertexPath,
            initial: limits.initialTailBytes,
            records: &vertex,
            missing: &vertexMissing,
            unreadable: &vertexUnreadable,
            markPartialOnTail: true,
            parse: parseVertexLine
        )
        ingestObserve(
            tail: &fingerTail,
            path: config.fingerprintPath,
            initial: limits.fingerprintInitialTailBytes,
            records: &fingerprints,
            missing: &fingerMissing,
            unreadable: &fingerUnreadable,
            parse: parseFingerprintLine
        )
        ingestSIWC()
        trim()
        var notes: [String] = []
        if let sessionNote { notes.append(sessionNote) }
        if updatesMissing { notes.append("等待会话记录") }
        if updatesUnreadable { notes.append("无法读取会话记录") }
        if vertexMissing { notes.append("Vertex 观察日志没有") }
        if vertexUnreadable { notes.append("Vertex 无法读取") }
        if fingerMissing { notes.append("8317 没有记录") }
        if fingerUnreadable { notes.append("8317 无法读取") }
        if siwcMissing { notes.append("GPT 日志没有") }
        if siwcUnreadable { notes.append("GPT 无法读取") }
        if sawTruncate { notes.append("日志被截断，已重新读") }
        if openedAtTail { notes.append("有日志只从末尾接着读") }
        if rejected > 0 { notes.append("有 \(rejected) 行读不懂，已跳过") }
        return projectCache(
            phase: sessionID == nil ? .waiting : .live,
            banner: nil,
            sessionID: sessionID,
            sessionUpdated: sessionUpdated,
            turns: turns,
            order: order,
            orphans: orphans,
            vertex: vertex,
            fingerprints: fingerprints,
            siwc: siwc,
            notes: notes,
            now: now,
            zone: config.timeZone
        )
    }

    private func loadSession(root: String) {
        let pointer = CacheConfig.sessionPointer(root: root)
        switch store.stat(pointer) {
        case .missing:
            dropSession("等待会话")
        case .unreadable:
            dropSession("无法读取会话")
        case .stat:
            switch store.read(pointer, offset: 0, maxBytes: 65_536) {
            case .missing:
                dropSession("等待会话")
            case .unreadable:
                dropSession("无法读取会话")
            case .data(let data):
                applyPointer(data, root: root)
            }
        }
    }

    private func applyPointer(_ data: Data, root: String) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let session = object["session_id"] as? String,
              let transcript = object["transcript_path"] as? String,
              !session.isEmpty, !transcript.isEmpty else {
            dropSession("等待会话")
            return
        }
        guard CacheConfig.pathIsInside(root: root, candidate: transcript) else {
            dropSession("会话路径不在运行目录内")
            return
        }
        let updated = (object["updated_at"] as? String).flatMap(parseISO8601)
        if session != sessionID || transcript != updatesPath {
            sessionID = session
            updatesPath = transcript
            turns.removeAll()
            order.removeAll()
            pendingRewind.removeAll()
            reopenIndex.removeAll()
            orphans.removeAll()
            updatesTail = LineTail(path: transcript, store: store, initialTailBytes: limits.initialTailBytes)
        }
        sessionUpdated = updated ?? sessionUpdated
        sessionNote = nil
    }

    private func dropSession(_ note: String) {
        sessionID = nil
        sessionUpdated = nil
        updatesPath = nil
        updatesTail = nil
        turns.removeAll()
        order.removeAll()
        pendingRewind.removeAll()
        reopenIndex.removeAll()
        orphans.removeAll()
        sessionNote = note
    }

    private func ingestUpdates(_ lines: [String]) {
        for line in lines {
            switch parseUpdateLine(line) {
            case .value(let event):
                apply(event)
            case .ignore:
                break
            case .reject:
                rejected += 1
            }
        }
    }

    private func apply(_ event: UpdateEvent) {
        switch event {
        case .user(let index, let created, let model):
            let latest = order.last { $0.promptIndex == index }
            let closed = latest.flatMap { turns[$0]?.completions.isEmpty == false } ?? false
            if latest == nil || closed || reopenIndex.contains(index) {
                reopenIndex.remove(index)
                let generation = (latest?.generation ?? 0) + 1
                let key = TurnKey(promptIndex: index, generation: generation)
                turns[key] = SessionTurn(promptIndex: index, generation: generation, createdAt: created, modelID: model)
                order.append(key)
            } else if let latest, var turn = turns[latest] {
                if let created {
                    if let existing = turn.createdAt {
                        if created < existing { turn.createdAt = created }
                    } else {
                        turn.createdAt = created
                    }
                }
                if let model {
                    if let existing = turn.modelID, existing != model { turn.modelChanged = true }
                    if turn.modelID == nil { turn.modelID = model }
                }
                turns[latest] = turn
            }
            if pendingRewind.contains(index), let key = order.last(where: { $0.promptIndex == index }) {
                turns[key]?.sawRewind = true
                pendingRewind.remove(index)
            }
        case .tool:
            guard let last = order.last else { return }
            turns[last]?.sawTool = true
            turns[last]?.toolCount += 1
        case .rewind(let target):
            reopenIndex.insert(target)
            if let key = order.last(where: { $0.promptIndex == target }) {
                turns[key]?.sawRewind = true
            } else {
                pendingRewind.insert(target)
            }
        case .completed(let completion):
            guard let last = order.last else {
                orphans.append(completion)
                return
            }
            turns[last]?.completions.append(completion)
        }
    }

    private func ingestObserve(
        tail: inout LineTail?,
        path: String,
        initial: Int,
        records: inout [ObserveRec],
        missing: inout Bool,
        unreadable: inout Bool,
        markPartialOnTail: Bool = false,
        parse: (String) -> ParseOutcome<ObserveRec>
    ) {
        if tail == nil {
            tail = LineTail(path: path, store: store, initialTailBytes: initial)
        }
        guard let tail else { return }
        let batch = tail.poll(maxBytes: limits.maxBytes)
        missing = batch.missing
        unreadable = batch.unreadable
        if batch.reset { records.removeAll() }
        if batch.truncated { sawTruncate = true }
        if batch.openedAtTail { openedAtTail = true }
        for line in batch.lines {
            switch parse(line) {
            case .value(var record):
                sequence += 1
                record.order = sequence
                if markPartialOnTail && batch.openedAtTail {
                    record.partial = true
                }
                records.append(record)
            case .ignore:
                break
            case .reject:
                rejected += 1
            }
        }
    }

    private func ingestSIWC() {
        if siwcTail == nil {
            siwcTail = LineTail(path: config.siwcPath, store: store, initialTailBytes: limits.initialTailBytes)
        }
        guard let siwcTail else { return }
        let batch = siwcTail.poll(maxBytes: limits.maxBytes)
        siwcMissing = batch.missing
        siwcUnreadable = batch.unreadable
        if batch.reset { siwc.removeAll() }
        if batch.truncated { sawTruncate = true }
        if batch.openedAtTail { openedAtTail = true }
        for line in batch.lines {
            switch parseSIWCLine(line, zone: config.timeZone) {
            case .value(let row):
                siwc.append(row)
            case .ignore:
                break
            case .reject:
                rejected += 1
            }
        }
    }

    private func trim() {
        while order.count > limits.maxTurns {
            let removed = order.removeFirst()
            turns.removeValue(forKey: removed)
        }
        if vertex.count > limits.maxVertex {
            vertex.removeFirst(vertex.count - limits.maxVertex)
        }
        if fingerprints.count > limits.maxFingerprint {
            fingerprints.removeFirst(fingerprints.count - limits.maxFingerprint)
        }
        if siwc.count > limits.maxSIWC {
            siwc.removeFirst(siwc.count - limits.maxSIWC)
        }
        if orphans.count > limits.maxSIWC {
            orphans.removeFirst(orphans.count - limits.maxSIWC)
        }
    }
}
