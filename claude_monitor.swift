import Cocoa
import SwiftUI
import Combine
import UserNotifications

// MARK: - NSBezierPath CGPath Extension

extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [CGPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            let type = element(at: i, associatedPoints: &points)
            switch type {
            case .moveTo: path.move(to: points[0])
            case .lineTo: path.addLine(to: points[0])
            case .curveTo: path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .cubicCurveTo: path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo: path.addQuadCurve(to: points[1], control: points[0])
            case .closePath: path.closeSubpath()
            @unknown default: break
            }
        }
        return path
    }
}

// MARK: - Config Manager

struct MonitorConfig: Codable {
    var tts_provider: String
    var elevenlabs: ElevenLabsConfig
    var say: SayConfig
    var announce: AnnounceConfig

    struct ElevenLabsConfig: Codable {
        var env_file: String
        var voice_id: String?
        var model: String
        var stability: Double
        var similarity_boost: Double
        var voice_design_prompt: String?
        var voice_design_name: String?
    }
    struct SayConfig: Codable {
        var voice: String
        var rate: Int
    }
    struct AnnounceConfig: Codable {
        var enabled: Bool
        var on_done: Bool
        var on_attention: Bool
        var on_start: Bool
        var volume: Double
    }
    struct SavedVoice: Codable {
        var id: String
        var name: String
    }
    var voices: [SavedVoice]?
    struct SummaryConfig: Codable {
        var enabled: Bool
        var env_file: String
        var model: String
        var threshold_chars: Int
    }
    var summary: SummaryConfig?
    struct NotificationConfig: Codable {
        var enabled: Bool
        var on_starting: Bool
        var on_working: Bool
        var on_done: Bool
        var on_attention: Bool
    }
    var notifications: NotificationConfig?
}

// MARK: - ElevenLabs Voice Info

struct ElevenLabsVoice: Identifiable {
    let id: String
    let name: String
}

struct ElevenLabsVoicesResponse: Codable {
    struct Voice: Codable {
        let voice_id: String
        let name: String
        let category: String?
    }
    let voices: [Voice]
}

class VoiceFetcher: ObservableObject {
    @Published var voices: [ElevenLabsVoice] = []
    @Published var hasFetched = false
    private var apiKey: String?

    func loadAPIKey(envFilePath: String) {
        let expanded = (envFilePath as NSString).expandingTildeInPath
        guard let content = try? String(contentsOfFile: expanded, encoding: .utf8) else { return }
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("ELEVENLABS_API_KEY=") {
                apiKey = String(trimmed.dropFirst("ELEVENLABS_API_KEY=".count))
                break
            }
        }
    }

    func fetchVoices() {
        guard let apiKey = apiKey, !apiKey.isEmpty else { return }
        guard let url = URL(string: "https://api.elevenlabs.io/v1/voices") else { return }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let data = data,
                  let response = try? JSONDecoder().decode(ElevenLabsVoicesResponse.self, from: data) else {
                return
            }
            // Only show user's own voices (cloned, generated, professional), not premade
            let voices = response.voices
                .filter { $0.category != "premade" }
                .map { ElevenLabsVoice(id: $0.voice_id, name: $0.name) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async {
                self?.voices = voices
                self?.hasFetched = true
            }
        }.resume()
    }

    func name(for voiceId: String) -> String? {
        voices.first(where: { $0.id == voiceId })?.name
    }

    func resolveVoiceName(id: String, completion: @escaping (String?) -> Void) {
        guard let apiKey = apiKey, !apiKey.isEmpty else { completion(nil); return }
        guard let url = URL(string: "https://api.elevenlabs.io/v1/voices/\(id)") else { completion(nil); return }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = json["name"] as? String else {
                completion(nil)
                return
            }
            completion(name)
        }.resume()
    }

    /// Design a voice from a text prompt, save it, and return the voice_id + name
    func designVoice(prompt: String, name: String, completion: @escaping (String?, String?) -> Void) {
        guard let apiKey = apiKey, !apiKey.isEmpty else { completion(nil, nil); return }
        guard let designURL = URL(string: "https://api.elevenlabs.io/v1/text-to-voice/design") else { completion(nil, nil); return }

        // Step 1: Generate preview
        var request = URLRequest(url: designURL)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "voice_description": prompt,
            "text": "Hello. A session just finished — your project is done and ready for review. Another session needs your attention, it looks like there is a permission prompt waiting. Everything else is still running smoothly.",
            "model_id": "eleven_multilingual_ttv_v2",
            "guidance_scale": 5,
            "quality": 0.9
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let previews = json["previews"] as? [[String: Any]],
                  let first = previews.first,
                  let generatedId = first["generated_voice_id"] as? String else {
                completion(nil, nil)
                return
            }

            // Step 2: Save as permanent voice
            self?.saveDesignedVoice(generatedId: generatedId, name: name, prompt: prompt, completion: completion)
        }.resume()
    }

    private func saveDesignedVoice(generatedId: String, name: String, prompt: String, completion: @escaping (String?, String?) -> Void) {
        guard let apiKey = apiKey, !apiKey.isEmpty else { completion(nil, nil); return }
        guard let url = URL(string: "https://api.elevenlabs.io/v1/text-to-voice") else { completion(nil, nil); return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "voice_name": name,
            "voice_description": prompt,
            "generated_voice_id": generatedId,
            "labels": ["source": "claude-monitor"]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let voiceId = json["voice_id"] as? String else {
                completion(nil, nil)
                return
            }
            let voiceName = json["name"] as? String ?? name
            completion(voiceId, voiceName)
        }.resume()
    }
}

class ConfigManager: ObservableObject {
    @Published var config: MonitorConfig?
    let voiceFetcher = VoiceFetcher()

    static let configPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude/monitor/config.json"
    }()

    init() {
        load()
        // Kick off voice fetch
        if let envFile = config?.elevenlabs.env_file {
            voiceFetcher.loadAPIKey(envFilePath: envFile)
            voiceFetcher.fetchVoices()
        }
    }

    func load() {
        guard let data = FileManager.default.contents(atPath: Self.configPath),
              let decoded = try? JSONDecoder().decode(MonitorConfig.self, from: data) else { return }
        self.config = decoded
    }

    func setVoice(_ voiceId: String) {
        config?.elevenlabs.voice_id = voiceId
        save()
    }

    func toggleVoice() {
        config?.announce.enabled.toggle()
        save()
    }

    var voiceEnabled: Bool {
        config?.announce.enabled ?? true
    }

    func toggleNotifications() {
        if config?.notifications == nil {
            config?.notifications = MonitorConfig.NotificationConfig(
                enabled: true, on_starting: false, on_working: true, on_done: true, on_attention: true
            )
        }
        config?.notifications?.enabled.toggle()
        save()
    }

    var notificationsEnabled: Bool {
        config?.notifications?.enabled ?? true
    }

    func save() {
        guard let config = config else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        try? data.write(to: URL(fileURLWithPath: Self.configPath))
    }

    var currentVoiceId: String {
        config?.elevenlabs.voice_id ?? ""
    }

    func voiceName(for id: String) -> String? {
        if let saved = config?.voices?.first(where: { $0.id == id }) {
            return saved.name
        }
        return voiceFetcher.name(for: id)
    }

    var allVoices: [ElevenLabsVoice] {
        var combined: [ElevenLabsVoice] = []
        var seenIds = Set<String>()
        if let saved = config?.voices {
            for v in saved {
                combined.append(ElevenLabsVoice(id: v.id, name: v.name))
                seenIds.insert(v.id)
            }
        }
        for v in voiceFetcher.voices {
            if !seenIds.contains(v.id) {
                combined.append(v)
            }
        }
        return combined
    }

    func addVoice(id: String, name: String) {
        var voices = config?.voices ?? []
        if !voices.contains(where: { $0.id == id }) {
            voices.append(MonitorConfig.SavedVoice(id: id, name: name))
            config?.voices = voices
            save()
        }
    }
}

// MARK: - Usage Manager

class UsageManager: ObservableObject {
    @Published var sevenDayPercent: Double? = nil    // 0-100
    @Published var sevenDayResetsAt: Date? = nil
    @Published var apiUnavailable = false

    private var timer: Timer?
    private let cachePath = (NSString("~/.claude/monitor/usage-cache.json") as NSString).expandingTildeInPath
    private var lastFetchTime: Date = .distantPast
    private var lastFetchSuccess = false

    func startPolling() {
        // Load cache immediately on startup
        loadCache()
        // Fetch in background
        fetchUsage()
        // Poll every 60 seconds
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.fetchUsage()
        }
    }

    private func loadCache() {
        guard let data = FileManager.default.contents(atPath: cachePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let timestamp = json["timestamp"] as? Double else { return }

        let cacheDate = Date(timeIntervalSince1970: timestamp)
        let ttl: TimeInterval = (json["success"] as? Bool == true) ? 60 : 15
        guard Date().timeIntervalSince(cacheDate) < ttl else { return }

        applyData(json)
    }

    private func saveCache(_ json: [String: Any], success: Bool) {
        var cache = json
        cache["timestamp"] = Date().timeIntervalSince1970
        cache["success"] = success
        let dir = (cachePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: cache) {
            try? data.write(to: URL(fileURLWithPath: cachePath))
        }
    }

    private func applyData(_ json: [String: Any]) {
        guard let sevenDay = json["seven_day"] as? [String: Any],
              let utilization = sevenDay["utilization"] as? Double else { return }

        let resetsAtStr = sevenDay["resets_at"] as? String
        var resetsAt: Date? = nil
        if let str = resetsAtStr {
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime]
            resetsAt = fmt.date(from: str)
            if resetsAt == nil {
                fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                resetsAt = fmt.date(from: str)
            }
        }

        DispatchQueue.main.async {
            self.sevenDayPercent = utilization
            self.sevenDayResetsAt = resetsAt
            self.apiUnavailable = false
        }
    }

    private func readCredentials() -> (accessToken: String, subscriptionType: String)? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { return nil }

            guard let jsonData = raw.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let oauth = json["claudeAiOauth"] as? [String: Any],
                  let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }

            let subType = oauth["subscriptionType"] as? String ?? ""
            return (token, subType)
        } catch {
            return nil
        }
    }

    private func fetchUsage() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }

            guard let creds = self.readCredentials() else {
                DispatchQueue.main.async { self.apiUnavailable = true }
                return
            }

            // Only show for subscription users (not API users)
            let sub = creds.subscriptionType.lowercased()
            guard sub.contains("max") || sub.contains("pro") || sub.contains("team") || sub.isEmpty else {
                DispatchQueue.main.async { self.apiUnavailable = true }
                return
            }

            guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else { return }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.timeoutInterval = 10

            URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                guard let self = self else { return }

                guard let data = data,
                      let httpResp = response as? HTTPURLResponse,
                      httpResp.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.saveCache([:], success: false)
                    DispatchQueue.main.async { self.apiUnavailable = true }
                    return
                }

                self.saveCache(json, success: true)
                self.applyData(json)
            }.resume()
        }
    }

    var resetTimeString: String? {
        guard let resetsAt = sevenDayResetsAt else { return nil }
        let remaining = resetsAt.timeIntervalSince(Date())
        guard remaining > 0 else { return nil }

        let hours = remaining / 3600
        if hours >= 24 {
            return "\(Int(hours / 24))d"
        } else if hours >= 1 {
            return "\(Int(hours))h"
        } else {
            return "\(max(1, Int(remaining / 60)))m"
        }
    }
}

// MARK: - Session Model

struct SessionInfo: Codable, Identifiable {
    let session_id: String
    var status: String
    var project: String
    var cwd: String
    var terminal: String
    var terminal_session_id: String
    var started_at: String
    var updated_at: String
    var last_prompt: String
    var title: String
    var renamed_title: String   // User-set via /rename command (detected from JSONL)
    var claude_summary: String  // Auto-generated by Claude (from sessions-index.json)

    var id: String { session_id }

    enum CodingKeys: String, CodingKey {
        case session_id, status, project, cwd, terminal, terminal_session_id, started_at, updated_at, last_prompt, title, renamed_title, claude_summary
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        session_id = try c.decode(String.self, forKey: .session_id)
        status = (try? c.decode(String.self, forKey: .status)) ?? "unknown"
        project = (try? c.decode(String.self, forKey: .project)) ?? "unknown"
        cwd = (try? c.decode(String.self, forKey: .cwd)) ?? ""
        terminal = (try? c.decode(String.self, forKey: .terminal)) ?? ""
        terminal_session_id = (try? c.decode(String.self, forKey: .terminal_session_id)) ?? ""
        started_at = (try? c.decode(String.self, forKey: .started_at)) ?? ""
        updated_at = (try? c.decode(String.self, forKey: .updated_at)) ?? ""
        last_prompt = (try? c.decode(String.self, forKey: .last_prompt)) ?? ""
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        renamed_title = (try? c.decode(String.self, forKey: .renamed_title)) ?? ""
        claude_summary = (try? c.decode(String.self, forKey: .claude_summary)) ?? ""
    }

    var statusColor: Color {
        switch status {
        case "starting":  return .gray
        case "working":   return .cyan
        case "done":      return .green
        case "attention": return .orange
        default:          return .gray
        }
    }

    var statusNSColor: NSColor {
        switch status {
        case "starting":  return .gray
        case "working":   return .cyan
        case "done":      return .systemGreen
        case "attention": return .orange
        default:          return .gray
        }
    }

    var statusIcon: String {
        switch status {
        case "starting":  return "circle.dotted"
        case "working":   return "circle.fill"
        case "done":      return "checkmark.circle.fill"
        case "attention": return "exclamationmark.triangle.fill"
        default:          return "circle"
        }
    }

    var elapsedString: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Try with fractional seconds first, then without
        var date = formatter.date(from: started_at)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: started_at)
        }
        guard let start = date else { return "" }
        let elapsed = Date().timeIntervalSince(start)
        if elapsed < 60 { return "\(Int(elapsed))s" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m" }
        return "\(Int(elapsed / 3600))h \(Int((elapsed.truncatingRemainder(dividingBy: 3600)) / 60))m"
    }

    var isStale: Bool {
        guard status != "done" && status != "attention" else { return false }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: updated_at)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: updated_at)
        }
        guard let updated = date else { return false }
        return Date().timeIntervalSince(updated) > 600 // 10 minutes
    }

    var displayName: String {
        // Priority: renamed_title (user /rename) > title (Gemini) > project
        if !renamed_title.isEmpty { return renamed_title }
        if !title.isEmpty { return title }
        return project
    }
}

// MARK: - Session Reader (polls directory)

class SessionReader: ObservableObject {
    @Published var sessions: [SessionInfo] = []
    @Published var foldedSessionIds: Set<String> = []
    private var timer: Timer?
    private var livenessTimer: Timer?

    var visibleSessions: [SessionInfo] {
        sessions.filter { !foldedSessionIds.contains($0.session_id) }
    }

    var foldedSessions: [SessionInfo] {
        sessions.filter { foldedSessionIds.contains($0.session_id) }
    }

    func foldSession(_ id: String) {
        foldedSessionIds.insert(id)
    }

    func unfoldSession(_ id: String) {
        foldedSessionIds.remove(id)
    }

    private let sessionsDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude/monitor/sessions"
    }()

    private var promptAccumulator: [String: String] = [:]
    private var lastSeenPrompt: [String: String] = [:]
    private var titleGenerated: Set<String> = []
    @Published var summarizeInFlight: Set<String> = []
    private var configManager: ConfigManager?
    private var lastKnownStatus: [String: String] = [:]
    private var isFirstPoll = true
    var notificationManager: NotificationManager?

    // Cache: sessions-index.json summaries per project [encodedPath: [sessionId: summary]]
    private var claudeIndexCache: [String: [String: String]] = [:]
    private var claudeIndexLastRead: [String: Date] = [:]
    // Cache: custom-title per project cwd [cwd: [jsonlSessionId: CustomTitleInfo]]
    private var customTitleCache: [String: [String: CustomTitleInfo]] = [:]
    private var customTitleLastRead: [String: Date] = [:]

    func setConfigManager(_ cm: ConfigManager) {
        self.configManager = cm
    }

    func setNotificationManager(_ nm: NotificationManager) {
        self.notificationManager = nm
    }

    /// Encode a cwd path to the Claude projects directory name format
    /// e.g. "/Users/wxtry/Code/unified_feature_server" -> "-Users-wxtry-Code-unified-feature-server"
    private func encodeCwdToProjectDir(_ cwd: String) -> String {
        return cwd.replacingOccurrences(of: "/", with: "-")
                  .replacingOccurrences(of: "_", with: "-")
    }

    /// Read Claude's sessions-index.json for a given project cwd, with caching (refresh every 30s).
    /// Tries parent directories if exact match not found.
    private func readClaudeIndex(forCwd cwd: String) -> [String: String] {
        let cacheKey = cwd
        if let lastRead = claudeIndexLastRead[cacheKey],
           Date().timeIntervalSince(lastRead) < 120,
           let cached = claudeIndexCache[cacheKey] {
            return cached
        }

        guard let projectDir = findClaudeProjectDir(forCwd: cwd) else {
            claudeIndexCache[cacheKey] = [:]
            claudeIndexLastRead[cacheKey] = Date()
            return [:]
        }

        let indexPath = "\(projectDir)/sessions-index.json"
        guard let data = FileManager.default.contents(atPath: indexPath) else {
            return claudeIndexCache[cacheKey] ?? [:]
        }

        do {
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let entries = json["entries"] as? [[String: Any]] ?? []
            var result: [String: String] = [:]
            for entry in entries {
                if let sid = entry["sessionId"] as? String,
                   let summary = entry["summary"] as? String, !summary.isEmpty {
                    result[sid] = summary
                }
            }
            claudeIndexCache[cacheKey] = result
            claudeIndexLastRead[cacheKey] = Date()
            return result
        } catch {
            NSLog("[ClaudeMonitor] Failed to read sessions-index for %@: %@", cwd, error.localizedDescription)
            return claudeIndexCache[cacheKey] ?? [:]
        }
    }

    /// Find the Claude projects directory for a cwd, trying parent paths if exact match not found.
    /// Claude stores JSONLs under the cwd where the session was started, which may be a parent of session.cwd.
    private func findClaudeProjectDir(forCwd cwd: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fm = FileManager.default
        var path = cwd
        while !path.isEmpty && path != "/" {
            let encoded = encodeCwdToProjectDir(path)
            let dir = "\(home)/.claude/projects/\(encoded)"
            if fm.fileExists(atPath: dir) {
                return dir
            }
            // Try parent
            path = (path as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// Custom title info: title and the JSONL file's modification date (for recency matching)
    struct CustomTitleInfo {
        let title: String
        let fileMtime: Date
    }

    /// Read custom-title entries from all JSONL files in a project directory, cached with 10s TTL.
    /// Returns map of [jsonlSessionId: CustomTitleInfo] for all sessions that have been renamed.
    private func readCustomTitles(forCwd cwd: String) -> [String: CustomTitleInfo] {
        let cacheKey = cwd
        if let lastRead = customTitleLastRead[cacheKey],
           Date().timeIntervalSince(lastRead) < 60,
           let cached = customTitleCache[cacheKey] {
            return cached
        }

        guard let projectDir = findClaudeProjectDir(forCwd: cwd) else {
            customTitleCache[cacheKey] = [:]
            customTitleLastRead[cacheKey] = Date()
            return [:]
        }

        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: projectDir) else {
            return customTitleCache[cacheKey] ?? [:]
        }

        var result: [String: CustomTitleInfo] = [:]
        let customTitleTag = "\"custom-title\""

        for file in files where file.hasSuffix(".jsonl") {
            let filePath = "\(projectDir)/\(file)"
            guard let data = fm.contents(atPath: filePath),
                  let content = String(data: data, encoding: .utf8) else { continue }

            guard content.contains(customTitleTag) else { continue }

            // Get file mtime for recency matching
            let attrs = try? fm.attributesOfItem(atPath: filePath)
            let mtime = (attrs?[.modificationDate] as? Date) ?? .distantPast

            for line in content.components(separatedBy: "\n") where !line.isEmpty {
                guard line.contains(customTitleTag) else { continue }
                guard let lineData = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      json["type"] as? String == "custom-title",
                      let title = json["customTitle"] as? String, !title.isEmpty,
                      !title.hasPrefix("<local-command"),
                      let sid = json["sessionId"] as? String else { continue }
                result[sid] = CustomTitleInfo(title: title, fileMtime: mtime)
            }
        }

        customTitleCache[cacheKey] = result
        customTitleLastRead[cacheKey] = Date()
        return result
    }

    private let ioQueue = DispatchQueue(label: "com.claude.monitor.io", qos: .utility)

    init() {
        ioQueue.async { [weak self] in
            self?.readSessionsBackground()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.ioQueue.async { self?.readSessionsBackground() }
        }
        livenessTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.pruneDeadSessions()
        }
    }

    /// Remove session files whose TTY no longer has any processes (terminal tab closed)
    func pruneDeadSessions() {
        let currentSessions = sessions
        guard !currentSessions.isEmpty else { return }

        // Build map: ttyName -> [session_id]
        var ttyMap: [String: [String]] = [:]
        for session in currentSessions {
            guard !session.terminal_session_id.isEmpty else { continue }
            if session.terminal == "terminal" || session.terminal == "ghostty" {
                let ttyName = session.terminal_session_id.replacingOccurrences(of: "/dev/", with: "")
                ttyMap[ttyName, default: []].append(session.session_id)
            }
        }
        guard !ttyMap.isEmpty else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }

            // Single shell command checks all TTYs at once
            let ttys = ttyMap.keys.joined(separator: " ")
            let script = "for tty in \(ttys); do ps -t \"$tty\" -o pid= 2>/dev/null | head -1 | grep -q . || echo \"$tty\"; done"

            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = ["-c", script]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice

            do {
                try task.run()
                task.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                let deadTTYs = Set(output.split(separator: "\n").map(String.init))

                for tty in deadTTYs {
                    if let sids = ttyMap[tty] {
                        for sid in sids {
                            let path = "\(self.sessionsDir)/\(sid).json"
                            try? FileManager.default.removeItem(atPath: path)
                            NSLog("[ClaudeMonitor] Pruned session %@ — TTY %@ gone", sid, tty)
                        }
                    }
                }
            } catch {}
        }
    }

    /// Called from background ioQueue — does all file I/O off main thread
    func readSessionsBackground() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: sessionsDir) else {
            DispatchQueue.main.async { self.sessions = [] }
            return
        }

        var loaded: [SessionInfo] = []
        // Collect unique cwds for batch reading Claude index
        var cwdSet: Set<String> = []
        for file in files where file.hasSuffix(".json") {
            let path = "\(sessionsDir)/\(file)"
            guard let data = fm.contents(atPath: path) else { continue }
            do {
                let session = try JSONDecoder().decode(SessionInfo.self, from: data)
                if !session.cwd.isEmpty { cwdSet.insert(session.cwd) }
                loaded.append(session)

                // Track prompt accumulation for title generation
                if !session.last_prompt.isEmpty {
                    let prev = self.lastSeenPrompt[session.session_id]
                    if prev != session.last_prompt {
                        self.lastSeenPrompt[session.session_id] = session.last_prompt
                        let existing = self.promptAccumulator[session.session_id] ?? ""
                        self.promptAccumulator[session.session_id] = existing + "\n" + session.last_prompt
                    }
                }
            } catch {
                NSLog("[ClaudeMonitor] Failed to decode %@: %@", file, error.localizedDescription)
            }
        }

        // Populate renamed_title (from custom-title in JSONL) and claude_summary (from sessions-index.json)
        var claudeIndexes: [String: [String: String]] = [:]
        var customTitles: [String: [String: CustomTitleInfo]] = [:]
        for cwd in cwdSet {
            claudeIndexes[cwd] = readClaudeIndex(forCwd: cwd)
            customTitles[cwd] = readCustomTitles(forCwd: cwd)
        }
        for i in loaded.indices {
            let session = loaded[i]
            // Check for custom-title (from /rename):
            // 1. Direct session_id match
            // 2. Fallback only if exactly one custom-title in the project
            if let titles = customTitles[session.cwd], !titles.isEmpty {
                if let info = titles[session.session_id] {
                    loaded[i].renamed_title = info.title
                } else if titles.count == 1, let info = titles.values.first {
                    loaded[i].renamed_title = info.title
                }
            }
            // Get Claude auto-summary from sessions-index.json
            if let index = claudeIndexes[session.cwd] {
                // Try direct match first
                if let summary = index[session.session_id], !summary.isEmpty {
                    loaded[i].claude_summary = summary
                } else if loaded[i].claude_summary.isEmpty {
                    // If no direct match, find any summary for this project (heuristic for ID mismatch)
                    for (_, summary) in index where !summary.isEmpty {
                        loaded[i].claude_summary = summary
                        break
                    }
                }
            }
        }

        // Clean up tracking for removed sessions
        let activeIds = Set(loaded.map { $0.session_id })
        for key in promptAccumulator.keys where !activeIds.contains(key) {
            promptAccumulator.removeValue(forKey: key)
            lastSeenPrompt.removeValue(forKey: key)
            titleGenerated.remove(key)
            summarizeInFlight.remove(key)
            lastKnownStatus.removeValue(forKey: key)
        }
        // Clean up folded IDs for sessions that no longer exist
        let staleFolded = foldedSessionIds.subtracting(activeIds)
        if !staleFolded.isEmpty {
            DispatchQueue.main.async {
                self.foldedSessionIds.subtract(staleFolded)
            }
        }

        // Sort: attention first, then working, then starting, then done
        let order: [String: Int] = ["attention": 0, "working": 1, "starting": 2, "done": 3]
        loaded.sort { (order[$0.status] ?? 9) < (order[$1.status] ?? 9) }

        // Detect state transitions and fire notifications
        if !isFirstPoll {
            for session in loaded {
                let oldStatus = lastKnownStatus[session.session_id]
                if let old = oldStatus, old != session.status {
                    notificationManager?.postStatusChange(
                        session: session,
                        oldStatus: old,
                        newStatus: session.status,
                        config: configManager?.config?.notifications
                    )
                }
                if oldStatus == nil && session.status != "starting" {
                    notificationManager?.postStatusChange(
                        session: session,
                        oldStatus: "",
                        newStatus: session.status,
                        config: configManager?.config?.notifications
                    )
                }
            }
        }

        // Update lastKnownStatus
        lastKnownStatus = [:]
        for session in loaded {
            lastKnownStatus[session.session_id] = session.status
        }
        isFirstPoll = false

        DispatchQueue.main.async {
            self.sessions = loaded
        }

        // Check if any session needs auto-summarize
        checkAutoSummarize()
    }

    private func checkAutoSummarize() {
        guard let config = configManager?.config?.summary, config.enabled else { return }
        let threshold = config.threshold_chars

        for (sessionId, accumulated) in promptAccumulator {
            let session = sessions.first { $0.session_id == sessionId }
            // Skip sessions that have been explicitly renamed via /rename
            if let session = session, !session.renamed_title.isEmpty {
                continue
            }

            if accumulated.count >= threshold
                && !titleGenerated.contains(sessionId)
                && !summarizeInFlight.contains(sessionId) {
                summarizeInFlight.insert(sessionId)
                let claudeSummary = session?.claude_summary ?? ""
                runSummarize(sessionId: sessionId, promptText: accumulated, project: session?.project ?? "", cwd: session?.cwd ?? "", claudeSummary: claudeSummary)
            }
        }
    }

    func runSummarize(sessionId: String, promptText: String, project: String = "", cwd: String = "", claudeSummary: String = "") {
        let scriptPath = "\(FileManager.default.homeDirectoryForCurrentUser.path)/.claude/monitor/summarize.sh"
        let sessionFilePath = "\(sessionsDir)/\(sessionId).json"

        // Build context: project info + Claude auto-summary (higher weight) + prompts
        var input = ""
        if !project.isEmpty || !cwd.isEmpty {
            input += "Project: \(project) (\(cwd))\n"
        }
        if !claudeSummary.isEmpty {
            input += "Claude Session Title: \(claudeSummary)\n"
        }
        if !project.isEmpty || !cwd.isEmpty || !claudeSummary.isEmpty {
            input += "---\n"
        }
        input += promptText

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }

            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = [scriptPath]

            let inputPipe = Pipe()
            let outputPipe = Pipe()
            task.standardInput = inputPipe
            task.standardOutput = outputPipe
            task.standardError = FileHandle.nullDevice

            do {
                try task.run()
                inputPipe.fileHandleForWriting.write(input.data(using: .utf8) ?? Data())
                inputPipe.fileHandleForWriting.closeFile()
                task.waitUntilExit()

                let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let title = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if !title.isEmpty && task.terminationStatus == 0 {
                    self.writeTitleToSession(sessionId: sessionId, title: title, filePath: sessionFilePath)
                    DispatchQueue.main.async {
                        self.titleGenerated.insert(sessionId)
                        self.summarizeInFlight.remove(sessionId)
                    }
                    NSLog("[ClaudeMonitor] Generated title for %@: %@", sessionId, title)
                } else {
                    DispatchQueue.main.async {
                        self.summarizeInFlight.remove(sessionId)
                    }
                    NSLog("[ClaudeMonitor] Summarize returned empty for %@", sessionId)
                }
            } catch {
                DispatchQueue.main.async {
                    self.summarizeInFlight.remove(sessionId)
                }
                NSLog("[ClaudeMonitor] Summarize failed for %@: %@", sessionId, error.localizedDescription)
            }
        }
    }

    func regenerateTitles() {
        guard let config = configManager?.config?.summary, config.enabled else { return }

        for session in sessions {
            // Skip sessions explicitly renamed via /rename — user-set names take priority
            if !session.renamed_title.isEmpty { continue }

            let accumulated = promptAccumulator[session.session_id] ?? ""
            guard !accumulated.isEmpty else { continue }
            guard !summarizeInFlight.contains(session.session_id) else { continue }
            summarizeInFlight.insert(session.session_id)
            titleGenerated.remove(session.session_id)
            runSummarize(sessionId: session.session_id, promptText: accumulated, project: session.project, cwd: session.cwd, claudeSummary: session.claude_summary)
        }
    }

    private func writeTitleToSession(sessionId: String, title: String, filePath: String) {
        let fm = FileManager.default
        guard let data = fm.contents(atPath: filePath) else { return }
        do {
            var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            json["title"] = title
            let updated = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
            let tmpPath = filePath + ".title.tmp"
            let tmpURL = URL(fileURLWithPath: tmpPath)
            let fileURL = URL(fileURLWithPath: filePath)
            try updated.write(to: tmpURL)
            _ = try fm.replaceItemAt(fileURL, withItemAt: tmpURL)
        } catch {
            NSLog("[ClaudeMonitor] Failed to write title for %@: %@", sessionId, error.localizedDescription)
            // Clean up tmp file on failure
            try? fm.removeItem(atPath: filePath + ".title.tmp")
        }
    }

    func discoverSessions() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", """
        SESSIONS_DIR="$HOME/.claude/monitor/sessions"
        NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        CLAUDE_PIDS=$(ps -eo pid=,comm= | awk '/claude/ && !/claude_monitor/ && !/awk/ {print $1}')
        for pid in $CLAUDE_PIDS; do
            tty_name=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
            [ -z "$tty_name" ] || [ "$tty_name" = "??" ] && continue
            grep -rlq "$tty_name" "$SESSIONS_DIR" 2>/dev/null && continue
            cwd=$(lsof -p "$pid" -d cwd -Fn 2>/dev/null | tail -1 | cut -c2-)
            [ -z "$cwd" ] && continue
            project=$(basename "$cwd")
            sid="discovered-${tty_name}"
            jq -n --arg sid "$sid" --arg project "$project" --arg cwd "$cwd" --arg term_sid "/dev/$tty_name" --arg now "$NOW" '{session_id:$sid,status:"working",project:$project,cwd:$cwd,terminal:"terminal",terminal_session_id:$term_sid,started_at:$now,updated_at:$now,last_prompt:""}' > "$SESSIONS_DIR/$sid.json.tmp" && mv "$SESSIONS_DIR/$sid.json.tmp" "$SESSIONS_DIR/$sid.json"
        done
        for f in "$SESSIONS_DIR"/*.json; do
            [ -f "$f" ] || continue
            tty=$(jq -r '.terminal_session_id // empty' "$f" 2>/dev/null)
            [ -z "$tty" ] && continue
            tty_pids=$(lsof -t "$tty" 2>/dev/null)
            has_claude=false
            for cpid in $CLAUDE_PIDS; do
                echo "$tty_pids" | grep -qw "$cpid" && { has_claude=true; break; }
            done
            if [ "$has_claude" = "false" ]; then
                status=$(jq -r '.status // empty' "$f" 2>/dev/null)
                [ "$status" = "working" ] || [ "$status" = "starting" ] && rm -f "$f"
            fi
        done
        """]
        try? task.run()
        task.waitUntilExit()
        ioQueue.async { [weak self] in
            self?.readSessionsBackground()
        }
    }
}

// MARK: - Terminal Switcher

func switchToSession(_ session: SessionInfo) {
    NSLog("[ClaudeMonitor] switchToSession: terminal=\(session.terminal) tty=\(session.terminal_session_id) project=\(session.project)")
    if session.terminal == "iterm2" && !session.terminal_session_id.isEmpty {
        switchToITerm2(sessionId: session.terminal_session_id)
    } else if session.terminal == "ghostty" {
        switchToGhostty()
    } else if session.terminal == "terminal" && !session.terminal_session_id.isEmpty {
        switchToTerminal(ttyPath: session.terminal_session_id)
    } else {
        NSLog("[ClaudeMonitor] falling back to cwd switch (no terminal info)")
        switchByTerminalCwd(cwd: session.cwd)
    }
}

func switchToITerm2(sessionId: String) {
    // sessionId format from ITERM_SESSION_ID: "w0t0p0:GUID"
    let parts = sessionId.split(separator: ":")
    guard parts.count >= 2 else {
        if let appleScript = NSAppleScript(source: "tell application \"iTerm2\" to activate") {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
        return
    }
    let uniqueId = String(parts[1])

    let script = """
    tell application "iTerm2"
        activate
        repeat with w in windows
            repeat with t in tabs of w
                repeat with s in sessions of t
                    if unique id of s is "\(uniqueId)" then
                        select t
                        set index of w to 1
                        return
                    end if
                end repeat
            end repeat
        end repeat
    end tell
    """

    if let appleScript = NSAppleScript(source: script) {
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
    }
}

func switchToTerminal(ttyPath: String) {
    // Match Terminal.app tab by its tty device path
    let script = """
    tell application "Terminal"
        activate
        repeat with w in windows
            try
                repeat with t in tabs of w
                    if tty of t is "\(ttyPath)" then
                        set selected tab of w to t
                        set index of w to 1
                        return
                    end if
                end repeat
            end try
        end repeat
    end tell
    """

    if let appleScript = NSAppleScript(source: script) {
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
    }
}

func switchToGhostty() {
    // Ghostty doesn't have an AppleScript dictionary; activate via NSRunningApplication
    let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.mitchellh.ghostty")
    if let app = apps.first {
        app.activate()
    }
}

func switchByTerminalCwd(cwd: String) {
    // Fallback: just activate the terminal app
    if let appleScript = NSAppleScript(source: "tell application \"Terminal\" to activate") {
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
    }
}

// MARK: - Terminal Window Frame

func getTerminalWindowFrame(session: SessionInfo) -> NSRect? {
    guard !session.terminal.isEmpty, !session.terminal_session_id.isEmpty else { return nil }

    let script: String

    if session.terminal == "iterm2" {
        let parts = session.terminal_session_id.split(separator: ":")
        guard parts.count >= 2 else { return nil }
        let uniqueId = String(parts[1])

        script = """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if unique id of s is "\(uniqueId)" then
                            return bounds of w
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """
    } else if session.terminal == "terminal" {
        let ttyPath = session.terminal_session_id

        script = """
        tell application "Terminal"
            repeat with w in windows
                try
                    repeat with t in tabs of w
                        if tty of t is "\(ttyPath)" then
                            return bounds of w
                        end if
                    end repeat
                end try
            end repeat
        end tell
        """
    } else if session.terminal == "ghostty" {
        // Ghostty has no AppleScript; use CGWindowList to find its frontmost window
        return getWindowFrameByBundleId("com.mitchellh.ghostty")
    } else {
        return nil
    }

    guard let appleScript = NSAppleScript(source: script) else { return nil }

    var error: NSDictionary?
    let result = appleScript.executeAndReturnError(&error)

    guard error == nil else { return nil }
    guard result.numberOfItems == 4 else { return nil }

    let left = result.atIndex(1)?.doubleValue ?? 0
    let top = result.atIndex(2)?.doubleValue ?? 0
    let right = result.atIndex(3)?.doubleValue ?? 0
    let bottom = result.atIndex(4)?.doubleValue ?? 0

    // AppleScript bounds use top-left origin relative to primary screen; AppKit uses bottom-left of primary
    let screenHeight = NSScreen.screens.first?.frame.height ?? 0
    let x = left
    let y = screenHeight - bottom
    let width = right - left
    let height = bottom - top

    return NSRect(x: x, y: y, width: width, height: height)
}

/// Get the frontmost normal window frame for an app by bundle identifier, using CGWindowList.
/// Returns frame in AppKit coordinates (bottom-left origin).
func getWindowFrameByBundleId(_ bundleId: String) -> NSRect? {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else { return nil }
    let pid = app.processIdentifier

    guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }

    // Find the first on-screen normal window owned by this PID
    for info in windowList {
        guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int32, ownerPID == pid,
              let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
              let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }

        let cgX = bounds["X"] ?? 0
        let cgY = bounds["Y"] ?? 0
        let w = bounds["Width"] ?? 0
        let h = bounds["Height"] ?? 0

        // Convert from CG coordinates (top-left origin) to AppKit (bottom-left origin)
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: cgX, y: screenHeight - cgY - h, width: w, height: h)
    }
    return nil
}

// MARK: - Terminal Window Mover

/// Moves a terminal window to the specified bounds (AppKit coordinates, bottom-left origin).
/// Does not activate/focus the window.
func moveTerminalWindow(session: SessionInfo, to rect: NSRect) {
    guard !session.terminal.isEmpty, !session.terminal_session_id.isEmpty else { return }

    // Convert AppKit coords (bottom-left origin) to AppleScript coords (top-left origin)
    let screenHeight = NSScreen.screens.first?.frame.height ?? 0
    let left = Int(rect.origin.x)
    let top = Int(screenHeight - rect.origin.y - rect.height)
    let right = Int(rect.origin.x + rect.width)
    let bottom = Int(screenHeight - rect.origin.y)

    let script: String

    if session.terminal == "iterm2" {
        let parts = session.terminal_session_id.split(separator: ":")
        guard parts.count >= 2 else { return }
        let uniqueId = String(parts[1])

        script = """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if unique id of s is "\(uniqueId)" then
                            set bounds of w to {\(left), \(top), \(right), \(bottom)}
                            return
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """
    } else if session.terminal == "terminal" {
        let ttyPath = session.terminal_session_id

        script = """
        tell application "Terminal"
            repeat with w in windows
                try
                    repeat with t in tabs of w
                        if tty of t is "\(ttyPath)" then
                            set bounds of w to {\(left), \(top), \(right), \(bottom)}
                            return
                        end if
                    end repeat
                end try
            end repeat
        end tell
        """
    } else {
        return
    }

    guard let appleScript = NSAppleScript(source: script) else { return }
    var error: NSDictionary?
    appleScript.executeAndReturnError(&error)
}

/// Stacks all session terminal windows in cascade, right-top aligned to the panel.
/// `sessions` should be in display order (same as list). `panelFrame` is the Monitor panel's frame in AppKit coords.
/// If `uniformSize` is provided, all windows are resized to that size before stacking.
func stackWindows(sessions: [SessionInfo], panelFrame: NSRect, uniformSize: NSSize? = nil) {
    let cascadeOffset: CGFloat = 30

    // Find the screen containing the panel (not NSScreen.main which is the key-window screen)
    let panelCenter = NSPoint(x: panelFrame.midX, y: panelFrame.midY)
    let screenFrame = NSScreen.screens.first(where: { $0.frame.contains(panelCenter) })?.visibleFrame
        ?? NSScreen.main?.visibleFrame ?? .zero

    // Anchor point: panel's bottom-right corner in AppKit coords.
    // Windows cascade downward from here (panel bottom = window top boundary).
    let anchorRight = panelFrame.maxX
    let anchorY = panelFrame.origin.y  // panel's bottom edge in AppKit (windows start below this)

    for (index, session) in sessions.enumerated() {
        // Skip sessions without terminal info (avoids unnecessary AppleScript call)
        guard !session.terminal.isEmpty, !session.terminal_session_id.isEmpty else { continue }

        // Get current window size; if uniformSize specified, use that instead
        let winSize: NSSize
        if let uniform = uniformSize {
            winSize = uniform
        } else {
            guard let currentFrame = getTerminalWindowFrame(session: session) else { continue }
            winSize = currentFrame.size
        }

        let offset = CGFloat(index) * cascadeOffset
        // Right edge aligned to anchor, each window shifts left and down
        let newX = max(screenFrame.minX, anchorRight - winSize.width - offset)
        let newY = max(screenFrame.minY, anchorY - winSize.height - offset)

        let newRect = NSRect(x: newX, y: newY, width: winSize.width, height: winSize.height)
        moveTerminalWindow(session: session, to: newRect)
    }
}

// MARK: - Pulsing Dot View

struct PulsingDot: View {
    let color: Color
    let isPulsing: Bool

    @State private var scale: CGFloat = 1.0

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .scaleEffect(scale)
            .shadow(color: color.opacity(0.6), radius: isPulsing ? 4 : 0)
            .onAppear {
                if isPulsing {
                    withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                        scale = 1.4
                    }
                }
            }
            .onChange(of: isPulsing) { _, newValue in
                if newValue {
                    withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                        scale = 1.4
                    }
                } else {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        scale = 1.0
                    }
                }
            }
    }
}

struct SpinnerView: View {
    @State private var rotation: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(Color.white.opacity(0.5), lineWidth: 1.5)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}

// MARK: - Fold Divider Bar

struct FoldDividerBar: View {
    let count: Int
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 1)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.white.opacity(0.3))
                Text("\(count) hidden")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.3))
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.white.opacity(0.3))
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Session Row View

struct SessionRowView: View {
    let session: SessionInfo
    var isSummarizing: Bool = false
    var onDismiss: (() -> Void)? = nil
    var onRestore: (() -> Void)? = nil
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            PulsingDot(
                color: session.statusColor,
                isPulsing: session.status == "working"
            )

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    if isSummarizing {
                        SpinnerView()
                            .frame(width: 10, height: 10)
                    }
                    Text(session.displayName)
                        .font(.system(size: 12, weight: .semibold, design: .default))
                        .foregroundColor(session.isStale ? .gray : .white)
                        .lineLimit(1)

                    Text(session.status)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(session.statusColor.opacity(session.isStale ? 0.5 : 0.8))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule()
                                .fill(session.statusColor.opacity(session.isStale ? 0.05 : 0.15))
                        )

                    Spacer()

                    if onRestore != nil || onDismiss != nil {
                        ZStack {
                            if isHovered {
                                if let onRestore = onRestore {
                                    Button {
                                        onRestore()
                                    } label: {
                                        Image(systemName: "arrow.uturn.backward")
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundColor(.white.opacity(0.35))
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                } else if let onDismiss = onDismiss {
                                    Button {
                                        onDismiss()
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundColor(.white.opacity(0.35))
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .frame(width: 28, height: 28)
                    }

                    Text(session.elapsedString)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.gray)
                }

                if !session.last_prompt.isEmpty {
                    Text(session.last_prompt)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Header Bar

// MARK: - Usage Pill View

struct UsagePillView: View {
    let percent: Double
    let resetTime: String?

    private var tierColor: Color {
        if percent < 50 { return Color(red: 0.52, green: 0.94, blue: 0.67) }
        if percent < 75 { return Color(red: 0.99, green: 0.88, blue: 0.28) }
        if percent < 90 { return Color(red: 0.96, green: 0.62, blue: 0.04) }
        return Color(red: 0.94, green: 0.27, blue: 0.27)
    }

    private var fillOpacity: Double {
        if percent < 50 { return 0.2 }
        if percent < 75 { return 0.25 }
        if percent < 90 { return 0.25 }
        return 0.3
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Background
                Capsule()
                    .fill(Color.white.opacity(0.06))

                // Fill bar
                Capsule()
                    .fill(tierColor.opacity(fillOpacity))
                    .frame(width: geo.size.width * min(percent / 100, 1.0))

                // Text
                HStack(spacing: 3) {
                    Text("\(Int(percent))%")
                        .foregroundColor(tierColor)
                    if let resetTime = resetTime {
                        Text("·")
                            .foregroundColor(.white.opacity(0.25))
                        Text(resetTime)
                            .foregroundColor(.white.opacity(0.45))
                    }
                }
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .frame(maxWidth: .infinity)
            }
        }
        .frame(width: 60, height: 16)
        .allowsHitTesting(false)
    }
}

// MARK: - Settings Popover

struct SettingsPopover: View {
    @ObservedObject var configManager: ConfigManager
    @ObservedObject var voiceFetcher: VoiceFetcher
    var sessionReader: SessionReader?
    @State private var pastedVoiceId: String? = nil
    @State private var refreshed = false
    @State private var isGenerating = false
    @State private var generateResult: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Refresh sessions
            Button {
                DispatchQueue.global(qos: .userInitiated).async {
                    sessionReader?.discoverSessions()
                    sessionReader?.regenerateTitles()
                }
                refreshed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { refreshed = false }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: refreshed ? "checkmark" : "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundColor(refreshed ? .green : .white.opacity(0.4))
                    Text(refreshed ? "Refreshed" : "Refresh sessions")
                        .font(.system(size: 11))
                        .foregroundColor(refreshed ? .green.opacity(0.8) : .white.opacity(0.6))
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            Divider().background(Color.white.opacity(0.1))

            // Master toggle
            Button {
                configManager.toggleVoice()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: configManager.voiceEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.system(size: 10))
                        .foregroundColor(configManager.voiceEnabled ? .cyan : .gray)
                    Text(configManager.voiceEnabled ? "Voice on" : "Voice off")
                        .font(.system(size: 11))
                        .foregroundColor(configManager.voiceEnabled ? .white : .white.opacity(0.4))
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            // Notifications toggle
            Button {
                configManager.toggleNotifications()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: configManager.notificationsEnabled ? "bell.badge.fill" : "bell.slash.fill")
                        .font(.system(size: 10))
                        .foregroundColor(configManager.notificationsEnabled ? .yellow : .gray)
                    Text(configManager.notificationsEnabled ? "Notifications on" : "Notifications off")
                        .font(.system(size: 11))
                        .foregroundColor(configManager.notificationsEnabled ? .white : .white.opacity(0.4))
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if configManager.voiceEnabled {
                Divider().background(Color.white.opacity(0.1))

                // Current voice display
                if let name = configManager.voiceName(for: configManager.currentVoiceId) {
                    HStack(spacing: 4) {
                        Text(name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.cyan)
                        Spacer()
                        Text(String(configManager.currentVoiceId.prefix(8)))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.white.opacity(0.2))
                    }
                }

                Text("Voice")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
                    .textCase(.uppercase)

                if voiceFetcher.hasFetched || !(configManager.config?.voices ?? []).isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(configManager.allVoices) { voice in
                                let isSelected = configManager.currentVoiceId == voice.id
                                Button {
                                    configManager.setVoice(voice.id)
                                    pastedVoiceId = nil
                                } label: {
                                    HStack(spacing: 6) {
                                        Circle()
                                            .fill(isSelected ? Color.cyan : Color.white.opacity(0.15))
                                            .frame(width: 6, height: 6)
                                        Text(voice.name)
                                            .font(.system(size: 11))
                                            .foregroundColor(isSelected ? .white : .white.opacity(0.5))
                                            .lineLimit(1)
                                        Spacer()
                                    }
                                    .padding(.vertical, 2)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                } else {
                    Text("Loading voices...")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.3))
                }

                Divider().background(Color.white.opacity(0.1))

                // Paste voice ID from clipboard
                Button {
                    if let pasted = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !pasted.isEmpty {
                        configManager.setVoice(pasted)
                        pastedVoiceId = String(pasted.prefix(20))
                        // Resolve name and persist to voice list
                        let voiceId = pasted
                        if let existing = configManager.voiceName(for: voiceId) {
                            configManager.addVoice(id: voiceId, name: existing)
                        } else {
                            voiceFetcher.resolveVoiceName(id: voiceId) { name in
                                DispatchQueue.main.async {
                                    configManager.addVoice(id: voiceId, name: name ?? "Voice \(String(voiceId.prefix(8)))")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.3))
                        Text("Paste voice ID")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.4))
                        Spacer()
                    }
                }
                .buttonStyle(.plain)

                if let pasted = pastedVoiceId {
                    Text("Set to \(pasted)...")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.green.opacity(0.6))
                }

                // Generate voice from design prompt
                if let prompt = configManager.config?.elevenlabs.voice_design_prompt, !prompt.isEmpty {
                    Divider().background(Color.white.opacity(0.1))

                    Button {
                        guard !isGenerating else { return }
                        isGenerating = true
                        generateResult = nil
                        let voiceName = configManager.config?.elevenlabs.voice_design_name ?? "claude-monitor"
                        voiceFetcher.designVoice(prompt: prompt, name: voiceName) { voiceId, name in
                            DispatchQueue.main.async {
                                isGenerating = false
                                if let voiceId = voiceId, let name = name {
                                    configManager.setVoice(voiceId)
                                    configManager.addVoice(id: voiceId, name: name)
                                    generateResult = name
                                    voiceFetcher.fetchVoices()
                                } else {
                                    generateResult = "failed"
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if isGenerating {
                                ProgressView()
                                    .scaleEffect(0.5)
                                    .frame(width: 10, height: 10)
                            } else {
                                Image(systemName: "wand.and.stars")
                                    .font(.system(size: 9))
                                    .foregroundColor(.purple.opacity(0.6))
                            }
                            Text(isGenerating ? "Generating..." : "Generate voice")
                                .font(.system(size: 10))
                                .foregroundColor(isGenerating ? .purple.opacity(0.4) : .purple.opacity(0.6))
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isGenerating)

                    if let result = generateResult {
                        Text(result == "failed" ? "Generation failed" : "Created \"\(result)\"")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(result == "failed" ? .red.opacity(0.6) : .green.opacity(0.6))
                    }
                }
            }

            Divider().background(Color.white.opacity(0.1))

            Button {
                NSApp.terminate(nil)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "power")
                        .font(.system(size: 10))
                        .foregroundColor(.red.opacity(0.6))
                    Text("Quit")
                        .font(.system(size: 11))
                        .foregroundColor(.red.opacity(0.6))
                    Spacer()
                }
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .frame(width: 200)
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
        )
    }
}

struct HeaderBar: View {
    let sessions: [SessionInfo]
    @ObservedObject var configManager: ConfigManager
    @ObservedObject var usageManager: UsageManager
    var sessionReader: SessionReader?
    @State private var showSettings = false
    @State private var lastStackClickTime: Date = .distantPast

    var attentionCount: Int { sessions.filter { $0.status == "attention" }.count }
    var workingCount: Int { sessions.filter { $0.status == "working" }.count }
    var doneCount: Int { sessions.filter { $0.status == "done" }.count }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.6))
                Text("Claude")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
                if let percent = usageManager.sevenDayPercent {
                    UsagePillView(percent: percent, resetTime: usageManager.resetTimeString)
                }
            }
            .allowsHitTesting(false)

            Spacer()

            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    if attentionCount > 0 {
                        HStack(spacing: 3) {
                            Circle().fill(Color.orange).frame(width: 6, height: 6)
                            Text("\(attentionCount)")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(.orange)
                        }
                    }
                    if workingCount > 0 {
                        HStack(spacing: 3) {
                            Circle().fill(Color.cyan).frame(width: 6, height: 6)
                            Text("\(workingCount)")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(.cyan)
                        }
                    }
                    if doneCount > 0 {
                        HStack(spacing: 3) {
                            Circle().fill(Color.green).frame(width: 6, height: 6)
                            Text("\(doneCount)")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(.green)
                        }
                    }

                    Text("\(sessions.count)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                }
                .allowsHitTesting(false)

                Button {
                    guard let panelFrame = NSApp.windows.first(where: { $0 is FloatingPanel })?.frame else { return }
                    let now = Date()
                    let isDoubleClick = now.timeIntervalSince(lastStackClickTime) < 2.0
                    lastStackClickTime = now
                    let orderedSessions = sessions
                    DispatchQueue.global(qos: .userInitiated).async {
                        if isDoubleClick {
                            // Uniform size: 50% of the panel's screen, capped at 1200x800
                            let panelCenter = NSPoint(x: panelFrame.midX, y: panelFrame.midY)
                            let screen = NSScreen.screens.first(where: { $0.frame.contains(panelCenter) }) ?? NSScreen.main
                            let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
                            let w = min(1200, visibleFrame.width * 0.5)
                            let h = min(800, visibleFrame.height * 0.6)
                            stackWindows(sessions: orderedSessions, panelFrame: panelFrame, uniformSize: NSSize(width: w, height: h))
                        } else {
                            stackWindows(sessions: orderedSessions, panelFrame: panelFrame)
                        }
                    }
                } label: {
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 8))
                        .foregroundColor(.white.opacity(0.2))
                }
                .buttonStyle(.plain)
                .help("Stack windows (click twice to resize)")

                Button {
                    showSettings.toggle()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 8))
                        .foregroundColor(.white.opacity(0.2))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                    SettingsPopover(configManager: configManager, voiceFetcher: configManager.voiceFetcher, sessionReader: sessionReader)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(WindowDragHandle())
    }
}

// MARK: - Main Content View

struct MonitorContentView: View {
    @ObservedObject var reader: SessionReader
    @ObservedObject var configManager: ConfigManager
    @ObservedObject var usageManager: UsageManager
    @State private var isExpanded = true
    @State private var isFoldExpanded = false
    @AppStorage("monitorWidth") private var panelWidth: Double = 280
    @AppStorage("monitorMaxHeight") private var panelMaxHeight: Double = 300
    private static let guideAnimator = ClickGuideAnimator()

    private func sessionButton(for session: SessionInfo, onDismiss: (() -> Void)? = nil, onRestore: (() -> Void)? = nil) -> some View {
        Button {
            let mouseLocation = NSEvent.mouseLocation
            let sessionCopy = session
            let animator = Self.guideAnimator
            DispatchQueue.global(qos: .userInitiated).async {
                let targetFrame = getTerminalWindowFrame(session: sessionCopy)
                DispatchQueue.main.async {
                    if let frame = targetFrame {
                        animator.animate(
                            from: mouseLocation,
                            to: frame,
                            color: sessionCopy.statusNSColor
                        )
                    }
                }
                switchToSession(sessionCopy)
            }
        } label: {
            SessionRowView(
                session: session,
                isSummarizing: reader.summarizeInFlight.contains(session.session_id),
                onDismiss: onDismiss,
                onRestore: onRestore
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header — always visible, drag to move
            HeaderBar(sessions: reader.visibleSessions, configManager: configManager, usageManager: usageManager, sessionReader: reader)

            if isExpanded && !reader.sessions.isEmpty {
                Divider()
                    .background(Color.white.opacity(0.1))

                ScrollView {
                    VStack(spacing: 0) {
                        // Visible sessions
                        ForEach(reader.visibleSessions) { session in
                            sessionButton(for: session, onDismiss: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    reader.foldSession(session.session_id)
                                }
                            })
                            if session.id != reader.visibleSessions.last?.id || !reader.foldedSessions.isEmpty {
                                Divider()
                                    .background(Color.white.opacity(0.05))
                                    .padding(.horizontal, 12)
                            }
                        }

                        // Fold divider bar
                        if !reader.foldedSessions.isEmpty {
                            FoldDividerBar(count: reader.foldedSessions.count, isExpanded: $isFoldExpanded)

                            // Folded sessions (expanded)
                            if isFoldExpanded {
                                ForEach(reader.foldedSessions) { session in
                                    sessionButton(for: session, onRestore: {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            reader.unfoldSession(session.session_id)
                                        }
                                    })
                                    .opacity(0.6)
                                    if session.id != reader.foldedSessions.last?.id {
                                        Divider()
                                            .background(Color.white.opacity(0.05))
                                            .padding(.horizontal, 12)
                                    }
                                }
                            }
                        }
                    }
                    .background(ScrollbarStyler())
                }
                .frame(maxHeight: panelMaxHeight)
            }
        }
        .frame(width: max(200, min(panelWidth, 600)))
        .fixedSize(horizontal: false, vertical: true)
        .overlay(alignment: .trailing) {
            ResizeHandle(currentWidth: panelWidth) { newWidth in
                panelWidth = newWidth
            }
            .frame(width: 6)
        }
        .overlay(alignment: .bottom) {
            VerticalResizeHandle(currentHeight: panelMaxHeight) { newHeight in
                panelMaxHeight = newHeight
            }
            .frame(height: 6)
        }
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
    }
}

struct ResizeHandle: NSViewRepresentable {
    let currentWidth: Double
    var onResize: (Double) -> Void

    func makeNSView(context: Context) -> ResizeHandleNSView {
        let view = ResizeHandleNSView()
        view.onResize = onResize
        view.startWidth = currentWidth
        return view
    }

    func updateNSView(_ nsView: ResizeHandleNSView, context: Context) {
        nsView.onResize = onResize
        if !nsView.isDragging { nsView.startWidth = currentWidth }
    }
}

class ResizeHandleNSView: NSView {
    var onResize: ((Double) -> Void)?
    var startWidth: Double = 280
    var isDragging = false
    private var dragOriginX: CGFloat = 0

    override var intrinsicContentSize: NSSize { NSSize(width: 6, height: NSView.noIntrinsicMetric) }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        dragOriginX = NSEvent.mouseLocation.x
    }

    override func mouseDragged(with event: NSEvent) {
        let delta = NSEvent.mouseLocation.x - dragOriginX
        let newWidth = max(200, min(startWidth + Double(delta), 600))
        onResize?(newWidth)
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
    }
}

struct VerticalResizeHandle: NSViewRepresentable {
    let currentHeight: Double
    var onResize: (Double) -> Void

    func makeNSView(context: Context) -> VerticalResizeHandleNSView {
        let view = VerticalResizeHandleNSView()
        view.onResize = onResize
        view.startHeight = currentHeight
        return view
    }

    func updateNSView(_ nsView: VerticalResizeHandleNSView, context: Context) {
        nsView.onResize = onResize
        if !nsView.isDragging { nsView.startHeight = currentHeight }
    }
}

class VerticalResizeHandleNSView: NSView {
    var onResize: ((Double) -> Void)?
    var startHeight: Double = 300
    var isDragging = false
    private var dragOriginY: CGFloat = 0

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 6) }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        dragOriginY = NSEvent.mouseLocation.y
    }

    override func mouseDragged(with event: NSEvent) {
        // Screen Y is bottom-up; dragging down (negative delta) should increase height
        let delta = dragOriginY - NSEvent.mouseLocation.y
        let newHeight = max(100, min(startHeight + Double(delta), 800))
        onResize?(newHeight)
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
    }
}

// MARK: - Custom Thin Scrollbar

class ThinScroller: NSScroller {
    override class func scrollerWidth(for controlSize: ControlSize, scrollerStyle: Style) -> CGFloat {
        return 5
    }

    override func drawKnob() {
        var knobRect = rect(for: .knob)
        knobRect = NSRect(
            x: bounds.width - 4,
            y: knobRect.origin.y + 2,
            width: 3,
            height: max(knobRect.height - 4, 8)
        )
        let path = NSBezierPath(roundedRect: knobRect, xRadius: 1.5, yRadius: 1.5)
        NSColor.white.withAlphaComponent(0.2).setFill()
        path.fill()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        // Transparent track — no background
    }
}

struct ScrollbarStyler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.setFrameSize(.zero)
        DispatchQueue.main.async {
            var superview = view.superview
            while let sv = superview {
                if let scrollView = sv as? NSScrollView {
                    scrollView.scrollerStyle = .overlay
                    scrollView.hasVerticalScroller = true
                    scrollView.autohidesScrollers = true
                    let scroller = ThinScroller()
                    scroller.controlSize = .mini
                    scrollView.verticalScroller = scroller
                    break
                }
                superview = sv.superview
            }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - NSVisualEffectView wrapper

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Floating Panel

class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.hidesOnDeactivate = false
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.isMovableByWindowBackground = false
        self.acceptsMouseMovedEvents = true
        self.ignoresMouseEvents = false
    }

    func restorePosition() {
        if let x = UserDefaults.standard.object(forKey: "monitorX") as? Double,
           let y = UserDefaults.standard.object(forKey: "monitorY") as? Double {
            self.setFrameOrigin(NSPoint(x: x, y: y))
        } else if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            // Top-right, below menu bar
            let x = screenFrame.maxX - 296
            let y = screenFrame.maxY - 60
            self.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    func savePosition() {
        UserDefaults.standard.set(self.frame.origin.x, forKey: "monitorX")
        UserDefaults.standard.set(self.frame.origin.y, forKey: "monitorY")
    }
}

// MARK: - Click-through Hosting View

class ClickHostingView<Content: View>: NSHostingView<Content> {
    private var cursorTrackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = cursorTrackingArea { removeTrackingArea(ta) }
        cursorTrackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved],
            owner: self
        )
        addTrackingArea(cursorTrackingArea!)
    }

    override func mouseMoved(with event: NSEvent) {
        let loc = event.locationInWindow // origin bottom-left
        let size = window?.frame.size ?? bounds.size
        if loc.x >= size.width - 6 {
            NSCursor.resizeLeftRight.set()
        } else if loc.y <= 6 {
            NSCursor.resizeUpDown.set()
        } else {
            NSCursor.arrow.set()
        }
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        super.mouseExited(with: event)
    }
}

// MARK: - Window Drag Handle (NSViewRepresentable)

struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DragHandleNSView { DragHandleNSView() }
    func updateNSView(_ nsView: DragHandleNSView, context: Context) {}

    class DragHandleNSView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

// MARK: - Notification Manager

class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    private var authorized = false
    private var available = false

    override init() {
        super.init()
        // UNUserNotificationCenter requires a valid bundle identifier (.app bundle).
        // When running as a bare binary, Bundle.main.bundleIdentifier is nil and
        // calling UNUserNotificationCenter.current() will crash.
        guard Bundle.main.bundleIdentifier != nil else {
            NSLog("[ClaudeMonitor] No bundle identifier — notifications disabled (run as .app bundle to enable)")
            return
        }
        available = true
        UNUserNotificationCenter.current().delegate = self
        requestAuthorization()
    }

    private func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            DispatchQueue.main.async {
                self.authorized = granted
            }
        }
    }

    func postStatusChange(session: SessionInfo, oldStatus: String, newStatus: String, config: MonitorConfig.NotificationConfig?) {
        guard available, authorized else { return }
        guard let config = config, config.enabled else { return }

        switch newStatus {
        case "starting":  guard config.on_starting else { return }
        case "working":   guard config.on_working else { return }
        case "done":      guard config.on_done else { return }
        case "attention": guard config.on_attention else { return }
        default: return
        }

        let content = UNMutableNotificationContent()
        content.title = "\(statusEmoji(newStatus)) \(session.displayName)"
        content.subtitle = statusDescription(newStatus)
        content.sound = .default
        content.threadIdentifier = session.session_id
        content.userInfo = [
            "session_id": session.session_id,
            "terminal": session.terminal,
            "terminal_session_id": session.terminal_session_id
        ]

        // Body: project, elapsed time, last prompt
        var bodyParts: [String] = []
        bodyParts.append("Project: \(session.project)")
        if !session.elapsedString.isEmpty {
            bodyParts.append("Elapsed: \(session.elapsedString)")
        }
        if !session.last_prompt.isEmpty {
            bodyParts.append("Last: \(session.last_prompt)")
        }
        content.body = bodyParts.joined(separator: "\n")

        let request = UNNotificationRequest(
            identifier: "\(session.session_id)-\(newStatus)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    private func statusEmoji(_ status: String) -> String {
        switch status {
        case "starting":  return "⏳"
        case "working":   return "🔵"
        case "done":      return "✅"
        case "attention": return "🔔"
        default:          return "⚪"
        }
    }

    private func statusDescription(_ status: String) -> String {
        switch status {
        case "starting":  return "Session started"
        case "working":   return "Started working"
        case "done":      return "Finished"
        case "attention": return "Needs permission"
        default:          return status
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        guard let sessionId = userInfo["session_id"] as? String,
              let terminal = userInfo["terminal"] as? String,
              let terminalSessionId = userInfo["terminal_session_id"] as? String else {
            completionHandler()
            return
        }

        let decoder = JSONDecoder()
        let json: [String: String] = [
            "session_id": sessionId,
            "terminal": terminal,
            "terminal_session_id": terminalSessionId
        ]
        if let data = try? JSONSerialization.data(withJSONObject: json),
           let session = try? decoder.decode(SessionInfo.self, from: data) {
            DispatchQueue.global(qos: .userInitiated).async {
                switchToSession(session)
            }
        }

        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: FloatingPanel!
    let reader = SessionReader()
    let configManager = ConfigManager()
    let usageManager = UsageManager()
    var sizeObserver: AnyCancellable?
    let notificationManager = NotificationManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        reader.setConfigManager(configManager)
        reader.setNotificationManager(notificationManager)
        usageManager.startPolling()

        panel = FloatingPanel()

        let hostingView = ClickHostingView(
            rootView: MonitorContentView(reader: reader, configManager: configManager, usageManager: usageManager)
        )
        hostingView.frame = NSRect(origin: .zero, size: NSSize(width: 280, height: 40))
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        panel.contentView = hostingView

        panel.restorePosition()
        panel.orderFrontRegardless()

        // Auto-resize panel to fit content
        sizeObserver = hostingView.publisher(for: \.fittingSize)
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] newSize in
                guard let self = self, let panel = self.panel else { return }
                let origin = panel.frame.origin
                // Grow downward from top edge
                let topY = origin.y + panel.frame.height
                let newOrigin = NSPoint(x: origin.x, y: topY - newSize.height)
                panel.setFrame(
                    NSRect(origin: newOrigin, size: newSize),
                    display: true,
                    animate: false
                )
            }

        // Save position on drag
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            self?.panel.savePosition()
        }

        // Cmd+Q to quit
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "q" {
                NSApp.terminate(nil)
                return nil
            }
            return event
        }
    }
}

// MARK: - Click Guide Animator

class ClickGuideAnimator {
    private var overlayWindows: [NSWindow] = []
    private var eventMonitor: Any?
    private var cleanupWorkItem: DispatchWorkItem?

    /// Create a per-screen transparent overlay window
    private func makeOverlay(for screen: NSScreen) -> NSWindow {
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = .screenSaver
        w.isOpaque = false
        w.backgroundColor = .clear
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let v = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        v.wantsLayer = true
        w.contentView = v
        return w
    }

    /// Find which screen contains a point
    private func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }

    /// Convert screen-space point to local window/view coords for a given screen
    private func localPoint(_ point: NSPoint, in screen: NSScreen) -> NSPoint {
        NSPoint(x: point.x - screen.frame.origin.x, y: point.y - screen.frame.origin.y)
    }

    /// Convert screen-space rect to local coords for a given screen
    private func localRect(_ rect: NSRect, in screen: NSScreen) -> NSRect {
        NSRect(x: rect.origin.x - screen.frame.origin.x, y: rect.origin.y - screen.frame.origin.y,
               width: rect.width, height: rect.height)
    }

    func animate(from fromPoint: NSPoint, to targetFrame: NSRect, color: NSColor) {
        cleanup()

        let targetMid = NSPoint(x: targetFrame.midX, y: targetFrame.midY)
        let sourceScreen = screen(containing: fromPoint)
        let targetScreen = screen(containing: targetMid)
        let sameScreen = (sourceScreen == targetScreen)

        // --- Distance-based flight duration (fix #1) ---
        let dx = targetMid.x - fromPoint.x
        let dy = targetMid.y - fromPoint.y
        let distance = sqrt(dx * dx + dy * dy)
        let flightDuration = max(0.3, min(0.8, distance / 1500.0))

        // --- Source screen: orb ---
        if let src = sourceScreen {
            let srcWindow = makeOverlay(for: src)
            let srcLayer = srcWindow.contentView!.layer!
            let lFrom = localPoint(fromPoint, in: src)

            // Orb destination: target center if same screen, otherwise fly toward screen edge
            let orbDest: NSPoint
            if sameScreen {
                orbDest = localPoint(targetMid, in: src)
            } else {
                // Fly toward the edge of this screen in the direction of target
                let lTarget = localPoint(targetMid, in: src)
                let screenW = src.frame.width
                let screenH = src.frame.height
                // Find parameter t where the line exits the screen bounds
                var tMin: CGFloat = 1.0
                let odx = lTarget.x - lFrom.x
                let ody = lTarget.y - lFrom.y
                if odx != 0 {
                    let tRight = (screenW - lFrom.x) / odx
                    let tLeft = -lFrom.x / odx
                    if tRight > 0 { tMin = min(tMin, tRight) }
                    if tLeft > 0 { tMin = min(tMin, tLeft) }
                }
                if ody != 0 {
                    let tTop = (screenH - lFrom.y) / ody
                    let tBottom = -lFrom.y / ody
                    if tTop > 0 { tMin = min(tMin, tTop) }
                    if tBottom > 0 { tMin = min(tMin, tBottom) }
                }
                orbDest = NSPoint(x: lFrom.x + odx * tMin * 0.95, y: lFrom.y + ody * tMin * 0.95)
            }

            // Orb layer
            let orbSize: CGFloat = 50
            let orbLayer = CAGradientLayer()
            orbLayer.type = .radial
            orbLayer.colors = [color.withAlphaComponent(0.8).cgColor, color.withAlphaComponent(0.0).cgColor]
            orbLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
            orbLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
            orbLayer.bounds = CGRect(x: 0, y: 0, width: orbSize, height: orbSize)
            orbLayer.cornerRadius = orbSize / 2
            orbLayer.position = lFrom
            srcLayer.addSublayer(orbLayer)

            // If same screen, also add border here
            if sameScreen {
                addBorderLayer(to: srcLayer, frame: localRect(targetFrame, in: src), color: color, delay: flightDuration)
            }

            srcWindow.orderFrontRegardless()
            overlayWindows.append(srcWindow)

            // Flight animation
            let midPt = NSPoint(x: (lFrom.x + orbDest.x) / 2, y: (lFrom.y + orbDest.y) / 2)
            let fdx = orbDest.x - lFrom.x
            let fdy = orbDest.y - lFrom.y
            let fDist = sqrt(fdx * fdx + fdy * fdy)
            let perpOff = fDist * 0.15
            let pX = -(fdy) / max(fDist, 1)
            let pY = fdx / max(fDist, 1)
            let ctrl = CGPoint(x: midPt.x + pX * perpOff, y: midPt.y + pY * perpOff)

            let path = CGMutablePath()
            path.move(to: lFrom)
            path.addQuadCurve(to: orbDest, control: ctrl)

            let flightAnim = CAKeyframeAnimation(keyPath: "position")
            flightAnim.path = path
            flightAnim.duration = flightDuration
            flightAnim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            flightAnim.fillMode = .forwards
            flightAnim.isRemovedOnCompletion = false
            orbLayer.add(flightAnim, forKey: "flight")

            // Dissolve orb after flight
            DispatchQueue.main.asyncAfter(deadline: .now() + flightDuration) { [weak self] in
                guard !(self?.overlayWindows.isEmpty ?? true) else { return }
                let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
                scaleAnim.fromValue = 1.0; scaleAnim.toValue = 3.0
                let fadeAnim = CABasicAnimation(keyPath: "opacity")
                fadeAnim.fromValue = 1.0; fadeAnim.toValue = 0.0
                let group = CAAnimationGroup()
                group.animations = [scaleAnim, fadeAnim]
                group.duration = 0.4
                group.fillMode = .forwards; group.isRemovedOnCompletion = false
                orbLayer.add(group, forKey: "dissolve")
            }
        }

        // --- Target screen (different from source): orb enters from edge + border ---
        if !sameScreen, let tgt = targetScreen {
            let tgtWindow = makeOverlay(for: tgt)
            let tgtLayer = tgtWindow.contentView!.layer!
            let lTarget = localPoint(targetMid, in: tgt)

            // Calculate entry point: where the line from source enters this screen
            let lSource = localPoint(fromPoint, in: tgt)
            let screenW = tgt.frame.width
            let screenH = tgt.frame.height
            var tMax: CGFloat = 0.0
            let edx = lTarget.x - lSource.x
            let edy = lTarget.y - lSource.y
            // Find the largest t < 1 where the line crosses a screen edge (entry point)
            if edx != 0 {
                let tLeft = -lSource.x / edx
                let tRight = (screenW - lSource.x) / edx
                if tLeft > 0 && tLeft < 1 { tMax = max(tMax, tLeft) }
                if tRight > 0 && tRight < 1 { tMax = max(tMax, tRight) }
            }
            if edy != 0 {
                let tBottom = -lSource.y / edy
                let tTop = (screenH - lSource.y) / edy
                if tBottom > 0 && tBottom < 1 { tMax = max(tMax, tBottom) }
                if tTop > 0 && tTop < 1 { tMax = max(tMax, tTop) }
            }
            let entryPoint = NSPoint(
                x: lSource.x + edx * max(tMax, 0.01),
                y: lSource.y + edy * max(tMax, 0.01)
            )

            // Second orb: enters from screen edge, flies to target center
            let orbSize: CGFloat = 50
            let orb2 = CAGradientLayer()
            orb2.type = .radial
            orb2.colors = [color.withAlphaComponent(0.8).cgColor, color.withAlphaComponent(0.0).cgColor]
            orb2.startPoint = CGPoint(x: 0.5, y: 0.5)
            orb2.endPoint = CGPoint(x: 1.0, y: 1.0)
            orb2.bounds = CGRect(x: 0, y: 0, width: orbSize, height: orbSize)
            orb2.cornerRadius = orbSize / 2
            orb2.position = entryPoint
            tgtLayer.addSublayer(orb2)

            // Border glow at target
            let secondFlightDuration = max(0.2, min(0.5, flightDuration * 0.6))
            addBorderLayer(to: tgtLayer, frame: localRect(targetFrame, in: tgt), color: color, delay: secondFlightDuration)

            tgtWindow.orderFrontRegardless()
            overlayWindows.append(tgtWindow)

            // Animate second orb after source orb reaches edge
            DispatchQueue.main.asyncAfter(deadline: .now() + flightDuration * 0.8) { [weak self] in
                guard !(self?.overlayWindows.isEmpty ?? true) else { return }

                // Flight from edge to target center
                let path2 = CGMutablePath()
                path2.move(to: entryPoint)
                path2.addLine(to: lTarget)
                let flight2 = CAKeyframeAnimation(keyPath: "position")
                flight2.path = path2
                flight2.duration = secondFlightDuration
                flight2.timingFunction = CAMediaTimingFunction(name: .easeOut)
                flight2.fillMode = .forwards
                flight2.isRemovedOnCompletion = false
                orb2.add(flight2, forKey: "flight")

                // Dissolve after arrival
                DispatchQueue.main.asyncAfter(deadline: .now() + secondFlightDuration) { [weak self] in
                    guard !(self?.overlayWindows.isEmpty ?? true) else { return }
                    let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
                    scaleAnim.fromValue = 1.0; scaleAnim.toValue = 3.0
                    let fadeAnim = CABasicAnimation(keyPath: "opacity")
                    fadeAnim.fromValue = 1.0; fadeAnim.toValue = 0.0
                    let group = CAAnimationGroup()
                    group.animations = [scaleAnim, fadeAnim]
                    group.duration = 0.4
                    group.fillMode = .forwards; group.isRemovedOnCompletion = false
                    orb2.add(group, forKey: "dissolve")
                }
            }
        }

        // Event monitor — cancel on any interaction
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] _ in
            self?.cancelWithFade()
        }

        // Auto-cleanup (allow extra time for cross-screen second orb)
        let totalDuration = sameScreen ? flightDuration + 1.0 : flightDuration + 2.0
        let workItem = DispatchWorkItem { [weak self] in self?.cleanup() }
        cleanupWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + totalDuration, execute: workItem)
    }

    /// Add a glowing border layer to the given parent layer (fix #3)
    private func addBorderLayer(to parent: CALayer, frame: NSRect, color: NSColor, delay: Double) {
        // Glow layer (larger, blurred shadow behind border)
        let glowInset: CGFloat = -8
        let glowRect = frame.insetBy(dx: glowInset, dy: glowInset)
        let glowLayer = CAShapeLayer()
        let glowPath = NSBezierPath(roundedRect: glowRect, xRadius: 14, yRadius: 14)
        glowLayer.path = glowPath.cgPath
        glowLayer.strokeColor = color.withAlphaComponent(0.6).cgColor
        glowLayer.lineWidth = 6
        glowLayer.fillColor = nil
        glowLayer.shadowColor = color.cgColor
        glowLayer.shadowRadius = 20
        glowLayer.shadowOpacity = 0.8
        glowLayer.shadowOffset = .zero
        glowLayer.opacity = 0
        parent.addSublayer(glowLayer)

        // Crisp border layer on top
        let borderLayer = CAShapeLayer()
        let borderPath = NSBezierPath(roundedRect: frame, xRadius: 10, yRadius: 10)
        borderLayer.path = borderPath.cgPath
        borderLayer.strokeColor = color.withAlphaComponent(0.9).cgColor
        borderLayer.lineWidth = 3
        borderLayer.fillColor = nil
        borderLayer.opacity = 0
        parent.addSublayer(borderLayer)

        // Pulse animation for both layers
        let startTime = CACurrentMediaTime() + delay
        for layer in [glowLayer, borderLayer] {
            let fadeIn = CABasicAnimation(keyPath: "opacity")
            fadeIn.fromValue = 0.0; fadeIn.toValue = 1.0
            fadeIn.duration = 0.15; fadeIn.beginTime = 0
            fadeIn.fillMode = .forwards

            let pulse = CAKeyframeAnimation(keyPath: "opacity")
            pulse.values = [1.0, 0.3, 1.0, 0.0]
            pulse.duration = 0.8; pulse.beginTime = 0.15
            pulse.fillMode = .forwards

            let group = CAAnimationGroup()
            group.animations = [fadeIn, pulse]
            group.duration = 0.95
            group.fillMode = .forwards; group.isRemovedOnCompletion = false
            group.beginTime = startTime
            layer.add(group, forKey: "pulse")
        }
    }

    private func cancelWithFade() {
        cleanupWorkItem?.cancel()
        guard !overlayWindows.isEmpty else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            for w in overlayWindows { w.animator().alphaValue = 0 }
        }, completionHandler: { [weak self] in
            self?.cleanup()
        })
    }

    func cleanup() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        for w in overlayWindows { w.orderOut(nil) }
        overlayWindows.removeAll()
        cleanupWorkItem?.cancel()
        cleanupWorkItem = nil
    }
}

// MARK: - Main Entry Point

@main
struct ClaudeMonitorApp {
    static func main() {
        let app = NSApplication.shared
        // Set app icon programmatically to ensure notifications pick it up
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            app.applicationIconImage = icon
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
