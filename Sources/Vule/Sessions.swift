import Foundation
import SwiftUI

enum Agent: String { case claude = "Claude", copilot = "Copilot" }

/// Ordered by how badly the session needs you.
enum Status: Int, Comparable {
    case idle, busy, done, waiting
    static func < (a: Status, b: Status) -> Bool { a.rawValue < b.rawValue }
    var label: String { ["Idle", "Working", "Done", "Needs you"][rawValue] }
    var needsYou: Bool { self >= .done }
}

struct Session: Identifiable, Equatable {
    let id: String
    let agent: Agent
    let tty: String
    var terminalID: String
    var cwd: String
    var status: Status
    var firstPrompt: String
    var preview: String
    var userName: String?
    var updated: Date
    var question: Question? = nil
}

/// What a waiting session is asking, so it can be answered from the notch.
/// Options are picked TUI-style: ↓ × index, then Enter.
struct Question: Equatable {
    let text: String
    let options: [String]
    /// Claude and Copilot permission dialogs both list allow-once / allow-always / deny, in that order.
    static func permission(_ text: String) -> Question { .init(text: text, options: ["Yes", "Yes, always", "No"]) }
}

// MARK: - Palette

/// Hue wheels, each ordered so a colour flows into its neighbour (session gradient = i → i+1).
/// Pick one from the island's right-click menu, or set your own:
///   defaults write dev.vule.notch customColors "FF0055,00E5FF,7C5CFF"
enum Palette {
    static let themes: [(name: String, hex: [UInt32])] = [
        ("Neon",   [0x00E5FF, 0x3D8BFF, 0x7C5CFF, 0xB98CFF, 0xFF3DF2, 0xFF4F7B, 0xFF7A3D, 0xFFC23D, 0xB6FF3D, 0x2DFFA8]),
        ("Aurora", [0x5EEAD4, 0x22D3EE, 0x60A5FA, 0x818CF8, 0xA78BFA, 0xC084FC, 0xE879F9, 0x4ADE80, 0x34D399, 0x2DD4BF]),
        ("Sunset", [0xFF6B6B, 0xFF8E53, 0xFFB347, 0xFFD166, 0xFF9F1C, 0xFF5D8F, 0xF72585, 0xF15BB5, 0xC77DFF, 0xFE6D73]),
        ("Jewel",  [0xE0115F, 0x3B6FE0, 0x50C878, 0x9966CC, 0xFFC87C, 0x40E0D0, 0xD4AF37, 0xE6A8D7, 0x7FFFD4, 0xFF5E3A]),
        ("Pastel", [0xA0C4FF, 0xBDB2FF, 0xFFC6FF, 0xFFADAD, 0xFFD6A5, 0xFDFFB6, 0xCAFFBF, 0x9BF6FF, 0xB8E0D2, 0xE2C2FF]),
    ]
    static var custom: [UInt32] {
        (UserDefaults.standard.string(forKey: "customColors") ?? "")
            .split(whereSeparator: { ",; ".contains($0) })
            .compactMap { UInt32($0.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) }
    }
    static var names: [String] { themes.map(\.name) + (custom.isEmpty ? [] : ["Custom"]) }
    static var current: String {
        get { UserDefaults.standard.string(forKey: "theme") ?? "Neon" }
        set { UserDefaults.standard.set(newValue, forKey: "theme") }
    }
    static var hex: [UInt32] {
        if current == "Custom", !custom.isEmpty { return custom }
        return (themes.first { $0.name == current } ?? themes[0]).hex
    }
    static func ns(_ i: Int) -> NSColor {
        let h = hex[i % hex.count]
        return NSColor(srgbRed: CGFloat(h >> 16 & 0xFF) / 255, green: CGFloat(h >> 8 & 0xFF) / 255, blue: CGFloat(h & 0xFF) / 255, alpha: 1)
    }
    static func color(_ i: Int) -> Color { Color(nsColor: ns(i)) }

    /// FNV-1a — stable across launches (Swift's hashValue is seeded per process).
    static func preferred(_ id: String) -> Int {
        var h: UInt64 = 0xcbf29ce484222325
        for b in id.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return Int(h % UInt64(hex.count))
    }

    /// Keep existing assignments; give new ids their preferred hue, probing past hues already on screen.
    static func assign(_ ids: [String], existing: [String: Int]) -> [String: Int] {
        var out = existing.filter { ids.contains($0.key) }
        for id in ids where out[id] == nil {
            let used = Set(out.values)
            var i = preferred(id)
            for _ in 0..<hex.count where used.contains(i) { i = (i + 1) % hex.count }
            out[id] = i
        }
        return out
    }
}

// MARK: - Discovery

/// Builds the live session list from: Ghostty terminals (tty) × process table × agent state on disk.
///   Copilot → ~/.copilot/session-state/<id>/inuse.<pid>.lock + events.jsonl (no setup needed)
///   Claude  → ~/.vule/claude/<id>.json written by hooks/vule-hook.sh
enum Discovery {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let claudeDir = home.appendingPathComponent(".vule/claude")
    static let copilotDir = home.appendingPathComponent(".copilot/session-state")

    struct Proc { let pid: Int32; let tty: String; let comm: String }

    static func processes() -> [Proc] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,tty=,comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard f.count == 3, let pid = Int32(f[0]), f[1] != "??" else { return nil }
            return Proc(pid: pid, tty: "/dev/" + f[1], comm: String(f[2]))
        }
    }

    static func scan(terminals: [Ghostty.Terminal]) -> [Session] {
        let termByTTY = Dictionary(terminals.map { ($0.tty, $0) }, uniquingKeysWith: { a, _ in a })
        let procs = processes()
        // Only real copilot processes — a stale lock's pid may since have been reused by something else.
        let ttyOfPid = Dictionary(procs.filter { $0.comm.contains("copilot") }.map { ($0.pid, $0.tty) },
                                  uniquingKeysWith: { a, _ in a })
        let claudeTTYs = Set(procs.filter { $0.comm.lowercased().contains("claude") }.map(\.tty))

        var byTTY: [String: Session] = [:]
        func offer(_ s: Session) {
            // One agent per terminal: if a tty has several (e.g. Copilot after /new), the freshest wins.
            if let cur = byTTY[s.tty], cur.updated > s.updated { return }
            byTTY[s.tty] = s
        }

        for s in copilotSessions(ttyOfPid: ttyOfPid) { if let t = termByTTY[s.tty] { var s = s; s.terminalID = t.id; offer(s) } }
        for s in claudeSessions() where claudeTTYs.contains(s.tty) {
            if let t = termByTTY[s.tty] { var s = s; s.terminalID = t.id; offer(s) }
        }
        return byTTY.values.sorted { $0.tty.localizedStandardCompare($1.tty) == .orderedAscending }
    }

    // MARK: Copilot

    static func copilotSessions(ttyOfPid: [Int32: String]) -> [Session] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: copilotDir, includingPropertiesForKeys: nil) else { return [] }
        return dirs.compactMap { dir -> Session? in
            guard let files = try? fm.contentsOfDirectory(atPath: dir.path),
                  let lock = files.first(where: { $0.hasPrefix("inuse.") && $0.hasSuffix(".lock") }),
                  let pid = Int32(lock.split(separator: ".")[1]),
                  let tty = ttyOfPid[pid] else { return nil }
            let events = dir.appendingPathComponent("events.jsonl")
            let mtime = (try? events.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let parsed = Cache.copilot(events, mtime: mtime)
            let yaml = (try? String(contentsOf: dir.appendingPathComponent("workspace.yaml"), encoding: .utf8)) ?? ""
            let named = yaml.contains("\nuser_named: true")
            return Session(id: dir.lastPathComponent, agent: .copilot, tty: tty, terminalID: "",
                           cwd: yamlValue(yaml, "cwd") ?? "", status: parsed.status, firstPrompt: parsed.first,
                           preview: parsed.preview, userName: named ? yamlValue(yaml, "name") : nil, updated: mtime,
                           question: parsed.question)
        }
    }

    static func yamlValue(_ yaml: String, _ key: String) -> String? {
        yaml.split(separator: "\n").first { $0.hasPrefix(key + ": ") }.map { String($0.dropFirst(key.count + 2)) }
    }

    /// Walk events newest→oldest until one decides the state. Noise (model.*, usage, hooks…) is skipped.
    static func copilotStatus(_ lines: [Substring]) -> Status {
        for line in lines.reversed() {
            guard let type = eventType(line) else { continue }
            var d: [String: Any] { json(line)?["data"] as? [String: Any] ?? [:] }
            switch type {
            case "permission.requested": return .waiting
            case "tool.execution_start": return d["toolName"] as? String == "ask_user" ? .waiting : .busy
            case "permission.completed", "tool.execution_complete", "user.message", "assistant.turn_start",
                 "subagent.started", "human_response.recorded", "session.compaction_start": return .busy
            case "assistant.message": return ((d["toolRequests"] as? [Any])?.isEmpty ?? true) ? .done : .busy
            case "session.task_complete", "session.error": return .done
            case "session.start", "session.resume", "session.shutdown": return .idle
            default: continue
            }
        }
        return .idle
    }

    /// The pending ask_user form / permission prompt, if that's the newest decisive event.
    static func copilotQuestion(_ lines: [Substring]) -> Question? {
        guard copilotStatus(lines) == .waiting,
              let line = lines.last(where: { ["tool.execution_start", "permission.requested"].contains(eventType($0)) }),
              let d = json(line)?["data"] as? [String: Any] else { return nil }
        if eventType(line) == "permission.requested" {
            let p = d["permissionRequest"] as? [String: Any]
            return .permission((p?["intention"] ?? p?["fullCommandText"] ?? p?["kind"]) as? String ?? "Permission needed")
        }
        let args = d["arguments"] as? [String: Any] ?? [:]
        let props = (args["requestedSchema"] as? [String: Any])?["properties"] as? [String: [String: Any]] ?? [:]
        // First choice field: enum, oneOf titles, or multi-select items. (Dictionary order isn't the form's; fine for 1-field forms.)
        let options = props.values.lazy.compactMap { f -> [String]? in
            let items = f["items"] as? [String: Any]
            return f["enum"] as? [String] ?? (f["oneOf"] ?? items?["anyOf"]).flatMap { ($0 as? [[String: Any]])?.compactMap { $0["title"] as? String } }
                ?? items?["enum"] as? [String]
        }.first ?? []
        return Question(text: clean(args["message"] as? String ?? ""), options: options)
    }

    // MARK: Claude

    static func claudeSessions() -> [Session] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: claudeDir, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }.compactMap { url -> Session? in
            guard let data = try? Data(contentsOf: url),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = o["session_id"] as? String, let tty = o["tty"] as? String else { return nil }
            let transcript = (o["transcript_path"] as? String).map { URL(fileURLWithPath: $0) }
            let mtime = transcript.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            let parsed = transcript.map { Cache.claude($0, mtime: mtime ?? .distantPast) } ?? (first: "", preview: "")
            let ts = (o["ts"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? .distantPast
            let status = claudeStatus(o)
            return Session(id: id, agent: .claude, tty: tty, terminalID: "", cwd: o["cwd"] as? String ?? "",
                           status: status, firstPrompt: parsed.first, preview: parsed.preview,
                           userName: nil, updated: max(ts, mtime ?? ts), question: status == .waiting ? claudeQuestion(o) : nil)
        }
    }

    static func claudeStatus(_ o: [String: Any]) -> Status {
        switch o["event"] as? String {
        case "UserPromptSubmit", "PostToolUse", "SubagentStop", "PreCompact": return .busy
        case "PreToolUse": return o["tool_name"] as? String == "AskUserQuestion" ? .waiting : .busy
        case "Stop": return .done
        case "Notification":
            let type = o["notification_type"] as? String ?? ""
            let msg = (o["message"] as? String ?? "").lowercased()
            return type == "idle_prompt" || msg.contains("waiting for your input") ? .done : .waiting
        default: return .idle
        }
    }

    static func claudeQuestion(_ o: [String: Any]) -> Question? {
        if let q = o["question"] as? [String: Any] {
            return Question(text: clean(q["text"] as? String ?? ""), options: q["options"] as? [String] ?? [])
        }
        return o["event"] as? String == "Notification" ? .permission(o["message"] as? String ?? "Permission needed") : nil
    }

    // MARK: Transcript helpers

    /// Copilot lines start with {"type":"…"} — read it without parsing a line that may hold a huge tool output.
    static func eventType(_ line: Substring) -> Substring? {
        guard line.hasPrefix(#"{"type":""#) else { return nil }
        let rest = line.dropFirst(9)
        return rest.firstIndex(of: "\"").map { rest[..<$0] }
    }

    static func json(_ line: Substring) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    }

    /// Read at most `limit` bytes from the head or tail of a file, split into whole lines.
    static func lines(_ url: URL, tail: Bool, limit: Int = 256 * 1024) -> [Substring] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = tail ? (size > UInt64(limit) ? size - UInt64(limit) : 0) : 0
        try? h.seek(toOffset: start)
        let data = (try? h.read(upToCount: limit)) ?? Data()
        var ls = String(decoding: data, as: UTF8.self).split(separator: "\n")
        if tail && start > 0 && !ls.isEmpty { ls.removeFirst() }   // partial first line
        if !tail && data.count == limit && !ls.isEmpty { ls.removeLast() } // partial last line
        return ls
    }

    /// One line of plain text: collapse whitespace, drop markdown markers (#, **, `).
    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "(?m)^\\s*#{1,6}\\s+|\\*\\*|`", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    static func claudeText(_ content: Any?) -> String? {
        if let s = content as? String { return s }
        return (content as? [[String: Any]])?.first { $0["type"] as? String == "text" }?["text"] as? String
    }
}

/// Re-parse a transcript only when its mtime changes; the first prompt never changes once found.
enum Cache {
    nonisolated(unsafe) private static var copilotCache: [URL: (Date, (status: Status, first: String, preview: String, question: Question?))] = [:]
    nonisolated(unsafe) private static var claudeCache: [URL: (Date, (first: String, preview: String))] = [:]

    static func copilot(_ url: URL, mtime: Date) -> (status: Status, first: String, preview: String, question: Question?) {
        if let (m, v) = copilotCache[url], m == mtime { return v }
        let tail = Discovery.lines(url, tail: true)
        var first = copilotCache[url]?.1.first ?? ""
        if first.isEmpty {
            first = Discovery.lines(url, tail: false).lazy.compactMap { Discovery.json($0) }
                .first { $0["type"] as? String == "user.message" }
                .flatMap { ($0["data"] as? [String: Any])?["content"] as? String }.map(Discovery.clean) ?? ""
        }
        let preview = tail.reversed().lazy.filter { Discovery.eventType($0) == "assistant.message" }
            .compactMap { Discovery.json($0) }
            .compactMap { o -> String? in
                guard
                      let c = (o["data"] as? [String: Any])?["content"] as? String, !c.isEmpty else { return nil }
                return Discovery.clean(c)
            }.first ?? ""
        let v = (Discovery.copilotStatus(tail), first, preview, Discovery.copilotQuestion(tail))
        copilotCache[url] = (mtime, v)
        return v
    }

    static func claude(_ url: URL, mtime: Date) -> (first: String, preview: String) {
        if let (m, v) = claudeCache[url], m == mtime { return v }
        var first = claudeCache[url]?.1.first ?? ""
        if first.isEmpty {
            first = Discovery.lines(url, tail: false).lazy.compactMap { Discovery.json($0) }
                .compactMap { o -> String? in
                    guard o["type"] as? String == "user", o["isMeta"] as? Bool != true,
                          let t = Discovery.claudeText((o["message"] as? [String: Any])?["content"]),
                          !t.hasPrefix("<") else { return nil }
                    return Discovery.clean(t)
                }.first ?? ""
        }
        let preview = Discovery.lines(url, tail: true).reversed().lazy
            .filter { $0.contains(#""type":"assistant""#) }.compactMap { Discovery.json($0) }
            .compactMap { o -> String? in
                guard o["type"] as? String == "assistant",
                      let t = Discovery.claudeText((o["message"] as? [String: Any])?["content"]), !t.isEmpty else { return nil }
                return Discovery.clean(t)
            }.first ?? ""
        claudeCache[url] = (mtime, (first, preview))
        return (first, preview)
    }
}

// MARK: - Store

@MainActor @Observable
final class SessionStore {
    var sessions: [Session] = []
    var focusedTTY: String?
    var colors: [String: Int] = [:]
    var names: [String: Codename] = [:]
    /// Session that just finished / started waiting — the notch "peeks" it.
    var peek: Session?
    var theme = Palette.current { didSet { Palette.current = theme } }

    private let worker = DispatchQueue(label: "vule.scan")
    private var timer: Timer?
    private var pending = Set<String>()

    func start() {
        names = Codenamer.load()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    private var scanning = false
    private func tick() {
        guard !scanning else { return }
        scanning = true
        worker.async {
            let snap = Ghostty.snapshot()
            let found = Discovery.scan(terminals: snap.terminals)
            DispatchQueue.main.async { [weak self] in self?.apply(found, focused: snap.focusedTTY) }
        }
    }

    private func apply(_ found: [Session], focused: String?) {
        scanning = false
        let old = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for s in found where s.status.needsYou && (old[s.id].map { $0.status < .done } ?? false) && s.tty != focused {
            peek = s
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        if found != sessions { sessions = found }
        if focusedTTY != focused { focusedTTY = focused }
        let c = Palette.assign(found.map(\.id), existing: colors)
        if c != colors { colors = c }
        for s in found where names[s.id] == nil && !s.firstPrompt.isEmpty && !pending.contains(s.id) {
            pending.insert(s.id)
            Task {
                let n = await Codenamer.make(from: s.firstPrompt)
                names[s.id] = n
                pending.remove(s.id)
                Codenamer.save(names)
            }
        }
    }

    func hue(_ s: Session) -> Int { colors[s.id] ?? Palette.preferred(s.id) }
    func color(_ s: Session) -> Color { Palette.color(hue(s)) }
    /// The session's two-tone gradient pair.
    func glow(_ s: Session) -> (NSColor, NSColor) { (Palette.ns(hue(s)), Palette.ns(hue(s) + 1)) }

    func title(_ s: Session) -> String {
        s.userName ?? names[s.id]?.title ?? (s.firstPrompt.isEmpty ? URL(fileURLWithPath: s.cwd).lastPathComponent : String(s.firstPrompt.prefix(28)))
    }

    func emoji(_ s: Session) -> String { names[s.id]?.emoji ?? (s.agent == .claude ? "✳︎" : "◆") }

    var focused: Session? { sessions.first { $0.tty == focusedTTY } }
}
