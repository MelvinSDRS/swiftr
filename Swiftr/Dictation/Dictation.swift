import AppKit
import AVFoundation
import HerdrKit
import Observation
import SwiftUI

/// Dictation: listens while the key is held (or from the field's
/// microphone button to a second click), turns the speech into text on
/// this Mac, and puts the text where the keyboard was: a message field, a
/// terminal, any text field. Nothing is sent: the person reads it first.
@MainActor @Observable
final class Dictation {
    static let shared = Dictation()

    enum Phase: Equatable {
        case idle
        case listening
        /// Heard: the models are writing it.
        case writing
    }

    private(set) var phase: Phase = .idle {
        didSet { DictationHUD.shared.refresh() }
    }
    /// The microphone's loudness while listening, 0 to 1: for the dump.
    /// The views that draw it hear `meter`, out of SwiftUI's sight.
    @ObservationIgnored private(set) var level: Float = 0
    @ObservationIgnored let meter = VoiceMeter()
    /// The pane whose Messages field the text goes to: that field shows
    /// how it goes. Nil for a terminal or another field: a panel shows it.
    private(set) var address: String?
    /// Whether the key started it: let go, it writes. Else the button: a
    /// second click.
    private(set) var byKey = false
    /// What went wrong last, shown a moment.
    private(set) var problem: String? {
        didSet { DictationHUD.shared.refresh() }
    }
    /// What the problem offers: System Settings for a refused microphone,
    /// Settings › Dictation for a missing model.
    private(set) var fix: Fix?

    enum Fix {
        case microphone
        case model
    }
    @ObservationIgnored weak var model: AppModel?
    /// Where the panel shows, for a terminal or another field: the window,
    /// and on the screen, what the text goes into.
    @ObservationIgnored private(set) weak var anchorWindow: NSWindow?
    @ObservationIgnored private(set) var anchorRect: NSRect?

    @ObservationIgnored private let mic = MicCapture()
    @ObservationIgnored private weak var targetView: NSView?
    @ObservationIgnored private var targetAddress: String?
    @ObservationIgnored private var job = 0
    @ObservationIgnored private var problemTask: Task<Void, Never>?
    /// Why the key's dictation didn't start, said once the key is let go:
    /// a key pressed for a shortcut shouldn't show it.
    @ObservationIgnored private var unsaid: (String, Fix?)?

    #if DEBUG
    /// The last dictation, for tests: what was heard and written, and how
    /// long each step took.
    @ObservationIgnored var debugLast: [String: Any] = [:]
    /// Names tests add to the conversation's.
    @ObservationIgnored var debugTerms: [String] = []
    #endif

    // MARK: Settings

    static let keyDefaults = "dictationKey"
    static let tidyDefaults = "dictationTidy"
    static let wordsDefaults = "dictationWords"

    /// The key held to dictate; nil when Settings says none, the field's
    /// button then the only way.
    static var key: DictationKey? {
        get {
            guard let data = UserDefaults.standard.data(forKey: keyDefaults) else { return .rightOption }
            return try? JSONDecoder().decode(DictationKey?.self, from: data)
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: keyDefaults)
            DictationKeys.shared.keyChanged()
        }
    }

    /// Whether Qwen3 tidies the text up, when it's downloaded.
    static var tidies: Bool {
        UserDefaults.standard.object(forKey: tidyDefaults) as? Bool ?? true
    }

    /// The person's own names, from Settings.
    static var myWords: [String] {
        DictationVocabulary.parse(UserDefaults.standard.string(forKey: wordsDefaults) ?? "")
    }

    var isReady: Bool {
        DictationLibrary.shared.isInstalled(DictationCatalog.speech)
    }

    // MARK: Listening

    /// The field's microphone button: starts listening for pane
    /// `address`'s field, or writes what was heard.
    func toggle(for address: String) {
        if phase == .listening {
            finish()
        } else {
            start(for: address)
        }
    }

    /// Starts listening. For pane `address`'s field from its button; with
    /// none, for whatever has the keyboard: the key's dictation, whose
    /// problems wait for `sayWhyNot`. Returns whether it listens.
    @discardableResult
    func start(for address: String? = nil, byKey: Bool = false) -> Bool {
        guard phase != .listening else { return false }
        unsaid = nil
        anchorWindow = NSApp.keyWindow
        anchorRect = nil
        func refuse(_ message: String, _ fix: Fix? = nil) -> Bool {
            if byKey {
                unsaid = (message, fix)
            } else {
                show(message, fix: fix, in: address)
            }
            return false
        }
        guard isReady else {
            return refuse(DictationEngine.EngineError.noModel.localizedDescription, .model)
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            // macOS asks; the button listens once it's allowed.
            AVCaptureDevice.requestAccess(for: .audio) { allowed in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if allowed, let address { self.start(for: address) }
                    }
                }
            }
            return false
        default:
            return refuse("Swiftr may not use the microphone.", .microphone)
        }
        guard chooseTarget(address) else {
            return refuse("Click where the text should go, then dictate.")
        }
        if let view = targetView, let window = view.window {
            anchorWindow = window
            anchorRect = window.convertToScreen(view.convert(view.visibleRect, to: nil))
        }
        do {
            try mic.start { [weak self] levels, end in
                guard let self, phase == .listening else { return }
                level = levels.last ?? level
                meter.push(levels, endingAt: end)
            }
        } catch {
            return refuse(error.localizedDescription)
        }
        job += 1
        clearProblem()
        meter.restart()
        self.byKey = byKey
        // A Messages field shows it above itself.
        self.address = targetView == nil || targetView is ComposerTextView ? targetAddress : nil
        phase = .listening
        // The models load while the person speaks.
        DictationEngine.shared.warmUp()
        return true
    }

    /// Where the text will go: the pane's field for its button, else what
    /// has the keyboard in Swiftr's window.
    private func chooseTarget(_ address: String?) -> Bool {
        targetView = nil
        targetAddress = address
        if address != nil { return true }
        let responder = NSApp.keyWindow?.firstResponder
        if let terminal = responder as? SwiftrTerminalView {
            targetView = terminal
            targetAddress = model?.focusedAddress
            return true
        }
        if let field = responder as? NSTextView, field.isEditable {
            targetView = field
            // The conversation the field writes to, for its names.
            targetAddress = field is ComposerTextView ? model?.focusedAddress : nil
            return true
        }
        // Nothing has the keyboard: the focused pane's field, when it shows its messages.
        if let focused = model?.focusedAddress, model?.showsMessages(focused) == true {
            targetAddress = focused
            return true
        }
        return false
    }

    /// Stops listening and writes what was heard where it goes.
    func finish() {
        guard phase == .listening else { return }
        let samples = mic.stop()
        level = 0
        // Less than a third of a second: nothing was said.
        guard Double(samples.count) >= MicCapture.rate / 3 else {
            reset()
            return
        }
        phase = .writing
        write(samples)
    }

    /// The key was held, and let go: why it didn't listen, if it didn't.
    func sayWhyNot() {
        guard let (message, fix) = unsaid else { return }
        unsaid = nil
        show(message, fix: fix, in: nil)
    }

    /// The key served a shortcut: nothing to say.
    func forgetWhyNot() {
        unsaid = nil
    }

    /// Stops listening and drops what was heard: a shortcut, a tap, Esc.
    func cancel() {
        guard phase != .idle else { return }
        if phase == .listening { _ = mic.stop() }
        job += 1
        reset()
    }

    private func reset() {
        // The problem, if any, shows where the dictation did.
        if problem == nil { address = nil }
        phase = .idle
        level = 0
        targetView = nil
        targetAddress = nil
    }

    private func write(_ samples: [Float]) {
        let job = job
        var names = conversationNames()
        #if DEBUG
        names = debugTerms + names
        #endif
        let terms = DictationVocabulary.terms(mine: Self.myWords, conversation: names, isWord: Self.isDictionaryWord)
        let started = Date()
        Task {
            do {
                let event = try await DictationEngine.shared.transcribe(samples, terms: terms)
                guard job == self.job else { return }
                let text = event.text ?? ""
                #if DEBUG
                debugLast = ["raw": event.raw ?? "", "heard": event.heard ?? "", "text": text, "tidy": event.tidy ?? "",
                             "timings": event.timings ?? [:], "terms": terms, "seconds": Double(samples.count) / MicCapture.rate,
                             "total": Date().timeIntervalSince(started) * 1000]
                #endif
                if text.isEmpty {
                    show("Nothing was heard: check the microphone in System Settings › Sound.", in: address)
                } else {
                    insert(text)
                }
            } catch {
                guard job == self.job else { return }
                show(error.localizedDescription, in: address)
            }
            if job == self.job { reset() }
        }
    }

    /// The names the conversation the text goes to uses, latest last.
    private func conversationNames() -> [String] {
        guard let address = targetAddress, let feed = model?.feeds.existing(address) else { return [] }
        let items = feed.rows.flatMap { row -> [TranscriptItem] in
            switch row {
            case .item(let item): [item]
            case .activity(_, let items): items
            }
        }
        let texts = items.suffix(60).compactMap { item -> String? in
            switch item.kind {
            case .text(let markdown): markdown
            case .prompt(let text, _): text
            default: nil
            }
        }
        return DictationVocabulary.names(in: texts)
    }

    /// Whether `word` is in the dictionary of a language Parakeet hears.
    private static func isDictionaryWord(_ word: String) -> Bool {
        // Written small: the checker takes any capitalized word for a
        // proper name.
        let word = word.lowercased()
        let checker = NSSpellChecker.shared
        return dictionaryLanguages.contains { language in
            checker.checkSpelling(of: word, startingAt: 0, language: language, wrap: false,
                                  inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }
    }

    /// The languages Parakeet hears that this Mac has a dictionary for: a
    /// language without one takes any word.
    private static let dictionaryLanguages: [String] = {
        let checker = NSSpellChecker.shared
        let available = checker.availableLanguages
        let parakeet = ["en", "fr", "de", "es", "it", "pt", "nl", "sv", "da", "fi", "pl", "cs", "sk", "sl", "hr", "ro",
                        "hu", "bg", "el", "et", "lv", "lt", "mt", "ru", "uk"]
        return parakeet.compactMap { code in available.first { $0 == code || $0.hasPrefix(code + "_") } }
            .filter { language in
                checker.checkSpelling(of: "zqxwvj", startingAt: 0, language: language, wrap: false,
                                      inSpellDocumentWithTag: 0, wordCount: nil).location != NSNotFound
            }
    }()

    // MARK: Writing

    private func insert(_ text: String) {
        if let terminal = targetView as? SwiftrTerminalView, terminal.window != nil {
            terminal.pasteText(text)
            return
        }
        if let field = targetView as? NSTextView, field.window != nil, field.isEditable {
            let range = field.selectedRange()
            let ns = field.string as NSString
            // The selection goes, as typing over it would.
            let around = ns.replacingCharacters(in: range, with: "")
            let (_, caret) = DictationText.insert(text, into: around, at: range.location)
            let piece = (DictationText.insert(text, into: around, at: range.location).text as NSString)
                .substring(with: NSRange(location: range.location, length: caret - range.location))
            field.insertText(piece, replacementRange: range)
            return
        }
        guard let address = targetAddress ?? address, let model else { return }
        let draft = model.drafts[address] ?? ""
        let feed = model.feeds.existing(address)
        let length = draft.utf16.count
        // The field's cursor, when it still knows this text; else the end.
        let at = feed?.fieldCaret.flatMap { $0.length == length ? $0.offset : nil } ?? length
        let (new, caret) = DictationText.insert(text, into: draft, at: at)
        model.drafts[address] = new
        if let feed {
            feed.caretTick += 1
            feed.caretAsk = CaretAsk(offset: caret, text: new, tick: feed.caretTick)
            feed.fieldCaret = (caret, new.utf16.count)
        }
    }

    /// Shows `message` a few seconds, in pane `address`'s Messages field
    /// or in the panel.
    private func show(_ message: String, fix: Fix? = nil, in address: String?) {
        self.address = address
        self.fix = fix
        problem = message
        problemTask?.cancel()
        problemTask = Task {
            guard (try? await Task.sleep(for: .seconds(fix == nil ? 4 : 8))) != nil else { return }
            clearProblem()
            if phase == .idle { self.address = nil }
        }
    }

    func clearProblem() {
        problemTask?.cancel()
        problem = nil
        fix = nil
    }

    /// Settings › Dictation, from a problem's button.
    static func openSettings(with open: OpenSettingsAction) {
        UserDefaults.standard.set(SettingsPane.dictation.rawValue, forKey: SettingsPane.defaultsKey)
        open()
    }

    static func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    #if DEBUG
    /// A voice made up for `debugLook`'s listening.
    @ObservationIgnored private var debugVoice: Timer?

    /// Shows a dictation's look without the microphone, for snapshots:
    /// "listening", "writing", "problem", "model" or "mic", then ":panel"
    /// for the panel, ":key" for the key's hint; "idle" ends it.
    func debugLook(_ look: String) {
        let parts = look.split(separator: ":").map(String.init)
        let inPanel = parts.contains("panel")
        anchorWindow = NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
        anchorRect = nil
        clearProblem()
        debugVoice?.invalidate()
        debugVoice = nil
        address = inPanel ? nil : model?.focusedAddress
        phase = .idle
        byKey = parts.contains("key")
        switch parts.first {
        case "listening":
            level = 0.6
            meter.restart()
            phase = .listening
            let started = CACurrentMediaTime()
            // As the microphone gives it: a tenth of a second at a time.
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.phase == .listening else { return }
                    let end = CACurrentMediaTime()
                    let levels = (0 ..< 5).map { i in
                        Float(VoiceMeter.speechLike(end - started - Double(4 - i) * VoiceMeter.moment))
                    }
                    self.meter.push(levels, endingAt: end)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            debugVoice = timer
        case "writing":
            phase = .writing
        case "problem":
            show("Nothing was heard: check the microphone in System Settings › Sound.", in: address)
        case "model":
            show(DictationEngine.EngineError.noModel.localizedDescription, fix: .model, in: address)
        case "mic":
            show("Swiftr may not use the microphone.", fix: .microphone, in: address)
        default:
            address = nil
            level = 0
        }
    }

    /// Dictates the recording at `path` as if heard into the field of pane
    /// `address` (the focused one when nil).
    func debugDictate(file path: String, into address: String?) {
        guard let samples = try? MicCapture.samples(of: URL(filePath: path)) else {
            show(MicCapture.MicError.unreadable.localizedDescription, in: nil)
            return
        }
        job += 1
        targetView = nil
        targetAddress = address ?? model?.focusedAddress
        self.address = targetAddress
        phase = .writing
        write(samples)
    }
    #endif
}
