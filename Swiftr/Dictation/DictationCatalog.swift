import Foundation

/// A model dictation runs on this Mac, downloaded when asked.
nonisolated struct DictationModel: Identifiable, Sendable {
    enum Role: Sendable {
        /// Turns speech into text: dictation needs it.
        case speech
        /// Listens again for the names in the vocabulary.
        case vocabulary
        /// Tidies the text up: punctuation, "um"s.
        case tidy
    }

    let id: String
    let role: Role
    let name: String
    let maker: String
    let about: String
    /// The Hugging Face repository, the commit Swiftr downloads from it,
    /// and the files it leaves out.
    let hub: HubRepo
    /// The folder's name: FluidAudio finds its models by it.
    let folderName: String
    /// Bytes the download takes, before the file list gives the exact count.
    let size: Int64
    let license: String

    /// Who made it and its license: what Settings shows under the pointer.
    var credits: String {
        "\(name) by \(maker) · \(license)"
    }
}

/// The models dictation offers: one to hear, two to do better.
nonisolated enum DictationCatalog {
    static let models: [DictationModel] = [speech, vocabulary, tidy]

    static func model(_ id: String) -> DictationModel? {
        models.first { $0.id == id }
    }

    /// Parakeet Ultra, NVIDIA's Parakeet TDT 0.6B v3 trained further by
    /// moondream, for the Neural Engine: 25 European languages, and it
    /// finds which one it hears.
    static let speech = DictationModel(
        id: "parakeet-ultra", role: .speech, name: "Parakeet Ultra", maker: "NVIDIA and moondream, Core ML by FluidInference",
        about: "Hears 25 languages, on the Neural Engine",
        hub: HubRepo(repo: "FluidInference/parakeet-ultra-coreml", revision: "95eaa59a39d4394f047a4dc5cce480388a60d1b6",
                     skip: ["*.md", ".gitattributes"]),
        folderName: "parakeet-ultra", size: 632_314_500, license: "CC BY 4.0")

    /// Parakeet CTC 110M scores the words of the vocabulary against the
    /// sound: a name heard wrong comes back as written.
    static let vocabulary = DictationModel(
        id: "parakeet-ctc", role: .vocabulary, name: "Parakeet CTC 110M", maker: "NVIDIA, Core ML by FluidInference",
        about: "Writes these names as they're spelled",
        hub: HubRepo(repo: "FluidInference/parakeet-ctc-110m-coreml", revision: "accdafd8cf8a2ff1cabe3c11e54416b405d409aa",
                     skip: ["*.md", ".gitattributes", "convert/*", "uv.lock", "pyproject.toml", "CtcHead.*"]),
        folderName: "parakeet-ctc-110m-coreml", size: 101_768_000, license: "CC BY 4.0")

    /// Qwen3 0.6B, a small language model, puts the punctuation and the
    /// capitals right and leaves out the "um"s, the words kept.
    static let tidy = DictationModel(
        id: "qwen3-0.6b", role: .tidy, name: "Qwen3 0.6B", maker: "Alibaba",
        about: "Takes out stumbles, puts the punctuation right",
        hub: HubRepo(repo: "mlx-community/Qwen3-0.6B-4bit", revision: "73e3e38d981303bc594367cd910ea6eb48349da8",
                     skip: ["*.md", ".gitattributes"]),
        folderName: "qwen3-0.6b-4bit", size: 351_383_598, license: "Apache 2.0")
}
