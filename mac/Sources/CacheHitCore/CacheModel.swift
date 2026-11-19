import Foundation

public enum CachePhase: Equatable {
    case synthetic
    case notConfigured
    case waiting
    case live
}

public struct Badge: Equatable, Identifiable {
    public var title: String
    public var detail: String
    public var id: String { title }

    public init(title: String, detail: String) {
        self.title = title
        self.detail = detail
    }
}

public enum CallLinkage: Equatable {
    case paired
    case pendingPrefix
    case ambiguous
    case fingerprint
    case unkeyed
}

public struct CallFigure: Equatable, Identifiable {
    public var id: String
    public var sequence: Int
    public var source: String
    public var linkage: CallLinkage
    public var hasPrefix: Bool
    public var hasUsage: Bool
    public var input: Int?
    public var cached: Int?
    public var cachedPresent: Bool
    public var firstDiff: String?
    public var hadFirstDiff: Bool
    public var imageCount: Int?
    public var status: Int?
    public var order: Int

    public init(
        id: String,
        sequence: Int,
        source: String,
        linkage: CallLinkage,
        hasPrefix: Bool,
        hasUsage: Bool,
        input: Int?,
        cached: Int?,
        cachedPresent: Bool,
        firstDiff: String?,
        hadFirstDiff: Bool,
        imageCount: Int?,
        status: Int?,
        order: Int
    ) {
        self.id = id
        self.sequence = sequence
        self.source = source
        self.linkage = linkage
        self.hasPrefix = hasPrefix
        self.hasUsage = hasUsage
        self.input = input
        self.cached = cached
        self.cachedPresent = cachedPresent
        self.firstDiff = firstDiff
        self.hadFirstDiff = hadFirstDiff
        self.imageCount = imageCount
        self.status = status
        self.order = order
    }
}

public struct SessionFigure: Equatable {
    public var input: Int?
    public var cached: Int?
    public var cachedPresent: Bool
    public var modelCalls: Int?
    public var numTurns: Int?
    public var stopReason: String?

    public init(
        input: Int?,
        cached: Int?,
        cachedPresent: Bool,
        modelCalls: Int?,
        numTurns: Int?,
        stopReason: String?
    ) {
        self.input = input
        self.cached = cached
        self.cachedPresent = cachedPresent
        self.modelCalls = modelCalls
        self.numTurns = numTurns
        self.stopReason = stopReason
    }
}

public struct TurnRow: Equatable, Identifiable {
    public var id: String
    public var promptIndex: Int
    public var timeText: String
    public var modelText: String
    public var headline: String
    public var badges: [Badge]
    public var lines: [String]
    public var calls: [CallFigure]
    public var sessionFigures: [SessionFigure]

    public init(
        id: String,
        promptIndex: Int,
        timeText: String,
        modelText: String,
        headline: String,
        badges: [Badge],
        lines: [String],
        calls: [CallFigure],
        sessionFigures: [SessionFigure]
    ) {
        self.id = id
        self.promptIndex = promptIndex
        self.timeText = timeText
        self.modelText = modelText
        self.headline = headline
        self.badges = badges
        self.lines = lines
        self.calls = calls
        self.sessionFigures = sessionFigures
    }
}

public struct UnlinkedGroup: Equatable, Identifiable {
    public var id: String
    public var title: String
    public var lines: [String]
    public var calls: [CallFigure]
    /// Present for SIWC rows. Not part of the visible copy.
    public var requestIDs: [String]

    public init(id: String, title: String, lines: [String], calls: [CallFigure], requestIDs: [String] = []) {
        self.id = id
        self.title = title
        self.lines = lines
        self.calls = calls
        self.requestIDs = requestIDs
    }
}

public struct CacheSnapshot: Equatable {
    public var phase: CachePhase
    public var banner: String?
    public var summary: String
    public var status: String
    public var turns: [TurnRow]
    public var unlinked: [UnlinkedGroup]
    public var footer: String
    public var visibleText: String

    public init(
        phase: CachePhase,
        banner: String?,
        summary: String,
        status: String,
        turns: [TurnRow],
        unlinked: [UnlinkedGroup],
        footer: String,
        visibleText: String
    ) {
        self.phase = phase
        self.banner = banner
        self.summary = summary
        self.status = status
        self.turns = turns
        self.unlinked = unlinked
        self.footer = footer
        self.visibleText = visibleText
    }

    public static let footerText = "徽章只是观察，不是原因。间隔不能用来判断 TTL。没有最终出站指纹时，不判断本地有没有改动。"

    public static func empty(phase: CachePhase, summary: String, status: String, banner: String? = nil) -> CacheSnapshot {
        let visible = [banner, "缓存", summary, status, footerText].compactMap { $0 }.joined(separator: "\n")
        return CacheSnapshot(
            phase: phase,
            banner: banner,
            summary: summary,
            status: status,
            turns: [],
            unlinked: [],
            footer: footerText,
            visibleText: visible
        )
    }
}

func formatHit(cached: Int, input: Int) -> String {
    guard input > 0 else { return "未知" }
    if cached == 0 { return "0%" }
    let pct = (Double(cached) / Double(input)) * 100
    if pct < 0.1 { return "<0.1%" }
    let tenths = (pct * 10).rounded() / 10
    if abs(tenths - tenths.rounded()) < 0.001 {
        return "\(Int(tenths.rounded()))%"
    }
    return String(format: "%.1f%%", tenths)
}

struct KnownHit: Equatable {
    var input: Int
    var cached: Int
}

func weightedHit(_ parts: [KnownHit]) -> (input: Int, cached: Int, text: String)? {
    guard !parts.isEmpty else { return nil }
    let input = parts.reduce(0) { $0 + $1.input }
    guard input > 0 else { return nil }
    let cached = parts.reduce(0) { $0 + $1.cached }
    return (input, cached, formatHit(cached: cached, input: input))
}

func formatGap(_ seconds: TimeInterval) -> String {
    let value = max(0, Int(seconds.rounded()))
    if value < 60 { return "\(value) 秒" }
    if value < 3600 {
        let minutes = value / 60
        let rest = value % 60
        return rest == 0 ? "\(minutes) 分" : "\(minutes) 分 \(rest) 秒"
    }
    let hours = value / 3600
    let minutes = (value % 3600) / 60
    return minutes == 0 ? "\(hours) 小时" : "\(hours) 小时 \(minutes) 分"
}

func formatLocal(_ date: Date, zone: TimeZone, now: Date) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = zone
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "HH:mm" : "M/d HH:mm"
    return formatter.string(from: date)
}

func tokenPhrase(input: Int?, cached: Int?, cachedPresent: Bool) -> String {
    let inputText = input.map { "输入 \($0)" } ?? "输入未知"
    if cachedPresent, let cached {
        let percent: String
        if let input, input > 0 {
            percent = formatHit(cached: cached, input: input)
        } else {
            percent = "未知"
        }
        return "\(inputText) · 缓存 \(cached) · \(percent)"
    }
    return "\(inputText) · 缓存未知"
}
