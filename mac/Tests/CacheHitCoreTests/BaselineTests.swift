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
        XCTAssertTrue(source.contains("full.insetBy(dx: -16, dy: -24)"))
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
        let ignore = try String(contentsOf: root.appendingPathComponent(".gitignore"), encoding: .utf8)
        XCTAssertTrue(ignore.contains("mac/local.py"))
        let package = try String(contentsOf: root.appendingPathComponent("mac/Package.swift"), encoding: .utf8)
        let tracked = try trackedPaths(repoRoot: root)
        let onDisk = PrivateOverlayPolicy.protected.filter { relative in
            FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path)
        }
        XCTAssertEqual(
            PrivateOverlayPolicy.problems(
                gitignore: ignore,
                trackedPaths: tracked,
                packageManifest: package,
                onDisk: onDisk
            ),
            []
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("mac/Sources/UsageRail/Resources/gemini.svg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("mac/Sources/UsageRail/Resources/vertex.svg").path))
    }

    func testPrivateOverlayMayBeAbsentOrAlreadyPresent() {
        let gitignore = "mac/local.py\n"
        let tracked = ["mac/collect.py", "mac/Package.swift"]
        let package = "name: \"UsageRail\"\n"
        let clean = PrivateOverlayPolicy.problems(
            gitignore: gitignore,
            trackedPaths: tracked,
            packageManifest: package,
            onDisk: []
        )
        let present = PrivateOverlayPolicy.problems(
            gitignore: gitignore,
            trackedPaths: tracked,
            packageManifest: package,
            onDisk: PrivateOverlayPolicy.protected
        )
        XCTAssertEqual(clean, [])
        XCTAssertEqual(present, [])
    }

    func testPreexistingSyntheticOverlayIsLeftInPlace() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("overlay-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let mac = directory.appendingPathComponent("mac")
        try FileManager.default.createDirectory(at: mac, withIntermediateDirectories: true)
        let sentinel = "SYNTHETIC_OVERLAY_NOT_A_KEY\n"
        for name in ["local.py", "vertex_status.py"] {
            try sentinel.write(to: mac.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let onDisk = PrivateOverlayPolicy.protected.filter { relative in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(relative).path)
        }
        XCTAssertEqual(onDisk, PrivateOverlayPolicy.protected)
        XCTAssertEqual(
            PrivateOverlayPolicy.problems(
                gitignore: "mac/local.py\n",
                trackedPaths: ["mac/collect.py"],
                packageManifest: "name: \"UsageRail\"\n",
                onDisk: onDisk
            ),
            []
        )
        for name in ["local.py", "vertex_status.py"] {
            let text = try String(contentsOf: mac.appendingPathComponent(name), encoding: .utf8)
            XCTAssertEqual(text, sentinel)
        }
        let absent = PrivateOverlayPolicy.problems(
            gitignore: "mac/local.py\n",
            trackedPaths: ["mac/collect.py"],
            packageManifest: "name: \"UsageRail\"\n",
            onDisk: []
        )
        XCTAssertEqual(absent, [])
    }

    func testShippingPrivateOverlayIsRejected() {
        let gitignore = "mac/local.py\n"
        let package = "name: \"UsageRail\"\n"
        XCTAssertFalse(PrivateOverlayPolicy.problems(
            gitignore: gitignore,
            trackedPaths: ["mac/local.py"],
            packageManifest: package,
            onDisk: []
        ).isEmpty)
        XCTAssertFalse(PrivateOverlayPolicy.problems(
            gitignore: gitignore,
            trackedPaths: ["mac/vertex_status.py"],
            packageManifest: package,
            onDisk: ["mac/vertex_status.py"]
        ).isEmpty)
        XCTAssertFalse(PrivateOverlayPolicy.problems(
            gitignore: gitignore,
            trackedPaths: ["mac/collect.py"],
            packageManifest: "resources: [\"mac/local.py\"]\n",
            onDisk: []
        ).isEmpty)
        XCTAssertFalse(PrivateOverlayPolicy.problems(
            gitignore: "build/\n",
            trackedPaths: ["mac/collect.py"],
            packageManifest: package,
            onDisk: []
        ).isEmpty)
    }

    private func trackedPaths(repoRoot: URL) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = repoRoot
        process.arguments = ["ls-files", "-z"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    }
}

/// Private overlay files may already exist on a machine. The cache drawer must not
/// track, package, or delete them. Disk presence is not a failure.
enum PrivateOverlayPolicy {
    static let protected = ["mac/local.py", "mac/vertex_status.py"]

    static func problems(
        gitignore: String,
        trackedPaths: [String],
        packageManifest: String,
        onDisk: [String]
    ) -> [String] {
        _ = onDisk
        var found: [String] = []
        let ignored = Set(
            gitignore.split(whereSeparator: \.isNewline).map {
                String($0).trimmingCharacters(in: .whitespaces)
            }
        )
        if !ignored.contains("mac/local.py") {
            found.append("mac/local.py is not gitignored")
        }
        let tracked = Set(trackedPaths)
        for path in protected {
            if tracked.contains(path) {
                found.append("tracked \(path)")
            }
            if packageManifest.contains(path) {
                found.append("package mentions \(path)")
            }
        }
        return found
    }
}
