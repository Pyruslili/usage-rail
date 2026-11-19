import AppKit
import CacheHitCore
import SwiftUI

/// Black/pink seam under the usage rail. Same slide timing, separate panel.
@MainActor
final class CacheCompanionModel: ObservableObject {
    @Published var snapshot = CacheSnapshot.empty(phase: .notConfigured, summary: "未配置", status: "未配置运行目录")
    @Published var expanded = false
    /// Text stays hidden until the window has finished opening, and is removed before it closes.
    @Published var showBody = false
    @Published var openTurnID: String?
}

@MainActor
final class CacheCompanion {
    private let model = CacheCompanionModel()
    private var engine: CacheEngine?
    private var config: CacheConfig?
    private weak var railPanel: NSPanel?
    private var panel: NSPanel?
    private var hoverTimer: Timer?
    private var dataTimer: Timer?
    private var collapseWork: DispatchWorkItem?
    private var animatingUntil = Date.distantPast

    func attach(railPanel: NSPanel) {
        self.railPanel = railPanel
    }

    func start() {
        makePanel()
        reload()
        layout(animated: false)
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.trackMouse()
                self?.layout(animated: false)
            }
        }
        dataTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.reload()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.layout(animated: false)
            }
        }
    }

    private func makePanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: CacheLayout.collapsedWidth, height: CacheLayout.collapsedHeight),
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
        panel.becomesKeyOnlyIfNeeded = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        let hosting = NSHostingController(rootView: CacheDrawerView(model: model))
        hosting.sizingOptions = []
        let host = hosting.view
        host.wantsLayer = true
        host.layer?.masksToBounds = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        if #available(macOS 14.0, *) {
            host.clipsToBounds = true
        }
        panel.contentViewController = hosting
        if let content = panel.contentView {
            content.wantsLayer = true
            content.layer?.masksToBounds = true
            if #available(macOS 14.0, *) {
                content.clipsToBounds = true
            }
        }
        self.panel = panel
        panel.orderFrontRegardless()
    }

    private func reload() {
        let resolved = CacheConfig.resolve()
        if config != resolved || engine == nil {
            config = resolved
            engine = CacheEngine(config: resolved)
        }
        let snapshot = engine?.poll(now: Date()) ?? model.snapshot
        model.snapshot = snapshot
        if let open = model.openTurnID, !snapshot.turns.contains(where: { $0.id == open }) {
            model.openTurnID = nil
        }
    }

    private func layout(animated: Bool) {
        guard let railPanel, let panel else { return }
        let screen = railPanel.screen ?? rightmostScreen()
        guard let screen else { return }
        let rail = CacheFrame(
            x: railPanel.frame.minX,
            y: railPanel.frame.minY,
            width: railPanel.frame.width,
            height: railPanel.frame.height
        )
        let box = CacheLayout.frame(
            rail: rail,
            screenMaxX: screen.frame.maxX,
            visibleMinY: screen.visibleFrame.minY,
            expanded: model.expanded
        )
        let rect = NSRect(x: box.x, y: box.y, width: box.width, height: box.height)
        panel.contentMinSize = rect.size
        panel.contentMaxSize = rect.size
        clip(panel)
        if !animated, Date() < animatingUntil {
            panel.orderFrontRegardless()
            return
        }
        guard panel.frame != rect else {
            panel.orderFrontRegardless()
            return
        }
        if animated {
            animatingUntil = Date().addingTimeInterval(CacheLayout.animationDuration)
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = CacheLayout.animationDuration
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.9, 0.28, 1)
                context.allowsImplicitAnimation = true
                panel.animator().setFrame(rect, display: true)
            }, completionHandler: {
                Task { @MainActor in
                    panel.setFrame(rect, display: true)
                    panel.contentMinSize = rect.size
                    panel.contentMaxSize = rect.size
                    self.model.showBody = self.model.expanded
                }
            })
        } else {
            panel.setFrame(rect, display: true)
            model.showBody = model.expanded
        }
        panel.orderFrontRegardless()
    }

    private func clip(_ panel: NSPanel) {
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.masksToBounds = true
        if #available(macOS 14.0, *) {
            panel.contentView?.clipsToBounds = true
        }
        if let host = panel.contentViewController?.view {
            host.frame = panel.contentView?.bounds ?? host.frame
            host.wantsLayer = true
            host.layer?.masksToBounds = true
            if #available(macOS 14.0, *) {
                host.clipsToBounds = true
            }
        }
    }

    private func trackMouse() {
        guard let railPanel else { return }
        let screen = railPanel.screen ?? rightmostScreen()
        guard let screen else { return }
        let rail = CacheFrame(
            x: railPanel.frame.minX,
            y: railPanel.frame.minY,
            width: railPanel.frame.width,
            height: railPanel.frame.height
        )
        let collapsed = CacheLayout.frame(rail: rail, screenMaxX: screen.frame.maxX, visibleMinY: screen.visibleFrame.minY, expanded: false)
        let opened = CacheLayout.frame(rail: rail, screenMaxX: screen.frame.maxX, visibleMinY: screen.visibleFrame.minY, expanded: true)
        let hot = CacheLayout.hotZone(frame: model.expanded ? opened : collapsed)
        let point = NSEvent.mouseLocation
        setExpanded(hot.contains(Double(point.x), Double(point.y)))
    }

    private func setExpanded(_ on: Bool) {
        if on {
            collapseWork?.cancel()
            collapseWork = nil
            guard !model.expanded else { return }
            model.showBody = false
            model.expanded = true
            layout(animated: true)
            return
        }
        guard model.expanded, collapseWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.model.showBody = false
            self.model.openTurnID = nil
            self.model.expanded = false
            self.layout(animated: true)
            self.collapseWork = nil
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + CacheLayout.collapseDelay, execute: work)
    }

    private func rightmostScreen() -> NSScreen? {
        NSScreen.screens.max(by: { $0.frame.maxX < $1.frame.maxX })
    }
}

private enum Seam {
    static let hot = Color(red: 0xE6 / 255, green: 0x3A / 255, blue: 0x7A / 255)
    static let blush = Color(red: 0xFE / 255, green: 0x83 / 255, blue: 0xC6 / 255)
    static let cream = Color(red: 0xFF / 255, green: 0xF2 / 255, blue: 0xF9 / 255)
    static let ink = Color.black
}

private struct CacheDrawerView: View {
    @ObservedObject var model: CacheCompanionModel

    private let inset = EdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 22)

    var body: some View {
        Group {
            if model.showBody {
                ZStack(alignment: .trailing) {
                    expandedBody
                        .padding(.trailing, 14)
                    Capsule()
                        .fill(Seam.hot)
                        .frame(width: 6, height: 32)
                        .padding(.trailing, 3)
                }
            } else {
                Capsule()
                    .fill(Seam.hot)
                    .padding(1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("缓存")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Seam.cream)
            Text(model.snapshot.summary)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Seam.cream)
                .monospacedDigit()
            if !model.snapshot.status.isEmpty, !model.snapshot.turns.isEmpty {
                Text(model.snapshot.status)
                    .font(.system(size: 13))
                    .foregroundStyle(Seam.cream.opacity(0.55))
            } else if model.snapshot.turns.isEmpty, !model.snapshot.status.isEmpty {
                Text(model.snapshot.status)
                    .font(.system(size: 13))
                    .foregroundStyle(Seam.cream.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.snapshot.turns.enumerated()), id: \.element.id) { index, turn in
                        if index > 0 {
                            Rectangle()
                                .fill(Seam.cream.opacity(0.08))
                                .frame(height: 1)
                                .padding(.vertical, 2)
                        }
                        turnRow(turn)
                    }
                }
            }
            if model.snapshot.banner != nil {
                Text("效果示意 · 全部为假数据")
                    .font(.system(size: 11))
                    .foregroundStyle(Seam.cream.opacity(0.4))
            }
        }
        .padding(inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(panelBackground)
    }

    private func turnRow(_ turn: TurnRow) -> some View {
        let open = model.openTurnID == turn.id
        let quiet = turn.headline.hasSuffix("%") == false || turn.caption == "未命中"
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                model.openTurnID = open ? nil : turn.id
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(turn.timeText.isEmpty ? turn.identityText : turn.timeText)
                            .font(.system(size: 12))
                            .foregroundStyle(Seam.cream.opacity(0.5))
                        Text(rowTitle(turn))
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Seam.cream)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 16)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(turn.headline)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(quiet ? Seam.blush : Seam.cream)
                            .monospacedDigit()
                            .lineLimit(1)
                        if let caption = turn.caption {
                            Text(caption)
                                .font(.system(size: 11))
                                .foregroundStyle(Seam.cream.opacity(0.45))
                        }
                    }
                }
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open, showsDetail(turn) {
                detailCard(turn)
                    .padding(.bottom, 8)
            }
        }
    }

    private func rowTitle(_ turn: TurnRow) -> String {
        if turn.modelText.isEmpty { return turn.identityText }
        if turn.timeText.isEmpty { return "\(turn.identityText)  \(turn.modelText)" }
        return "\(turn.identityText)  \(turn.modelText)"
    }

    private func showsDetail(_ turn: TurnRow) -> Bool {
        turn.imageCount > 0 || turn.toolCount > 0 || turn.didRewind || !turn.shownRequests.isEmpty || turn.lines.count == 1
    }

    private func detailCard(_ turn: TurnRow) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if turn.imageCount > 0 {
                detailGroup("这次发送") {
                    chip("图片 \(turn.imageCount) 张")
                }
            }
            if turn.toolCount > 0 || turn.didRewind {
                detailGroup("对话操作") {
                    HStack(spacing: 8) {
                        if turn.toolCount > 0 { chip("工具 \(turn.toolCount) 次") }
                        if turn.didRewind { chip("回退") }
                    }
                }
            }
            if !turn.shownRequests.isEmpty {
                detailGroup("每次请求") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(turn.shownRequests) { request in
                            HStack {
                                Text(request.label)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Seam.cream.opacity(0.85))
                                Spacer(minLength: 12)
                                Text(request.value)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(request.value.hasSuffix("%") && request.value != "0%" ? Seam.cream : Seam.blush)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            }
            if let note = turn.lines.first {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(Seam.cream.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Seam.cream.opacity(0.06))
        )
    }

    private func detailGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Seam.cream.opacity(0.45))
            content()
        }
    }

    private func chip(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12))
            .foregroundStyle(Seam.cream.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Seam.cream.opacity(0.18), lineWidth: 1)
            )
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Seam.ink)
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Seam.cream.opacity(0.06), lineWidth: 1)
            )
    }
}
