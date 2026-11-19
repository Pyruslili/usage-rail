import AppKit
import Darwin
import Network
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
    static let height: CGFloat = 420
    static let topInset: CGFloat = 72
    static let corner: CGFloat = 25
    static let serverPort = 8765
    static let slotCount: CGFloat = 6
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
    var monthly: UsageWindow?
    var spent_usd: Double?
    var budget_usd: Double?
    var daily_usd: Double?
}

private struct GeminiUsage: Decodable {
    var ok: Bool
    var error: String?
    var plan: String?
    var session: UsageWindow?
    var weekly: UsageWindow?
    var argon: UsageWindow?
}

private struct DeepSeekUsage: Decodable {
    var ok: Bool
    var error: String?
    var available: Bool?
    var balance_cny: Double?
    var budget_cny: Double?
    var remaining: UsageWindow?
}

private struct VertexUsage: Decodable {
    var ok: Bool
    var project: String?
    var bridge_online: Bool?
    var oauth_ready: Bool?
    var observed_unix: Int?
    var cumulative_budget_usd: Double?
    var cumulative_spend_usd: Double?
    var cumulative_source: String?
    var cumulative_observed_unix: Int?
    var cumulative_cost_basis: String?
    var coverage_from: String?
    var coverage_through: String?
    var isFresh: Bool {
        guard let observed_unix else { return false }
        return (0...180).contains(Date().timeIntervalSince1970 - Double(observed_unix))
    }
    var localOnline: Bool { isFresh && bridge_online == true }
    var oauthObserved: Bool { isFresh && oauth_ready == true }
    func cost(at now: Date = Date()) -> Double? {
        guard cumulative_source == "cloud_billing_export",
              let stamp = cumulative_observed_unix,
              (0..<86400).contains(now.timeIntervalSince1970 - Double(stamp)),
              let spend = cumulative_spend_usd, spend.isFinite, spend >= 0 else { return nil }
        return spend
    }
    var officialSpend: Double? { cost() }
    var budgetPercent: Double? {
        guard let budget = cumulative_budget_usd, budget.isFinite, budget > 0,
              let spend = officialSpend else { return nil }
        let percent = spend / budget * 100
        return percent.isFinite && percent < Double(Int.max) ? percent : nil
    }
    var budgetPercentLabel: String { budgetPercent.map { formatPercent($0) } ?? "—%" }
}

private struct Snapshot: Decodable {
    var fetched_at: String?
    var fetched_unix: Int?
    var gpt: GPTUsage?
    var grok: GrokUsage?
    var kimi: KimiUsage?
    var claude: ClaudeUsage?
    var deepseek: DeepSeekUsage?
    var gemini: GeminiUsage?
    var vertex: VertexUsage?
}

private enum Hovered: Equatable {
    case gpt, grok, kimi, claude, deepseek, gemini, vertex, endpoint
}

private struct InterfaceIPv4 {
    var name: String
    var ip: String
}

private func listedIPv4() -> [InterfaceIPv4] {
    var result: [InterfaceIPv4] = []
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0 else { return [] }
    defer { freeifaddrs(ifaddr) }
    var ptr = ifaddr
    while let ifa = ptr {
        defer { ptr = ifa.pointee.ifa_next }
        let flags = Int32(ifa.pointee.ifa_flags)
        guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
        guard let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let namelen = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard getnameinfo(sa, namelen, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
        let ip = String(decoding: host.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
        if ip.hasPrefix("127.") || ip.hasPrefix("169.254.") { continue }
        result.append(InterfaceIPv4(name: String(cString: ifa.pointee.ifa_name), ip: ip))
    }
    return result
}

private func isTailscaleIP(_ ip: String) -> Bool {
    let parts = ip.split(separator: ".").compactMap { Int($0) }
    guard parts.count == 4 else { return false }
    return parts[0] == 100 && parts[1] >= 64 && parts[1] <= 127
}

private func currentLANIPv4() -> String? {
    let all = listedIPv4()
    if let en0 = all.first(where: { $0.name == "en0" && !isTailscaleIP($0.ip) }) {
        return en0.ip
    }
    return all.first(where: { !$0.name.hasPrefix("utun") && !isTailscaleIP($0.ip) })?.ip
}

private func currentTailscaleIPv4() -> String? {
    listedIPv4().first(where: { isTailscaleIP($0.ip) })?.ip
}

private func endpointURL(_ ip: String) -> String {
    "http://\(ip):\(Metrics.serverPort)"
}

// MARK: - Store

@MainActor
private final class UsageStore: ObservableObject {
    @Published var snapshot: Snapshot?
    @Published var hovered: Hovered?
    @Published var expanded = false
    @Published var lastError: String?
    @Published var collecting = false
    @Published var lanIPv4: String?
    @Published var tailscaleIPv4: String?
    @Published var copied = false
    private var copiedWork: DispatchWorkItem?

    var lanURL: String? { lanIPv4.map(endpointURL) }
    var tailscaleURL: String? { tailscaleIPv4.map(endpointURL) }

    var lanOctet: String {
        guard let ip = lanIPv4, let last = ip.split(separator: ".").last else { return "—" }
        return ".\(last)"
    }

    func refreshAddresses() {
        lanIPv4 = currentLANIPv4()
        tailscaleIPv4 = currentTailscaleIPv4()
    }

    func copyLANEndpoint() {
        refreshAddresses()
        guard let url = lanURL ?? tailscaleURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        copied = true
        copiedWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.copied = false
        }
        copiedWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

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

private struct EndpointMark: View {
    var body: some View {
        ZStack {
            Circle().stroke(Palette.cream.opacity(0.16), lineWidth: 2.6)
            Image(systemName: "wifi")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.cream)
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
                    store.refreshAddresses()
                    store.refresh(runCollector: true)
                }
                Button("Quit") { NSApp.terminate(nil) }
            }
    }

    private var expandedBody: some View {
        VStack(spacing: 18) {
            gptSlot
            geminiSlot
            grokSlot
            claudeSlot
            deepseekSlot
            endpointSlot
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
        let claude = store.snapshot?.claude
        let ok = claude?.ok == true
        if let monthly = claude?.monthly?.used_percent {
            return slot(ring: AnyView(SingleRing(percent: monthly, logo: "claude")), percent: ok ? monthly : nil)
        }
        let session = claude?.session?.used_percent
        let weekly = claude?.weekly?.used_percent
        let shown = max(session ?? 0, weekly ?? 0)
        return slot(ring: AnyView(DualRing(inner: weekly, outer: session, logo: "claude")), percent: ok ? shown : nil)
    }

    private var deepseekSlot: some View {
        let dp = store.snapshot?.deepseek
        let ok = dp?.ok == true
        if let remaining = dp?.remaining?.used_percent {
            return AnyView(slot(
                ring: AnyView(SingleRing(percent: remaining, logo: "deepseek", remaining: true)),
                percent: ok ? remaining : nil,
                remaining: true
            ))
        }
        return AnyView(VStack(spacing: 5) {
            SingleRing(percent: nil, logo: "deepseek")
            Text(ok ? formatYuan(dp?.balance_cny) : "—")
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .foregroundStyle(ok && dp?.available == false ? Palette.hot : Palette.blush)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        })
    }

    private var geminiSlot: some View {
        let gemini = store.snapshot?.gemini
        let ok = gemini?.ok == true
        let session = gemini?.session?.used_percent
        let weekly = gemini?.weekly?.used_percent
        let argon = gemini?.argon?.used_percent
        let shown = [session, weekly, argon].compactMap { $0 }.max()
        return slot(
            ring: AnyView(DualRing(inner: weekly, outer: session, logo: "gemini")),
            percent: ok ? shown : nil
        )
    }

    private var vertexSlot: some View {
        let vertex = store.snapshot?.vertex
        let percent = vertex?.budgetPercent
        return slot(
            ring: AnyView(SingleRing(percent: percent, logo: "vertex")),
            percent: percent,
            percentLabel: vertex?.budgetPercentLabel ?? "—%"
        )
    }

    private var endpointSlot: some View {
        VStack(spacing: 5) {
            EndpointMark()
            Text(store.lanOctet)
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.blush)
                .monospacedDigit()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            store.copyLANEndpoint()
        }
    }

    private func slot(ring: AnyView, percent: Double?, remaining: Bool = false, percentLabel: String? = nil) -> some View {
        VStack(spacing: 5) {
            ring
            Text(percentLabel ?? formatPercent(percent))
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
            case .gemini: geminiCard
            case .vertex: vertexCard
            case .endpoint: endpointCard
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
            if claude?.ok == true, claude?.monthly?.used_percent != nil {
                barRow(title: "Monthly", subtitle: formatReset(claude?.monthly), percent: claude?.monthly?.used_percent, brand: Palette.hot)
                if let spent = claude?.spent_usd, let budget = claude?.budget_usd {
                    Text(String(format: "$%.2f / $%.2f", spent, budget))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(Palette.cream)
                        .monospacedDigit()
                    if let daily = claude?.daily_usd {
                        Text(String(format: "Today $%.2f", daily))
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(Palette.blush.opacity(0.85))
                            .monospacedDigit()
                    }
                }
            } else if claude?.ok == true {
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
                if dp?.remaining?.used_percent != nil {
                    barRow(
                        title: "Wallet",
                        subtitle: "of \(formatYuan(dp?.budget_cny))",
                        percent: dp?.remaining?.used_percent,
                        brand: remainingColor(dp?.remaining?.used_percent),
                        remaining: true
                    )
                }
            } else {
                unavailable(dp?.error)
            }
        }
    }

    private var geminiCard: some View {
        let gemini = store.snapshot?.gemini
        return cardShell(title: "Gemini", logo: "gemini") {
            if gemini?.ok == true {
                barRow(title: "5-hour", subtitle: formatReset(gemini?.session), percent: gemini?.session?.used_percent, brand: Palette.hot)
                barRow(title: "Weekly", subtitle: formatReset(gemini?.weekly), percent: gemini?.weekly?.used_percent, brand: Palette.blush)
                barRow(title: "Argon weekly", subtitle: formatReset(gemini?.argon), percent: gemini?.argon?.used_percent, brand: Palette.hot)
            } else {
                unavailable(gemini?.error)
            }
        }
    }

    private var vertexCard: some View {
        let vertex = store.snapshot?.vertex
        return cardShell(title: "Vertex API", symbol: "cloud") {
            Text(vertex?.localOnline == true ? "本机桥接已连通" : "本机桥接状态未知／离线")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.cream)
            Text(vertex?.oauthObserved == true ? "服务账号自动认证 · 无需网页登录" : "自动认证待确认 · 不是订阅登录")
                .font(.system(size: 10))
                .foregroundStyle(Palette.blush)
            Text("累计参照 $\(Int(vertex?.cumulative_budget_usd ?? 300)) · 自设")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.cream)
            VStack(alignment: .leading, spacing: 4) {
                GeometryReader { geometry in
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: 2))
                        path.addLine(to: CGPoint(x: geometry.size.width, y: 2))
                    }
                    .stroke(Palette.blush.opacity(0.35), style: StrokeStyle(lineWidth: 3, dash: [4, 4]))
                }
                .frame(height: 4)
                Text(vertex?.officialSpend != nil
                     ? "累计已用 \(vertex?.budgetPercentLabel ?? "—%")"
                     : "累计已用未知 / 账单未同步")
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.blush)
            }
            Text("账单未接入 ≠ API 未连接。\n自设 $300 不是 Google 赠金或余额。旧月度0未迁移。")
                .font(.system(size: 9))
                .foregroundStyle(Palette.blush.opacity(0.85))
            Text(vertex?.project ?? "Project unknown")
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(Palette.cream.opacity(0.6))
                .lineLimit(2)
        }
    }

    private var endpointCard: some View {
        cardShell(title: store.copied ? "Copied" : "LAN", symbol: "wifi") {
            if let url = store.lanURL {
                Text(url)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Palette.cream)
                    .textSelection(.enabled)
                    .monospacedDigit()
                Text(store.copied ? "Copied." : "Click to copy.")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(Palette.blush.opacity(0.85))
            } else {
                Text("No LAN address yet.")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.blush.opacity(0.8))
            }
            if let ts = store.tailscaleURL {
                Text("Tailscale")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.cream.opacity(0.72))
                    .padding(.top, 4)
                Text(ts)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Palette.blush.opacity(0.9))
                    .monospacedDigit()
            }
        }
    }

    private func cardShell<Content: View>(title: String, symbol: String? = nil, logo: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.cream)
                        .frame(width: 12, height: 12)
                } else if let logo {
                    LogoView(name: logo).frame(width: 12, height: 12)
                }
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
    var pathMonitor: NWPathMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        store.loadCache()
        store.refreshAddresses()
        store.refresh(runCollector: true)
        makeRail()
        makeCard()
        dock()
        watchPath()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.store.refreshAddresses()
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
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.store.refreshAddresses()
            }
        }
    }

    private func watchPath() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                self?.store.refreshAddresses()
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        pathMonitor = monitor
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
        store.refreshAddresses()
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
            let hover: Hovered = [.endpoint, .deepseek, .claude, .grok, .gemini, .gpt][idx]
            if store.hovered != hover {
                store.hovered = hover
                if hover == .endpoint { store.refreshAddresses() }
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
                store.refreshAddresses()
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
        case .gpt: slotIndex = 5
        case .gemini: slotIndex = 4
        case .vertex: cardPanel.orderOut(nil); return
        case .grok: slotIndex = 3
        case .kimi: cardPanel.orderOut(nil); return
        case .claude: slotIndex = 2
        case .deepseek: slotIndex = 1
        case .endpoint: slotIndex = 0
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
