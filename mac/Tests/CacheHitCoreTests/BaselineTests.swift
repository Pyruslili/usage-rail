import Foundation
import XCTest

final class BaselineTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testDirtyRailStaysSixSlotsAndCacheIsBelow() throws {
        let source = try String(contentsOf: root.appendingPathComponent("mac/Sources/UsageRail/UsageRailApp.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("static let height: CGFloat = 420"))
        XCTAssertTrue(source.contains("static let slotCount: CGFloat = 6"))
        XCTAssertTrue(source.contains("static let collapsedWidth: CGFloat = 8"))
        XCTAssertTrue(source.contains("static let expandedWidth: CGFloat = 50"))
        XCTAssertTrue(source.contains("static let topInset: CGFloat = 72"))
        XCTAssertTrue(source.contains("0xE6 / 255"))
        XCTAssertTrue(source.contains("0x3A / 255"))
        XCTAssertTrue(source.contains("0x7A / 255"))
        XCTAssertTrue(source.contains("0xFE / 255"))
        XCTAssertTrue(source.contains("0x83 / 255"))
        XCTAssertTrue(source.contains("0xC6 / 255"))
        XCTAssertTrue(source.contains("0xFF / 255"))
        XCTAssertTrue(source.contains("0xF2 / 255"))
        XCTAssertTrue(source.contains("0xF9 / 255"))
        XCTAssertTrue(source.contains("let hover: Hovered = [.endpoint, .deepseek, .claude, .grok, .gemini, .gpt][idx]"))
        XCTAssertTrue(source.contains("case .kimi: cardPanel.orderOut(nil); return"))
        XCTAssertTrue(source.contains("case .vertex: cardPanel.orderOut(nil); return"))
        XCTAssertTrue(source.contains("ctx.duration = 0.34"))
        XCTAssertTrue(source.contains("deadline: .now() + 0.22"))
        let body = source.split(separator: "private var expandedBody").dropFirst().first?.split(separator: "private var railBackground").first ?? ""
        let bodyText = String(body)
        XCTAssertTrue(bodyText.contains("gptSlot"))
        XCTAssertTrue(bodyText.contains("geminiSlot"))
        XCTAssertTrue(bodyText.contains("grokSlot"))
        XCTAssertTrue(bodyText.contains("claudeSlot"))
        XCTAssertTrue(bodyText.contains("deepseekSlot"))
        XCTAssertTrue(bodyText.contains("endpointSlot"))
        XCTAssertFalse(bodyText.contains("kimiSlot"))
        XCTAssertFalse(bodyText.contains("vertexSlot"))
        XCTAssertLessThan(bodyText.range(of: "gptSlot")!.lowerBound, bodyText.range(of: "geminiSlot")!.lowerBound)
        XCTAssertLessThan(bodyText.range(of: "geminiSlot")!.lowerBound, bodyText.range(of: "endpointSlot")!.lowerBound)
        XCTAssertTrue(source.contains("spent_usd"))
        XCTAssertTrue(source.contains("budget_usd"))
        XCTAssertTrue(source.contains("budget_cny"))
        XCTAssertTrue(source.contains("cacheCompanion.attach(railPanel: railPanel)"))
        XCTAssertTrue(source.contains("cacheCompanion.start()"))
        XCTAssertTrue(source.contains("serverPort = 8765"))
    }

    func testCollectorKeepsLocalHookAndDoesNotRefreshKimi() throws {
        let source = try String(contentsOf: root.appendingPathComponent("mac/collect.py"), encoding: .utf8)
        XCTAssertTrue(source.contains("def _apply_local()"))
        XCTAssertTrue(source.contains("local.py"))
        XCTAssertTrue(source.contains("\"kimi\": (prev or {}).get(\"kimi\")"))
        XCTAssertFalse(source.contains("fetch_vertex"))
        let collect = source.split(separator: "def collect()").dropFirst().first?.split(separator: "def _apply_local()").first ?? ""
        XCTAssertFalse(String(collect).contains("fetch_kimi()"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("mac/local.py").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("mac/vertex_status.py").path))
        let ignore = try String(contentsOf: root.appendingPathComponent(".gitignore"), encoding: .utf8)
        XCTAssertTrue(ignore.contains("mac/local.py"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("mac/Sources/UsageRail/Resources/gemini.svg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("mac/Sources/UsageRail/Resources/vertex.svg").path))
    }
}
