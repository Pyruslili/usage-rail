import Foundation
import XCTest
@testable import CacheHitCore

final class CacheHitCoreTests: XCTestCase {
    func testMissingCachedIsUnknownNotZero() {
        let lab = Lab()
        lab.point()
        lab.write(lab.transcript, [
            userChunk(index: 8, created: "2026-01-15T14:18:00Z", model: "example-model-a"),
            completedChunk(usage: ["inputTokens": 21000, "outputTokens": 50, "cacheCreationTokens": 5000, "modelCalls": 1, "numTurns": 1])
        ].joined(separator: "\n") + "\n", inode: 2)
        lab.write("/runtime/vertex.jsonl", [
            vertexPrefix(req: "ffffffff-0000-4000-8000-111111111111", turn: "8", diff: "none", conv: lab.session),
            vertexUsage(req: "ffffffff-0000-4000-8000-111111111111", turn: "8", prompt: 21000, cached: nil, conv: lab.session)
        ].joined(separator: "\n") + "\n", inode: 10)
        let snapshot = lab.poll()
        let turn = snapshot.turns[0]
        XCTAssertEqual(turn.headline, "缓存未知")
        XCTAssertEqual(turn.calls[0].cachedPresent, false)
        XCTAssertNil(turn.calls[0].cached)
        XCTAssertFalse(snapshot.visibleText.contains("0%"))
        XCTAssertFalse(snapshot.visibleText.contains("缓存 0"))
        XCTAssertFalse(snapshot.visibleText.contains("5000"))
        XCTAssertTrue(snapshot.visibleText.contains("缓存未知"))
        assertHonest(snapshot)
    }

    func testNullCachedIsAlsoUnknown() {
        let lab = Lab()
        lab.point()
        lab.write(lab.transcript, userChunk(index: 8, created: "2026-01-15T14:18:00Z", model: "example-model-a") + "\n", inode: 2)
        lab.write("/runtime/vertex.jsonl", [
            vertexPrefix(req: "req-null", turn: "8", conv: lab.session),
            vertexUsage(req: "req-null", turn: "8", prompt: 10, conv: lab.session, includeNullCached: true)
        ].joined(separator: "\n") + "\n", inode: 10)
        let turn = lab.poll().turns[0]
        XCTAssertFalse(turn.calls[0].cachedPresent)
        XCTAssertEqual(turn.headline, "缓存未知")
    }

    func testGenuineCachedZero() {
        let lab = Lab()
        lab.point()
        lab.write(lab.transcript, userChunk(index: 7, created: "2026-01-15T14:17:00Z", model: "example-model-a") + "\n", inode: 2)
        lab.write("/runtime/vertex.jsonl", [
            vertexPrefix(req: "req-zero", turn: "7", diff: "first", conv: lab.session),
            vertexUsage(req: "req-zero", turn: "7", prompt: 100, cached: 0, conv: lab.session)
        ].joined(separator: "\n") + "\n", inode: 10)
        let snapshot = lab.poll()
        XCTAssertEqual(snapshot.turns[0].calls[0].cached, 0)
        XCTAssertTrue(snapshot.turns[0].calls[0].cachedPresent)
        XCTAssertEqual(snapshot.turns[0].headline, "0%")
        XCTAssertTrue(snapshot.visibleText.contains("缓存 0"))
        XCTAssertTrue(snapshot.visibleText.contains("Vertex 观察：首次"))
    }

    func testExactLinkAndUnlinkedConv() {
        let lab = Lab()
        lab.point()
        lab.write(lab.transcript, userChunk(index: 7, created: "2026-01-15T14:17:00Z", model: "example-model-a") + "\n", inode: 2)
        lab.write("/runtime/vertex.jsonl", [
            vertexPrefix(req: "req-link", turn: "7", conv: lab.session),
            vertexUsage(req: "req-link", turn: "7", prompt: 20000, cached: 19800, conv: lab.session),
            vertexPrefix(req: "req-other", turn: "7", conv: "turn-example-not-a-session"),
            vertexUsage(req: "req-other", turn: "7", prompt: 777001, cached: 1, conv: "turn-example-not-a-session")
        ].joined(separator: "\n") + "\n", inode: 10)
        let snapshot = lab.poll()
        XCTAssertEqual(snapshot.turns.count, 1)
        XCTAssertEqual(snapshot.turns[0].calls.count, 1)
        XCTAssertEqual(snapshot.turns[0].calls[0].linkage, .paired)
        XCTAssertEqual(snapshot.turns[0].calls[0].input, 20000)
        XCTAssertEqual(snapshot.turns[0].headline, "99%")
        XCTAssertFalse(snapshot.visibleText.contains("777001"))
        XCTAssertTrue(snapshot.visibleText.contains("属于别的会话"))
        XCTAssertEqual(snapshot.turns[0].timeText, "22:17")
        XCTAssertTrue(snapshot.visibleText.contains("Vertex 最终出站"))
    }

    func testSIWCStaysUnlinkedAndIgnoresPrintedPercent() {
        let lab = Lab()
        lab.point()
        let created = "2026-01-15T06:19:01Z"
        lab.write(lab.transcript, userChunk(index: 4, created: created, model: "example-gpt-model") + "\n", inode: 2)
        lab.write("/runtime/siwc.log", [
            siwcLine(cached: 1, input: 3, requestID: "req_synthetic_xyz", printed: "50.0"),
            "2026-01-15 14:19:02,004 INFO siwc_proxy: POST /v1/responses 200 model=example-gpt-model req_id=req_wrong_key 10ms input=888001 cached=1 (50.0%) output=1\n"
        ].joined(), inode: 12)
        let snapshot = lab.poll()
        XCTAssertTrue(snapshot.turns[0].calls.isEmpty)
        let group = snapshot.unlinked.first { $0.id == "siwc" }
        XCTAssertEqual(group?.requestIDs, ["req_synthetic_xyz"])
        XCTAssertEqual(group?.calls.count, 1)
        XCTAssertEqual(group?.calls[0].input, 3)
        XCTAssertEqual(group?.calls[0].cached, 1)
        XCTAssertTrue(snapshot.visibleText.contains("33.3%"))
        XCTAssertTrue(snapshot.visibleText.contains("没有会话号，不能对上某一条"))
        XCTAssertTrue(snapshot.visibleText.contains("原因未知 / 观察不可用"))
        XCTAssertFalse(snapshot.visibleText.contains("req_synthetic_xyz"))
        XCTAssertFalse(snapshot.visibleText.contains("888001"))
        XCTAssertFalse(snapshot.visibleText.contains("50.0%"))
        XCTAssertFalse(snapshot.visibleText.contains("50%"))
    }

    func testMultipleCallsKeepOrderAndWeightedSum() {
        let lab = Lab()
        lab.point()
        lab.write(lab.transcript, userChunk(index: 7, created: "2026-01-15T14:17:00Z", model: "example-model-a") + "\n", inode: 2)
        lab.write("/runtime/vertex.jsonl", [
            vertexPrefix(req: "req-multi", turn: "7", diff: "first", conv: lab.session),
            vertexUsage(req: "req-multi", turn: "7", prompt: 100, cached: 0, conv: lab.session),
            vertexPrefix(req: "req-multi", turn: "7", diff: "none", conv: lab.session),
            vertexUsage(req: "req-multi", turn: "7", prompt: 1000, cached: 80, conv: lab.session)
        ].joined(separator: "\n") + "\n", inode: 10)
        let snapshot = lab.poll()
        let calls = snapshot.turns[0].calls
        XCTAssertEqual(calls.map(\.linkage), [.paired, .paired])
        XCTAssertEqual(calls.map(\.sequence), [1, 2])
        XCTAssertEqual(calls.map(\.cached), [0, 80])
        XCTAssertEqual(snapshot.turns[0].headline, "合计 7.3%")
        XCTAssertTrue(snapshot.visibleText.contains("输入 1100"))
        XCTAssertTrue(snapshot.visibleText.contains("缓存 80"))
        XCTAssertFalse(snapshot.visibleText.contains("4%"))
        XCTAssertTrue(snapshot.visibleText.contains("未知清缓存仍可能发生"))
        assertHonest(snapshot)
    }

    func testUnknownCachedIsLeftOutOfTheSum() {
        let lab = Lab()
        lab.point()
        lab.write(lab.transcript, userChunk(index: 7, created: "2026-01-15T14:17:00Z", model: "example-model-a") + "\n", inode: 2)
        lab.write("/runtime/vertex.jsonl", [
            vertexPrefix(req: "req-mix", turn: "7", diff: "none", conv: lab.session),
            vertexUsage(req: "req-mix", turn: "7", prompt: 10, cached: 10, conv: lab.session),
            vertexPrefix(req: "req-mix", turn: "7", diff: "none", conv: lab.session),
            vertexUsage(req: "req-mix", turn: "7", prompt: 100, cached: nil, conv: lab.session)
        ].joined(separator: "\n") + "\n", inode: 10)
        let snapshot = lab.poll()
        XCTAssertEqual(snapshot.turns[0].headline, "100%")
        XCTAssertTrue(snapshot.visibleText.contains("没有当成 0"))
        XCTAssertFalse(snapshot.visibleText.contains("输入 110"))
    }

    func testAggregateIsNotSplitAndNotMixedWithVertex() {
        let lab = Lab()
        lab.point()
        lab.write(lab.transcript, [
            userChunk(index: 3, created: "2026-01-15T14:00:00Z", model: "example-model-a"),
            completedChunk(usage: [
                "inputTokens": 80000,
                "cachedReadTokens": 10000,
                "modelCalls": 3,
                "numTurns": 3
            ])
        ].joined(separator: "\n") + "\n", inode: 2)
        let snapshot = lab.poll()
        XCTAssertEqual(snapshot.turns[0].calls.count, 0)
        XCTAssertEqual(snapshot.turns[0].sessionFigures[0].modelCalls, 3)
        XCTAssertEqual(snapshot.turns[0].headline, "合计 12.5%")
        XCTAssertTrue(snapshot.visibleText.contains("不可拆"))
        XCTAssertTrue(snapshot.visibleText.contains("没有把合计拆成单次"))
        XCTAssertTrue(snapshot.visibleText.contains("没有 Vertex 最终出站指纹"))
        XCTAssertFalse(snapshot.visibleText.contains("26666"))
        XCTAssertFalse(snapshot.visibleText.contains("没有本地改动"))
    }

    func testSessionAndVertexDenominatorsStaySeparate() {
        let lab = Lab()
        lab.point()
        lab.write(lab.transcript, [
            userChunk(index: 7, created: "2026-01-15T14:17:00Z", model: "example-model-a"),
            completedChunk(usage: ["inputTokens": 99, "cachedReadTokens": 1, "modelCalls": 1])
        ].joined(separator: "\n") + "\n", inode: 2)
        lab.write("/runtime/vertex.jsonl", [
            vertexPrefix(req: "req-sep", turn: "7", conv: lab.session),
            vertexUsage(req: "req-sep", turn: "7", prompt: 20, cached: 10, conv: lab.session)
        ].joined(separator: "\n") + "\n", inode: 10)
        let snapshot = lab.poll()
        XCTAssertEqual(snapshot.turns[0].calls[0].input, 20)
        XCTAssertEqual(snapshot.turns[0].sessionFigures[0].input, 99)
        XCTAssertTrue(snapshot.visibleText.contains("没有把会话合计和 Vertex 相加"))
        XCTAssertFalse(snapshot.visibleText.contains("输入 119"))
    }

    func testRateLimitHasNoUsage() {
        let lab = Lab()
        lab.point()
        lab.write(lab.transcript, [
            userChunk(index: 9, created: "2026-01-15T14:30:00Z", model: "example-model-a"),
            completedChunk(stop: "rate_limit")
        ].joined(separator: "\n") + "\n", inode: 2)
        let snapshot = lab.poll()
        XCTAssertEqual(snapshot.turns[0].headline, "限流 · 无用量")
        XCTAssertFalse(snapshot.visibleText.contains("0%"))
        XCTAssertFalse(snapshot.visibleText.contains("缓存 0"))
    }

    func testVertex429IsNotZero() {
        let lab = Lab()
        lab.point()
        lab.write(lab.transcript, userChunk(index: 7, created: "2026-01-15T14:17:00Z", model: "example-model-a") + "\n", inode: 2)
        lab.write("/runtime/vertex.jsonl", [
            vertexPrefix(req: "req-429", turn: "7", conv: lab.session),
            vertexUsage(req: "req-429", turn: "7", prompt: 50, cached: nil, status: 429, conv: lab.session)
        ].joined(separator: "\n") + "\n", inode: 10)
        let snapshot = lab.poll()
        XCTAssertEqual(snapshot.turns[0].headline, "限流 · 无可用命中率")
        XCTAssertTrue(snapshot.visibleText.contains("限流"))
        XCTAssertFalse(snapshot.visibleText.contains("0%"))
    }

    func testPendingTurn() {
        let lab = Lab()
        lab.point()
        lab.write(lab.transcript, userChunk(index: 2, created: "2026-01-15T13:00:00Z", model: "example-model-a") + "\n", inode: 2)
        let snapshot = lab.poll()
        XCTAssertEqual(snapshot.turns[0].headline, "进行中")
        XCTAssertTrue(snapshot.turns[0].calls.isEmpty)
    }

    func testAmbiguousSameRequestIsNotCrossPaired() {
        let lab = Lab()
        lab.point()
        lab.write(lab.transcript, userChunk(index: 7, created: "2026-01-15T14:17:00Z", model: "example-model-a") + "\n", inode: 2)
        lab.write("/runtime/vertex.jsonl", [
            vertexPrefix(req: "req-amb", turn: "7", diff: "tools", conv: lab.session),
            vertexPrefix(req: "req-amb", turn: "7", diff: "msg[1] user", conv: lab.session),
            vertexUsage(req: "req-amb", turn: "7", prompt: 10, cached: 5, conv: lab.session)
        ].joined(separator: "\n") + "\n", inode: 10)
        let calls = lab.poll().turns[0].calls
        XCTAssertEqual(calls.count, 3)
        XCTAssertTrue(calls.allSatisfy { $0.linkage == .ambiguous })
        XCTAssertFalse(calls.contains { $0.hasPrefix && $0.hasUsage })
        XCTAssertEqual(calls.map(\.sequence), [1, 2, 3])
        XCTAssertEqual(calls[0].firstDiff, "tools")
        XCTAssertNil(calls[2].firstDiff)
        XCTAssertEqual(calls[2].cached, 5)
        let text = lab.poll().visibleText
        XCTAssertTrue(text.contains("对应关系不明"))
        XCTAssertTrue(text.contains("相同下标不是同一条历史"))
        XCTAssertTrue(text.contains("没有算进合计"))
    }

    func testCleanTrailingPrefixStaysPending() {
        let lab = Lab()
        lab.point()
        lab.write(lab.transcript, userChunk(index: 7, created: "2026-01-15T14:17:00Z", model: "example-model-a") + "\n", inode: 2)
        lab.write("/runtime/vertex.jsonl", [
            vertexPrefix(req: "req-go", turn: "7", diff: "first", conv: lab.session),
            vertexUsage(req: "req-go", turn: "7", prompt: 10, cached: 0, conv: lab.session),
            vertexPrefix(req: "req-go", turn: "7", diff: "tools", conv: lab.session)
        ].joined(separator: "\n") + "\n", inode: 10)
        let calls = lab.poll().turns[0].calls
        XCTAssertEqual(calls.map(\.linkage), [.paired, .pendingPrefix])
        XCTAssertEqual(calls[0].cached, 0)
        XCTAssertFalse(calls[1].hasUsage)
    }

    func testUnkeyedRecordsAreNotPaired() {
        let lab = Lab()
        lab.point()
        lab.write(lab.transcript, userChunk(index: 7, created: "2026-01-15T14:17:00Z", model: "example-model-a") + "\n", inode: 2)
        lab.write("/runtime/vertex.jsonl", [
            vertexPrefix(req: nil, turn: "7", diff: "unkeyed", conv: lab.session),
            vertexUsage(req: nil, turn: "7", prompt: 40, cached: 10, conv: lab.session)
        ].joined(separator: "\n") + "\n", inode: 10)
        let calls = lab.poll().turns[0].calls
        XCTAssertEqual(calls.map(\.linkage), [.unkeyed, .unkeyed])
        XCTAssertFalse(calls.contains { $0.hasPrefix && $0.hasUsage })
    }

    func testFingerprintHasNoFirstDiffAndIsNotVertex() {
        let lab = Lab()
        lab.point(updated: "2026-01-15T16:00:00Z")
        lab.write(lab.transcript, userChunk(index: 3, created: "2026-01-15T14:00:00Z", model: "example-gate-model") + "\n", inode: 2)
        lab.write("/runtime/finger.jsonl", fingerprintLine(req: "xai-example-request-token-0001", turn: "3", conv: lab.session) + "\n", inode: 11)
        let snapshot = lab.poll()
        let text = snapshot.visibleText
        XCTAssertTrue(text.contains("没有 first_diff"))
        XCTAssertTrue(text.contains("不能把它当成前缀没变"))
        XCTAssertTrue(text.contains("不是 Vertex 最终出站"))
        XCTAssertTrue(text.contains("覆盖有限"))
        XCTAssertTrue(text.contains("8317 比当前会话旧"))
        XCTAssertFalse(text.contains("前缀未变"))
        XCTAssertFalse(text.contains("没有本地改动"))
        XCTAssertEqual(snapshot.turns[0].calls.first?.source, "fingerprint")
        XCTAssertFalse(snapshot.turns[0].calls[0].hadFirstDiff)
    }

    func testBadgesAreObservations() {
        let lab = Lab()
        lab.point()
        lab.write(lab.transcript, [
            userChunk(index: 5, created: "2026-01-15T14:00:00Z", model: "example-model-a"),
            userChunk(index: 6, created: "2026-01-15T14:00:30Z", model: "example-model-b"),
            toolChunk(),
            rewindChunk(target: 6)
        ].joined(separator: "\n") + "\n", inode: 2)
        lab.write("/runtime/vertex.jsonl", [
            vertexPrefix(req: "req-img", turn: "6", diff: "tools", images: 2, conv: lab.session),
            vertexUsage(req: "req-img", turn: "6", prompt: 30, cached: 0, conv: lab.session)
        ].joined(separator: "\n") + "\n", inode: 10)
        let snapshot = lab.poll()
        let turn = snapshot.turns.first { $0.promptIndex == 6 }
        XCTAssertEqual(turn?.badges.map(\.title), ["图 2", "工具", "回退", "换模型", "间隔"])
        XCTAssertTrue(snapshot.visibleText.contains("这是观察，不是原因。"))
        XCTAssertTrue(snapshot.visibleText.contains("不是前缀变化结论"))
        XCTAssertTrue(snapshot.visibleText.contains("仍然不是结论"))
        XCTAssertTrue(snapshot.visibleText.contains("30 秒"))
        XCTAssertTrue(snapshot.visibleText.contains("间隔不能用来判断 TTL"))
        assertHonest(snapshot)
    }

    func testShortGapDoesNotJudgeTTL() {
        let lab = Lab()
        lab.point()
        lab.write(lab.transcript, [
            userChunk(index: 1, created: "2026-01-15T14:00:00Z", model: "example-model-a"),
            userChunk(index: 2, created: "2026-01-15T14:00:20Z", model: "example-model-a")
        ].joined(separator: "\n") + "\n", inode: 2)
        let text = lab.poll().visibleText
        XCTAssertTrue(text.contains("20 秒"))
        XCTAssertTrue(text.contains("间隔不能用来判断 TTL"))
        XCTAssertFalse(text.contains("没有过期"))
    }

    func testSeveralChunksAreOneTurn() {
        let lab = Lab()
        lab.point()
        lab.write(lab.transcript, [
            userChunk(index: 4, created: "2026-01-15T14:10:00Z", model: "example-model-a", body: "SECRET_ONE"),
            userChunk(index: 4, created: "2026-01-15T14:10:01Z", model: "example-model-a", body: "SECRET_TWO")
        ].joined(separator: "\n") + "\n", inode: 2)
        let snapshot = lab.poll()
        XCTAssertEqual(snapshot.turns.count, 1)
        XCTAssertEqual(snapshot.turns[0].promptIndex, 4)
        XCTAssertFalse(snapshot.visibleText.contains("SECRET_ONE"))
        XCTAssertFalse(snapshot.visibleText.contains("SECRET_TWO"))
    }

    func testPrivacyDropsBodyURLHashAndToolPayload() {
        let lab = Lab()
        lab.point()
        lab.write(lab.transcript, [
            userChunk(index: 7, created: "2026-01-15T14:17:00Z", model: "example-model-a"),
            toolChunk()
        ].joined(separator: "\n") + "\n", inode: 2)
        lab.write("/runtime/vertex.jsonl", [
            vertexPrefix(req: "req-priv", turn: "7", diff: "none", images: 1, conv: lab.session),
            vertexUsage(req: "req-priv", turn: "7", prompt: 10, cached: 1, conv: lab.session)
        ].joined(separator: "\n") + "\n", inode: 10)
        let snapshot = lab.poll()
        assertHonest(snapshot)
        XCTAssertFalse(snapshot.visibleText.contains("prompt_forexample"))
        XCTAssertTrue(snapshot.visibleText.contains("图 1"))
    }

    func testSessionSwitchAndOutsidePath() {
        let lab = Lab()
        lab.point()
        lab.write(lab.transcript, userChunk(index: 1, created: "2026-01-15T14:00:00Z", model: "example-model-a") + "\n", inode: 2)
        XCTAssertEqual(lab.poll().turns.map(\.promptIndex), [1])
        let other = "/runtime/state/noxbuild-room/.grok-home/.grok/sessions/ws/22222222-2222-4333-8444-555555555555/updates.jsonl"
        lab.write(other, userChunk(index: 9, created: "2026-01-15T15:00:00Z", model: "example-model-b") + "\n", inode: 3)
        lab.point(session: "22222222-2222-4333-8444-555555555555", transcript: other)
        let switched = lab.poll()
        XCTAssertEqual(switched.turns.map(\.promptIndex), [9])
        XCTAssertEqual(switched.turns[0].modelText, "example-model-b")
        lab.point(transcript: "/etc/passwd")
        let blocked = lab.poll()
        XCTAssertEqual(blocked.phase, .waiting)
        XCTAssertTrue(blocked.turns.isEmpty)
        XCTAssertTrue(blocked.visibleText.contains("不在运行目录内"))
        XCTAssertFalse(blocked.visibleText.contains("root:"))
    }

    func testRotationTruncationPartialAndUnreadable() throws {
        let store = MemoryFiles()
        store.files["/log"] = MemoryFiles.File(inode: 1, data: Data("one\ntwo\nthree\n".utf8))
        let tail = LineTail(path: "/log", store: store, initialTailBytes: 1000)
        XCTAssertEqual(tail.poll(maxBytes: 4).lines, ["one"])
        store.files["/log.1"] = store.files["/log"]
        store.files["/log"] = MemoryFiles.File(inode: 2, data: Data("four\n".utf8))
        let rotated = tail.poll(maxBytes: 1000)
        XCTAssertTrue(rotated.rotated)
        XCTAssertEqual(rotated.lines, ["two", "three", "four"])

        let truncating = LineTail(path: "/shrink", store: store, initialTailBytes: 1000)
        store.files["/shrink"] = MemoryFiles.File(inode: 5, data: Data("keep\n".utf8))
        XCTAssertEqual(truncating.poll(maxBytes: 100).lines, ["keep"])
        store.files["/shrink"] = MemoryFiles.File(inode: 5, data: Data("new\n".utf8))
        let truncated = truncating.poll(maxBytes: 100)
        XCTAssertTrue(truncated.truncated)
        XCTAssertTrue(truncated.reset)
        XCTAssertEqual(truncated.lines, ["new"])

        let partialTail = LineTail(path: "/partial", store: store, initialTailBytes: 1000)
        store.files["/partial"] = MemoryFiles.File(inode: 6, data: Data("hel".utf8))
        XCTAssertEqual(partialTail.poll(maxBytes: 100).lines, [])
        store.files["/partial"] = MemoryFiles.File(inode: 6, data: Data("hello\n".utf8))
        XCTAssertEqual(partialTail.poll(maxBytes: 100).lines, ["hello"])

        store.files["/secret"] = MemoryFiles.File(inode: 7, data: Data("nope\n".utf8), unreadable: true)
        let denied = LineTail(path: "/secret", store: store, initialTailBytes: 1000).poll(maxBytes: 10)
        XCTAssertTrue(denied.unreadable)
        XCTAssertTrue(denied.lines.isEmpty)

        let wide = "hello\nworld\n"
        store.files["/wide"] = MemoryFiles.File(inode: 8, data: Data(wide.utf8))
        let opened = LineTail(path: "/wide", store: store, initialTailBytes: 10).poll(maxBytes: 100)
        XCTAssertTrue(opened.openedAtTail)
        XCTAssertEqual(opened.lines, ["world"])
    }

    func testLiveFilePartialLine() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("updates.jsonl")
        try Data("hel".utf8).write(to: url)
        let tail = LineTail(path: url.path, store: LiveTailStore(), initialTailBytes: 1000)
        XCTAssertEqual(tail.poll(maxBytes: 100).lines, [])
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("lo\n".utf8))
        try handle.close()
        XCTAssertEqual(tail.poll(maxBytes: 100).lines, ["hello"])
    }

    func testNotConfiguredIsNotSynthetic() {
        let files = MemoryFiles()
        files.files["/runtime/state/active_session.json"] = MemoryFiles.File(inode: 1, data: Data("SECRET_ONLY_IN_FILE".utf8))
        let engine = CacheEngine(
            config: CacheConfig(runtimeRoot: nil, vertexPath: "/x", fingerprintPath: "/y", siwcPath: "/z", synthetic: false, timeZone: .gmt),
            store: files
        )
        let snapshot = engine.poll()
        XCTAssertEqual(snapshot.phase, .notConfigured)
        XCTAssertTrue(snapshot.visibleText.contains("未配置运行目录"))
        XCTAssertFalse(snapshot.visibleText.contains("合成预览"))
        XCTAssertFalse(snapshot.visibleText.contains("example-model-a"))
        XCTAssertFalse(snapshot.visibleText.contains("SECRET_ONLY_IN_FILE"))
    }

    func testSyntheticPreviewIsLabeledAndDoesNotReadFiles() {
        let files = MemoryFiles()
        files.files["/runtime/state/active_session.json"] = MemoryFiles.File(inode: 1, data: Data("SECRET_ONLY_IN_FILE".utf8))
        let zone = TimeZone(secondsFromGMT: 8 * 3600)!
        let engine = CacheEngine(
            config: CacheConfig(runtimeRoot: "/runtime", vertexPath: "/x", fingerprintPath: "/y", siwcPath: "/z", synthetic: true, timeZone: zone),
            store: files
        )
        let snapshot = engine.poll(now: Date(timeIntervalSince1970: 1_768_500_000))
        XCTAssertEqual(snapshot.phase, .synthetic)
        XCTAssertEqual(snapshot.banner, "合成预览 · 不是本机数据")
        XCTAssertTrue(snapshot.visibleText.contains("example-model-a"))
        XCTAssertTrue(snapshot.visibleText.contains("未关联 · GPT"))
        XCTAssertFalse(snapshot.visibleText.contains("req_synthetic_xyz"))
        XCTAssertFalse(snapshot.visibleText.contains("SECRET_ONLY_IN_FILE"))
        XCTAssertTrue(snapshot.visibleText.contains("未知清缓存仍可能发生"))
        assertHonest(snapshot)
    }

    func testConfigIsOptInAndHasNoUsername() {
        let settings = Data(#"{"runtimeRoot":"/from-file","ignored":"SECRET_SETTING"}"#.utf8)
        let fromFile = CacheConfig.resolve(environment: [:], home: "/home/example", settingsJSON: settings, loadSettingsFile: false)
        XCTAssertEqual(fromFile.runtimeRoot, "/from-file")
        XCTAssertEqual(fromFile.vertexPath, "/home/example/Library/Logs/nox-vertex-observe.jsonl")
        XCTAssertFalse(fromFile.vertexPath.contains("lili"))
        XCTAssertFalse(fromFile.siwcPath.contains("SECRET"))
        let fromEnv = CacheConfig.resolve(
            environment: [
                "NOXBUILD_RUNTIME": "/from-env",
                "NOX_VERTEX_OBSERVE_LOG": "/var/log/vertex.jsonl",
                "USAGE_RAIL_CACHE_SYNTHETIC": "yes"
            ],
            home: "/home/example",
            settingsJSON: settings,
            loadSettingsFile: false
        )
        XCTAssertEqual(fromEnv.runtimeRoot, "/from-env")
        XCTAssertEqual(fromEnv.vertexPath, "/var/log/vertex.jsonl")
        XCTAssertTrue(fromEnv.synthetic)
    }

    func testLayoutSitsBelowTheRail() {
        XCTAssertEqual(CacheLayout.bottomCardDrop, 65)
        XCTAssertEqual(CacheLayout.reservedBelowRail, 81)
        let screens: [(rail: CacheFrame, maxX: Double)] = [
            (CacheFrame(x: 1390, y: 200, width: 8, height: 420), 1440),
            (CacheFrame(x: 1390, y: 400, width: 50, height: 420), 1440),
            (CacheFrame(x: 2000, y: 120, width: 50, height: 420), 2560)
        ]
        for sample in screens {
            let rail = CacheFrame(
                x: sample.maxX - CacheLayout.railExpandedWidth,
                y: sample.rail.minY,
                width: CacheLayout.railExpandedWidth,
                height: CacheLayout.railHeight
            )
            let railHot = CacheLayout.railHotZone(rail: rail)
            let card = CacheLayout.bottomCardFrame(rail: rail)
            let cardHot = card.inset(by: CacheLayout.cardHoverPad)
            for expanded in [false, true] {
                let drawer = CacheLayout.frame(rail: rail, screenMaxX: sample.maxX, visibleMinY: 0, expanded: expanded)
                let drawerHot = CacheLayout.hotZone(frame: drawer)
                XCTAssertEqual(drawer.maxX, sample.maxX)
                XCTAssertEqual(drawer.maxY, rail.minY - CacheLayout.reservedBelowRail, accuracy: 0.001)
                XCTAssertFalse(drawer.intersects(rail))
                XCTAssertFalse(drawer.intersects(card))
                XCTAssertFalse(drawerHot.intersects(rail))
                XCTAssertFalse(drawerHot.intersects(railHot))
                XCTAssertFalse(drawerHot.intersects(card))
                XCTAssertFalse(drawerHot.intersects(cardHot))
                XCTAssertFalse(drawerHot.contains(rail.midX, rail.minY - 1))
                XCTAssertTrue(railHot.contains(rail.midX, rail.minY - 1))
                if drawer.height > 0 {
                    XCTAssertTrue(drawerHot.contains(drawer.midX, drawer.midY))
                    XCTAssertFalse(railHot.contains(drawer.midX, drawer.midY))
                    XCTAssertFalse(cardHot.contains(drawer.midX, drawer.midY))
                }
            }
        }
        let tightRail = CacheFrame(x: 50, y: 40, width: 50, height: 420)
        let tight = CacheLayout.frame(rail: tightRail, screenMaxX: 100, visibleMinY: 0, expanded: true)
        XCTAssertEqual(tight.height, 0)
        XCTAssertLessThanOrEqual(tight.maxY, tightRail.minY - CacheLayout.reservedBelowRail)
        XCTAssertFalse(tight.intersects(tightRail))
        XCTAssertEqual(CacheLayout.animationDuration, 0.34)
        XCTAssertEqual(CacheLayout.collapseDelay, 0.22)
    }

    func testRetentionDropsOldestTurns() {
        let lab = Lab(limits: CacheLimits(maxTurns: 2, initialTailBytes: 8_000_000, fingerprintInitialTailBytes: 8_000_000))
        lab.point()
        let lines = (1...4).map { userChunk(index: $0, created: "2026-01-15T14:0\($0):00Z", model: "example-model-a") }
        lab.write(lab.transcript, lines.joined(separator: "\n") + "\n", inode: 2)
        XCTAssertEqual(lab.poll().turns.map(\.promptIndex), [4, 3])
    }

    func testWaitingForSessionIsNotSampleData() {
        let lab = Lab()
        let snapshot = lab.poll()
        XCTAssertEqual(snapshot.phase, .waiting)
        XCTAssertTrue(snapshot.visibleText.contains("等待会话"))
        XCTAssertTrue(snapshot.turns.isEmpty)
        XCTAssertFalse(snapshot.visibleText.contains("example-model-a"))
    }
}
