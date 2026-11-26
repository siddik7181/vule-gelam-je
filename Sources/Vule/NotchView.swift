import SwiftUI

@MainActor @Observable
final class NotchUI {
    var notch = CGSize(width: 190, height: 32)
    var expanded = false
    var pinned = false        // opened by hotkey / typing — don't collapse on mouse-out
    var selectedID: String?
    var draft = ""
    var shapeSize: CGSize = .zero
    var shift: CGFloat = 0         // x offset that keeps the notch gap over the camera when the wings differ
    var cardsHeight: CGFloat = 0   // natural height of the session list; past 330pt it scrolls
    var focusField = false
    var onRelease: () -> Void = {}
}

// MARK: - Shape

/// Flush top with the small concave "ears" of the hardware notch, rounded bottom.
struct NotchShape: Shape {
    var ear: CGFloat
    var radius: CGFloat
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(ear, radius) }
        set { ear = newValue.first; radius = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let e = ear, b = min(radius, r.height / 2), w = r.width, h = r.height
        var p = Path()
        p.move(to: .zero)
        p.addQuadCurve(to: .init(x: e, y: e), control: .init(x: e, y: 0))
        p.addLine(to: .init(x: e, y: h - b))
        p.addQuadCurve(to: .init(x: e + b, y: h), control: .init(x: e, y: h))
        p.addLine(to: .init(x: w - e - b, y: h))
        p.addQuadCurve(to: .init(x: w - e, y: h - b), control: .init(x: w - e, y: h))
        p.addLine(to: .init(x: w - e, y: e))
        p.addQuadCurve(to: .init(x: w, y: 0), control: .init(x: w - e, y: 0))
        p.closeSubpath()
        return p
    }
}

// MARK: - Root

struct NotchRoot: View {
    @Environment(SessionStore.self) var store
    @Environment(NotchUI.self) var ui

    private let ear: CGFloat = 8
    private var spring: Animation { .spring(response: 0.42, dampingFraction: 0.82) }

    var body: some View {
        VStack(spacing: 0) {
            content
                .padding(.horizontal, ear)
                .background {
                    ZStack(alignment: .bottom) {
                        Color.black
                        if ui.expanded, let s = selected {
                            // The whole island picks up the target session's hue — you always know where Enter goes.
                            LinearGradient(colors: [store.color(s).opacity(0.22), .clear], startPoint: .bottom, endPoint: .top)
                                .frame(height: 160)
                        }
                    }
                    .clipShape(NotchShape(ear: ear, radius: ui.expanded || store.peek != nil ? 26 : 12))
                    .shadow(color: .black.opacity(ui.expanded ? 0.45 : 0), radius: 18, y: 8)
                }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { if ui.shapeSize != $0 { ui.shapeSize = $0 } }
                .offset(x: shift)
                .onChange(of: shift, initial: true) { ui.shift = shift }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(spring, value: ui.expanded)
        .animation(spring, value: store.peek?.id)
        .animation(spring, value: store.focusedTTY)
        .animation(spring, value: store.sessions.map(\.id))
        .preferredColorScheme(.dark)
        .id(store.theme)   // CA effects bake their colours in at creation
        .contextMenu {
            Picker("Theme", selection: Bindable(store).theme) {
                ForEach(Palette.names, id: \.self) { Text($0).tag($0) }
            }
            Divider()
            Button("Quit Vule") { NSApp.terminate(nil) }
        }
    }

    var shift: CGFloat {
        guard !ui.expanded, store.peek == nil, !store.sessions.isEmpty else { return 0 }
        let (l, r) = TopRow.wings(store)
        return (r - l) / 2
    }

    var selected: Session? {
        store.sessions.first { $0.id == ui.selectedID } ?? store.focused ?? store.sessions.first
    }

    @ViewBuilder var content: some View {
        if ui.expanded && !store.sessions.isEmpty {
            ExpandedView(selected: selected)
        } else if let p = store.peek, let live = store.sessions.first(where: { $0.id == p.id }) {
            VStack(spacing: 0) {
                TopRow(full: true)
                SessionCard(session: live, selected: true, compact: true)
                    .padding(.horizontal, 14).padding(.bottom, 12).padding(.top, 2)
            }
            .frame(width: ui.notch.width + 2 * 170)
            .transition(.blurReplace)
            .task(id: p.id) {
                try? await Task.sleep(for: .seconds(4.5))
                if store.peek?.id == p.id { store.peek = nil }
            }
        } else if store.sessions.isEmpty {
            Color.clear.frame(width: ui.notch.width, height: ui.notch.height)
        } else {
            TopRow()
        }
    }
}

// MARK: - Collapsed row: dots | notch | where-you're-typing

struct TopRow: View {
    @Environment(SessionStore.self) var store
    @Environment(NotchUI.self) var ui
    var full = false   // peek/expanded: centred row with the title. Collapsed, the title lives in the chin under the camera

    /// Each wing hugs its own content (dots left, title right when shown), capped so menu-bar items stay visible.
    static func wings(_ store: SessionStore, full: Bool = false) -> (CGFloat, CGFloat) {
        let n = CGFloat(store.sessions.count)
        let dots = full ? n * 14 + max(0, n - 1) * 7 + 16 : 14   // collapsed: dots live in the chin
        let title = store.focused.map { !full ? 14 : 8 + 18 + 6 + ceil((store.title($0) as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width) + 6 } ?? 0
        return (min(150, max(14, dots)), min(150, max(14, title)))
    }

    var body: some View {
        let wide = full
        let (l, r) = Self.wings(store, full: wide)
        let wing = max(l, r)
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                if wide { ForEach(store.sessions) { s in StatusDot(session: s, focused: s.tty == store.focusedTTY) } }
            }
            .padding(.trailing, 8)
            .frame(width: full ? wing : l, alignment: .trailing)

            Color.clear.frame(width: ui.notch.width)
                .overlay(alignment: .top) {
                    if !wide, !store.sessions.isEmpty { Chin().offset(y: ui.notch.height) }
                }

            ZStack(alignment: .leading) {
                Color.clear   // keeps the wing's width even when it's empty, so the notch gap stays over the camera
                if wide, let f = store.focused {
                    HStack(spacing: 6) {
                        Text(store.emoji(f)).font(.system(size: 12))
                        let (a, b) = store.glow(f)
                        // Hidden Text sizes the slot; the shimmer itself is a CA gradient masked by the glyphs.
                        Text(store.title(f))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .hidden()
                            .overlay { ShimmerText(text: store.title(f), a: a, b: b, period: f.status == .busy ? 1.1 : 2.0) }
                            .id("\(f.id)\(f.status == .busy)")
                    }
                    .id(f.id)
                    .transition(.blurReplace)
                }
            }
            .padding(.leading, 8)
            .frame(width: full ? wing : r, alignment: .leading)
            .clipped()
        }
        .frame(height: ui.notch.height)
    }
}

/// Session dots + the focused session's codename, hanging just below the camera like a drip off the island.
struct Chin: View {
    @Environment(SessionStore.self) var store

    static let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
    static let maxWidth: CGFloat = 380

    /// (whole strip width, title slot width) — shared with the signal code so rings start from the right dot.
    static func layout(_ store: SessionStore) -> (CGFloat, CGFloat) {
        let n = CGFloat(store.sessions.count)
        let dots = n * 14 + max(0, n - 1) * 7
        guard let f = store.focused else { return (dots + 20, 0) }
        let room = maxWidth - 20 - dots - 8 - 18   // padding, dots, gap, emoji
        let title = max(0, min(room, ceil((store.title(f) as NSString).size(withAttributes: [.font: font]).width)))
        return (20 + dots + 8 + 18 + title, title)
    }

    var body: some View {
        let (_, tw) = Self.layout(store)
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                ForEach(store.sessions) { s in StatusDot(session: s, focused: s.tty == store.focusedTTY) }
            }
            if let f = store.focused {
                let (a, b) = store.glow(f), t = store.title(f)
                HStack(spacing: 4) {
                    Text(store.emoji(f)).font(.system(size: 10)).frame(width: 14)
                    ShimmerText(text: t, a: a, b: b, size: 11, period: f.status == .busy ? 1.1 : 2.0)
                        .frame(width: tw, height: 14)
                        .id("\(f.id)\(f.status == .busy)")
                }
                .frame(height: 20)
                .overlay(alignment: .bottom) {
                    // Progress line under the title while the session works.
                    if f.status == .busy { Glow(kind: .stream, a: a, b: b).frame(height: 2).offset(y: 1).transition(.opacity) }
                }
                .id(f.id)
                .transition(.blurReplace)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 20)
        .padding(.bottom, 3)
        .fixedSize()
        .background(UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10).fill(.black))
    }
}

struct StatusDot: View {
    @Environment(SessionStore.self) var store
    let session: Session
    let focused: Bool

    var body: some View {
        let c = store.color(session), (a, b) = store.glow(session)
        let core = Circle().fill(c).frame(width: focused ? 7 : 5, height: focused ? 7 : 5)
            .shadow(color: c.opacity(focused ? 1 : 0.6), radius: focused ? 5 : 3)
        // Effects are CALayer animations: the render server drives them, so the app spends ~0 CPU per frame
        // (a SwiftUI phaseAnimator re-ran layout every frame, ~4% CPU per animating dot).
        ZStack {
            switch session.status {
            case .busy:    Glow(kind: .signal, period: 2.4, a: a, b: b); Glow(kind: .comet, a: a, b: b); core
            case .waiting: Glow(kind: .signal, period: 1.2, a: .systemOrange, b: .systemYellow); core
            case .done:    Circle().stroke(c.opacity(0.8), lineWidth: 1); core
            case .idle:    core.opacity(0.45)
            }
        }
        .frame(width: 14, height: 14)
        .help("\(store.title(session)) — \(session.status.label)")
    }
}

// MARK: - Expanded

struct ExpandedView: View {
    @Environment(SessionStore.self) var store
    @Environment(NotchUI.self) var ui
    let selected: Session?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        @Bindable var ui = ui
        VStack(spacing: 10) {
            TopRow(full: true)
            if ui.cardsHeight <= 330 { cards } else { ScrollView { cards }.scrollIndicators(.never).frame(height: 330) }

            if let s = selected { replyBar(s, draft: $ui.draft) }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .frame(width: max(520, ui.notch.width + 300))
        .transition(.blurReplace)
        .onAppear { fieldFocused = ui.focusField }
        .onChange(of: ui.focusField) { _, v in fieldFocused = v }
        .onChange(of: fieldFocused) { _, v in if v { ui.pinned = true } }
    }

    var cards: some View {
        VStack(spacing: 6) {
            ForEach(store.sessions) { s in
                SessionCard(session: s, selected: s.id == selected?.id, compact: false)
                    .onTapGesture(count: 2) { Ghostty.focus(s.terminalID) }
                    .onTapGesture { ui.selectedID = s.id; fieldFocused = true }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
            if abs(ui.cardsHeight - h) > 0.5 { ui.cardsHeight = h }
        }
    }

    func replyBar(_ s: Session, draft: Binding<String>) -> some View {
        let c = store.color(s)
        return HStack(spacing: 10) {
            Text(store.emoji(s)).font(.system(size: 13))
            TextField("Reply to \(store.title(s))…", text: draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .rounded))
                .focused($fieldFocused)
                .onSubmit { send(s) }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.escape) { ui.onRelease(); return .handled }
            if s.status == .waiting && s.question == nil && ui.draft.isEmpty {
                pill("Allow ↵", c) { Ghostty.pressEnter(s.terminalID) }
            }
            pill("Open ↗", c) { Ghostty.focus(s.terminalID); ui.onRelease() }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(c.opacity(0.10), in: .capsule)
        .overlay(Capsule().strokeBorder(c.opacity(0.45), lineWidth: 1))
    }

    func pill(_ t: String, _ c: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(.system(size: 11, weight: .semibold, design: .rounded))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(c.opacity(0.2), in: .capsule)
                .foregroundStyle(c)
        }.buttonStyle(.plain)
    }

    func send(_ s: Session) {
        let text = ui.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Ghostty.send(text, to: s.terminalID)
        ui.draft = ""
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }

    func move(_ d: Int) {
        let list = store.sessions
        guard !list.isEmpty else { return }
        let i = list.firstIndex { $0.id == selected?.id } ?? 0
        ui.selectedID = list[(i + d + list.count) % list.count].id
    }
}

struct SessionCard: View {
    @Environment(SessionStore.self) var store
    let session: Session
    let selected: Bool
    let compact: Bool

    var body: some View {
        let c = store.color(session)
        let here = session.tty == store.focusedTTY
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(LinearGradient(colors: [c, Color(nsColor: store.glow(session).1)], startPoint: .top, endPoint: .bottom)).frame(width: 3).padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(store.emoji(session)).font(.system(size: 13))
                    Text(store.title(session))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if here {
                        Text("typing here")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(c.opacity(0.25), in: .capsule)
                            .foregroundStyle(c)
                    }
                    Spacer(minLength: 6)
                    StatusChip(status: session.status, agent: session.agent)
                }
                if let q = session.question {
                    QuestionView(question: q, color: c, terminalID: session.terminalID)
                } else if !session.preview.isEmpty || !compact {
                    Text(session.preview.isEmpty ? session.firstPrompt : session.preview)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(compact ? 1 : 2)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14).fill(selected ? c.opacity(0.13) : .white.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? c.opacity(0.35) : .clear, lineWidth: 1))
        .contentShape(.rect)
    }
}

/// The pending question with its options as tappable rows — tapping answers it in the terminal.
struct QuestionView: View {
    let question: Question
    let color: Color
    let terminalID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !question.text.isEmpty {
                Text(question.text)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
            }
            ForEach(Array(question.options.enumerated()), id: \.offset) { i, o in
                Button { Ghostty.choose(i, in: terminalID) } label: {
                    HStack(spacing: 7) {
                        Text("\(i + 1)")
                            .font(.system(size: 9.5, weight: .bold, design: .rounded))
                            .frame(width: 16, height: 16)
                            .background(color.opacity(0.25), in: .circle)
                            .foregroundStyle(color)
                        Text(o).font(.system(size: 11.5, design: .rounded)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.white.opacity(0.05), in: .rect(cornerRadius: 8))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct StatusChip: View {
    let status: Status
    let agent: Agent

    var body: some View {
        let tint: Color = switch status {
        case .waiting: .orange
        case .done: .green
        case .busy: .cyan
        case .idle: .gray
        }
        HStack(spacing: 5) {
            Text(agent.rawValue).foregroundStyle(.white.opacity(0.35))
            Circle().fill(tint).frame(width: 5, height: 5)
            Text(status.label).foregroundStyle(tint)
        }
        .font(.system(size: 10, weight: .medium, design: .rounded))
    }
}

/// Looping Core Animation effects hosted in SwiftUI.
struct Glow: NSViewRepresentable {
    enum Kind { case comet, signal, stream }
    let kind: Kind
    var period = 1.8
    let a: NSColor
    let b: NSColor

    final class View: NSView {
        var kind = Kind.comet
        let grad = CAGradientLayer(), ring = CAShapeLayer(), clip = CALayer(), rep = CAReplicatorLayer()
        private var slidWidth: CGFloat = 0

        override func layout() {
            super.layout()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            let r = bounds
            switch kind {
            case .comet:
                grad.frame = r
                ring.frame = r
                ring.path = CGPath(ellipseIn: r.insetBy(dx: 1, dy: 1), transform: nil)
            case .signal:
                rep.frame = r
                ring.frame = r
                ring.path = CGPath(ellipseIn: r.insetBy(dx: 1, dy: 1), transform: nil)
            case .stream:
                // Two periods wide, slid by one period per loop → seamless flow.
                clip.frame = r
                grad.frame = CGRect(x: -r.width, y: 0, width: r.width * 2, height: r.height)
                ring.frame = r
                ring.path = CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil)
                if r.width != slidWidth, r.width > 0 {
                    slidWidth = r.width
                    let x = CABasicAnimation(keyPath: "transform.translation.x")
                    x.fromValue = 0; x.toValue = r.width; x.duration = 1.6
                    x.repeatCount = .infinity; x.isRemovedOnCompletion = false
                    grad.add(x, forKey: "flow")
                }
            }
            CATransaction.commit()
        }
    }

    func makeNSView(context: Context) -> View {
        let v = View(); v.kind = kind; v.wantsLayer = true
        let root = v.layer!, g = v.grad, ring = v.ring, period = period
        root.masksToBounds = false
        func loop(_ key: String, _ from: Any, _ to: Any, _ d: Double, reverse: Bool = false, linear: Bool = false) -> CABasicAnimation {
            let x = CABasicAnimation(keyPath: key)
            x.fromValue = from; x.toValue = to; x.duration = d
            x.autoreverses = reverse; x.repeatCount = .infinity; x.isRemovedOnCompletion = false
            x.timingFunction = .init(name: linear ? .linear : .easeInEaseOut)
            return x
        }
        switch kind {
        case .comet:
            // Conic gradient spun behind a ring mask: a bright head chasing a fading tail.
            g.type = .conic
            g.startPoint = .init(x: 0.5, y: 0.5); g.endPoint = .init(x: 0.5, y: 0)
            g.colors = [NSColor.clear.cgColor, b.withAlphaComponent(0.5).cgColor, a.cgColor, NSColor.white.cgColor]
            ring.fillColor = nil; ring.strokeColor = NSColor.black.cgColor; ring.lineWidth = 1.6
            g.mask = ring
            root.addSublayer(g)
            root.shadowColor = a.cgColor; root.shadowRadius = 3; root.shadowOpacity = 0.9; root.shadowOffset = .zero
            g.add(loop("transform.rotation.z", 0, -2 * Double.pi, 1.1, linear: true), forKey: "spin")
        case .signal:
            // Beacon: rings radiate out of the dot and fade, staggered by a replicator like a radio signal.
            ring.fillColor = nil; ring.strokeColor = a.cgColor; ring.lineWidth = 1.2
            ring.opacity = 0
            let wave = CAAnimationGroup()
            let grow = CABasicAnimation(keyPath: "transform.scale"); grow.fromValue = 0.4; grow.toValue = 2.1
            grow.timingFunction = .init(name: .easeOut)
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 1; fade.toValue = 0
            let tint = CABasicAnimation(keyPath: "strokeColor"); tint.fromValue = a.cgColor; tint.toValue = b.cgColor
            wave.animations = [grow, fade, tint]
            wave.duration = period; wave.repeatCount = .infinity; wave.isRemovedOnCompletion = false
            ring.add(wave, forKey: "wave")
            v.rep.instanceCount = 3
            v.rep.instanceDelay = period / 3
            v.rep.addSublayer(ring)
            root.addSublayer(v.rep)
            root.shadowColor = a.cgColor; root.shadowRadius = 4; root.shadowOpacity = 1; root.shadowOffset = .zero
        case .stream:
            g.startPoint = .init(x: 0, y: 0.5); g.endPoint = .init(x: 1, y: 0.5)
            let w = NSColor.white.withAlphaComponent(0.95).cgColor
            g.colors = [a.cgColor, b.cgColor, w, a.cgColor, b.cgColor, w, a.cgColor]
            ring.fillColor = NSColor.black.cgColor
            v.clip.mask = ring; v.clip.addSublayer(g)
            root.addSublayer(v.clip)
            root.shadowColor = a.cgColor; root.shadowRadius = 6; root.shadowOpacity = 1; root.shadowOffset = .zero
        }
        return v
    }

    func updateNSView(_ v: View, context: Context) {}
}

/// Text filled with a gradient that streams left → right (render-server driven, ~0 app CPU).
struct ShimmerText: NSViewRepresentable {
    let text: String
    let a: NSColor
    let b: NSColor
    var size: CGFloat = 12
    let period: Double

    final class View: NSView {
        let grad = CAGradientLayer(), glyphs = CATextLayer(), box = CALayer()
        var period = 3.0
        private var flowWidth: CGFloat = 0
        override var isFlipped: Bool { true }

        override func layout() {
            super.layout()
            let r = bounds
            CATransaction.begin(); CATransaction.setDisableActions(true)
            box.frame = r
            glyphs.frame = r
            glyphs.contentsScale = window?.backingScaleFactor ?? 2
            grad.frame = CGRect(x: -r.width * 2, y: 0, width: r.width * 3, height: r.height)
            CATransaction.commit()
            if r.width > 0, r.width != flowWidth {
                flowWidth = r.width
                let x = CABasicAnimation(keyPath: "transform.translation.x")
                x.fromValue = 0; x.toValue = r.width; x.duration = period
                x.repeatCount = .infinity; x.isRemovedOnCompletion = false
                grad.add(x, forKey: "flow")
            }
        }
    }

    func makeNSView(context: Context) -> View {
        let v = View(); v.wantsLayer = true; v.period = period
        let g = v.grad, t = v.glyphs, box = v.box
        // Dimmed session hue with a sharp white-hot band; three repeats so a one-width slide loops seamlessly.
        let lo = a.blended(withFraction: 0.35, of: .black)!.cgColor, mid = b.cgColor, hot = NSColor.white.cgColor
        let band: [CGColor] = [lo, lo, mid, hot, mid, lo]
        let stops: [Double] = [0, 0.3, 0.42, 0.5, 0.58, 1]
        g.colors = band + band + band
        g.locations = (0..<3).flatMap { k in stops.map { NSNumber(value: (Double(k) + $0) / 3) } }
        g.startPoint = .init(x: 0, y: 0.5); g.endPoint = .init(x: 1, y: 0.5)
        let base = NSFont.systemFont(ofSize: size, weight: .semibold)
        t.font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        t.fontSize = size
        t.string = text
        t.foregroundColor = NSColor.black.cgColor
        t.truncationMode = .end
        box.mask = t
        box.addSublayer(g)
        v.layer!.addSublayer(box)
        // Shadow of the masked glyphs = a neon glow in the session hue.
        v.layer!.shadowColor = a.cgColor; v.layer!.shadowRadius = 5; v.layer!.shadowOpacity = 0.85; v.layer!.shadowOffset = .zero
        return v
    }

    func updateNSView(_ v: View, context: Context) {
        if (v.glyphs.string as? String) != text { v.glyphs.string = text }
    }
}
