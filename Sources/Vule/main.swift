import AppKit
import Carbon.HIToolbox
import SwiftUI

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }   // so the reply field can take typing without activating the app
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = SessionStore()
    let ui = NotchUI()
    var panel: NotchPanel!
    let burst = SignalBurst()
    private var lastStatus: [String: Status] = [:]
    private var lastFired: [String: Date] = [:]
    private var waitSince: [String: Date] = [:]
    private var seen: Set<String> = []   // waiting sessions you've already looked at: no more signal
    private var hoverSince: Date?
    private var outsideSince: Date?
    private static let size = NSSize(width: 720, height: 460)

    func applicationDidFinishLaunching(_ note: Notification) {
        panel = NotchPanel(contentRect: .init(origin: .zero, size: Self.size),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .init(Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.delegate = self
        let host = NSHostingView(rootView: NotchRoot().environment(store).environment(ui))
        host.sizingOptions = []   // fixed-size panel; letting SwiftUI drive window size causes a layout loop
        panel.contentView = host
        ui.onRelease = { [weak self] in self?.collapse() }
        place()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
        Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackMouse(); self?.updateSignal() }
        }
        HotKey.register { [weak self] in self?.toggleFromKeyboard() }
        if CommandLine.arguments.contains("--signal") {   // preview the burst
            var level = 0
            Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let s = self.store.sessions.first else { return }
                    self.burst.fire(s.id, from: self.dotPoint(0, of: self.store.sessions.count), colors: self.store.glow(s), strong: true, level: level % 4)
                    level += 1
                }
            }
        }
        if CommandLine.arguments.contains("--demo") {   // sample sessions, no scanning (`--demo peek` pops the question)
            Preview.sample(into: store)
            if CommandLine.arguments.contains("peek") { store.peek = store.sessions.first }
        } else {
            store.start()
        }
    }

    /// Center the panel under the screen that has the notch (or the main screen's menu bar).
    func place() {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let f = screen.frame
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            ui.notch = .init(width: f.width - l.width - r.width, height: screen.safeAreaInsets.top)
        } else {
            ui.notch = .init(width: 0, height: max(24, f.maxY - screen.visibleFrame.maxY))
        }
        panel.setFrame(.init(x: f.midX - Self.size.width / 2, y: f.maxY - Self.size.height,
                             width: Self.size.width, height: Self.size.height), display: true)
    }

    /// The panel is mostly transparent, so it only takes the mouse while the pointer is over the island.
    func trackMouse() {
        let p = NSEvent.mouseLocation, f = panel.frame, s = ui.shapeSize
        let island = NSRect(x: f.midX - s.width / 2, y: f.maxY - s.height, width: s.width, height: s.height).insetBy(dx: -4, dy: -4)
        let inside = island.contains(p)
        panel.ignoresMouseEvents = !inside

        if inside {
            outsideSince = nil
            hoverSince = hoverSince ?? Date()
            // Small dwell so sweeping toward the menu bar doesn't pop the island open.
            if !ui.expanded, !store.sessions.isEmpty, Date().timeIntervalSince(hoverSince!) > 0.18 { expand(focusField: false) }
        } else {
            hoverSince = nil
            outsideSince = outsideSince ?? Date()
            if ui.expanded, !ui.pinned, Date().timeIntervalSince(outsideSince!) > 0.35 { collapse() }
        }
    }

    /// Zion-style attention burst: rings shoot out of the session's dot when it starts asking you something
    /// (and again every 10s, bigger each time), a gentler ripple when it finishes. Once you look at it (its Ghostty tab, or its card
    /// in the island opened via ⌘⇧Space / reply box; plain hover doesn't count) it goes quiet until it asks again.
    func updateSignal() {
        let ghosttyFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.mitchellh.ghostty"
        let now = Date(), sessions = store.sessions
        for (i, s) in sessions.enumerated() {
            let was = lastStatus[s.id]
            lastStatus[s.id] = s.status
            if s.status != .waiting { waitSince[s.id] = nil; seen.remove(s.id) } else if waitSince[s.id] == nil { waitSince[s.id] = now }
            if (ghosttyFront && s.tty == store.focusedTTY) || (ui.expanded && ui.pinned && ui.selectedID == s.id) {
                if s.status == .waiting { seen.insert(s.id) }
                burst.stop(s.id)
                continue
            }
            let strong = s.status == .waiting && !seen.contains(s.id) && (was != .waiting || now.timeIntervalSince(lastFired[s.id] ?? .distantPast) >= 10)
            let gentle = s.status == .done && was == .busy
            guard strong || gentle, was != nil else { continue }
            lastFired[s.id] = now
            // Escalates each 10s repeat: level 0…3 (caps at 30s of ignoring it).
            let level = strong ? min(Int(now.timeIntervalSince(waitSince[s.id] ?? now) / 10), 3) : 0
            burst.fire(s.id, from: dotPoint(i, of: sessions.count), colors: store.glow(s), strong: strong, level: level)
        }
        lastStatus = lastStatus.filter { id, _ in sessions.contains { $0.id == id } }
        waitSince = waitSince.filter { id, _ in sessions.contains { $0.id == id } }
        seen = seen.filter { id in sessions.contains { $0.id == id } }
    }

    /// Screen position of the i-th dot in the collapsed row (mirrors TopRow's layout).
    func dotPoint(_ i: Int, of n: Int) -> CGPoint {
        let f = panel.frame
        return CGPoint(x: f.midX - ui.notch.width / 2 - 8 - 7 - CGFloat(n - 1 - i) * 21, y: f.maxY - ui.notch.height / 2)
    }

    func expand(focusField: Bool) {
        let s = store.sessions
        // Default target: whoever needs you (not the one you're already in), else where you're typing.
        ui.selectedID = store.peek?.id
            ?? s.filter { $0.status.needsYou && $0.tty != store.focusedTTY }.max { $0.status < $1.status }?.id
            ?? store.focused?.id ?? s.first?.id
        store.peek = nil
        ui.focusField = focusField
        ui.expanded = true
    }

    func collapse() {
        ui.expanded = false
        ui.pinned = false
        ui.focusField = false
        if panel.isKeyWindow {
            // Hand the keyboard back to whatever app (Ghostty) had it.
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }

    func toggleFromKeyboard() {
        if ui.expanded { collapse(); return }
        guard !store.sessions.isEmpty else { NSSound.beep(); return }
        expand(focusField: true)
        ui.pinned = true
        panel.makeKey()
    }

    func windowDidResignKey(_ notification: Notification) {
        if ui.expanded { collapse() }
    }
}

/// Shockwave rings on a click-through overlay per display: from the dot on the notch screen,
/// from the top centre on the others so you catch it wherever you are. Core Animation only.
@MainActor
final class SignalBurst {
    private var live: [String: [NSPanel]] = [:]

    /// Cut a session's burst short (you just looked at it).
    func stop(_ id: String) {
        live.removeValue(forKey: id)?.forEach { $0.close() }
    }

    func fire(_ id: String, from dot: CGPoint, colors: (NSColor, NSColor), strong: Bool, level: Int = 0) {
        let duration = strong ? 2.4 + Double(level) * 0.4 : 3.0
        stop(id)
        for screen in NSScreen.screens {
            let f = screen.frame
            let origin = f.contains(dot) ? dot : CGPoint(x: f.midX, y: f.maxY - 16)
            let w = NSPanel(contentRect: f, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false
            w.ignoresMouseEvents = true; w.isReleasedWhenClosed = false
            w.level = .init(Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)   // just under the notch island
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            w.setFrame(f, display: false)
            let v = NSView(frame: .init(origin: .zero, size: f.size)); v.wantsLayer = true
            w.contentView = v
            let c = CGPoint(x: origin.x - f.minX, y: origin.y - f.minY)
            let reach = f.width * (strong ? 0.25 + CGFloat(level) * 0.15 : 0.12)
            let (a, b) = strong ? (NSColor.systemOrange, colors.0) : colors
            for k in 0..<(strong ? 3 + level : 1) {
                Self.ring(in: v.layer!, at: c, reach: reach, a: a, b: b, delay: Double(k) * 0.28, duration: duration - 0.6)
            }
            Self.flash(in: v.layer!, at: c, reach: reach * 0.55, color: a, duration: duration * 0.5)
            w.orderFrontRegardless()
            live[id, default: []].append(w)
            DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.2) { [weak self] in
                w.close()
                self?.live[id]?.removeAll { $0 === w }
            }
        }
    }

    /// One ring: grows out with ease-out, thins, shifts hue a → b, and fades; glows via its own shadow.
    private static func ring(in root: CALayer, at c: CGPoint, reach: CGFloat, a: NSColor, b: NSColor, delay: Double, duration: Double) {
        let l = CAShapeLayer()
        l.frame = root.bounds
        l.fillColor = nil; l.strokeColor = a.cgColor; l.lineWidth = 1.5; l.opacity = 0
        l.shadowColor = a.cgColor; l.shadowRadius = 8; l.shadowOpacity = 1; l.shadowOffset = .zero
        func circle(_ r: CGFloat) -> CGPath { CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil) }
        let path = CABasicAnimation(keyPath: "path"); path.fromValue = circle(6); path.toValue = circle(reach)
        path.timingFunction = .init(controlPoints: 0.15, 0.7, 0.3, 1)
        let width = CABasicAnimation(keyPath: "lineWidth"); width.fromValue = 7; width.toValue = 1.2
        let fade = CAKeyframeAnimation(keyPath: "opacity"); fade.values = [0, 1, 0.8, 0]; fade.keyTimes = [0, 0.06, 0.45, 1]
        let hue = CABasicAnimation(keyPath: "strokeColor"); hue.fromValue = a.cgColor; hue.toValue = b.cgColor
        let glow = CABasicAnimation(keyPath: "shadowColor"); glow.fromValue = a.cgColor; glow.toValue = b.cgColor
        let g = CAAnimationGroup(); g.animations = [path, width, fade, hue, glow]
        g.duration = duration; g.beginTime = CACurrentMediaTime() + delay; g.fillMode = .both; g.isRemovedOnCompletion = false
        l.add(g, forKey: "ring")
        root.addSublayer(l)
    }

    /// Soft disc of light that blooms at the source and fades — the "flash" before the rings travel.
    private static func flash(in root: CALayer, at c: CGPoint, reach: CGFloat, color: NSColor, duration: Double) {
        let l = CAGradientLayer()
        l.type = .radial
        l.frame = CGRect(x: c.x - reach, y: c.y - reach, width: 2 * reach, height: 2 * reach)
        l.startPoint = .init(x: 0.5, y: 0.5); l.endPoint = .init(x: 1, y: 1)
        l.colors = [color.withAlphaComponent(0.45).cgColor, color.withAlphaComponent(0.12).cgColor, NSColor.clear.cgColor]
        l.opacity = 0
        let grow = CABasicAnimation(keyPath: "transform.scale"); grow.fromValue = 0.1; grow.toValue = 1
        grow.timingFunction = .init(name: .easeOut)
        let fade = CAKeyframeAnimation(keyPath: "opacity"); fade.values = [0, 1, 0]; fade.keyTimes = [0, 0.15, 1]
        let g = CAAnimationGroup(); g.animations = [grow, fade]; g.duration = duration; g.isRemovedOnCompletion = false; g.fillMode = .forwards
        l.add(g, forKey: "flash")
        root.addSublayer(l)
    }
}

/// ⌘⇧Space via Carbon — the one global-hotkey API that needs no Accessibility permission.
enum HotKey {
    nonisolated(unsafe) static var handler: (@MainActor () -> Void)?

    static func register(_ action: @escaping @MainActor () -> Void) {
        handler = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKey.handler?() } }
            return noErr
        }, 1, &spec, nil, nil)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(cmdKey | shiftKey), EventHotKeyID(signature: 0x56554C45, id: 1),
                            GetApplicationEventTarget(), 0, &ref)
    }
}

if let i = CommandLine.arguments.firstIndex(of: "--name"), i + 1 < CommandLine.arguments.count {
    let prompt = CommandLine.arguments[i + 1]
    Task { let n = await Codenamer.make(from: prompt); print("\(n.emoji) \(n.title)"); exit(0) }
    RunLoop.main.run()
}

if let i = CommandLine.arguments.firstIndex(of: "--render"), i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { Preview.render(to: CommandLine.arguments[i + 1]) }
    exit(0)
}

if CommandLine.arguments.contains("--list") {
    let snap = Ghostty.snapshot()
    print("ghostty terminals: \(snap.terminals.count), focused: \(snap.focusedTTY ?? "-")")
    for s in Discovery.scan(terminals: snap.terminals) {
        print("\(s.agent.rawValue)\t\(s.tty)\t\(s.status.label)\t\(s.id.prefix(8))\t\(s.firstPrompt.prefix(60))")
    }
    exit(0)
}

if CommandLine.arguments.contains("--selftest") {
    SelfTest.run()
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
