import AppKit

/// Talks to Ghostty 1.4+ through its AppleScript dictionary (terminal id / tty / input text / send key).
/// All calls run on one serial queue: NSAppleScript is not thread-safe.
enum Ghostty {
    struct Terminal: Equatable { let id: String; let tty: String; let cwd: String }

    static let bundleID = "com.mitchellh.ghostty"
    private static let queue = DispatchQueue(label: "vule.ghostty")

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    // `tab` is a Ghostty class inside the tell block, so the separator is defined outside it.
    private static let listScript = NSAppleScript(source: """
        set sep to ASCII character 9
        tell application id "\(bundleID)"
            set out to ""
            repeat with t in terminals
                set out to out & (id of t) & sep & (tty of t) & sep & (working directory of t) & linefeed
            end repeat
            try
                set out to out & "FOCUS" & sep & (tty of focused terminal of selected tab of front window)
            end try
            return out
        end tell
        """)!

    /// Every live terminal plus the tty of the one you're typing into (front window's focused split).
    static func snapshot() -> (terminals: [Terminal], focusedTTY: String?) {
        guard isRunning else { return ([], nil) }
        return queue.sync {
            var err: NSDictionary?
            guard let out = listScript.executeAndReturnError(&err).stringValue else {
                NSLog("Vule: Ghostty snapshot failed: \(err ?? [:])")
                return ([], nil)
            }
            return parse(out)
        }
    }

    static func parse(_ out: String) -> (terminals: [Terminal], focusedTTY: String?) {
        var terms: [Terminal] = [], focus: String?
        for line in out.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if f.first == "FOCUS", f.count > 1 { focus = f[1] }
            else if f.count >= 3 { terms.append(.init(id: f[0], tty: f[1], cwd: f[2])) }
        }
        return (terms, focus)
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    @discardableResult
    private static func run(_ source: String) -> Bool {
        queue.sync {
            var err: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&err)
            if let err { NSLog("Vule AppleScript error: \(err)") }
            return err == nil
        }
    }

    private static func term(_ id: String) -> String { "terminal id \"\(escape(id))\"" }

    /// Paste text into a terminal and press Enter — without focusing it.
    static func send(_ text: String, to id: String) {
        DispatchQueue.global().async {
            run("tell application id \"\(bundleID)\" to input text \"\(escape(text))\" to \(term(id))")
            // Give the TUI a beat to ingest the bracketed paste before submitting.
            Thread.sleep(forTimeInterval: 0.15)
            run("tell application id \"\(bundleID)\" to send key \"enter\" to \(term(id))")
        }
    }

    /// Pick the i-th option of a TUI select list (Claude/Copilot questions & permission prompts): ↓ × i, then Enter.
    static func choose(_ i: Int, in id: String) {
        DispatchQueue.global().async {
            for _ in 0..<i {
                run("tell application id \"\(bundleID)\" to send key \"arrowDown\" to \(term(id))")
                // Copilot's TUI drops the selection if Enter lands before it re-renders; 50ms was too fast.
                Thread.sleep(forTimeInterval: 0.2)
            }
            run("tell application id \"\(bundleID)\" to send key \"enter\" to \(term(id))")
        }
    }

    static func pressEnter(_ id: String) {
        DispatchQueue.global().async { run("tell application id \"\(bundleID)\" to send key \"enter\" to \(term(id))") }
    }

    static func focus(_ id: String) {
        DispatchQueue.global().async {
            run("tell application id \"\(bundleID)\"\nfocus \(term(id))\nactivate\nend tell")
        }
    }
}
