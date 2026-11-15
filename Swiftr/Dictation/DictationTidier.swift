import Foundation
import HerdrKit
@preconcurrency import MLX
import MLXAudioCore
import MLXAudioTTS
import MLXNN
import Tokenizers

/// Qwen3 0.6B tidying a dictation up, in the dictation helper: the text
/// heard goes in with `DictationTidy`'s rules, the tidied text comes out,
/// a token at a time, the likeliest each time.
nonisolated final class DictationTidier: @unchecked Sendable {
    let folder: String
    private let model: Qwen3Model
    private let tokenizer: any Tokenizer
    /// The tokens that end an answer: <|im_end|> and <|endoftext|>.
    private let stops: Set<Int>
    /// The tokens the model last read, and what it made of them: the next
    /// piece starts with the same rules and examples, which it needn't
    /// read again.
    private var read: [Int] = []
    private var cache: [KVCache]?

    init(folder: String) async throws {
        self.folder = folder
        let directory = URL(filePath: folder, directoryHint: .isDirectory)
        let data = try Data(contentsOf: directory.appending(path: "config.json"))
        let model = Qwen3Model(try JSONDecoder().decode(Qwen3Configuration.self, from: data))
        let base = try JSONDecoder().decode(BaseConfiguration.self, from: data)
        var weights: [String: MLXArray] = [:]
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where file.pathExtension == "safetensors" {
            weights.merge(try MLX.loadArrays(url: file)) { _, new in new }
        }
        weights = model.sanitize(weights: weights)
        if let quantization = base.perLayerQuantization {
            // The layers the file stores in 4 bits.
            quantize(model: model) { path, _ in
                weights["\(path).scales"] != nil ? quantization.quantization(layer: path)?.asTuple : nil
            }
        }
        try model.update(parameters: ModuleParameters.unflattened(weights), verify: .all)
        eval(model)
        self.model = model
        // Not Qwen3Model's own loading: it fetches a speech decoder too.
        tokenizer = try await AutoTokenizer.from(modelFolder: directory)
        stops = base.effectiveEOSTokenIds.union([151_643, 151_645])
    }

    /// `heard` tidied up, with the names to spell; nil when it isn't
    /// written by `deadline`.
    func tidy(_ heard: String, names: [String], deadline: ContinuousClock.Instant) throws -> String? {
        let messages: [Message] = DictationTidy.messages(heard: heard, names: names).map {
            ["role": $0.role, "content": $0.content]
        }
        // Qwen3 answers at once, without thinking first.
        let prompt = try tokenizer.applyChatTemplate(messages: messages, tools: nil, additionalContext: ["enable_thinking": false])
        // Only what differs from the last prompt goes in; at least a token,
        // for the next one's odds.
        if self.cache?.first?.offset != read.count { (self.cache, read) = (nil, []) }
        let cache = self.cache ?? model.makeCache()
        let same = min(zip(read, prompt).prefix { $0 == $1 }.count, prompt.count - 1)
        for layer in cache { layer.trim(layer.offset - same) }
        self.cache = cache
        read = prompt
        var logits = model(MLXArray(prompt[same...].map(Int32.init))[.newAxis], cache: cache)
        var answer: [Int] = []
        let limit = DictationTidy.tokenLimit(for: heard)
        while answer.count < limit {
            let next = logits[0, -1].argMax().item(Int.self)
            if stops.contains(next) { break }
            answer.append(next)
            if ContinuousClock.now > deadline { return nil }
            logits = model(MLXArray([Int32(next)])[.newAxis], cache: cache)
            read.append(next)
        }
        return tokenizer.decode(tokens: answer, skipSpecialTokens: true)
    }
}
