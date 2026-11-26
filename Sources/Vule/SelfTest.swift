import AppKit
import SwiftUI

/// `Vule --selftest` — the logic that silently breaks if a CLI changes its log format.
enum SelfTest {
    static func run() {
        func ev(_ type: String, _ data: String = "{}") -> Substring { Substring("{\"type\":\"\(type)\",\"data\":\(data)}") }
        let st = Discovery.copilotStatus

        // Copilot state machine
        check(st([ev("session.start")]) == .idle, "fresh session is idle")
        check(st([ev("user.message"), ev("assistant.turn_start"), ev("model.response")]) == .busy, "thinking is busy")
        check(st([ev("assistant.message", #"{"toolRequests":[{}]}"#), ev("tool.execution_start", #"{"toolName":"bash"}"#)]) == .busy, "tool run is busy")
        check(st([ev("assistant.message", #"{"toolRequests":[{}]}"#), ev("permission.requested")]) == .waiting, "permission prompt waits")
        check(st([ev("tool.execution_start", #"{"toolName":"ask_user"}"#), ev("session.usage_record")]) == .waiting, "ask_user waits")
        check(st([ev("user.message"), ev("assistant.message", #"{"content":"hi","toolRequests":[]}"#), ev("assistant.turn_end"), ev("session.usage_record")]) == .done, "final answer is done")
        check(st([ev("tool.execution_complete"), ev("assistant.turn_end")]) == .busy, "turn_end between tool steps stays busy")

        let ask = ev("tool.execution_start", #"{"toolName":"ask_user","arguments":{"message":"Pick **one**","requestedSchema":{"properties":{"c":{"type":"string","enum":["Red","Blue"]}}}}}"#)
        check(Discovery.copilotQuestion([ask]) == Question(text: "Pick one", options: ["Red", "Blue"]), "copilot ask_user options")
        check(Discovery.copilotQuestion([ask, ev("tool.execution_complete")]) == nil, "answered question disappears")
        check(Discovery.copilotQuestion([ev("permission.requested", #"{"permissionRequest":{"intention":"List dirs"}}"#)])?.options.count == 3, "copilot permission options")

        // Claude hook → state
        check(Discovery.claudeStatus(["event": "Stop"]) == .done, "claude stop")
        check(Discovery.claudeStatus(["event": "Notification", "notification_type": "permission_prompt"]) == .waiting, "claude permission")
        check(Discovery.claudeStatus(["event": "Notification", "notification_type": "idle_prompt"]) == .done, "claude idle prompt")
        check(Discovery.claudeStatus(["event": "PreToolUse", "tool_name": "AskUserQuestion"]) == .waiting, "claude question")
        check(Discovery.claudeQuestion(["event": "PreToolUse", "question": ["text": "Which DB?", "options": ["Postgres", "SQLite"]]])
              == Question(text: "Which DB?", options: ["Postgres", "SQLite"]), "claude question options")

        // Colours: stable, and unique while ≤ palette size
        let ids = (0..<8).map { "session-\($0)" }
        let a = Palette.assign(ids, existing: [:])
        check(Set(a.values).count == ids.count, "unique hues")
        check(Palette.assign(ids + ["new"], existing: a).filter { ids.contains($0.key) } == a, "existing hues never shift")

        // Ghostty + codename parsing
        let snap = Ghostty.parse("A\t/dev/ttys001\t/x\nB\t/dev/ttys002\t/y\nFOCUS\t/dev/ttys002")
        check(snap.terminals.count == 2 && snap.focusedTTY == "/dev/ttys002", "ghostty parse")
        check(Ghostty.escape(#"say "hi" \o/"#) == #"say \"hi\" \\o/"#, "applescript escape")
        check(Codenamer.parse("🔥 Payments Spike") == Codename(emoji: "🔥", title: "Payments Spike"), "codename parse")
        check(Codenamer.parse("Payments Spike") == nil, "codename needs emoji")

        check(Discovery.clean("# RDE\n## Part 1: **Foundations** `x`") == "RDE Part 1: Foundations x", "markdown stripped")

        print("selftest OK")
    }

    static func check(_ ok: Bool, _ what: String) {
        if !ok { print("FAIL: \(what)"); exit(1) }
    }
}

/// `Vule --render out.png` — draws collapsed / peek / expanded with sample sessions, for design iteration.
@MainActor
enum Preview {
    /// Sample sessions for `--render` and `--demo` (README screenshots without real work on screen).
    static func sample(into store: SessionStore) {
        func s(_ id: String, _ agent: Agent, _ tty: String, _ st: Status, _ preview: String) -> Session {
            Session(id: id, agent: agent, tty: tty, terminalID: id, cwd: "/x", status: st, firstPrompt: preview,
                    preview: preview, userName: nil, updated: .now)
        }
        var asking = s("a", .claude, "t1", .waiting, "")
        asking.question = Question(text: "Want me to run the migration against staging? It touches 3 tables.", options: ["Run on staging", "Dry-run first", "Skip it"])
        store.sessions = [
            asking,
            s("b", .copilot, "t2", .busy, "Reading payment-service logs between 02:55 and 03:10…"),
            s("c", .claude, "t3", .done, "Found 3 issues in the auth middleware: token refresh races on…"),
            s("d", .copilot, "t4", .idle, "Kafka consumers retry with exponential backoff capped at 30s."),
        ]
        store.names = ["a": .init(emoji: "🗄️", title: "Schema Migration"), "b": .init(emoji: "🔥", title: "Payments Spike"),
                       "c": .init(emoji: "🔍", title: "Auth PR Review"), "d": .init(emoji: "💬", title: "Kafka Retries")]
        store.colors = ["a": 0, "b": 2, "c": 1, "d": 5]
        store.focusedTTY = "t2"
    }

    static func render(to path: String) {
        let store = SessionStore()
        sample(into: store)

        func shot(_ configure: (NotchUI) -> Void, peek: Session? = nil) -> NSImage? {
            let ui = NotchUI()
            ui.notch = .init(width: 185, height: 32)
            configure(ui)
            store.peek = peek
            let view = ZStack(alignment: .top) {
                LinearGradient(colors: [Color(white: 0.22), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
                NotchRoot().environment(store).environment(ui)
            }.frame(width: 720, height: 440)
            let r = ImageRenderer(content: view)
            r.scale = 2
            return r.nsImage
        }
        let imgs = [shot { _ in }, shot({ _ in }, peek: store.sessions[2]),
                    shot { $0.expanded = true; $0.selectedID = "a"; $0.draft = "" }].compactMap { $0 }
        let out = NSImage(size: .init(width: 720, height: 440 * CGFloat(imgs.count)))
        out.lockFocus()
        for (i, img) in imgs.reversed().enumerated() { img.draw(in: .init(x: 0, y: CGFloat(i) * 440, width: 720, height: 440)) }
        out.unlockFocus()
        if let tiff = out.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
            print("rendered \(path)")
        }
    }
}
