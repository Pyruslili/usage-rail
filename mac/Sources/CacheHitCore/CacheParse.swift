import Foundation

enum ParseOutcome<T> {
    case value(T)
    case ignore
    case reject
}

enum UpdateEvent {
    case user(promptIndex: Int, createdAt: Date?, modelID: String?)
    case tool
    case rewind(target: Int)
    case completed(CompletionRecord)
}

struct CompletionRecord {
    var stopReason: String?
    var input: Int?
    var cached: Int?
    var cachedPresent: Bool
    var modelCalls: Int?
    var numTurns: Int?
}

enum ObserveKind {
    case prefix
    case usage
}

enum ObserveSource: Equatable {
    case vertex
    case fingerprint
}

struct ObserveRec {
    var source: ObserveSource
    var kind: ObserveKind
    var req: String?
    var conv: String?
    var turn: String?
    var model: String?
    var time: Date?
    var firstDiff: String?
    var hadFirstDiff: Bool
    var imageCount: Int?
    var promptTokens: Int?
    var cachedTokens: Int?
    var cachedPresent: Bool
    var status: Int?
    var order: Int
    /// True when this record came from a log opened mid-file. It cannot prove the turn's first request.
    var partial: Bool = false
}

struct SIWCRow {
    var time: Date?
    var model: String?
    var requestID: String
    var status: Int
    var input: Int
    var cached: Int
    var output: Int
}

func jsonInt(_ value: Any?) -> Int? {
    // `is Bool` is true for NSNumber 0 and 1 because of bridging. Only real booleans are rejected.
    if let value, type(of: value) == Bool.self { return nil }
    switch value {
    case let number as Int:
        return number
    case let number as Int64:
        return Int(exactly: number)
    case let number as Double:
        guard number.isFinite, number.rounded() == number else { return nil }
        return Int(exactly: number)
    case let number as NSNumber:
        return number.intValue
    default:
        return nil
    }
}

func jsonObject(_ line: String) -> [String: Any]? {
    guard let data = line.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return object
}

private let allowedModel = try! NSRegularExpression(pattern: #"^[A-Za-z0-9._:/+-]{1,64}$"#)
private let messageDiff = try! NSRegularExpression(pattern: #"^msg\[(\d+)\] ([A-Za-z]+)$"#)
private let siwcPattern = try! NSRegularExpression(
    pattern: #"^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2}),(\d{3}) INFO siwc_proxy: POST /v1/responses (\d+) model=(\S+) request_id=(\S+) (\d+)ms input=(\d+) cached=(\d+) \(([0-9.]+)%\) output=(\d+)\s*$"#
)
private let offsetTime = try! NSRegularExpression(
    pattern: #"^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2}) ([+-])(\d{2})(\d{2})?$"#
)

func cleanToken(_ value: String?) -> String? {
    guard let value, allowedModel.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil else {
        return nil
    }
    return value
}

func parseISO8601(_ text: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: text) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: text)
}

func parseOffsetTimestamp(_ text: String) -> Date? {
    guard let match = offsetTime.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
    func piece(_ index: Int) -> Int? {
        guard let range = Range(match.range(at: index), in: text) else { return nil }
        return Int(text[range])
    }
    guard let year = piece(1), let month = piece(2), let day = piece(3),
          let hour = piece(4), let minute = piece(5), let second = piece(6),
          let signRange = Range(match.range(at: 7), in: text),
          let offsetHour = piece(8) else { return nil }
    let sign = text[signRange] == "-" ? -1 : 1
    let offsetMinute = piece(9) ?? 0
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: sign * ((offsetHour * 3600) + (offsetMinute * 60))) ?? .gmt
    var parts = DateComponents()
    parts.year = year
    parts.month = month
    parts.day = day
    parts.hour = hour
    parts.minute = minute
    parts.second = second
    return calendar.date(from: parts)
}

func parseWallClock(date: String, time: String, milliseconds: String, zone: TimeZone) -> Date? {
    let dateParts = date.split(separator: "-").compactMap { Int($0) }
    let timeParts = time.split(separator: ":").compactMap { Int($0) }
    guard dateParts.count == 3, timeParts.count == 3, let ms = Int(milliseconds) else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    var parts = DateComponents()
    parts.year = dateParts[0]
    parts.month = dateParts[1]
    parts.day = dateParts[2]
    parts.hour = timeParts[0]
    parts.minute = timeParts[1]
    parts.second = timeParts[2]
    parts.nanosecond = ms * 1_000_000
    return calendar.date(from: parts)
}

func allowFirstDiff(_ value: Any?) -> String? {
    guard let text = value as? String else { return nil }
    if ["none", "first", "tools", "system", "params", "unkeyed", "skipped_inflight"].contains(text) {
        return text
    }
    let range = NSRange(text.startIndex..., in: text)
    guard let match = messageDiff.firstMatch(in: text, range: range),
          let indexRange = Range(match.range(at: 1), in: text),
          let roleRange = Range(match.range(at: 2), in: text) else {
        return nil
    }
    return "msg[\(text[indexRange])] \(text[roleRange])"
}

func imageCount(of value: Any?) -> Int? {
    guard let value, !(value is NSNull) else { return nil }
    guard let rows = value as? [Any] else { return nil }
    var total = 0
    for row in rows {
        guard let triple = row as? [Any], triple.count == 3, let count = jsonInt(triple[2]) else {
            return nil
        }
        total += count
    }
    return total
}

func parseUpdateLine(_ line: String) -> ParseOutcome<UpdateEvent> {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return .ignore }
    guard let root = jsonObject(trimmed) else { return .reject }
    guard let method = root["method"] as? String,
          method == "session/update" || method == "_x.ai/session/update",
          let params = root["params"] as? [String: Any],
          let update = params["update"] as? [String: Any],
          let kind = update["sessionUpdate"] as? String else {
        return .ignore
    }
    let envelope = jsonInt(root["timestamp"]).map { Date(timeIntervalSince1970: Double($0) / 1000) }
    switch kind {
    case "user_message_chunk":
        guard let meta = update["_meta"] as? [String: Any], let index = jsonInt(meta["promptIndex"]) else {
            return .ignore
        }
        let created = (meta["created_at"] as? String).flatMap(parseISO8601) ?? envelope
        let model = cleanToken(meta["modelId"] as? String)
        return .value(.user(promptIndex: index, createdAt: created, modelID: model))
    case "tool_call", "tool_call_update":
        return .value(.tool)
    case "rewind_marker":
        guard let target = jsonInt(update["target_prompt_index"]) else { return .ignore }
        return .value(.rewind(target: target))
    case "turn_completed":
        return .value(.completed(completion(from: update)))
    default:
        return .ignore
    }
}

private func completion(from update: [String: Any]) -> CompletionRecord {
    var record = CompletionRecord(
        stopReason: nil,
        input: nil,
        cached: nil,
        cachedPresent: false,
        modelCalls: nil,
        numTurns: nil
    )
    if let stop = update["stop_reason"] as? String,
       ["end_turn", "cancelled", "rate_limit"].contains(stop) {
        record.stopReason = stop
    }
    if let usage = update["usage"] as? [String: Any] {
        record.input = jsonInt(usage["inputTokens"])
        if let cached = jsonInt(usage["cachedReadTokens"]) {
            record.cached = cached
            record.cachedPresent = true
        }
        record.modelCalls = jsonInt(usage["modelCalls"])
        record.numTurns = jsonInt(usage["numTurns"])
    }
    return record
}

func parseVertexLine(_ line: String) -> ParseOutcome<ObserveRec> {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return .ignore }
    guard let root = jsonObject(trimmed) else { return .reject }
    guard (root["layer"] as? String) == "vertex_final_outbound" else { return .ignore }
    guard let event = root["event"] as? String else { return .ignore }
    let kind: ObserveKind
    switch event {
    case "prefix": kind = .prefix
    case "usage": kind = .usage
    default: return .ignore
    }
    return .value(observe(root, source: .vertex, kind: kind))
}

func parseFingerprintLine(_ line: String) -> ParseOutcome<ObserveRec> {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return .ignore }
    guard let root = jsonObject(trimmed) else { return .reject }
    guard root["msgs"] != nil || root["req"] != nil || root["model"] != nil else { return .ignore }
    return .value(observe(root, source: .fingerprint, kind: .prefix))
}

private func observe(_ root: [String: Any], source: ObserveSource, kind: ObserveKind) -> ObserveRec {
    let hadFirstDiff = root["first_diff"] != nil
    var cachedPresent = false
    var cached: Int?
    if let value = jsonInt(root["cached_tokens"]) {
        cached = value
        cachedPresent = true
    }
    return ObserveRec(
        source: source,
        kind: kind,
        req: nonEmpty(root["req"] as? String),
        conv: nonEmpty(root["conv"] as? String),
        turn: nonEmpty(root["turn"] as? String),
        model: cleanToken(root["model"] as? String),
        time: (root["ts"] as? String).flatMap(parseOffsetTimestamp),
        firstDiff: hadFirstDiff ? allowFirstDiff(root["first_diff"]) : nil,
        hadFirstDiff: hadFirstDiff,
        imageCount: imageCount(of: root["msgs"]),
        promptTokens: jsonInt(root["prompt_tokens"]),
        cachedTokens: cached,
        cachedPresent: cachedPresent,
        status: jsonInt(root["status"]),
        order: 0
    )
}

func parseSIWCLine(_ line: String, zone: TimeZone) -> ParseOutcome<SIWCRow> {
    if !line.contains("siwc_proxy:") || !line.contains("POST /v1/responses") { return .ignore }
    let range = NSRange(line.startIndex..., in: line)
    guard let match = siwcPattern.firstMatch(in: line, range: range) else { return .reject }
    func text(_ index: Int) -> String? {
        guard let part = Range(match.range(at: index), in: line) else { return nil }
        return String(line[part])
    }
    guard let day = text(1), let clock = text(2), let ms = text(3),
          let status = text(4).flatMap(Int.init),
          let model = text(5),
          let requestID = text(6),
          let input = text(8).flatMap(Int.init),
          let cached = text(9).flatMap(Int.init),
          let output = text(11).flatMap(Int.init) else {
        return .reject
    }
    return .value(SIWCRow(
        time: parseWallClock(date: day, time: clock, milliseconds: ms, zone: zone),
        model: cleanToken(model),
        requestID: requestID,
        status: status,
        input: input,
        cached: cached,
        output: output
    ))
}

private func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
}
