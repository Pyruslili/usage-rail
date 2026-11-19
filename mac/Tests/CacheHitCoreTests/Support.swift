import Foundation
import XCTest
@testable import CacheHitCore

final class MemoryFiles: TailStore {
    struct File {
        var inode: UInt64
        var data: Data
        var unreadable = false
        var modified: Date?
    }

    var files: [String: File] = [:]

    func stat(_ path: String) -> TailStatResult {
        guard let file = files[path] else { return .missing }
        if file.unreadable { return .unreadable }
        return .stat(TailStat(device: 1, inode: file.inode, size: UInt64(file.data.count), modified: file.modified))
    }

    func read(_ path: String, offset: UInt64, maxBytes: Int) -> TailReadResult {
        guard let file = files[path] else { return .missing }
        if file.unreadable { return .unreadable }
        let start = Int(offset)
        guard start < file.data.count else { return .data(Data()) }
        let end = min(file.data.count, start + max(0, maxBytes))
        return .data(file.data.subdata(in: start..<end))
    }
}

struct Lab {
    let files = MemoryFiles()
    let root = "/runtime"
    let session = "11111111-2222-4333-8444-555555555555"
    let zone = TimeZone(secondsFromGMT: 8 * 3600)!
    let now: Date
    var engine: CacheEngine
    let transcript: String

    init(limits: CacheLimits = CacheLimits(initialTailBytes: 8_000_000, fingerprintInitialTailBytes: 8_000_000)) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        now = calendar.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: 23))!
        transcript = "/runtime/state/noxbuild-room/.grok-home/.grok/sessions/ws/11111111-2222-4333-8444-555555555555/updates.jsonl"
        files.files["/runtime/vertex.jsonl"] = MemoryFiles.File(inode: 10, data: Data())
        files.files["/runtime/finger.jsonl"] = MemoryFiles.File(inode: 11, data: Data())
        files.files["/runtime/siwc.log"] = MemoryFiles.File(inode: 12, data: Data())
        let config = CacheConfig(
            runtimeRoot: root,
            vertexPath: "/runtime/vertex.jsonl",
            fingerprintPath: "/runtime/finger.jsonl",
            siwcPath: "/runtime/siwc.log",
            synthetic: false,
            timeZone: zone
        )
        engine = CacheEngine(config: config, limits: limits, store: files)
    }

    func point(session: String? = nil, transcript: String? = nil, updated: String = "2026-01-15T16:00:00Z") {
        let object: [String: Any] = [
            "session_id": session ?? self.session,
            "transcript_path": transcript ?? self.transcript,
            "updated_at": updated
        ]
        files.files[CacheConfig.sessionPointer(root: root)] = MemoryFiles.File(
            inode: 1,
            data: try! JSONSerialization.data(withJSONObject: object)
        )
    }

    func write(_ path: String, _ text: String, inode: UInt64) {
        files.files[path] = MemoryFiles.File(inode: inode, data: Data(text.utf8))
    }

    func poll() -> CacheSnapshot {
        engine.poll(now: now)
    }
}

func jsonLine(_ object: Any) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object)
    return String(decoding: data, as: UTF8.self)
}

func userChunk(index: Int, created: String, model: String, body: String = "SECRET_BODY_do_not_show", url: String = "https://secret.example/a") -> String {
    jsonLine([
        "timestamp": 1_768_117_020_000,
        "method": "session/update",
        "params": [
            "sessionId": "11111111-2222-4333-8444-555555555555",
            "update": [
                "sessionUpdate": "user_message_chunk",
                "content": ["type": "text", "text": body + " " + url],
                "_meta": ["promptIndex": index, "created_at": created, "modelId": model, "noxContext": "ignore-me"]
            ],
            "_meta": ["eventId": "evt_\(index)", "agentTimestampMs": 1_768_117_020_000]
        ]
    ])
}

func toolChunk(raw: String = "SECRET_TOOL_INPUT") -> String {
    jsonLine([
        "method": "session/update",
        "params": [
            "update": [
                "sessionUpdate": "tool_call",
                "toolCallId": "tool_1",
                "rawInput": raw,
                "title": "SECRET_TITLE",
                "_meta": ["x.ai/tool": ["input": raw]]
            ]
        ]
    ])
}

func rewindChunk(target: Int) -> String {
    jsonLine([
        "method": "session/update",
        "params": [
            "update": [
                "sessionUpdate": "rewind_marker",
                "target_prompt_index": target,
                "created_at": "2026-01-15T14:20:00Z"
            ]
        ]
    ])
}

func completedChunk(stop: String = "end_turn", usage: [String: Int]? = nil) -> String {
    var update: [String: Any] = [
        "sessionUpdate": "turn_completed",
        "prompt_id": "prompt_forexample_aaaa",
        "stop_reason": stop
    ]
    if let usage { update["usage"] = usage }
    return jsonLine([
        "method": "session/update",
        "params": [
            "update": update,
            "_meta": ["eventId": "evt_done", "promptId": "prompt_forexample_aaaa"]
        ]
    ])
}

func vertexPrefix(req: String?, turn: String, diff: String? = "none", images: Int? = 0, conv: String, hash: String = "ab12cd34ef") -> String {
    var object: [String: Any] = [
        "event": "prefix",
        "layer": "vertex_final_outbound",
        "ts": "2026-01-15 14:17:05 +08",
        "model": "example-vertex-model",
        "stream": true,
        "conv": conv,
        "turn": turn
    ]
    if let req { object["req"] = req }
    if let images {
        object["msgs"] = [["user", hash, images]]
    }
    if let diff { object["first_diff"] = diff }
    return jsonLine(object)
}

func vertexUsage(req: String?, turn: String, prompt: Int, cached: Int? = nil, status: Int = 200, conv: String, includeNullCached: Bool = false) -> String {
    var object: [String: Any] = [
        "event": "usage",
        "layer": "vertex_final_outbound",
        "ts": "2026-01-15 14:17:09 +08",
        "model": "example-vertex-model",
        "conv": conv,
        "turn": turn,
        "status": status,
        "prompt_tokens": prompt,
        "candidates_tokens": 8
    ]
    if let req { object["req"] = req }
    if let cached { object["cached_tokens"] = cached }
    if includeNullCached { object["cached_tokens"] = NSNull() }
    return jsonLine(object)
}

func fingerprintLine(req: String, turn: String, conv: String, ts: String = "2026-01-15 06:00:00 +08") -> String {
    jsonLine([
        "ts": ts,
        "model": "example-gate-model",
        "bytes": 8000,
        "req": req,
        "conv": conv,
        "turn": turn,
        "msgs": [["user", "ab12cd34ef", 1]]
    ])
}

func siwcLine(cached: Int, input: Int, requestID: String = "req_synthetic_xyz", printed: String = "50.0", model: String = "example-gpt-model") -> String {
    "2026-01-15 14:19:01,004 INFO siwc_proxy: POST /v1/responses 200 model=\(model) request_id=\(requestID) 4100ms input=\(input) cached=\(cached) (\(printed)%) output=640\n"
}

func assertHonest(_ snapshot: CacheSnapshot, file: StaticString = #filePath, line: UInt = #line) {
    let text = snapshot.visibleText
    for phrase in ["没有本地改动", "因为", "导致", "所以未命中", "证明", "TTL 已", "TTL 没", "未过期", "ab12cd34ef", "SECRET_BODY", "secret.example", "SECRET_TOOL", "SECRET_TITLE"] {
        XCTAssertFalse(text.contains(phrase), "leaked or overclaimed [\(phrase)] in \(text)", file: file, line: line)
    }
    XCTAssertTrue(text.contains("不是原因"), file: file, line: line)
    XCTAssertTrue(text.contains("不能用来判断 TTL") || text.contains("间隔不能用来判断 TTL"), file: file, line: line)
}
