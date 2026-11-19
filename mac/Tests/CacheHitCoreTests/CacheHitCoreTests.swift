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
        XCTAssertEqual(turn.headline, "暂无数据")
        XCTAssertEqual(turn.calls[0].cachedPresent, false)
        XCTAssertNil(turn.calls[0].cached)
        XCTAssertFalse(snapshot.visibleText.contains("0%"))
        XCTAssertFalse(snapshot.visibleText.contains("缓存 0"))
        XCTAssertFalse(snapshot.visibleText.contains("5000"))
        XCTAssertEqual(turn.lines, ["这次没有缓存数据。"])
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
        XCTAssertEqual(turn.headline, "暂无数据")
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
        XCTAssertEqual(snapshot.turns[0].caption, "未命中")
        XCTAssertEqual(snapshot.turns[0].calls[0].firstDiff, "first")
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
        XCTAssertEqual(snapshot.turns[0].calls[0].source, "vertex")
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
        XCTAssertEqual(snapshot.turns[0].headline, "0%")
        XCTAssertEqual(snapshot.turns[0].firstCached, 0)
        XCTAssertEqual(snapshot.turns[0].calls[1].cached, 80)
        XCTAssertEqual(snapshot.summary, "整体命中 0%")
        XCTAssertFalse(snapshot.faceText.contains("7.3%"))
        XCTAssertFalse(snapshot.faceText.contains("合计"))
        XCTAssertFalse(snapshot.faceText.contains("4%"))
        XCTAssertEqual(snapshot.turns[0].calls[0].firstDiff, "first")
        XCTAssertEqual(snapshot.turns[0].shownRequests.map(\.label), ["刚发出这条", "工具续跑 1"])
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
        XCTAssertEqual(snapshot.turns[0].firstCached, 10)
        XCTAssertFalse(snapshot.turns[0].calls[1].cachedPresent)
        XCTAssertFalse(snapshot.faceText.contains("输入 110"))
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
        XCTAssertEqual(snapshot.turns[0].headline, "暂无数据")
        XCTAssertNil(snapshot.turns[0].firstInput)
        XCTAssertFalse(snapshot.faceText.contains("12.5%"))
        XCTAssertFalse(snapshot.faceText.contains("合计"))
        XCTAssertEqual(snapshot.turns[0].lines, ["这条只有整轮合计，无法单独知道第一次。"])
        XCTAssertFalse(snapshot.visibleText.contains("12.5%"))
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
        XCTAssertEqual(snapshot.turns[0].firstInput, 20)
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
        XCTAssertEqual(snapshot.turns[0].headline, "请求受限")
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
        XCTAssertEqual(snapshot.turns[0].headline, "请求受限")
        XCTAssertTrue(snapshot.visibleText.contains("请求受限"))
        XCTAssertFalse(snapshot.visibleText.contains("0%"))
    }

    func testPendingTurn() {
        let lab = Lab()
        lab.point()
        lab.write(lab.transcript, userChunk(index: 2, created: "2026-01-15T13:00:00Z", model: "example-model-a") + "\n", inode: 2)
        let snapshot = lab.poll()
        XCTAssertEqual(snapshot.turns[0].headline, "等待")
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
        let row = lab.poll().turns[0]
        XCTAssertEqual(row.headline, "暂无数据")
        XCTAssertEqual(row.lines, ["这几次对不上，看不出第一次。"])
        XCTAssertFalse(row.lines.joined().contains("%"))
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
        XCTAssertFalse(text.contains("没有 first_diff"))
        XCTAssertFalse(snapshot.faceText.contains("前缀未变"))
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
        XCTAssertEqual(turn?.imageCount, 2)
        XCTAssertEqual(turn?.toolCount, 1)
        XCTAssertEqual(turn?.didRewind, true)
        XCTAssertFalse(snapshot.faceText.contains("TTL"))
        XCTAssertFalse(snapshot.visibleText.contains("不是原因"))
        assertHonest(snapshot)
    }

    func testShortGapDoesNotJudgeTTL() {
        let lab = Lab()
        lab.point()
        lab.write(lab.transcript, [
            userChunk(index: 1, created: "2026-01-15T14:00:00Z", model: "example-model-a"),
            userChunk(index: 2, created: "2026-01-15T14:00:20Z", model: "example-model-a")
        ].joined(separator: "\n") + "\n", inode: 2)
        let snapshot = lab.poll()
        XCTAssertTrue(snapshot.turns.contains { $0.badges.contains { $0.title == "间隔" } })
        XCTAssertFalse(snapshot.faceText.contains("TTL"))
        XCTAssertFalse(snapshot.visibleText.contains("没有过期"))
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
        XCTAssertFalse(snapshot.visibleText.contains("未知清缓存"))
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

    func testFirstCallZeroStaysZeroWhenLaterHits() {
        let lab = Lab()
        lab.point()
        lab.write(lab.transcript, userChunk(index: 7, created: "2026-01-15T14:17:00Z", model: "example-model-a") + "\n", inode: 2)
        lab.write("/runtime/vertex.jsonl", [
            vertexPrefix(req: "req-first", turn: "7", diff: "first", conv: lab.session),
            vertexUsage(req: "req-first", turn: "7", prompt: 100, cached: 0, conv: lab.session),
            vertexPrefix(req: "req-first", turn: "7", diff: "tools", conv: lab.session),
            vertexUsage(req: "req-first", turn: "7", prompt: 100, cached: 100, conv: lab.session)
        ].joined(separator: "\n") + "\n", inode: 10)
        let snapshot = lab.poll()
        XCTAssertEqual(snapshot.turns[0].headline, "0%")
        XCTAssertEqual(snapshot.turns[0].firstCached, 0)
        XCTAssertEqual(snapshot.turns[0].calls[1].cached, 100)
        XCTAssertEqual(snapshot.summary, "整体命中 0%")
        XCTAssertFalse(snapshot.faceText.contains("100%"))
        XCTAssertFalse(snapshot.faceText.contains("合计"))
    }

    func testFirstCallMissingStaysUnknownWhenLaterHits() {
        let lab = Lab()
        lab.point()
        lab.write(lab.transcript, userChunk(index: 7, created: "2026-01-15T14:17:00Z", model: "example-model-a") + "\n", inode: 2)
        lab.write("/runtime/vertex.jsonl", [
            vertexPrefix(req: "req-miss", turn: "7", diff: "none", conv: lab.session),
            vertexUsage(req: "req-miss", turn: "7", prompt: 100, cached: nil, conv: lab.session),
            vertexPrefix(req: "req-miss", turn: "7", diff: "none", conv: lab.session),
            vertexUsage(req: "req-miss", turn: "7", prompt: 100, cached: 100, conv: lab.session)
        ].joined(separator: "\n") + "\n", inode: 10)
        let snapshot = lab.poll()
        XCTAssertEqual(snapshot.turns[0].headline, "暂无数据")
        XCTAssertNil(snapshot.turns[0].firstCached)
        XCTAssertEqual(snapshot.turns[0].calls[1].cached, 100)
        XCTAssertFalse(snapshot.faceText.contains("100%"))
        XCTAssertEqual(snapshot.summary, "整体命中 暂无")
    }

    func testEarlyRateLimitIsNotALaterSuccess() {
        let lab = Lab()
        lab.point()
        lab.write(lab.transcript, userChunk(index: 7, created: "2026-01-15T14:17:00Z", model: "example-model-a") + "\n", inode: 2)
        lab.write("/runtime/vertex.jsonl", [
            vertexPrefix(req: "req-429", turn: "7", diff: "none", conv: lab.session),
            vertexUsage(req: "req-429", turn: "7", prompt: 80, cached: nil, status: 429, conv: lab.session),
            vertexPrefix(req: "req-429", turn: "7", diff: "none", conv: lab.session),
            vertexUsage(req: "req-429", turn: "7", prompt: 80, cached: 80, conv: lab.session)
        ].joined(separator: "\n") + "\n", inode: 10)
        let snapshot = lab.poll()
        XCTAssertEqual(snapshot.turns[0].headline, "请求受限")
        XCTAssertFalse(snapshot.faceText.contains("100%"))
        XCTAssertFalse(snapshot.faceText.contains("0%"))
    }

    func testSingleModelCallIsTheFirstRequest() {
        let lab = Lab()
        lab.point()
        lab.write(lab.transcript, [
            userChunk(index: 4, created: "2026-01-15T14:00:00Z", model: "example-model-a"),
            completedChunk(usage: ["inputTokens": 100, "cachedReadTokens": 50, "modelCalls": 1, "numTurns": 1])
        ].joined(separator: "\n") + "\n", inode: 2)
        let snapshot = lab.poll()
        XCTAssertEqual(snapshot.turns[0].headline, "50%")
        XCTAssertEqual(snapshot.turns[0].firstInput, 100)
        XCTAssertEqual(snapshot.turns[0].firstCached, 50)
        XCTAssertEqual(snapshot.summary, "整体命中 50%")
    }

    func testPartialLogDoesNotUseTheFirstSurvivingCall() {
        let files = MemoryFiles()
        let zone = TimeZone(secondsFromGMT: 8 * 3600)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let now = calendar.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: 23))!
        let root = "/runtime"
        let transcript = "/runtime/state/noxbuild-room/.grok-home/.grok/sessions/ws/s/updates.jsonl"
        let session = "11111111-2222-4333-8444-555555555555"
        let pointer = jsonLine([
            "session_id": session,
            "transcript_path": transcript,
            "updated_at": "2026-01-15T16:00:00Z"
        ])
        files.files["/runtime/state/active_session.json"] = MemoryFiles.File(inode: 1, data: Data(pointer.utf8))
        files.files[transcript] = MemoryFiles.File(inode: 2, data: Data((userChunk(index: 7, created: "2026-01-15T14:17:00Z", model: "example-model-a") + "\n").utf8))
        let early = [
            vertexPrefix(req: "req-early", turn: "7", diff: "first", conv: session),
            vertexUsage(req: "req-early", turn: "7", prompt: 10, cached: 0, conv: session)
        ].joined(separator: "\n") + "\n"
        let later = [
            vertexPrefix(req: "req-later", turn: "7", diff: "tools", conv: session),
            vertexUsage(req: "req-later", turn: "7", prompt: 10, cached: 10, conv: session)
        ].joined(separator: "\n") + "\n"
        files.files["/runtime/vertex.jsonl"] = MemoryFiles.File(inode: 10, data: Data((early + later).utf8))
        files.files["/runtime/finger.jsonl"] = MemoryFiles.File(inode: 11, data: Data())
        files.files["/runtime/siwc.log"] = MemoryFiles.File(inode: 12, data: Data())
        let tail = later.utf8.count + 1
        let engine = CacheEngine(
            config: CacheConfig(runtimeRoot: root, vertexPath: "/runtime/vertex.jsonl", fingerprintPath: "/runtime/finger.jsonl", siwcPath: "/runtime/siwc.log", synthetic: false, timeZone: zone),
            limits: CacheLimits(initialTailBytes: tail, fingerprintInitialTailBytes: 8_000_000),
            store: files
        )
        let snapshot = engine.poll(now: now)
        XCTAssertEqual(snapshot.turns.count, 1)
        XCTAssertEqual(snapshot.turns[0].headline, "暂无数据")
        XCTAssertTrue(snapshot.turns[0].calls.allSatisfy(\.partial))
        XCTAssertFalse(snapshot.faceText.contains("100%"))
        XCTAssertFalse(snapshot.faceText.contains("0%"))
    }

    func testPendingBecomesTheFirstUsage() {
        let lab = Lab()
        lab.point()
        lab.write(lab.transcript, userChunk(index: 7, created: "2026-01-15T14:17:00Z", model: "example-model-a") + "\n", inode: 2)
        XCTAssertEqual(lab.poll().turns[0].headline, "等待")
        let existing = lab.files.files["/runtime/vertex.jsonl"]?.data ?? Data()
        let added = [
            vertexPrefix(req: "req-live", turn: "7", diff: "first", conv: lab.session),
            vertexUsage(req: "req-live", turn: "7", prompt: 100, cached: 40, conv: lab.session)
        ].joined(separator: "\n") + "\n"
        lab.files.files["/runtime/vertex.jsonl"] = MemoryFiles.File(inode: 10, data: existing + Data(added.utf8))
        let snapshot = lab.poll()
        XCTAssertEqual(snapshot.turns[0].headline, "40%")
        XCTAssertEqual(snapshot.turns[0].firstCached, 40)
    }

    func testRewindReusesTheIndexWithoutMerging() {
        let lab = Lab()
        lab.point()
        lab.write(lab.transcript, [
            userChunk(index: 7, created: "2026-01-15T14:00:00Z", model: "example-model-a"),
            completedChunk(usage: ["inputTokens": 100, "cachedReadTokens": 10, "modelCalls": 1]),
            rewindChunk(target: 7),
            userChunk(index: 7, created: "2026-01-15T14:30:00Z", model: "example-model-b")
        ].joined(separator: "\n") + "\n", inode: 2)
        let snapshot = lab.poll()
        XCTAssertEqual(snapshot.turns.map(\.identityText), ["#7·2", "#7"])
        XCTAssertEqual(snapshot.turns.map(\.headline), ["等待", "10%"])
        XCTAssertEqual(Set(snapshot.turns.map(\.id)).count, 2)
        XCTAssertEqual(snapshot.turns[1].firstCached, 10)
        XCTAssertNil(snapshot.turns[0].firstCached)
    }

    func testOverallWeightsFirstCallsAndSkipsUnknown() {
        let lab = Lab()
        lab.point()
        lab.write(lab.transcript, [
            userChunk(index: 1, created: "2026-01-15T14:00:00Z", model: "example-model-a"),
            userChunk(index: 2, created: "2026-01-15T14:05:00Z", model: "example-model-a")
        ].joined(separator: "\n") + "\n", inode: 2)
        lab.write("/runtime/vertex.jsonl", [
            vertexPrefix(req: "req-a", turn: "1", diff: "first", conv: lab.session),
            vertexUsage(req: "req-a", turn: "1", prompt: 100, cached: 0, conv: lab.session),
            vertexPrefix(req: "req-b", turn: "2", diff: "none", conv: lab.session),
            vertexUsage(req: "req-b", turn: "2", prompt: 300, cached: nil, conv: lab.session),
            vertexPrefix(req: "req-b", turn: "2", diff: "tools", conv: lab.session),
            vertexUsage(req: "req-b", turn: "2", prompt: 300, cached: 300, conv: lab.session)
        ].joined(separator: "\n") + "\n", inode: 10)
        let snapshot = lab.poll()
        XCTAssertEqual(snapshot.turns.first { $0.promptIndex == 1 }?.headline, "0%")
        XCTAssertEqual(snapshot.turns.first { $0.promptIndex == 2 }?.headline, "暂无数据")
        XCTAssertEqual(snapshot.summary, "整体命中 0%")
        XCTAssertFalse(snapshot.faceText.contains("50%"))
        XCTAssertFalse(snapshot.summary.contains("100%"))
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
