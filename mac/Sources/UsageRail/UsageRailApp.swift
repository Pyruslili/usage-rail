import AppKit
import SwiftUI

private let cacheURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".cache/usage-rail/usage.json")

private let collectorURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("collect.py")

private enum Palette {
    static let hot = Color(red: 0xE6 / 255, green: 0x3A / 255, blue: 0x7A / 255)
    static let blush = Color(red: 0xFE / 255, green: 0x83 / 255, blue: 0xC6 / 255)
    static let cream = Color(red: 0xFF / 255, green: 0xF2 / 255, blue: 0xF9 / 255)
    static let ink = Color.black
}

private enum Metrics {
    static let ring: CGFloat = 28
    static let icon: CGFloat = 12
    static let expandedWidth: CGFloat = 50
    static let collapsedWidth: CGFloat = 8
    static let height: CGFloat = 340
    static let topInset: CGFloat = 72
    static let corner: CGFloat = 25
    static let slotCount: CGFloat = 5
}

// MARK: - Models

private struct UsageWindow: Decodable {
    var label: String?
    var used_percent: Double?
    var reset_at: Int?
    var reset_after_seconds: Int?
}

private struct GPTUsage: Decodable {
    var ok: Bool
    var error: String?
    var plan: String?
    var session: UsageWindow?
    var weekly: UsageWindow?
}

private struct GrokUsage: Decodable {
    var ok: Bool
    var error: String?
    var period: String?
    var weekly: UsageWindow?
}

private struct KimiUsage: Decodable {
    var ok: Bool
    var error: String?
    var plan: String?
    var monthly: UsageWindow?
    var session: UsageWindow?
}

private struct ClaudeUsage: Decodable {
    var ok: Bool
    var error: String?
    var session: UsageWindow?
    var weekly: UsageWindow?
}

private struct DeepSeekUsage: Decodable {
    var ok: Bool
    var error: String?
    var available: Bool?
    var balance_cny: Double?
}

private struct Snapshot: Decodable {
    var fetched_at: String?
    var fetched_unix: Int?
    var gpt: GPTUsage?
    var grok: GrokUsage?
    var kimi: KimiUsage?
    var claude: ClaudeUsage?
    var deepseek: DeepSeekUsage?
}

private enum Hovered: Equatable {
    case gpt, grok, kimi, claude, deepseek
}

// MARK: - Store

@MainActor
private final class UsageStore: ObservableObject {
    @Published var snapshot: Snapshot?
    @Published var hovered: Hovered?
    @Published var expanded = false
    @Published var lastError: String?
    @Published var collecting = false

    func refresh(runCollector: Bool) {
        if runCollector {
            collecting = true
            let python = URL(fileURLWithPath: "/usr/bin/python3")
            let process = Process()
            process.executableURL = python
            let script = ProcessInfo.processInfo.environment["USAGE_RAIL_ROOT"].map {
                $0 + "/collect.py"
            } ?? collectorURL.path
            process.arguments = [script]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            DispatchQueue.global(qos: .utility).async { [weak self] in
                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    DispatchQueue.main.async {
                        self?.lastError = "collector failed"
                        self?.collecting = false
                    }
                    return
                }
                DispatchQueue.main.async {
                    self?.loadCache()
                    self?.collecting = false
                }
            }
        } else {
            loadCache()
        }
    }

    func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL) else { return }
        do {
            snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            lastError = nil
        } catch {
            lastError = "cache parse"
        }
    }
}

// MARK: - Formatting

private func usageColor(_ percent: Double?) -> Color {
    guard let percent else { return Palette.cream.opacity(0.28) }
    if percent >= 80 { return Palette.hot }
    if percent >= 45 { return Palette.hot.opacity(0.92) }
    return Palette.blush
}

private func remainingColor(_ percent: Double?) -> Color {
    guard let percent else { return Palette.cream.opacity(0.28) }
    if percent <= 18 { return Palette.hot }
    if percent <= 40 { return Palette.hot.opacity(0.92) }
    return Palette.blush
}

private func formatPercent(_ percent: Double?) -> String {
    guard let percent else { return "—" }
    return "\(Int(percent.rounded()))%"
}

private func formatYuan(_ value: Double?) -> String {
    guard let value else { return "—" }
    if abs(value) >= 100 { return String(format: "¥%.0f", value) }
    return String(format: "¥%.2f", value)
}

private func formatReset(_ window: UsageWindow?) -> String {
    guard let window else { return "" }
    if let resetAt = window.reset_at {
        let remaining = max(0, resetAt - Int(Date().timeIntervalSince1970))
        return "Resets in " + formatDuration(remaining)
    }
    if let seconds = window.reset_after_seconds {
        return "Resets in " + formatDuration(seconds)
    }
    return ""
}

private func formatDuration(_ seconds: Int) -> String {
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3600 { return "\(seconds / 60) min" }
    if seconds < 86400 {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
    let d = seconds / 86400
    let h = (seconds % 86400) / 3600
    return h == 0 ? "\(d)d" : "\(d)d \(h)h"
}

private func trim(_ value: Double?) -> CGFloat {
    guard let value else { return 0 }
    return CGFloat(min(max(value / 100.0, 0), 1))
}

// MARK: - Logo

private func loadLogo(_ name: String) -> NSImage? {
    guard let url = Bundle.module.url(forResource: name, withExtension: "svg"),
          let image = NSImage(contentsOf: url) else { return nil }
    image.isTemplate = true
    return image
}

private struct LogoView: View {
    let name: String

    var body: some View {
        if let image = loadLogo(name) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(Palette.cream)
        }
    }
}

// MARK: - Rings

private struct DualRing: View {
    var inner: Double?
    var outer: Double?
    var logo: String

    var body: some View {
        ZStack {
            Circle().stroke(Palette.cream.opacity(0.16), lineWidth: 2.6)
            Circle()
                .trim(from: 0, to: trim(outer))
                .stroke(usageColor(outer), style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Circle()
                .stroke(Palette.cream.opacity(0.20), lineWidth: 1.7)
                .padding(4.5)
            Circle()
                .trim(from: 0, to: trim(inner))
                .stroke(Palette.blush, style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
                .padding(4.5)
                .rotationEffect(.degrees(-90))
            LogoView(name: logo)
                .frame(width: Metrics.icon, height: Metrics.icon)
        }
        .frame(width: Metrics.ring, height: Metrics.ring)
    }
}

private struct SingleRing: View {
    var percent: Double?
    var logo: String
    var remaining: Bool = false

    var body: some View {
        ZStack {
            Circle().stroke(Palette.cream.opacity(0.16), lineWidth: 2.6)
            Circle()
                .trim(from: 0, to: trim(percent))
                .stroke(remaining ? remainingColor(percent) : usageColor(percent), style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            LogoView(name: logo)
                .frame(width: Metrics.icon, height: Metrics.icon)
        }
        .frame(width: Metrics.ring, height: Metrics.ring)
    }
}

// MARK: - Rail

private struct RailView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        Color.clear
            .overlay(alignment: .topLeading) {
                expandedBody
            }
            .clipped()
            .contextMenu {
                Button("Refresh") {
                    store.refresh(runCollector: true)
                }
                Button("Quit") { NSApp.terminate(nil) }
            }
    }

    private var expandedBody: some View {
        VStack(spacing: 18) {
            gptSlot
            grokSlot
            kimiSlot
            claudeSlot
            deepseekSlot
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 8)
        .frame(width: Metrics.expandedWidth, height: Metrics.height)
        .background(railBackground)
        .overlay(alignment: .leading) {
            Capsule()
                .fill(Palette.hot)
                .frame(width: 2)
                .padding(.vertical, 22)
                .padding(.leading, 3)
        }
    }

    private var railBackground: some View {
        UnevenRoundedRectangle(
            cornerRadii: .init(
                topLeading: Metrics.corner,
                bottomLeading: Metrics.corner,
                bottomTrailing: 0,
                topTrailing: 0
            ),
            style: .continuous
        )
        .fill(Palette.ink)
        .overlay(
            UnevenRoundedRectangle(
                cornerRadii: .init(
                    topLeading: Metrics.corner,
                    bottomLeading: Metrics.corner,
                    bottomTrailing: 0,
                    topTrailing: 0
                ),
                style: .continuous
            )
            .stroke(Palette.hot.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: Palette.hot.opacity(0.18), radius: 8, x: -2, y: 0)
    }

    private var gptSlot: some View {
        let session = store.snapshot?.gpt?.session?.used_percent
        let weekly = store.snapshot?.gpt?.weekly?.used_percent
        let shown = max(session ?? 0, weekly ?? 0)
        let ok = store.snapshot?.gpt?.ok == true
        return slot(ring: AnyView(DualRing(inner: weekly, outer: session, logo: "gpt")), percent: ok ? shown : nil)
    }

    private var grokSlot: some View {
        let percent = store.snapshot?.grok?.weekly?.used_percent
        let ok = store.snapshot?.grok?.ok == true
        return slot(ring: AnyView(SingleRing(percent: percent, logo: "grok")), percent: ok ? percent : nil)
    }

    private var kimiSlot: some View {
        let percent = store.snapshot?.kimi?.monthly?.used_percent
        let ok = store.snapshot?.kimi?.ok == true
        return slot(ring: AnyView(SingleRing(percent: percent, logo: "kimi")), percent: ok ? percent : nil)
    }

    private var claudeSlot: some View {
        let session = store.snapshot?.claude?.session?.used_percent
        let weekly = store.snapshot?.claude?.weekly?.used_percent
        let shown = max(session ?? 0, weekly ?? 0)
        let ok = store.snapshot?.claude?.ok == true
        return slot(ring: AnyView(DualRing(inner: weekly, outer: session, logo: "claude")), percent: ok ? shown : nil)
    }

    private var deepseekSlot: some View {
        let dp = store.snapshot?.deepseek
        let ok = dp?.ok == true
        return VStack(spacing: 5) {
            SingleRing(percent: nil, logo: "deepseek")
            Text(ok ? formatYuan(dp?.balance_cny) : "—")
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .foregroundStyle(ok && dp?.available == false ? Palette.hot : Palette.blush)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }

    private func slot(ring: AnyView, percent: Double?, remaining: Bool = false) -> some View {
        VStack(spacing: 5) {
            ring
            Text(formatPercent(percent))
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .foregroundStyle(remaining ? remainingColor(percent) : usageColor(percent))
                .monospacedDigit()
        }
    }
}

// MARK: - Card

private struct CardView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        Group {
            switch store.hovered {
            case .gpt: gptCard
            case .grok: grokCard
            case .kimi: kimiCard
            case .claude: claudeCard
            case .deepseek: deepseekCard
            case nil: Color.clear.frame(width: 1, height: 1)
            }
        }
        .animation(.easeOut(duration: 0.16), value: store.hovered)
    }

    private var gptCard: some View {
        let gpt = store.snapshot?.gpt
        return cardShell(title: "GPT Usage", logo: "gpt") {
            if gpt?.ok == true {
                barRow(title: "Current session", subtitle: formatReset(gpt?.session), percent: gpt?.session?.used_percent, brand: Palette.hot)
                barRow(title: "Weekly", subtitle: formatReset(gpt?.weekly), percent: gpt?.weekly?.used_percent, brand: Palette.blush)
            } else {
                unavailable(gpt?.error)
            }
        }
    }

    private var grokCard: some View {
        let grok = store.snapshot?.grok
        return cardShell(title: "Grok Usage", logo: "grok") {
            if grok?.ok == true {
                barRow(title: "Weekly pool", subtitle: formatReset(grok?.weekly), percent: grok?.weekly?.used_percent, brand: Palette.hot)
            } else {
                unavailable(grok?.error)
            }
        }
    }

    private var kimiCard: some View {
        let kimi = store.snapshot?.kimi
        return cardShell(title: "Kimi Usage", logo: "kimi") {
            if kimi?.ok == true {
                barRow(title: "Monthly", subtitle: formatReset(kimi?.monthly), percent: kimi?.monthly?.used_percent, brand: Palette.hot)
                if kimi?.session?.used_percent != nil {
                    barRow(title: "5-hour window", subtitle: formatReset(kimi?.session), percent: kimi?.session?.used_percent, brand: Palette.blush)
                }
            } else {
                unavailable(kimi?.error)
            }
        }
    }

    private var claudeCard: some View {
        let claude = store.snapshot?.claude
        return cardShell(title: "Claude", logo: "claude") {
            if claude?.ok == true {
                barRow(title: "5-hour", subtitle: formatReset(claude?.session), percent: claude?.session?.used_percent, brand: Palette.hot)
                barRow(title: "Weekly", subtitle: formatReset(claude?.weekly), percent: claude?.weekly?.used_percent, brand: Palette.blush)
            } else {
                unavailable(claude?.error)
            }
        }
    }

    private var deepseekCard: some View {
        let dp = store.snapshot?.deepseek
        return cardShell(title: "DeepSeek", logo: "deepseek") {
            if dp?.ok == true {
                Text(formatYuan(dp?.balance_cny))
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.cream)
                    .monospacedDigit()
            } else {
                unavailable(dp?.error)
            }
        }
    }

    private func cardShell<Content: View>(title: String, logo: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                LogoView(name: logo).frame(width: 12, height: 12)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.cream)
                Spacer()
            }
            content()
        }
        .padding(12)
        .frame(width: 228, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Palette.ink)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Palette.hot.opacity(0.4), lineWidth: 1)
                )
                .shadow(color: Palette.hot.opacity(0.22), radius: 12, x: 0, y: 4)
        )
    }

    private func barRow(title: String, subtitle: String, percent: Double?, brand: Color, remaining: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.cream.opacity(0.72))
                Spacer()
                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.blush.opacity(0.7))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.cream.opacity(0.12))
                    Capsule()
                        .fill(remaining ? remainingColor(percent) : usageColor(percent))
                        .frame(width: geo.size.width * CGFloat(min(max((percent ?? 0) / 100.0, 0), 1)))
                }
            }
            .frame(height: 4)
            Text(remaining ? "\(formatPercent(percent)) left" : "\(formatPercent(percent)) Used")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Palette.cream)
        }
    }

    private func unavailable(_ error: String?) -> some View {
        Text(error ?? "unavailable")
            .font(.system(size: 10))
            .foregroundStyle(Palette.blush.opacity(0.8))
    }
}

// MARK: - Windows

private final class HostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
    override var fittingSize: NSSize { bounds.size }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = UsageStore()
    var railPanel: NSPanel!
    var cardPanel: NSPanel!
    var refreshTimer: Timer?
    var hoverWatcher: Timer?
    var collapseWork: DispatchWorkItem?
    var localMonitor: Any?
    var globalMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        store.loadCache()
        store.refresh(runCollector: true)
        makeRail()
        makeCard()
        dock()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.store.refresh(runCollector: true)
            }
        }
        hoverWatcher = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.trackMouse()
                self?.placeCard()
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            Task { @MainActor in self?.trackMouse() }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            Task { @MainActor in self?.trackMouse() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.dock()
            }
        }
    }

    private func makeRail() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.collapsedWidth, height: Metrics.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.contentMinSize = NSSize(width: Metrics.collapsedWidth, height: Metrics.height)
        panel.contentMaxSize = NSSize(width: Metrics.expandedWidth, height: Metrics.height)
        let hosting = NSHostingController(rootView: RailView(store: store))
        hosting.sizingOptions = []
        hosting.view.frame = NSRect(x: 0, y: 0, width: Metrics.collapsedWidth, height: Metrics.height)
        hosting.view.autoresizingMask = [.width, .height]
        hosting.view.wantsLayer = true
        hosting.view.layer?.masksToBounds = true
        hosting.view.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentViewController = hosting
        panel.menu = railMenu()
        railPanel = panel
        panel.orderFrontRegardless()
    }

    private func makeCard() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = true
        let view = HostingView(rootView: CardView(store: store))
        view.frame = NSRect(x: 0, y: 0, width: 240, height: 200)
        panel.contentView = view
        cardPanel = panel
    }

    private func railMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Refresh", action: #selector(refreshNow), keyEquivalent: "r")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit Usage Rail", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc private func refreshNow() {
        store.refresh(runCollector: true)
    }

    private func rightmostScreen() -> NSScreen {
        NSScreen.screens.max(by: { $0.frame.maxX < $1.frame.maxX }) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func expandedFrame(on screen: NSScreen) -> NSRect {
        let vis = screen.visibleFrame
        let size = NSSize(width: Metrics.expandedWidth, height: Metrics.height)
        let x = screen.frame.maxX - size.width
        let y = vis.maxY - size.height - Metrics.topInset
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    private func collapsedFrame(on screen: NSScreen) -> NSRect {
        let full = expandedFrame(on: screen)
        return NSRect(
            x: screen.frame.maxX - Metrics.collapsedWidth,
            y: full.minY,
            width: Metrics.collapsedWidth,
            height: Metrics.height
        )
    }

    private func dock(animated: Bool = false) {
        guard let railPanel else { return }
        let screen = rightmostScreen()
        let rect = store.expanded ? expandedFrame(on: screen) : collapsedFrame(on: screen)
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.34
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.9, 0.28, 1)
                ctx.allowsImplicitAnimation = true
                railPanel.animator().setFrame(rect, display: true)
            }, completionHandler: {
                Task { @MainActor in
                    railPanel.setFrame(rect, display: true)
                }
            })
        } else {
            railPanel.setFrame(rect, display: true)
        }
        railPanel.orderFrontRegardless()
        placeCard()
    }

    private func trackMouse() {
        let loc = NSEvent.mouseLocation
        let screen = rightmostScreen()
        let full = expandedFrame(on: screen)
        let sliver = collapsedFrame(on: screen)
        var hot = full.insetBy(dx: -16, dy: -24).union(sliver.insetBy(dx: -10, dy: -24))
        if store.hovered != nil {
            let card = cardPanel.frame
            hot = hot.union(card.insetBy(dx: -8, dy: -8))
        }
        setExpanded(hot.contains(loc))
        updateHovered(at: loc)
    }

    private func updateHovered(at loc: NSPoint) {
        guard store.expanded, let railPanel else { return }
        let rail = railPanel.frame
        if rail.insetBy(dx: -6, dy: -2).contains(loc) {
            let ratio = (loc.y - rail.minY) / max(rail.height, 1)
            let idx = min(Int(Metrics.slotCount) - 1, max(0, Int(ratio * Metrics.slotCount)))
            let hover: Hovered = [.deepseek, .claude, .kimi, .grok, .gpt][idx]
            if store.hovered != hover {
                store.hovered = hover
            }
            return
        }
        if store.hovered != nil, cardPanel.frame.insetBy(dx: -8, dy: -8).contains(loc) {
            return
        }
        store.hovered = nil
    }

    private func setExpanded(_ on: Bool) {
        if on {
            collapseWork?.cancel()
            collapseWork = nil
            if !store.expanded {
                store.expanded = true
                dock(animated: true)
            }
            return
        }
        guard store.expanded, collapseWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.store.hovered = nil
            self.store.expanded = false
            self.dock(animated: true)
            self.collapseWork = nil
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    private func placeCard() {
        guard let railPanel, let cardPanel else { return }
        guard store.expanded, store.hovered != nil else {
            cardPanel.orderOut(nil)
            return
        }
        let rail = railPanel.frame
        let size = cardPanel.frame.size
        let slotIndex: CGFloat
        switch store.hovered {
        case .gpt: slotIndex = 4
        case .grok: slotIndex = 3
        case .kimi: slotIndex = 2
        case .claude: slotIndex = 1
        case .deepseek: slotIndex = 0
        case nil: slotIndex = 0
        }
        let slotHeight = rail.height / Metrics.slotCount
        let y = rail.minY + slotHeight * slotIndex + (slotHeight - size.height) / 2
        let x = rail.minX - size.width - 6
        cardPanel.setFrameOrigin(NSPoint(x: x, y: y))
        cardPanel.orderFrontRegardless()
    }
}

@main
enum UsageRailMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
