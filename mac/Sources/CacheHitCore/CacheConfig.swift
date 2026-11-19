import Foundation

public struct CacheConfig: Equatable {
    public var runtimeRoot: String?
    public var vertexPath: String
    public var fingerprintPath: String
    public var siwcPath: String
    public var synthetic: Bool
    public var timeZone: TimeZone

    public init(
        runtimeRoot: String?,
        vertexPath: String,
        fingerprintPath: String,
        siwcPath: String,
        synthetic: Bool,
        timeZone: TimeZone
    ) {
        self.runtimeRoot = runtimeRoot
        self.vertexPath = vertexPath
        self.fingerprintPath = fingerprintPath
        self.siwcPath = siwcPath
        self.synthetic = synthetic
        self.timeZone = timeZone
    }

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String? = nil,
        settingsJSON: Data? = nil,
        loadSettingsFile: Bool = true,
        timeZone: TimeZone = .current
    ) -> CacheConfig {
        let homePath = home ?? FileManager.default.homeDirectoryForCurrentUser.path
        let synthetic = Self.truthy(environment["USAGE_RAIL_CACHE_SYNTHETIC"])
        var root = environment["NOXBUILD_RUNTIME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if root?.isEmpty != false {
            root = nil
            let data: Data?
            if let settingsJSON {
                data = settingsJSON
            } else if loadSettingsFile {
                data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath(home: homePath)))
            } else {
                data = nil
            }
            if let data,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let value = object["runtimeRoot"] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { root = trimmed }
            }
        }
        return CacheConfig(
            runtimeRoot: root,
            vertexPath: override(environment["NOX_VERTEX_OBSERVE_LOG"], home: homePath, fallback: "/Library/Logs/nox-vertex-observe.jsonl"),
            fingerprintPath: override(environment["NOX_PREFIX_FINGERPRINT_LOG"], home: homePath, fallback: "/Library/Logs/nox-prefix-fingerprints.jsonl"),
            siwcPath: override(environment["NOX_SIWC_LOG"], home: homePath, fallback: "/Library/Logs/nox-openai-siwc.log"),
            synthetic: synthetic,
            timeZone: timeZone
        )
    }

    public static func settingsPath(home: String) -> String {
        home + "/.cache/usage-rail/cache-companion.json"
    }

    public static func sessionPointer(root: String) -> String {
        URL(fileURLWithPath: root).appendingPathComponent("state/active_session.json").path
    }

    public static func pathIsInside(root: String, candidate: String) -> Bool {
        let rootPath = URL(fileURLWithPath: root).standardizedFileURL.path
        let candidatePath = URL(fileURLWithPath: candidate).standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private static func override(_ value: String?, home: String, fallback: String) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        return home + fallback
    }

    private static func truthy(_ value: String?) -> Bool {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes": return true
        default: return false
        }
    }
}

public struct CacheLimits: Equatable {
    public var maxBytes: Int
    public var maxTurns: Int
    public var maxVertex: Int
    public var maxFingerprint: Int
    public var maxSIWC: Int
    public var initialTailBytes: Int
    public var fingerprintInitialTailBytes: Int

    public init(
        maxBytes: Int = 512 * 1024,
        maxTurns: Int = 80,
        maxVertex: Int = 300,
        maxFingerprint: Int = 80,
        maxSIWC: Int = 40,
        initialTailBytes: Int = 1_500_000,
        fingerprintInitialTailBytes: Int = 256 * 1024
    ) {
        self.maxBytes = maxBytes
        self.maxTurns = maxTurns
        self.maxVertex = maxVertex
        self.maxFingerprint = maxFingerprint
        self.maxSIWC = maxSIWC
        self.initialTailBytes = initialTailBytes
        self.fingerprintInitialTailBytes = fingerprintInitialTailBytes
    }
}
