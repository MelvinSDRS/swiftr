/// Voice models and Dictation run on MLX and the Neural Engine, which only
/// Apple silicon has. On an Intel Mac Swiftr leaves them out: Read Aloud
/// uses the Mac's own voices, and Dictation isn't offered.
nonisolated enum SpeechModels {
    static var supported: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }
}
