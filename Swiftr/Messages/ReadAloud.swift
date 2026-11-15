import AppKit
import AVFoundation
import HerdrKit
import NaturalLanguage
import Observation

/// Reads an agent's message aloud, in the voice chosen for the message's
/// language, without its code (see `SpeechText`): a downloaded voice
/// model's (`ModelReader`), else one of this Mac's. One message at a time:
/// another's button stops the first.
@MainActor @Observable
final class ReadAloud {
    static let shared = ReadAloud()

    /// The message being read (its transcript item's id), nil when quiet.
    private(set) var readingID: String?
    /// Grows each time this Mac's voices change (one downloaded in System
    /// Settings), so Settings lists them again.
    private(set) var voicesChanged = 0
    /// What went wrong the last time a voice model read, by model id.
    private(set) var modelErrors: [String: String] = [:]
    /// Grows each time the languages Settings lists change.
    private(set) var languagesChanged = 0
    @ObservationIgnored private var voicesObserver: NSObjectProtocol?

    private init() {
        voicesObserver = NotificationCenter.default.addObserver(forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.voicesChanged += 1 }
        }
    }

    @ObservationIgnored private var synthesizer: AVSpeechSynthesizer?
    /// Says when the reading ends; one per reading, so the end of a stopped
    /// reading can't end the next.
    @ObservationIgnored private var ending: ReadingEnd?
    @ObservationIgnored private var readings = 0

    #if DEBUG
    /// The last reading: what was said, in which language and voice.
    @ObservationIgnored private(set) var debugState: [String: Any] = [:]
    #endif

    /// Reads `markdown`, or stops when `id` is the message being read.
    func toggle(id: String, markdown: String) {
        if readingID == id {
            stop()
        } else {
            read(id: id, markdown: markdown)
        }
    }

    /// Reads `markdown` aloud, after stopping whatever was being read.
    func read(id: String, markdown: String) {
        let language = Self.language(of: SpeechText.make(markdown))
        Self.remember(language)
        say(SpeechText.make(markdown, language: language), language: language, id: id)
    }

    /// A few words in the voice `language` would be read in, for Settings.
    func sample(_ language: String) {
        say(Self.sampleText(language), language: language, id: Self.sampleID(language))
    }

    /// A few words in a model's voice, for Settings' lists of voices when
    /// Swiftr has no recording of it. Its model must be here.
    func sample(voice: ModelVoice) {
        guard let model = VoiceCatalog.model(voice.model), VoiceLibrary.shared.isInstalled(model) else { return }
        say(Self.sampleText(voice.language), language: voice.language, id: Self.sampleID(voice.key), voice: .model(model, voice))
    }

    func stop() {
        synthesizer?.stopSpeaking(at: .immediate)
        synthesizer = nil
        ending = nil
        ModelReader.shared.stop()
        readingID = nil
    }

    private func say(_ text: String, language: String, id: String, voice: Voice? = nil) {
        stop()
        guard !text.isEmpty else { return }
        readings += 1
        let reading = readings
        readingID = id
        switch voice ?? Self.voice(for: language) {
        case .model(let model, let voice):
            let chunks = SpeechChunks.make(text)
            #if DEBUG
            debugState = ["id": id, "language": language, "engine": "model", "voice": voice.key, "speed": Self.speed, "text": text, "chunks": chunks, "ended": false]
            #endif
            ModelReader.shared.read(chunks, voice: voice, model: model, speed: Self.speed, quiet: Self.quiet) { [weak self] error, heard in
                guard let self, self.readings == reading else { return }
                if let error {
                    self.modelErrors[model.id] = error
                    #if DEBUG
                    self.debugState["error"] = error
                    #endif
                    // Nothing heard yet: this Mac's voice reads it instead.
                    if !heard {
                        self.speak(text, language: language, voice: Self.systemVoices(for: language).first, reading: reading, id: id)
                        return
                    }
                } else {
                    self.modelErrors[model.id] = nil
                }
                self.ended(reading)
            }
        case .system(let voice):
            speak(text, language: language, voice: voice, reading: reading, id: id)
        }
    }

    /// Reads `text` with one of this Mac's voices.
    private func speak(_ text: String, language: String, voice: AVSpeechSynthesisVoice?, reading: Int, id: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice ?? AVSpeechSynthesisVoice(language: language)
        utterance.rate = Self.rate
        if Self.quiet { utterance.volume = 0 }
        #if DEBUG
        let error = debugState["error"]
        debugState = ["id": id, "language": language, "engine": "system", "voice": utterance.voice?.identifier ?? "", "rate": utterance.rate, "text": text, "ended": false]
        if let error { debugState["error"] = error }
        #endif
        let end = ReadingEnd(reading: reading)
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = end
        self.synthesizer = synthesizer
        ending = end
        synthesizer.speak(utterance)
    }

    /// Tests run without a sound.
    private static var quiet: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["SWIFTR_QUIET"] == "1"
        #else
        false
        #endif
    }

    /// Reading number `reading` finished or was stopped: its button turns
    /// back, unless another reading took over.
    fileprivate func ended(_ reading: Int) {
        guard readings == reading, readingID != nil else { return }
        synthesizer = nil
        ending = nil
        readingID = nil
        #if DEBUG
        debugState["ended"] = true
        #endif
    }

    // MARK: Voices

    /// The language `text` is written in ("fr"), else the Mac's.
    static func language(of text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        if let found = recognizer.dominantLanguage, found != .undetermined {
            return base(found.rawValue)
        }
        return base(Locale.preferredLanguages.first ?? "en")
    }

    /// `fr` of `fr-CA`.
    static func base(_ tag: String) -> String {
        String(tag.split(separator: "-").first ?? Substring(tag))
    }

    /// This Mac's voices for `language` ("fr"), best first: Premium, then
    /// Enhanced, then the plain ones; in each, the Mac's region first, then
    /// the language's default voice. Novelty voices and the older robotic
    /// ones (Eloquence's, MacInTalk's) are left out.
    static func systemVoices(for language: String) -> [AVSpeechSynthesisVoice] {
        let home = Locale.current.region.map { language + "-" + $0.identifier }
        let standard = AVSpeechSynthesisVoice(language: home ?? language)?.identifier
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { voice in
                base(voice.language) == language
                    && !voice.voiceTraits.contains(.isNoveltyVoice)
                    && !voice.identifier.hasPrefix("com.apple.eloquence.")
                    && !voice.identifier.hasPrefix("com.apple.speech.synthesis.voice.")
            }
            .sorted { a, b in
                if a.quality != b.quality { return a.quality.rawValue > b.quality.rawValue }
                if (a.language == home) != (b.language == home) { return a.language == home }
                if (a.identifier == standard) != (b.identifier == standard) { return a.identifier == standard }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }

    /// A voice to read in: a downloaded model's, or one of this Mac's.
    enum Voice {
        case model(VoiceModel, ModelVoice)
        case system(AVSpeechSynthesisVoice?)
    }

    /// The voice `language` is read in: the one chosen in Settings, else
    /// the automatic one.
    static func voice(for language: String) -> Voice {
        let chosen = UserDefaults.standard.string(forKey: voiceKey(language)) ?? ""
        if let model = modelVoice(chosen, language: language) {
            return .model(model.model, model.voice)
        }
        if !chosen.contains("/"), !chosen.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: chosen) {
            return .system(voice)
        }
        return automaticVoice(for: language)
    }

    /// The first downloaded model's best voice for `language`, else this
    /// Mac's best.
    static func automaticVoice(for language: String) -> Voice {
        if let voice = modelVoices(for: language).first, let model = VoiceCatalog.model(voice.model) {
            return .model(model, voice)
        }
        return .system(systemVoices(for: language).first ?? AVSpeechSynthesisVoice(language: language))
    }

    /// The downloaded models' voices for `language`, in the catalog's order.
    static func modelVoices(for language: String) -> [ModelVoice] {
        VoiceCatalog.models.filter { VoiceLibrary.shared.isInstalled($0) }.flatMap { $0.voices(for: language) }
    }

    /// The model voice a Settings value names, when its model is here.
    static func modelVoice(_ key: String, language: String) -> (model: VoiceModel, voice: ModelVoice)? {
        guard key.contains("/"), let found = VoiceCatalog.voice(key), found.voice.language == language,
              VoiceLibrary.shared.isInstalled(found.model) else { return nil }
        return found
    }

    /// "Voxtral: Female, casual" or "Audrey (France, Premium)".
    static func label(_ voice: Voice) -> String {
        switch voice {
        case .model(let model, let voice): "\(model.name): \(voice.label)"
        case .system(let voice): voice.map(label) ?? "System voice"
        }
    }

    /// Where Settings keeps the voice chosen for `language`.
    static func voiceKey(_ language: String) -> String {
        "readAloudVoice-" + language
    }

    /// "Audrey (France, Premium)".
    static func label(_ voice: AVSpeechSynthesisVoice) -> String {
        var name = voice.name
        // Better voices carry their kind in their name too: "Audrey (Premium)".
        if voice.quality != .default, name.hasSuffix(")"), let open = name.lastIndex(of: "(") {
            name = name[..<open].trimmingCharacters(in: .whitespaces)
        }
        var details: [String] = []
        let parts = voice.language.split(separator: "-")
        if parts.count > 1, let region = Locale.current.localizedString(forRegionCode: String(parts[1])) {
            details.append(region)
        }
        switch voice.quality {
        case .premium: details.append("Premium")
        case .enhanced: details.append("Enhanced")
        default: break
        }
        return details.isEmpty ? name : "\(name) (\(details.joined(separator: ", ")))"
    }

    /// "French" for "fr".
    static func name(_ language: String) -> String {
        Locale.current.localizedString(forLanguageCode: language) ?? language
    }

    // MARK: Settings

    static let speedKey = "readAloudSpeed"
    static let speeds: [Double] = [0.75, 1, 1.25, 1.5, 1.75, 2]

    /// The speed chosen in Settings, 1 for the voice's own. A speed Swiftr
    /// no longer offers reads as the nearest one: 1.4 as 1.5.
    static var speed: Double {
        #if DEBUG
        if let debugSpeed { return debugSpeed }
        #endif
        return nearest(UserDefaults.standard.object(forKey: speedKey) as? Double ?? 1)
    }

    /// The speed offered nearest `speed`.
    static func nearest(_ speed: Double) -> Double {
        speeds.min { abs($0 - speed) < abs($1 - speed) } ?? 1
    }

    #if DEBUG
    /// A speed for tests, in place of Settings' one, which the installed app
    /// shares.
    static var debugSpeed: Double?
    #endif

    /// The pace of this Mac's voices, from the speed chosen in Settings.
    static var rate: Float {
        let rate = AVSpeechUtteranceDefaultSpeechRate * Float(speed)
        return min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, rate))
    }

    /// The languages messages were read in, for Settings.
    private static let languagesKey = "readAloudLanguages"

    /// The languages Settings offers a voice for: the Mac's, then those
    /// messages were read in or that were added there.
    static var settingsLanguages: [String] {
        var out: [String] = []
        for tag in Locale.preferredLanguages + (UserDefaults.standard.stringArray(forKey: languagesKey) ?? []) {
            let language = base(tag)
            if !out.contains(language) { out.append(language) }
        }
        return out
    }

    /// The Mac's own languages, which Settings always lists.
    static func isMacLanguage(_ language: String) -> Bool {
        Locale.preferredLanguages.contains { base($0) == language }
    }

    /// Languages a voice here can read that Settings doesn't list yet: the
    /// voice models' and this Mac's, by name.
    static var otherLanguages: [String] {
        var all = Set(VoiceCatalog.models.flatMap(\.languages))
        for voice in AVSpeechSynthesisVoice.speechVoices() { all.insert(base(voice.language)) }
        return all.subtracting(settingsLanguages).sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
    }

    /// Lists `language` in Settings, as reading a message in it does.
    static func remember(_ language: String) {
        var read = UserDefaults.standard.stringArray(forKey: languagesKey) ?? []
        guard !read.contains(language) else { return }
        read.append(language)
        UserDefaults.standard.set(read, forKey: languagesKey)
        shared.languagesChanged += 1
    }

    /// Takes `language` off Settings' list, with the voice chosen for it;
    /// reading a message in it lists it again.
    static func forget(_ language: String) {
        var read = UserDefaults.standard.stringArray(forKey: languagesKey) ?? []
        read.removeAll { $0 == language }
        UserDefaults.standard.set(read, forKey: languagesKey)
        UserDefaults.standard.removeObject(forKey: voiceKey(language))
        shared.languagesChanged += 1
    }

    /// The button that plays `language`'s sample is the one reading.
    static func sampleID(_ language: String) -> String {
        "sample-" + language
    }

    static func sampleText(_ language: String) -> String {
        switch language {
        case "fr": "Bonjour ! Voici la voix qui lira les réponses de vos agents. J'ai fini les changements, et tous les tests passent."
        case "en": "Hello! This is the voice that reads your agents' answers. I've finished the changes, and all the tests pass."
        case "es": "¡Hola! Esta es la voz que leerá las respuestas de tus agentes. He terminado los cambios y todas las pruebas pasan."
        case "de": "Hallo! Das ist die Stimme, die die Antworten deiner Agenten vorliest. Ich bin mit den Änderungen fertig, und alle Tests laufen durch."
        case "it": "Ciao! Questa è la voce che leggerà le risposte dei tuoi agenti. Ho finito le modifiche e tutti i test passano."
        case "pt": "Olá! Esta é a voz que vai ler as respostas dos seus agentes. Terminei as alterações e todos os testes passam."
        case "nl": "Hallo! Dit is de stem die de antwoorden van je agents voorleest. Ik ben klaar met de wijzigingen en alle tests slagen."
        case "hi": "नमस्ते! यह वह आवाज़ है जो आपके एजेंटों के जवाब पढ़ेगी। मैंने बदलाव पूरे कर लिए हैं, और सभी टेस्ट पास हो गए हैं।"
        case "ar": "مرحبًا! هذا هو الصوت الذي سيقرأ إجابات وكلائك. لقد أنهيت التغييرات، وجميع الاختبارات ناجحة."
        case "ja": "こんにちは！これはエージェントの返事を読み上げる声です。変更が終わり、すべてのテストが通りました。"
        case "zh": "你好！这是朗读你的智能体回答的声音。我已经完成了修改，所有测试都通过了。"
        default: Locale(identifier: language).localizedString(forLanguageCode: language) ?? language
        }
    }

    /// System Settings › Accessibility › Read & Speak, where System voice
    /// downloads better voices.
    static func openSystemVoices() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?AX_FEATURE_SPOKENCONTENT") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// The delegate of one reading: tells `ReadAloud` when it ends, finished
/// or stopped. The synthesizer may call from any thread.
private final class ReadingEnd: NSObject, AVSpeechSynthesizerDelegate {
    nonisolated let reading: Int

    init(reading: Int) {
        self.reading = reading
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        end()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        end()
    }

    nonisolated private func end() {
        let reading = reading
        Task { @MainActor in ReadAloud.shared.ended(reading) }
    }
}
