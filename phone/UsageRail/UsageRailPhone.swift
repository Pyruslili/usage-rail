import SwiftUI
import UIKit
import UniformTypeIdentifiers

private enum Palette {
    static let hot = Color(red: 0xE6 / 255, green: 0x3A / 255, blue: 0x7A / 255)
    static let blush = Color(red: 0xFE / 255, green: 0x83 / 255, blue: 0xC6 / 255)
    static let cream = Color(red: 0xFF / 255, green: 0xF2 / 255, blue: 0xF9 / 255)
}

private enum Kind: String, CaseIterable, Identifiable {
    case claude, gpt, grok, kimi, deepseek
    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: return "Claude"
        case .gpt: return "GPT"
        case .grok: return "Grok"
        case .kimi: return "Kimi"
        case .deepseek: return "DeepSeek"
        }
    }

    var logo: String { rawValue }
}

private struct Window: Decodable, Equatable {
    var used_percent: Double?
    var reset_at: Int?
}

private struct Node: Decodable, Equatable {
    var ok: Bool?
    var stale: Bool?
    var session: Window?
    var weekly: Window?
    var monthly: Window?
    var balance_cny: Double?
    var available: Bool?
}

private struct Snapshot: Decodable, Equatable {
    var gpt: Node?
    var grok: Node?
    var kimi: Node?
    var claude: Node?
    var deepseek: Node?

    func node(_ kind: Kind) -> Node? {
        switch kind {
        case .gpt: return gpt
        case .grok: return grok
        case .kimi: return kimi
        case .claude: return claude
        case .deepseek: return deepseek
        }
    }
}

private struct Row: Identifiable {
    var id: String { title }
    var title: String
    var percent: Double?
    var resetAt: Int?
}

@MainActor
private final class Store: ObservableObject {
    @Published var snap: Snapshot?
    @Published var urlText: String
    @Published var status: String = ""
    @Published var selected: Kind?

    private let urlKey = "usage.rail.url"

    init() {
        urlText = UserDefaults.standard.string(forKey: urlKey) ?? ""
        if let data = try? Data(contentsOf: Self.fileURL) {
            apply(data)
        }
    }

    func saveURL() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        urlText = trimmed
        UserDefaults.standard.set(trimmed, forKey: urlKey)
    }

    func importFile(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            status = "Could not read that file."
            return
        }
        guard apply(data) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
        status = ""
    }

    func refresh() async {
        saveURL()
        guard let url = URL(string: urlText), !urlText.isEmpty else { return }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                status = "The URL did not return usage."
                return
            }
            guard apply(data) else { return }
            try? data.write(to: Self.fileURL, options: .atomic)
            status = ""
        } catch {
            status = "Could not reach the URL."
        }
    }

    @discardableResult
    private func apply(_ data: Data) -> Bool {
        guard let decoded = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            status = "That is not a usage file."
            return false
        }
        snap = decoded
        return true
    }

    private static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("usage.json")
    }
}

@main
struct UsageRailPhoneApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        WindowGroup {
            RailScreen(store: store)
        }
    }
}

private struct RailScreen: View {
    @ObservedObject var store: Store
    @State private var importing = false

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            if let kind = store.selected {
                DetailCard(kind: kind, snap: store.snap)
            }
            HStack(spacing: 12) {
                ForEach(Kind.allCases) { kind in
                    Button {
                        store.selected = store.selected == kind ? nil : kind
                    } label: {
                        MiniRing(
                            percent: outer(kind),
                            inner: inner(kind),
                            logo: kind.logo,
                            selected: store.selected == kind,
                            stale: store.snap?.node(kind)?.stale == true
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(kind.title)
                }
            }
            if store.snap == nil {
                Text("Import usage.json, or set a URL that returns it.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Palette.hot.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }
            VStack(spacing: 10) {
                TextField("https://…/usage.json", text: $store.urlText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 13, design: .rounded))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(.white.opacity(0.7)))
                HStack(spacing: 12) {
                    Button("Import") { importing = true }
                    Button("Refresh") { Task { await store.refresh() } }
                }
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.hot)
                if !store.status.isEmpty {
                    Text(store.status)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(Palette.hot)
                }
            }
            .padding(.horizontal, 28)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.cream)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            if case let .success(url) = result {
                store.importFile(url)
            }
        }
        .onSubmit { Task { await store.refresh() } }
    }

    private func outer(_ kind: Kind) -> Double? {
        guard let node = store.snap?.node(kind), node.ok != false else { return nil }
        switch kind {
        case .claude: return node.session?.used_percent
        case .gpt: return node.session?.used_percent
        case .grok: return node.weekly?.used_percent
        case .kimi: return node.monthly?.used_percent
        case .deepseek: return nil
        }
    }

    private func inner(_ kind: Kind) -> Double? {
        guard let node = store.snap?.node(kind), node.ok != false else { return nil }
        switch kind {
        case .claude: return node.weekly?.used_percent
        case .gpt: return node.weekly?.used_percent
        case .kimi: return node.session?.used_percent
        case .grok, .deepseek: return nil
        }
    }
}

private struct MiniRing: View {
    var percent: Double?
    var inner: Double?
    var logo: String
    var selected: Bool
    var stale: Bool

    var body: some View {
        ZStack {
            Circle().stroke(Palette.hot.opacity(0.16), lineWidth: 2.2)
            Circle()
                .trim(from: 0, to: trim(percent))
                .stroke(ringColor, style: StrokeStyle(lineWidth: selected ? 2.6 : 2.2, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if inner != nil {
                Circle()
                    .trim(from: 0, to: trim(inner))
                    .stroke(Palette.blush.opacity(stale ? 0.35 : 0.9), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                    .padding(3.5)
                    .rotationEffect(.degrees(-90))
            }
            Image(logo)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 12, height: 12)
                .foregroundStyle(Palette.hot.opacity(stale ? 0.4 : 0.92))
        }
        .frame(width: 36, height: 36)
    }

    private var ringColor: Color {
        if stale { return Palette.hot.opacity(0.35) }
        if selected { return Palette.hot }
        return Palette.blush
    }
}

private struct DetailCard: View {
    var kind: Kind
    var snap: Snapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(kind.logo)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 12, height: 12)
                    .foregroundStyle(Palette.hot)
                Text(kind.title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            if kind == .deepseek {
                Text(yuan)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            } else if rows.isEmpty {
                Text(snap?.node(kind)?.ok == false ? "unavailable" : "—")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(row.title)
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(.primary.opacity(0.72))
                            Spacer(minLength: 8)
                            Text(formatReset(row.resetAt))
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundStyle(Palette.hot.opacity(0.75))
                                .monospacedDigit()
                        }
                        ZStack(alignment: .leading) {
                            Capsule().fill(Palette.hot.opacity(0.12))
                            Capsule()
                                .fill(Palette.hot)
                                .scaleEffect(x: trim(row.percent), y: 1, anchor: .leading)
                        }
                        .frame(height: 3)
                        Text(percentText(row.percent) + " used")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 228, alignment: .topLeading)
        .background { CardBlur() }
    }

    private var yuan: String {
        guard let node = snap?.node(.deepseek), node.ok != false, let value = node.balance_cny else { return "—" }
        if abs(value) >= 100 { return String(format: "¥%.0f", value) }
        return String(format: "¥%.2f", value)
    }

    private var rows: [Row] {
        guard let node = snap?.node(kind), node.ok != false else { return [] }
        switch kind {
        case .claude:
            return [
                Row(title: "5-hour", percent: node.session?.used_percent, resetAt: node.session?.reset_at),
                Row(title: "Weekly", percent: node.weekly?.used_percent, resetAt: node.weekly?.reset_at),
            ]
        case .gpt:
            return [
                Row(title: "5-hour", percent: node.session?.used_percent, resetAt: node.session?.reset_at),
                Row(title: "Weekly", percent: node.weekly?.used_percent, resetAt: node.weekly?.reset_at),
            ]
        case .grok:
            return [Row(title: "Weekly", percent: node.weekly?.used_percent, resetAt: node.weekly?.reset_at)]
        case .kimi:
            return [
                Row(title: "5-hour", percent: node.session?.used_percent, resetAt: node.session?.reset_at),
                Row(title: "Monthly", percent: node.monthly?.used_percent, resetAt: node.monthly?.reset_at),
            ]
        case .deepseek:
            return []
        }
    }
}

private struct CardBlur: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        let style: UIBlurEffect.Style = colorScheme == .dark
            ? .systemUltraThinMaterialDark
            : .systemUltraThinMaterialLight
        ZStack {
            Blur(style: style)
            LinearGradient(
                colors: [Color.white.opacity(0.35), Palette.blush.opacity(0.16), Color.white.opacity(0.12)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Palette.hot.opacity(0.28), lineWidth: 1))
    }
}

private struct Blur: UIViewRepresentable {
    var style: UIBlurEffect.Style

    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView()
        view.backgroundColor = .clear
        view.clipsToBounds = true
        context.coordinator.style = style
        UIView.performWithoutAnimation {
            view.effect = UIBlurEffect(style: style)
        }
        return view
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        guard context.coordinator.style != style else { return }
        context.coordinator.style = style
        UIView.performWithoutAnimation {
            uiView.effect = UIBlurEffect(style: style)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var style: UIBlurEffect.Style?
    }
}

private func formatReset(_ resetAt: Int?) -> String {
    guard let resetAt else { return "" }
    let remaining = max(0, resetAt - Int(Date().timeIntervalSince1970))
    if remaining < 60 { return "\(remaining)s" }
    if remaining < 3600 { return "\(remaining / 60) min" }
    if remaining < 86400 {
        let hours = remaining / 3600
        let minutes = (remaining % 3600) / 60
        return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
    }
    let days = remaining / 86400
    let hours = (remaining % 86400) / 3600
    return hours == 0 ? "\(days)d" : "\(days)d \(hours)h"
}

private func trim(_ value: Double?) -> CGFloat {
    guard let value else { return 0 }
    return CGFloat(min(max(value / 100.0, 0), 1))
}

private func percentText(_ value: Double?) -> String {
    guard let value else { return "—" }
    return "\(Int(value.rounded()))%"
}
