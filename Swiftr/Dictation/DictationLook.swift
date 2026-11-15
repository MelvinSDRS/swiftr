import AppKit
import SwiftUI

// The look of a dictation: bars that follow the voice, and a line of light
// around what the text goes into. Core Animation draws both from the
// levels the microphone hears, so a conversation under them isn't drawn
// again for each (see WorkingRow).

/// The voice's loudness as it comes, for the views that draw it. Not
/// watched by SwiftUI, which would go over the whole conversation each
/// tenth of a second.
@MainActor
final class VoiceMeter {
    /// The meter's unit: the loudness of a fiftieth of a second.
    nonisolated static let moment: CFTimeInterval = 1.0 / 50

    /// When the person started speaking.
    private(set) var started = Date()
    /// The last seconds heard: when each fiftieth of a second ended, on
    /// Core Animation's clock, and how loud it was.
    private var heard: [(end: CFTimeInterval, level: CGFloat)] = []
    private var listeners: [ObjectIdentifier: (CGFloat) -> Void] = [:]

    func restart() {
        started = Date()
        heard = []
    }

    /// Fiftieths of a second heard, the last ending at `end`: the
    /// microphone gives them a tenth of a second at a time.
    func push(_ levels: [Float], endingAt end: CFTimeInterval) {
        guard !levels.isEmpty else { return }
        for (i, level) in levels.enumerated() {
            heard.append((end - Double(levels.count - 1 - i) * Self.moment, CGFloat(level)))
        }
        if let kept = heard.firstIndex(where: { $0.end > end - 5 }), kept > 0 {
            heard.removeFirst(kept)
        }
        let loudness = CGFloat(levels.reduce(0, +) / Float(levels.count))
        for hear in listeners.values { hear(loudness) }
    }

    /// How loud the voice was from `start` to `end`: 0 where nothing was
    /// heard.
    func level(from start: CFTimeInterval, to end: CFTimeInterval) -> CGFloat {
        var sum: CGFloat = 0
        var count = 0
        for moment in heard.reversed() {
            if moment.end <= start { break }
            if moment.end <= end {
                sum += moment.level
                count += 1
            }
        }
        return count > 0 ? sum / CGFloat(count) : 0
    }

    func listen(_ owner: AnyObject, _ hear: @escaping (CGFloat) -> Void) {
        listeners[ObjectIdentifier(owner)] = hear
    }

    func stopListening(_ owner: AnyObject) {
        listeners[ObjectIdentifier(owner)] = nil
    }

    /// A level that sounds like someone speaking, `t` seconds in: words,
    /// syllables two or three a second, and a breath now and then. For
    /// pictures and tests.
    nonisolated static func speechLike(_ t: Double) -> CGFloat {
        let word = 0.6 + 0.4 * abs(sin(t * 1.3)) * (0.6 + 0.4 * sin(t * 0.7 + 1.2))
        let syllables = abs(sin(t * 7.5)) * 0.65 + abs(sin(t * 11.0 + 0.6)) * 0.35
        let pause = (t.truncatingRemainder(dividingBy: 4.2) > 3.7) ? 0.08 : 1.0
        return CGFloat(max(0.05, min(1, (0.3 + 0.7 * word * syllables) * pause)))
    }
}

/// The voice's colors: the accent and two neighbors on the color wheel, so
/// any theme's accent gives a soft gradient of its own.
enum VoiceInk {
    static func colors(_ accent: Color, in environment: EnvironmentValues) -> [CGColor] {
        let resolved = NSColor(cgColor: accent.resolve(in: environment).cgColor)?.usingColorSpace(.deviceRGB) ?? .systemBlue
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        resolved.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        func shade(_ turn: CGFloat, _ more: CGFloat, _ light: CGFloat) -> CGColor {
            NSColor(hue: (hue + turn + 1).truncatingRemainder(dividingBy: 1),
                    saturation: min(1, max(0, saturation + more)),
                    brightness: min(1, max(0, brightness + light)), alpha: 1).cgColor
        }
        return [shade(-0.08, 0.06, -0.04), shade(0, 0, 0), shade(0.09, -0.04, 0.08)]
    }
}

// MARK: Bars

/// The voice as thin bars that come in on the right and move left, fading
/// as they go; the time spoken at the end. While the text is written, the
/// bars stop, sink, and a light goes over them.
final class VoiceWaveView: NSView {
    enum Source: Equatable {
        /// What Dictation hears.
        case microphone
        /// A voice made up, for Settings' picture.
        case demo
    }

    enum Phase: Equatable {
        case listening
        case writing
    }

    static let barWidth: CGFloat = 2.5
    static let gap: CGFloat = 2
    /// A bar comes in every twelfth of a second, and they all move left a
    /// bar's width in that time: smoothly, at a calm pace.
    static let period: CFTimeInterval = 1.0 / 12
    /// The bars show the voice this late: macOS gives the microphone's
    /// sound a tenth of a second at a time, and the bars move on between.
    static let delay: CFTimeInterval = 0.18
    /// Bars are made this far ahead, out of sight on the right, so they
    /// keep coming while the main thread is busy a moment.
    private static let ahead: CFTimeInterval = 0.5
    private var step: CGFloat { Self.barWidth + Self.gap }

    /// Holds the colors, cut to the bars' shape.
    private let body = CALayer()
    private let ink = CAGradientLayer()
    private let light = CAGradientLayer()
    private let bars = CAShapeLayer()
    private let clock = CATextLayer()

    /// The bars' levels, 0 to 1, the newest last. Bar `newest` comes in at
    /// `newest` periods on Core Animation's clock, the one before it a
    /// period earlier.
    private var levels: [CGFloat] = []
    private var newest = 0
    /// How far left of their place the bars stopped, while the text is
    /// written.
    private var stoppedAt: CGFloat?
    private var source: Source = .microphone
    private var phase: Phase = .listening
    private var colors: [CGColor] = []
    private var clockFont: CGFloat?
    private var started = Date()
    private var shownSeconds = -1
    private var ticker: Timer?
    private var demoStart: CFTimeInterval = 0
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        ink.startPoint = CGPoint(x: 0, y: 0.5)
        ink.endPoint = CGPoint(x: 1, y: 0.5)
        light.startPoint = CGPoint(x: 0, y: 0.5)
        light.endPoint = CGPoint(x: 1, y: 0.5)
        light.opacity = 0
        bars.fillColor = .white
        body.mask = bars
        body.addSublayer(ink)
        body.addSublayer(light)
        layer?.addSublayer(body)
        clock.alignmentMode = .right
        clock.isHidden = true
        layer?.addSublayer(clock)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(source: Source, phase: Phase, colors: [CGColor], clockFont: CGFloat?, clockColor: CGColor, started: Date) {
        // The microphone's bars start over with each dictation; the made-up
        // voice goes on.
        let startOver = source != self.source || (source == .microphone && started != self.started)
        let phaseChanged = phase != self.phase
        self.source = source
        self.started = started
        self.clockFont = clockFont
        self.phase = phase
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if colors != self.colors {
            self.colors = colors
            let clear = colors.first?.copy(alpha: 0) ?? .clear
            ink.colors = [clear, colors[0].copy(alpha: 0.55) ?? colors[0], colors[1], colors[2]]
            ink.locations = [0, 0.3, 0.75, 1]
            let white = CGColor(gray: 1, alpha: 0.9)
            light.colors = [white.copy(alpha: 0) ?? white, white, white.copy(alpha: 0) ?? white]
        }
        if let clockFont {
            clock.isHidden = false
            clock.font = NSFont.monospacedDigitSystemFont(ofSize: clockFont, weight: .medium)
            clock.fontSize = clockFont
            clock.foregroundColor = clockColor
        } else {
            clock.isHidden = true
        }
        CATransaction.commit()
        if startOver { listen() }
        if phaseChanged { self.phaseChanged() }
        tickClock()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let scale = window?.backingScaleFactor ?? 2
        clock.contentsScale = scale
        let clockWidth = clockFont.map { $0 * 2.6 } ?? 0
        let lineHeight = (clockFont ?? 0) * 1.25
        clock.frame = CGRect(x: bounds.maxX - clockWidth, y: bounds.midY - lineHeight / 2, width: clockWidth, height: lineHeight)
        var area = bounds
        area.size.width -= clockWidth > 0 ? clockWidth + 8 : 0
        body.frame = area
        ink.frame = body.bounds
        light.frame = body.bounds
        bars.bounds = body.bounds
        bars.position.y = body.bounds.midY
        if let stoppedAt { bars.position.x = body.bounds.midX + stoppedAt }
        CATransaction.commit()
        if phase == .listening {
            catchUp()
        } else {
            drawBars()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        listen()
        if window != nil { phaseChanged() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    /// Hears the microphone, or makes a voice up, while in a window: the
    /// bars start over.
    private func listen() {
        Dictation.shared.meter.stopListening(self)
        ticker?.invalidate()
        ticker = nil
        levels = []
        stoppedAt = nil
        guard window != nil else { return }
        #if DEBUG
        Self.debugLive.add(self)
        #endif
        switch source {
        case .microphone:
            Dictation.shared.meter.listen(self) { [weak self] _ in self?.catchUp() }
        case .demo:
            // Already speaking when it shows.
            demoStart = CACurrentMediaTime() - 3
        }
        // Bars come in while nothing is heard too, a line of dots; and the
        // made-up voice comes from here.
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.catchUp() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
        catchUp()
    }

    /// Makes the bars whose time has come or soon will, and sets them
    /// moving left from now on: Core Animation moves them between two
    /// calls, a tenth of a second apart while the microphone gives sound.
    private func catchUp() {
        let area = body.bounds
        guard phase == .listening, window != nil, area.width > 0 else { return }
        let now = CACurrentMediaTime()
        let inSight = Int((now / Self.period).rounded(.down))
        let last = Int(((now + Self.ahead) / Self.period).rounded(.down))
        let oldest = inSight - Int((area.width / step).rounded(.up)) - 2
        var first = newest - levels.count + 1
        if levels.isEmpty || newest < oldest || first > inSight {
            levels = []
            first = oldest
        }
        // Gone on the left.
        if first < oldest {
            levels.removeFirst(min(levels.count, oldest - first))
            first = oldest
        }
        // Not in sight yet: made again, with what was heard since.
        levels.removeLast(max(0, levels.count - (inSight - first + 1)))
        newest = first + levels.count - 1
        while newest < last {
            newest += 1
            let level = level(ofBar: newest)
            levels.append((levels.last ?? level) * 0.35 + level * 0.65)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        drawBars()
        scroll(from: now)
        CATransaction.commit()
        tickClock()
    }

    /// How loud bar `k` stands: the voice in the period before it comes in,
    /// `delay` earlier.
    private func level(ofBar k: Int) -> CGFloat {
        let end = Double(k) * Self.period - Self.delay
        switch source {
        case .microphone:
            return Dictation.shared.meter.level(from: end - Self.period, to: end)
        case .demo:
            return VoiceMeter.speechLike(end - demoStart)
        }
    }

    private func drawBars() {
        let area = body.bounds
        guard area.width > 0, area.height > 0 else { return }
        let path = CGMutablePath()
        let first = newest - levels.count + 1
        for (i, level) in levels.enumerated() {
            let k = first + i
            // Before the first word: dots, a line waiting for the voice. A bar
            // a little taller or shorter than the next: a voice, not a curve.
            let height = max(Self.barWidth, area.height * min(1, pow(max(0, level - 0.06) / 0.8, 1.35)) * Self.grain(k))
            // Bar `newest` just right of the area: `scroll` brings them in.
            let x = area.maxX - CGFloat(newest - k) * step
            path.addRoundedRect(in: CGRect(x: x, y: area.midY - height / 2, width: Self.barWidth, height: height),
                                cornerWidth: Self.barWidth / 2, cornerHeight: Self.barWidth / 2)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bars.path = path
        CATransaction.commit()
    }

    /// Between 0.9 and 1, the same each time bar `k` is drawn.
    private static func grain(_ k: Int) -> CGFloat {
        var x = UInt64(bitPattern: Int64(k)) &* 0x9E37_79B9_7F4A_7C15
        x ^= x >> 29
        return 0.9 + 0.1 * CGFloat(x & 0xFFFF) / 0xFFFF
    }

    /// Moves the bars left a bar's width each period, from `now` until the
    /// last one made is in.
    private func scroll(from now: CFTimeInterval) {
        let rest = body.bounds.midX
        let anchor = Double(newest) * Self.period
        let step = step
        func place(_ t: CFTimeInterval) -> CGFloat { rest - CGFloat((t - anchor) / Self.period) * step }
        guard !reduceMotion else {
            bars.removeAnimation(forKey: "scroll")
            bars.position.x = place(now)
            return
        }
        let end = max(anchor, now) + Self.period
        let move = CABasicAnimation(keyPath: "position.x")
        move.fromValue = place(now)
        move.toValue = place(end)
        move.beginTime = bars.convertTime(now, from: nil)
        move.duration = end - now
        move.fillMode = .forwards
        move.isRemovedOnCompletion = false
        bars.position.x = place(end)
        bars.add(move, forKey: "scroll")
    }

    private func tickClock() {
        guard clockFont != nil, phase == .listening else { return }
        let seconds = max(0, Int(Date().timeIntervalSince(started)))
        guard seconds != shownSeconds else { return }
        shownSeconds = seconds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clock.string = String(format: "%d:%02d", seconds / 60, seconds % 60)
        CATransaction.commit()
    }

    /// Writing: the bars stop, sink, and a light goes over them, over and
    /// over.
    private func phaseChanged() {
        guard window != nil else { return }
        bars.removeAnimation(forKey: "sink")
        light.removeAnimation(forKey: "light")
        switch phase {
        case .listening:
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            light.opacity = 0
            bars.transform = CATransform3DIdentity
            CATransaction.commit()
            stoppedAt = nil
            catchUp()
        case .writing:
            let sink = CABasicAnimation(keyPath: "transform.scale.y")
            sink.fromValue = 1
            sink.toValue = 0.4
            sink.duration = 0.5
            sink.timingFunction = CAMediaTimingFunction(name: .easeOut)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // Where Core Animation has them now.
            let x = bars.presentation()?.position.x ?? bars.position.x
            bars.removeAnimation(forKey: "scroll")
            bars.position.x = x
            stoppedAt = x - body.bounds.midX
            bars.transform = CATransform3DMakeScale(1, 0.4, 1)
            light.opacity = reduceMotion ? 0 : 1
            CATransaction.commit()
            bars.add(sink, forKey: "sink")
            guard !reduceMotion else { return }
            let pass = CABasicAnimation(keyPath: "locations")
            pass.fromValue = [-0.4, -0.2, 0]
            pass.toValue = [1, 1.2, 1.4]
            pass.duration = 1.1
            pass.repeatCount = .infinity
            pass.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            light.locations = [-0.4, -0.2, 0]
            light.add(pass, forKey: "light")
        }
    }

    override func removeFromSuperview() {
        Dictation.shared.meter.stopListening(self)
        ticker?.invalidate()
        ticker = nil
        super.removeFromSuperview()
    }

    /// Nothing here to click.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

#if DEBUG
extension VoiceWaveView {
    /// The bars drawing now, for `dictation-probe`.
    static let debugLive = NSHashTable<VoiceWaveView>.weakObjects()

    /// Where bar 0 stands on screen, as Core Animation has it now: it
    /// moves left a bar's width each period, smoothly if all goes well.
    var debugPlace: Double {
        let x = bars.presentation()?.position.x ?? bars.position.x
        return Double(x - body.bounds.midX) + Double(body.bounds.maxX) - Double(newest) * Double(step)
    }

    /// Writes where the bars stand, 240 times a second for `seconds`, to
    /// `url`: [[time, place], …] for each view drawing.
    static func debugProbe(seconds: Double, to url: URL) {
        let views = debugLive.allObjects.filter { $0.window != nil }
        nonisolated(unsafe) var samples: [[[Double]]] = views.map { _ in [] }
        let start = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 240, repeats: true) { timer in
            let done = MainActor.assumeIsolated {
                let now = CACurrentMediaTime()
                for (i, view) in views.enumerated() { samples[i].append([now - start, view.debugPlace]) }
                guard now - start >= seconds else { return false }
                if let data = try? JSONSerialization.data(withJSONObject: samples) { try? data.write(to: url) }
                return true
            }
            if done { timer.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }
}
#endif

struct VoiceWave: NSViewRepresentable {
    var source: VoiceWaveView.Source = .microphone
    var phase: VoiceWaveView.Phase = .listening
    /// Shows the time spoken at the end, in type this big.
    var clockSize: CGFloat?
    var started = Date()
    /// The theme's accent, else the system's.
    var accent: Color?

    func makeNSView(context: Context) -> VoiceWaveView {
        VoiceWaveView()
    }

    func updateNSView(_ view: VoiceWaveView, context: Context) {
        let environment = context.environment
        let colors = VoiceInk.colors(accent ?? environment.themeAccent ?? .accentColor, in: environment)
        let clockColor = Color.primary.opacity(0.55).resolve(in: environment).cgColor
        view.show(source: source, phase: phase, colors: colors, clockFont: clockSize, clockColor: clockColor, started: started)
    }
}

// MARK: The edge

/// A line of light around what the voice goes into: the accent's colors
/// turning slowly, its glow following the voice. While the text is
/// written, it breathes.
final class VoiceEdgeView: NSView {
    /// Room left around the edge for its glow.
    static let room: CGFloat = 12

    private let holder = CALayer()
    private let spin = CAGradientLayer()
    private let edges = CALayer()
    private let line = CAShapeLayer()
    private let soft = CAShapeLayer()
    private let wide = CAShapeLayer()
    private var source: VoiceWaveView.Source = .microphone
    private var phase: VoiceWaveView.Phase = .listening
    private var corner: CGFloat = 12
    private var colors: [CGColor] = []
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        spin.type = .conic
        spin.startPoint = CGPoint(x: 0.5, y: 0.5)
        spin.endPoint = CGPoint(x: 0.5, y: 0)
        for (shape, width, opacity) in [(wide, 14.0, 0.08), (soft, 5.0, 0.25), (line, 1.25, 0.9)] {
            shape.fillColor = nil
            shape.strokeColor = .white
            shape.lineWidth = width
            shape.opacity = Float(opacity)
            edges.addSublayer(shape)
        }
        holder.mask = edges
        holder.addSublayer(spin)
        layer?.addSublayer(holder)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(source: VoiceWaveView.Source, phase: VoiceWaveView.Phase, corner: CGFloat, colors: [CGColor]) {
        let sourceChanged = source != self.source
        self.source = source
        self.corner = corner
        if colors != self.colors {
            self.colors = colors
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            spin.colors = [colors[0], colors[1], colors[2], colors[1], colors[0]]
            CATransaction.commit()
        }
        if sourceChanged { listen() }
        if phase != self.phase {
            self.phase = phase
            moveAll()
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        holder.frame = bounds
        edges.frame = bounds
        let side = hypot(bounds.width, bounds.height)
        spin.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        spin.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let rect = bounds.insetBy(dx: Self.room, dy: Self.room)
        let radius = min(corner, rect.height / 2, rect.width / 2)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        for shape in [line, soft, wide] {
            shape.frame = bounds
            shape.path = path
        }
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        listen()
        moveAll()
    }

    private func listen() {
        Dictation.shared.meter.stopListening(self)
        guard window != nil, source == .microphone else { return }
        Dictation.shared.meter.listen(self) { [weak self] level in self?.hear(level) }
    }

    /// The glow follows the voice.
    private func hear(_ level: CGFloat) {
        guard phase == .listening else { return }
        CATransaction.begin()
        // A tenth of a second to get there: the next level comes then.
        CATransaction.setAnimationDuration(0.1)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
        soft.opacity = Float(0.15 + 0.45 * level)
        wide.opacity = Float(0.04 + 0.2 * level)
        CATransaction.commit()
    }

    private func moveAll() {
        guard window != nil else { return }
        if !reduceMotion, spin.animation(forKey: "turn") == nil {
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = 0
            turn.toValue = -2 * Double.pi
            turn.duration = 7
            turn.repeatCount = .infinity
            spin.add(turn, forKey: "turn")
        }
        holder.removeAnimation(forKey: "breathe")
        // Writing, or the picture in Settings: a slow breath instead of the voice.
        guard phase == .writing || source == .demo else { return }
        soft.opacity = 0.3
        wide.opacity = 0.1
        guard !reduceMotion else { return }
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 1
        breathe.toValue = 0.45
        breathe.duration = phase == .writing ? 0.7 : 1.6
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        holder.add(breathe, forKey: "breathe")
    }

    override func removeFromSuperview() {
        Dictation.shared.meter.stopListening(self)
        super.removeFromSuperview()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Around a shape `corner` round: lay it out `VoiceEdgeView.room` bigger
/// than the shape on each side.
struct VoiceEdge: NSViewRepresentable {
    var source: VoiceWaveView.Source = .microphone
    var phase: VoiceWaveView.Phase = .listening
    let corner: CGFloat
    var accent: Color?

    func makeNSView(context: Context) -> VoiceEdgeView {
        VoiceEdgeView()
    }

    func updateNSView(_ view: VoiceEdgeView, context: Context) {
        let environment = context.environment
        view.show(source: source, phase: phase, corner: corner,
                  colors: VoiceInk.colors(accent ?? environment.themeAccent ?? .accentColor, in: environment))
    }
}

extension View {
    /// The line of light around this view, `corner` round.
    func voiceEdge(source: VoiceWaveView.Source = .microphone, phase: VoiceWaveView.Phase = .listening, corner: CGFloat, accent: Color? = nil) -> some View {
        overlay {
            VoiceEdge(source: source, phase: phase, corner: corner, accent: accent)
                .padding(-VoiceEdgeView.room)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
