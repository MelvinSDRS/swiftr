import AppKit
import SwiftUI

// The look of a dictation: bars that follow the voice, and a line of light
// around what the text goes into. Core Animation draws both from the
// levels the microphone hears, so a conversation under them isn't drawn
// again for each (see WorkingRow).

/// The voice's loudness as it comes, for the views that draw it. Not
/// watched by SwiftUI, which would go over the whole conversation each
/// twentieth of a second.
@MainActor
final class VoiceMeter {
    /// When the person started speaking.
    private(set) var started = Date()
    private var listeners: [ObjectIdentifier: (CGFloat) -> Void] = [:]

    func restart() {
        started = Date()
    }

    func push(_ level: Float) {
        for hear in listeners.values { hear(CGFloat(level)) }
    }

    func listen(_ owner: AnyObject, _ hear: @escaping (CGFloat) -> Void) {
        listeners[ObjectIdentifier(owner)] = hear
    }

    func stopListening(_ owner: AnyObject) {
        listeners[ObjectIdentifier(owner)] = nil
    }

    /// A level that sounds like someone speaking, `t` seconds in: words,
    /// and short silences between them. For pictures and tests.
    nonisolated static func speechLike(_ t: Double) -> CGFloat {
        let word = 0.55 + 0.45 * abs(sin(t * 1.7)) * (0.6 + 0.4 * sin(t * 0.8 + 1.2))
        let syllables = abs(sin(t * 11.0)) * 0.6 + abs(sin(t * 17.0 + 0.6)) * 0.4
        let pause = (t.truncatingRemainder(dividingBy: 3.4) > 3.0) ? 0.1 : 1.0
        return CGFloat(max(0.05, min(1, (0.3 + 0.75 * word * syllables) * pause)))
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
/// bars sink and a light goes over them.
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
    private var step: CGFloat { Self.barWidth + Self.gap }

    /// Holds the colors, cut to the bars' shape.
    private let body = CALayer()
    private let ink = CAGradientLayer()
    private let light = CAGradientLayer()
    private let bars = CAShapeLayer()
    private let clock = CATextLayer()

    /// The levels heard, the latest last.
    private var levels: [CGFloat] = []
    private var source: Source = .microphone
    private var phase: Phase = .listening
    private var colors: [CGColor] = []
    private var clockFont: CGFloat?
    private var started = Date()
    private var shownSeconds = -1
    private var demo: Timer?
    private var demoStart = Date()
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
        let sourceChanged = source != self.source
        self.source = source
        self.started = started
        self.clockFont = clockFont
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
        if sourceChanged { listen() }
        if phase != self.phase {
            self.phase = phase
            phaseChanged()
        }
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
        bars.position = CGPoint(x: body.bounds.midX, y: body.bounds.midY)
        CATransaction.commit()
        drawBars()
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

    /// Hears the microphone, or makes a voice up, while in a window.
    private func listen() {
        Dictation.shared.meter.stopListening(self)
        demo?.invalidate()
        demo = nil
        guard window != nil else { return }
        switch source {
        case .microphone:
            Dictation.shared.meter.listen(self) { [weak self] level in self?.hear(level) }
        case .demo:
            // Already speaking when it shows.
            let earlier = 3.0
            demoStart = Date() - earlier
            levels = stride(from: 0, to: earlier, by: 1.0 / 24).map { VoiceMeter.speechLike($0) }
            drawBars()
            let timer = Timer(timeInterval: 1.0 / 24, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.hear(VoiceMeter.speechLike(Date().timeIntervalSince(self.demoStart)))
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            demo = timer
        }
    }

    private func hear(_ level: CGFloat) {
        guard phase == .listening else { return }
        // A bar a little taller or shorter than the next: a voice, not a curve.
        let previous = levels.last ?? 0
        let smooth = previous * 0.25 + level * 0.75
        levels.append(smooth * CGFloat.random(in: 0.82 ... 1))
        let most = Int(bounds.width / step) + 4
        if levels.count > most * 2 { levels.removeFirst(levels.count - most) }
        drawBars()
        tickClock()
        guard !reduceMotion else { return }
        // In from the right: Core Animation slides them a bar's width.
        let slide = CABasicAnimation(keyPath: "transform.translation.x")
        slide.fromValue = step
        slide.toValue = 0
        slide.duration = 1.0 / 22
        bars.add(slide, forKey: "slide")
    }

    private func drawBars() {
        let area = body.bounds
        guard area.width > 0, area.height > 0 else { return }
        let tallest = area.height
        let path = CGMutablePath()
        var x = area.maxX - Self.barWidth
        var i = levels.count - 1
        while x > area.minX - step {
            // Before the first word: dots, a line waiting for the voice.
            let level = i >= 0 ? levels[i] : 0
            let height = max(Self.barWidth, tallest * min(1, pow(max(0, level - 0.06) / 0.8, 1.35)))
            let bar = CGRect(x: x, y: area.midY - height / 2, width: Self.barWidth, height: height)
            path.addRoundedRect(in: bar, cornerWidth: Self.barWidth / 2, cornerHeight: Self.barWidth / 2)
            x -= step
            i -= 1
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bars.path = path
        CATransaction.commit()
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

    /// Writing: the bars sink and a light goes over them, over and over.
    private func phaseChanged() {
        guard window != nil else { return }
        bars.removeAnimation(forKey: "sink")
        light.removeAnimation(forKey: "light")
        switch phase {
        case .listening:
            light.opacity = 0
            bars.transform = CATransform3DIdentity
        case .writing:
            let sink = CABasicAnimation(keyPath: "transform.scale.y")
            sink.fromValue = 1
            sink.toValue = 0.4
            sink.duration = 0.5
            sink.timingFunction = CAMediaTimingFunction(name: .easeOut)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
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
        demo?.invalidate()
        demo = nil
        super.removeFromSuperview()
    }

    /// Nothing here to click.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

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
        CATransaction.setAnimationDuration(0.12)
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
            turn.duration = 5
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
