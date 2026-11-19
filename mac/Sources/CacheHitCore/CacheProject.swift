import Foundation

struct SessionTurn {
    var promptIndex: Int
    var createdAt: Date?
    var modelID: String?
    var modelChanged = false
    var sawTool = false
    var sawRewind = false
    var completions: [CompletionRecord] = []
}

private struct DraftCall {
    var conv: String?
    var turn: String?
    var figure: CallFigure
}

func projectCache(
    phase: CachePhase,
    banner: String?,
    sessionID: String?,
    sessionUpdated: Date?,
    turns: [Int: SessionTurn],
    orphans: [CompletionRecord] = [],
    vertex: [ObserveRec],
    fingerprints: [ObserveRec],
    siwc: [SIWCRow],
    notes: [String],
    now: Date,
    zone: TimeZone
) -> CacheSnapshot {
    let known = Set(turns.keys)
    let vertexDrafts = pairVertex(vertex)
    let fingerDrafts = fingerprintDrafts(fingerprints)
    var byTurn: [Int: [DraftCall]] = [:]
    var looseVertex: [DraftCall] = []
    var looseFinger: [DraftCall] = []
    var otherVertex = 0
    var otherFinger = 0

    for draft in vertexDrafts {
        switch place(conv: draft.conv, turn: draft.turn, session: sessionID, known: known) {
        case .linked(let index):
            byTurn[index, default: []].append(draft)
        case .unlinked:
            looseVertex.append(draft)
        case .other:
            otherVertex += 1
        case .hold:
            break
        }
    }
    for draft in fingerDrafts {
        switch place(conv: draft.conv, turn: draft.turn, session: sessionID, known: known) {
        case .linked(let index):
            byTurn[index, default: []].append(draft)
        case .unlinked:
            looseFinger.append(draft)
        case .other:
            otherFinger += 1
        case .hold:
            break
        }
    }

    let ordered = turns.keys.sorted()
    var rows: [TurnRow] = []
    for (position, index) in ordered.enumerated() {
        guard let turn = turns[index] else { continue }
        let previous = position > 0 ? turns[ordered[position - 1]] : nil
        rows.append(renderTurn(turn, calls: byTurn[index] ?? [], previous: previous, now: now, zone: zone))
    }
    rows.reverse()

    var unlinked: [UnlinkedGroup] = []
    if !looseVertex.isEmpty {
        unlinked.append(group(id: "vertex", title: "未关联 · Vertex", drafts: looseVertex))
    }
    if !looseFinger.isEmpty {
        unlinked.append(group(id: "fingerprint", title: "未关联 · 8317", drafts: looseFinger))
    }
    if !siwc.isEmpty {
        unlinked.append(siwcGroup(siwc))
    }
    if !orphans.isEmpty {
        var lines: [String] = ["没有对上用户消息"]
        let figures = orphans.map {
            SessionFigure(input: $0.input, cached: $0.cached, cachedPresent: $0.cachedPresent, modelCalls: $0.modelCalls, numTurns: $0.numTurns, stopReason: $0.stopReason)
        }
        for (offset, figure) in figures.enumerated() {
            lines.append(contentsOf: sessionLines(figure, index: offset + 1, total: figures.count))
        }
        unlinked.append(UnlinkedGroup(id: "orphan-usage", title: "未关联 · 会话合计", lines: lines, calls: []))
    }

    var statusNotes = notes
    if turns.isEmpty, sessionID != nil, !statusNotes.contains(where: { $0.contains("等待会话") || $0.contains("无法读取") || $0.contains("不在运行目录") }) {
        statusNotes.append("当前会话还没有用户消息")
    }
    if otherVertex > 0 {
        statusNotes.append("另有 \(otherVertex) 条 Vertex 记录属于别的会话，没有放进来")
    }
    if otherFinger > 0 {
        statusNotes.append("另有 \(otherFinger) 条 8317 记录属于别的会话，没有放进来")
    }
    if !fingerprints.isEmpty {
        statusNotes.append("8317 覆盖有限，不是 Vertex 最终出站")
        if let sessionUpdated, let newest = fingerprints.compactMap(\.time).max(), newest < sessionUpdated {
            statusNotes.append("8317 比当前会话旧")
        }
    }
    let status = statusNotes.isEmpty ? "已读取" : statusNotes.joined(separator: " · ")
    let summary: String
    if let newest = rows.first {
        summary = "最近 #\(newest.promptIndex) · \(newest.headline)"
    } else if phase == .notConfigured {
        summary = "未配置"
    } else {
        summary = "等待"
    }
    let snapshot = CacheSnapshot(
        phase: phase,
        banner: banner,
        summary: summary,
        status: status,
        turns: rows,
        unlinked: unlinked,
        footer: CacheSnapshot.footerText,
        visibleText: ""
    )
    return CacheSnapshot(
        phase: snapshot.phase,
        banner: snapshot.banner,
        summary: snapshot.summary,
        status: snapshot.status,
        turns: snapshot.turns,
        unlinked: snapshot.unlinked,
        footer: snapshot.footer,
        visibleText: visibleCopy(snapshot)
    )
}

func syntheticSnapshot(now: Date, zone: TimeZone) -> CacheSnapshot {
    let created = parseOffsetTimestamp("2026-01-15 14:17:00 +08") ?? now
    var turn = SessionTurn(promptIndex: 7, createdAt: created, modelID: "example-model-a")
    turn.completions = [CompletionRecord(
        stopReason: "end_turn",
        input: 20000,
        cached: 19800,
        cachedPresent: true,
        modelCalls: 1,
        numTurns: 1
    )]
    let prefix = ObserveRec(
        source: .vertex,
        kind: .prefix,
        req: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
        conv: "11111111-2222-4333-8444-555555555555",
        turn: "7",
        model: "example-vertex-model",
        time: created,
        firstDiff: "none",
        hadFirstDiff: true,
        imageCount: 2,
        promptTokens: nil,
        cachedTokens: nil,
        cachedPresent: false,
        status: nil,
        order: 1
    )
    let usage = ObserveRec(
        source: .vertex,
        kind: .usage,
        req: prefix.req,
        conv: prefix.conv,
        turn: prefix.turn,
        model: "example-vertex-model",
        time: created,
        firstDiff: nil,
        hadFirstDiff: false,
        imageCount: nil,
        promptTokens: 20000,
        cachedTokens: 19800,
        cachedPresent: true,
        status: 200,
        order: 2
    )
    let row = SIWCRow(
        time: created,
        model: "example-gpt-model",
        requestID: "req_synthetic_xyz",
        status: 200,
        input: 18000,
        cached: 9000,
        output: 640
    )
    return projectCache(
        phase: .synthetic,
        banner: "合成预览 · 不是本机数据",
        sessionID: "11111111-2222-4333-8444-555555555555",
        sessionUpdated: created,
        turns: [7: turn],
        orphans: [],
        vertex: [prefix, usage],
        fingerprints: [],
        siwc: [row],
        notes: ["合成预览 · 不是本机数据"],
        now: now,
        zone: zone
    )
}

private enum Placement {
    case linked(Int)
    case unlinked
    case other
    case hold
}

private func place(conv: String?, turn: String?, session: String?, known: Set<Int>) -> Placement {
    guard let session else { return .hold }
    guard let conv else { return .unlinked }
    if conv != session { return .other }
    guard let turn, let index = strictTurn(turn) else { return .unlinked }
    return known.contains(index) ? .linked(index) : .unlinked
}

private func strictTurn(_ text: String) -> Int? {
    guard !text.isEmpty, text.allSatisfy(\.isNumber) else { return nil }
    return Int(text)
}

private func pairVertex(_ records: [ObserveRec]) -> [DraftCall] {
    let sorted = records.sorted { $0.order < $1.order }
    var groups: [String: [ObserveRec]] = [:]
    var keys: [String] = []
    var unkeyed: [ObserveRec] = []
    for record in sorted {
        if let req = record.req {
            if groups[req] == nil { keys.append(req) }
            groups[req, default: []].append(record)
        } else {
            unkeyed.append(record)
        }
    }
    var drafts: [DraftCall] = []
    for key in keys {
        drafts.append(contentsOf: pairGroup(groups[key] ?? []))
    }
    for record in unkeyed {
        drafts.append(draft(record, sequence: 1, linkage: .unkeyed, hasPrefix: record.kind == .prefix, hasUsage: record.kind == .usage))
    }
    return drafts
}

private func pairGroup(_ records: [ObserveRec]) -> [DraftCall] {
    guard cleanPairs(records) else {
        return records.enumerated().map { offset, record in
            draft(record, sequence: offset + 1, linkage: .ambiguous, hasPrefix: record.kind == .prefix, hasUsage: record.kind == .usage)
        }
    }
    var drafts: [DraftCall] = []
    var index = 0
    var sequence = 1
    while index < records.count {
        if index + 1 < records.count, isPrefixUsage(records[index], records[index + 1]) {
            drafts.append(merged(records[index], records[index + 1], sequence: sequence))
            sequence += 1
            index += 2
        } else {
            drafts.append(draft(records[index], sequence: sequence, linkage: .pendingPrefix, hasPrefix: true, hasUsage: false))
            sequence += 1
            index += 1
        }
    }
    return drafts
}

private func cleanPairs(_ records: [ObserveRec]) -> Bool {
    var index = 0
    var pairs = 0
    while index < records.count {
        if index + 1 < records.count, isPrefixUsage(records[index], records[index + 1]) {
            pairs += 1
            index += 2
            continue
        }
        if index == records.count - 1, records[index].kind == .prefix {
            return true
        }
        return false
    }
    return pairs > 0
}

private func isPrefixUsage(_ prefix: ObserveRec, _ usage: ObserveRec) -> Bool {
    prefix.kind == .prefix && usage.kind == .usage && prefix.conv == usage.conv && prefix.turn == usage.turn
}

private func merged(_ prefix: ObserveRec, _ usage: ObserveRec, sequence: Int) -> DraftCall {
    let figure = CallFigure(
        id: "vertex-\(prefix.order)-\(usage.order)",
        sequence: sequence,
        source: "vertex",
        linkage: .paired,
        hasPrefix: true,
        hasUsage: true,
        input: usage.promptTokens,
        cached: usage.cachedTokens,
        cachedPresent: usage.cachedPresent,
        firstDiff: prefix.firstDiff,
        hadFirstDiff: prefix.hadFirstDiff,
        imageCount: prefix.imageCount,
        status: usage.status,
        order: prefix.order
    )
    return DraftCall(conv: prefix.conv, turn: prefix.turn, figure: figure)
}

private func draft(
    _ record: ObserveRec,
    sequence: Int,
    linkage: CallLinkage,
    hasPrefix: Bool,
    hasUsage: Bool
) -> DraftCall {
    let source = record.source == .vertex ? "vertex" : "fingerprint"
    let figure = CallFigure(
        id: "\(source)-\(record.order)",
        sequence: sequence,
        source: source,
        linkage: linkage,
        hasPrefix: hasPrefix,
        hasUsage: hasUsage,
        input: hasUsage ? record.promptTokens : nil,
        cached: hasUsage ? record.cachedTokens : nil,
        cachedPresent: hasUsage && record.cachedPresent,
        firstDiff: hasPrefix ? record.firstDiff : nil,
        hadFirstDiff: hasPrefix && record.hadFirstDiff,
        imageCount: hasPrefix ? record.imageCount : nil,
        status: hasUsage ? record.status : nil,
        order: record.order
    )
    return DraftCall(conv: record.conv, turn: record.turn, figure: figure)
}

private func fingerprintDrafts(_ records: [ObserveRec]) -> [DraftCall] {
    records.sorted { $0.order < $1.order }.enumerated().map { offset, record in
        draft(record, sequence: offset + 1, linkage: .fingerprint, hasPrefix: true, hasUsage: false)
    }
}

private func renderTurn(
    _ turn: SessionTurn,
    calls: [DraftCall],
    previous: SessionTurn?,
    now: Date,
    zone: TimeZone
) -> TurnRow {
    let figures = calls.map(\.figure).sorted { $0.order < $1.order }
    let sessions = turn.completions.map {
        SessionFigure(
            input: $0.input,
            cached: $0.cached,
            cachedPresent: $0.cachedPresent,
            modelCalls: $0.modelCalls,
            numTurns: $0.numTurns,
            stopReason: $0.stopReason
        )
    }
    var lines: [String] = []
    lines.append(contentsOf: figures.flatMap(callLines))
    let known = figures.filter(isKnownVertexHit)
    if known.count > 1, let hit = weightedHit(known.map { KnownHit(input: $0.input ?? 0, cached: $0.cached ?? 0) }) {
        lines.append("Vertex 合计 · 输入 \(hit.input) · 缓存 \(hit.cached) · \(hit.text)")
    }
    let unknownCached = figures.filter { $0.source == "vertex" && $0.linkage == .paired && $0.hasUsage && !$0.cachedPresent && ($0.status == nil || $0.status == 200) }
    if !unknownCached.isEmpty, !known.isEmpty {
        lines.append("其中 \(unknownCached.count) 次缓存未知，没有当成 0")
    }
    if figures.contains(where: { $0.linkage == .ambiguous }) {
        lines.append("有对应关系不明的记录，没有算进合计")
    }
    if turn.completions.count > 1 {
        lines.append("多条回合结束，没有拆成多条用户消息")
    }
    for (offset, session) in sessions.enumerated() {
        lines.append(contentsOf: sessionLines(session, index: offset + 1, total: sessions.count))
    }
    if !sessions.isEmpty, figures.contains(where: { $0.source == "vertex" && $0.hasUsage }) {
        lines.append("没有把会话合计和 Vertex 相加")
    }
    if !figures.contains(where: { $0.source == "vertex" && $0.hasPrefix }) {
        lines.append("这条没有 Vertex 最终出站指纹。原因未知 / 观察不可用")
    }
    if turn.sawTool, figures.contains(where: { $0.firstDiff == "tools" }) {
        lines.append("同时看到工具活动和 Vertex tools 变化。仍然不是结论。")
    }
    if calls.filter({ $0.figure.source == "fingerprint" }).count > 1 {
        lines.append("多条 8317 前缀没有合并")
    }

    var badges: [Badge] = []
    let imageTotal = figures.compactMap { figure -> Int? in
        guard figure.source == "vertex" else { return nil }
        return figure.imageCount
    }.reduce(0, +)
    let vertexSawImage = figures.contains { $0.source == "vertex" && $0.imageCount != nil }
    if vertexSawImage, imageTotal > 0 {
        badges.append(Badge(title: "图 \(imageTotal)", detail: "图片 \(imageTotal)。这是观察，不是原因。"))
    } else if !vertexSawImage, let fingerImages = figures.filter({ $0.source == "fingerprint" }).compactMap(\.imageCount).max(), fingerImages > 0 {
        badges.append(Badge(title: "图 \(fingerImages)", detail: "8317 图片 \(fingerImages)。这是观察，不是原因。"))
    }
    if turn.sawTool {
        badges.append(Badge(title: "工具", detail: "有工具活动。这是观察，不是原因。"))
    }
    if turn.sawRewind {
        badges.append(Badge(title: "回退", detail: "有回退标记。这是观察，不是前缀变化结论。"))
    }
    if turn.modelChanged || (previous?.modelID != nil && turn.modelID != nil && previous?.modelID != turn.modelID) {
        badges.append(Badge(title: "换模型", detail: "模型有变化。这是观察，不是原因。"))
    }
    if let previousDate = previous?.createdAt, let date = turn.createdAt {
        let gap = formatGap(date.timeIntervalSince(previousDate))
        badges.append(Badge(title: "间隔", detail: "与上一条间隔 \(gap)。间隔不能用来判断 TTL。"))
    }
    lines.append(contentsOf: badges.map(\.detail))

    let timeText = turn.createdAt.map { formatLocal($0, zone: zone, now: now) } ?? "时间未知"
    let modelText = turn.modelID ?? "模型未知"
    let pending = turn.completions.isEmpty && !figures.contains(where: { $0.hasUsage })
    return TurnRow(
        id: "turn-\(turn.promptIndex)",
        promptIndex: turn.promptIndex,
        timeText: timeText,
        modelText: modelText,
        headline: headline(sessions: sessions, calls: figures, pending: pending),
        badges: badges,
        lines: lines,
        calls: figures,
        sessionFigures: sessions
    )
}

private func isKnownVertexHit(_ call: CallFigure) -> Bool {
    call.source == "vertex"
        && call.linkage == .paired
        && call.cachedPresent
        && (call.input ?? 0) > 0
        && (call.status == nil || call.status == 200)
}

private func headline(sessions: [SessionFigure], calls: [CallFigure], pending: Bool) -> String {
    let known = calls.filter(isKnownVertexHit)
    if known.count == 1, let input = known[0].input, let cached = known[0].cached {
        return formatHit(cached: cached, input: input)
    }
    if known.count > 1, let hit = weightedHit(known.map { KnownHit(input: $0.input ?? 0, cached: $0.cached ?? 0) }) {
        return "合计 \(hit.text)"
    }
    if calls.contains(where: { $0.status == 429 }), known.isEmpty {
        return "限流 · 无可用命中率"
    }
    if sessions.count == 1 {
        let session = sessions[0]
        if session.stopReason == "rate_limit", session.input == nil, !session.cachedPresent {
            return "限流 · 无用量"
        }
        if session.stopReason == "cancelled", session.input == nil, !session.cachedPresent {
            return "未完成 · 无用量"
        }
        if session.cachedPresent, let cached = session.cached, let input = session.input, input > 0 {
            let text = formatHit(cached: cached, input: input)
            let multi = (session.modelCalls ?? 0) > 1 || (session.numTurns ?? 0) > 1
            return multi ? "合计 \(text)" : text
        }
    }
    if pending { return "进行中" }
    return "缓存未知"
}

private func sessionLines(_ session: SessionFigure, index: Int, total: Int) -> [String] {
    let multi = (session.modelCalls ?? 0) > 1 || (session.numTurns ?? 0) > 1
    let unknownCount = session.modelCalls == nil && session.numTurns == nil && (session.input != nil || session.cachedPresent)
    var label = total > 1 ? "会话记录 \(index)" : "会话日志"
    if multi {
        let count = session.modelCalls ?? session.numTurns ?? 0
        label += " · 合计 · \(count) 次 · 不可拆"
    } else if unknownCount {
        label += " · 次数未知 · 不拆"
    }
    if session.stopReason == "rate_limit", session.input == nil, !session.cachedPresent {
        return ["限流 · 无用量"]
    }
    if session.stopReason == "cancelled", session.input == nil, !session.cachedPresent {
        return ["未完成 · 无用量"]
    }
    guard session.input != nil || session.cachedPresent else {
        return ["\(label) · 无用量 · 缓存未知"]
    }
    var lines = ["\(label) · \(tokenPhrase(input: session.input, cached: session.cached, cachedPresent: session.cachedPresent))"]
    if multi { lines.append("没有把合计拆成单次") }
    return lines
}

private func callLines(_ call: CallFigure) -> [String] {
    if call.source == "fingerprint" || call.linkage == .fingerprint {
        var lines = ["8317 前缀 · 没有 first_diff · 不能把它当成前缀没变 · 覆盖有限 · 不是 Vertex 最终出站"]
        if let count = call.imageCount, count > 0 {
            lines.append("图片 \(count)。这是观察，不是原因。")
        }
        return lines
    }
    switch call.linkage {
    case .paired:
        var head = "Vertex 最终出站 · \(tokenPhrase(input: call.input, cached: call.cached, cachedPresent: call.cachedPresent))"
        head += statusSuffix(call.status)
        return [head, prefixSentence(call)] + imageLine(call)
    case .pendingPrefix:
        return ["Vertex 最终出站 · 进行中 · 还没有用量", prefixSentence(call)] + imageLine(call)
    case .ambiguous:
        if call.hasUsage {
            var head = "Vertex · 对应关系不明 · 只有用量 · \(tokenPhrase(input: call.input, cached: call.cached, cachedPresent: call.cachedPresent))"
            head += statusSuffix(call.status)
            return [head, "用量和前缀没有配成一对"]
        }
        return ["Vertex · 对应关系不明 · 只有前缀", prefixSentence(call)] + imageLine(call)
    case .unkeyed:
        if call.hasUsage {
            var head = "Vertex · 没有请求号 · 只有用量 · \(tokenPhrase(input: call.input, cached: call.cached, cachedPresent: call.cachedPresent))"
            head += statusSuffix(call.status)
            return [head, "没有和别的记录配对"]
        }
        return ["Vertex · 没有请求号 · 只有前缀", prefixSentence(call), "没有和别的记录配对"] + imageLine(call)
    case .fingerprint:
        return callLines(CallFigure(
            id: call.id,
            sequence: call.sequence,
            source: "fingerprint",
            linkage: .fingerprint,
            hasPrefix: true,
            hasUsage: false,
            input: nil,
            cached: nil,
            cachedPresent: false,
            firstDiff: nil,
            hadFirstDiff: false,
            imageCount: call.imageCount,
            status: nil,
            order: call.order
        ))
    }
}

private func statusSuffix(_ status: Int?) -> String {
    guard let status, status != 200 else { return "" }
    if status == 429 { return " · 限流" }
    return " · 未完成 \(status)"
}

private func imageLine(_ call: CallFigure) -> [String] {
    guard let count = call.imageCount, count > 0 else { return [] }
    return ["图片 \(count)。这是观察，不是原因。"]
}

private func prefixSentence(_ call: CallFigure) -> String {
    guard call.hadFirstDiff else { return "原因未知 / 观察不可用" }
    switch call.firstDiff {
    case "none":
        return "Vertex 观察：前缀未变。未知清缓存仍可能发生"
    case "first":
        return "Vertex 观察：首次"
    case "tools":
        return "Vertex 观察：tools 变化"
    case "system":
        return "Vertex 观察：system 变化"
    case "params":
        return "Vertex 观察：params 变化"
    case "unkeyed":
        return "Vertex 观察：没有请求号"
    case "skipped_inflight":
        return "Vertex 观察：进行中被跳过"
    case let value? where value.hasPrefix("msg["):
        return "Vertex 观察：\(value)。相同下标不是同一条历史"
    default:
        return "原因未知 / 观察不可用"
    }
}

private func group(id: String, title: String, drafts: [DraftCall]) -> UnlinkedGroup {
    let figures = drafts.map(\.figure).sorted { $0.order < $1.order }
    return UnlinkedGroup(id: id, title: title, lines: figures.flatMap(callLines), calls: figures)
}

private func siwcGroup(_ rows: [SIWCRow]) -> UnlinkedGroup {
    var lines: [String] = []
    var calls: [CallFigure] = []
    for (offset, row) in rows.enumerated() {
        var head = "GPT · 未关联 · \(tokenPhrase(input: row.input, cached: row.cached, cachedPresent: true))"
        if let model = row.model { head += " · \(model)" }
        head += statusSuffix(row.status)
        head += " · 输出 \(row.output)"
        lines.append(head)
        lines.append("没有会话号，不能对上某一条。原因未知 / 观察不可用。")
        calls.append(CallFigure(
            id: "siwc-\(offset)",
            sequence: offset + 1,
            source: "siwc",
            linkage: .unkeyed,
            hasPrefix: false,
            hasUsage: true,
            input: row.input,
            cached: row.cached,
            cachedPresent: true,
            firstDiff: nil,
            hadFirstDiff: false,
            imageCount: nil,
            status: row.status,
            order: offset
        ))
    }
    return UnlinkedGroup(id: "siwc", title: "未关联 · GPT", lines: lines, calls: calls, requestIDs: rows.map(\.requestID))
}

private func visibleCopy(_ snapshot: CacheSnapshot) -> String {
    var parts: [String] = []
    if let banner = snapshot.banner { parts.append(banner) }
    parts.append("缓存")
    parts.append(snapshot.summary)
    parts.append(snapshot.status)
    for turn in snapshot.turns {
        parts.append(turn.timeText)
        parts.append("#\(turn.promptIndex)")
        parts.append(turn.modelText)
        parts.append(turn.headline)
        parts.append(contentsOf: turn.badges.map(\.title))
        parts.append(contentsOf: turn.lines)
    }
    for group in snapshot.unlinked {
        parts.append(group.title)
        parts.append(contentsOf: group.lines)
    }
    parts.append(snapshot.footer)
    return parts.joined(separator: "\n")
}
