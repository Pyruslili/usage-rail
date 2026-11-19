import AppKit
import CacheHitCore
import SwiftUI

/// Black/pink seam under the usage rail. Same slide timing, separate panel.
@MainActor
final class CacheCompanionModel: ObservableObject {
    @Published var snapshot = CacheSnapshot.empty(phase: .notConfigured, summary: "未配置", status: "未配置运行目录")
    @Published var expanded = false
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
        hosting.view.frame = panel.contentView?.bounds ?? .zero
        hosting.view.autoresizingMask = [.width, .height]
        hosting.view.wantsLayer = true
        hosting.view.layer?.masksToBounds = true
        hosting.view.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentViewController = hosting
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
                }
            })
        } else {
            panel.setFrame(rect, display: true)
        }
        panel.orderFrontRegardless()
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
            model.expanded = true
            layout(animated: true)
            return
        }
        guard model.expanded, collapseWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if model.expanded {
                if let banner = model.snapshot.banner {
                    Text(banner)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Seam.hot)
                }
                Text(model.snapshot.status)
                    .font(.system(size: 9))
                    .foregroundStyle(Seam.blush.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.snapshot.turns) { turn in
                            turnRow(turn)
                        }
                        ForEach(model.snapshot.unlinked) { group in
                            unlinked(group)
                        }
                    }
                }
                Text(model.snapshot.footer)
                    .font(.system(size: 8))
                    .foregroundStyle(Seam.cream.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .frame(width: CGFloat(CacheLayout.expandedWidth), alignment: .topLeading)
        .background(panelBackground)
        .overlay(alignment: .leading) {
            Capsule()
                .fill(Seam.hot)
                .frame(width: 2)
                .padding(.vertical, 12)
                .padding(.leading, 3)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("缓存")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Seam.cream)
            Text(model.snapshot.summary)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Seam.blush)
                .monospacedDigit()
        }
    }

    private func turnRow(_ turn: TurnRow) -> some View {
        let open = model.openTurnID == turn.id
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                model.openTurnID = open ? nil : turn.id
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(turn.timeText)  #\(turn.promptIndex)  \(turn.modelText)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Seam.cream)
                    Text(turn.headline)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(Seam.blush)
                        .monospacedDigit()
                    if !turn.badges.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(turn.badges) { badge in
                                Text(badge.title)
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundStyle(Seam.cream)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Seam.hot.opacity(0.35)))
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(turn.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 9))
                            .foregroundStyle(Seam.cream.opacity(0.82))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func unlinked(_ group: UnlinkedGroup) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(group.title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Seam.hot)
            ForEach(Array(group.lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 9))
                    .foregroundStyle(Seam.cream.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var panelBackground: some View {
        UnevenRoundedRectangle(
            cornerRadii: .init(
                topLeading: CGFloat(CacheLayout.corner),
                bottomLeading: CGFloat(CacheLayout.corner),
                bottomTrailing: 0,
                topTrailing: 0
            ),
            style: .continuous
        )
        .fill(Seam.ink)
        .overlay(
            UnevenRoundedRectangle(
                cornerRadii: .init(
                    topLeading: CGFloat(CacheLayout.corner),
                    bottomLeading: CGFloat(CacheLayout.corner),
                    bottomTrailing: 0,
                    topTrailing: 0
                ),
                style: .continuous
            )
            .stroke(Seam.hot.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: Seam.hot.opacity(0.18), radius: 8, x: -2, y: 0)
    }
}
