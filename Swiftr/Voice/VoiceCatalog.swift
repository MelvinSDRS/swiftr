import Foundation

/// A voice model Swiftr can download and read with, on this Mac.
nonisolated struct VoiceModel: Identifiable, Sendable {
    let id: String
    let name: String
    let maker: String
    /// What it's good at, a sentence.
    let about: String
    /// The Hugging Face repository, and the commit Swiftr downloads from it.
    let repo: String
    let revision: String
    /// Bytes the download takes, before the file list gives the exact count.
    let size: Int64
    /// Memory it takes while it reads, in gigabytes.
    let memory: Double
    let license: String
    /// Its license allows only non-commercial use.
    var personalUseOnly = false
    /// Its voices, best first in each language.
    let voices: [ModelVoice]
    /// Files of the repository the download leaves out.
    var skip = ["*.md", ".gitattributes", "*.pt", "samples/*"]

    /// The languages it reads, in its voices' order.
    var languages: [String] {
        var out: [String] = []
        for voice in voices where !out.contains(voice.language) { out.append(voice.language) }
        return out
    }

    func voices(for language: String) -> [ModelVoice] {
        voices.filter { $0.language == language }
    }

    /// Who made it, its license and the memory it takes: what Settings
    /// shows under the pointer.
    var credits: String {
        let use = personalUseOnly ? ", personal use only" : ""
        return "\(name) by \(maker) · \(license)\(use) · about \(memory.formatted()) GB of memory while it reads"
    }
}

/// One of a model's voices.
nonisolated struct ModelVoice: Identifiable, Sendable {
    /// Its model's id.
    let model: String
    /// The model's own name for it.
    let id: String
    /// "Heart" or "Female".
    let name: String
    /// What it sounds like when the name doesn't say: "American female".
    var detail: String?
    /// The language it reads ("fr").
    let language: String
    /// The language as the model names it, when it wants one.
    var hint: String?
    /// Decibels that bring it to the others' loudness.
    var gain = 0.0

    /// How Settings keeps it: "voxtral/fr_female".
    var key: String { model + "/" + id }

    /// "Heart, American female".
    var label: String {
        detail.map { "\(name), \($0)" } ?? name
    }

    /// The recording Settings plays, in the app: "voxtral-fr_female", with
    /// the language when the model has the voice in several.
    var sampleName: String {
        hint == nil ? "\(model)-\(id)" : "\(model)-\(id)-\(language)"
    }
}

/// The voice models Swiftr offers, the recommended one first.
nonisolated enum VoiceCatalog {
    static let models: [VoiceModel] = [voxtral, kokoro, vibeVoice, pocket, qwen]

    static func model(_ id: String) -> VoiceModel? {
        models.first { $0.id == id }
    }

    /// The voice a Settings key names ("voxtral/fr_female"), with its model.
    static func voice(_ key: String) -> (model: VoiceModel, voice: ModelVoice)? {
        let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, let model = model(parts[0]),
              let voice = model.voices.first(where: { $0.id == parts[1] }) else { return nil }
        return (model, voice)
    }

    static let recommended = "voxtral"

    // Gains: what each voice's sample needed to reach -20 dB.

    static let voxtral = VoiceModel(
        id: "voxtral", name: "Voxtral", maker: "Mistral AI",
        about: "The most natural voices.",
        repo: "mlx-community/Voxtral-4B-TTS-2603-mlx-4bit",
        revision: "f98fc91b9cb5adc7dab56102c690458276c14c6a",
        size: 2_542_797_221, memory: 3.5, license: "CC BY-NC 4.0", personalUseOnly: true,
        voices: voices("voxtral", [
            ("fr_female", "Female", nil, "fr", 1.5), ("fr_male", "Male", nil, "fr", 1.5),
            ("casual_female", "Female", "casual", "en", 8.5), ("neutral_female", "Female", "neutral", "en", 10),
            ("cheerful_female", "Female", "cheerful", "en", 11.5), ("casual_male", "Male", "casual", "en", 13),
            ("neutral_male", "Male", "neutral", "en", 11.5),
            ("es_female", "Female", nil, "es", 3.5), ("es_male", "Male", nil, "es", 2.5),
            ("de_female", "Female", nil, "de", 2.5), ("de_male", "Male", nil, "de", 4.5),
            ("it_female", "Female", nil, "it", 4.5), ("it_male", "Male", nil, "it", 0.5),
            ("pt_female", "Female", nil, "pt", 2.5), ("pt_male", "Male", nil, "pt", 4),
            ("nl_female", "Female", nil, "nl", 1.5), ("nl_male", "Male", nil, "nl", 1),
            ("hi_female", "Female", nil, "hi", -2), ("hi_male", "Male", nil, "hi", -5),
            ("ar_male", "Male", nil, "ar", 4.5),
        ]))

    static let kokoro = VoiceModel(
        id: "kokoro", name: "Kokoro", maker: "hexgrad",
        about: "Small and quick, with many voices.",
        repo: "mlx-community/Kokoro-82M-bf16",
        revision: "a71e4d38b236d968966a2002c4c895dbd12b1c3c",
        size: 355_322_783 + 11_000_000, memory: 1, license: "Apache 2.0",
        voices: voices("kokoro", [
            ("af_heart", "Heart", "American female", "en", 3.5), ("af_bella", "Bella", "American female", "en", 2),
            ("af_nicole", "Nicole", "American female", "en", 1.5), ("am_michael", "Michael", "American male", "en", 4.5),
            ("am_fenrir", "Fenrir", "American male", "en", 0.5), ("bf_emma", "Emma", "British female", "en", 1.5),
            ("bm_george", "George", "British male", "en", 2.5), ("bm_fable", "Fable", "British male", "en", 4),
            ("ff_siwis", "Siwis", "female", "fr", 1.5),
            // Its Hindi, Japanese and Chinese voices read garbled here.
            ("ef_dora", "Dora", "female", "es", 4.5), ("em_alex", "Alex", "male", "es", 4),
            ("if_sara", "Sara", "female", "it", -4), ("im_nicola", "Nicola", "male", "it", 0.5),
            ("pf_dora", "Dora", "Brazilian female", "pt", 4), ("pm_alex", "Alex", "Brazilian male", "pt", 4),
        ]))

    static let vibeVoice = VoiceModel(
        id: "vibevoice", name: "VibeVoice", maker: "Microsoft",
        about: "Natural voices that start reading at once.",
        repo: "mlx-community/VibeVoice-Realtime-0.5B-4bit",
        revision: "550877a15358642c1e062aa38ce1fe0623beaa1b",
        size: 732_671_870 + 11_000_000, memory: 1.2, license: "MIT",
        voices: voices("vibevoice", [
            ("en-Emma_woman", "Emma", "female", "en", 2), ("en-Grace_woman", "Grace", "female", "en", 1.5),
            ("en-Carter_man", "Carter", "male", "en", 0.5), ("en-Davis_man", "Davis", "male", "en", 1),
            ("en-Frank_man", "Frank", "male", "en", 1.5), ("en-Mike_man", "Mike", "male", "en", -2.5),
        ]))

    static let pocket = VoiceModel(
        id: "pocket", name: "Pocket TTS", maker: "Kyutai",
        about: "The smallest, and quick.",
        repo: "mlx-community/pocket-tts",
        revision: "cbf71d5f6657bbc3f4bc02f85ee408261225bec7",
        size: 240_320_741, memory: 1, license: "CC BY 4.0",
        voices: voices("pocket", [
            ("alba", "Alba", nil, "en", -2), ("fantine", "Fantine", nil, "en", 1.5),
            ("cosette", "Cosette", nil, "en", 8), ("eponine", "Eponine", nil, "en", 1),
            ("azelma", "Azelma", nil, "en", 3), ("marius", "Marius", nil, "en", 2.5),
            ("javert", "Javert", nil, "en", 4), ("jean", "Jean", nil, "en", 5.5),
        ]))

    static let qwen = VoiceModel(
        id: "qwen3", name: "Qwen3-TTS", maker: "Alibaba",
        about: "Lively, expressive voices.",
        repo: "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit",
        revision: "049ef77fe8816b536193c0c25f9a214d17921282",
        size: 1_973_572_801, memory: 3, license: "Apache 2.0",
        voices: [
            ModelVoice(model: "qwen3", id: "serena", name: "Serena", detail: "female", language: "fr", hint: "french", gain: 3),
            ModelVoice(model: "qwen3", id: "ryan", name: "Ryan", detail: "male", language: "fr", hint: "french", gain: -1.5),
            ModelVoice(model: "qwen3", id: "aiden", name: "Aiden", detail: "male", language: "en", hint: "english", gain: -3),
            ModelVoice(model: "qwen3", id: "ryan", name: "Ryan", detail: "male", language: "en", hint: "english", gain: 1),
            ModelVoice(model: "qwen3", id: "serena", name: "Serena", detail: "female", language: "en", hint: "english", gain: 4.5),
        ])

    private static func voices(_ model: String, _ list: [(String, String, String?, String, Double)]) -> [ModelVoice] {
        list.map { ModelVoice(model: model, id: $0.0, name: $0.1, detail: $0.2, language: $0.3, gain: $0.4) }
    }
}
