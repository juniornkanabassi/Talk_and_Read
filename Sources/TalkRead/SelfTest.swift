// Headless `--selftest-tts` (word-timing round trip) and `--selftest-asr` (dictation fixtures) runners. Stub; owned by WP3.
import Foundation

enum SelfTest {
    /// Synthesises the text file, transcribes it back and reports timing error. Returns the process exit code.
    static func tts(file: String) async -> Int32 {
        FileHandle.standardError.write(Data("--selftest-tts \(file): not implemented yet (WP3)\n".utf8))
        return 2
    }
    /// Transcribes every audio file in the directory and reports WER. Returns the process exit code.
    static func asr(directory: String) async -> Int32 {
        FileHandle.standardError.write(Data("--selftest-asr \(directory): not implemented yet (WP3)\n".utf8))
        return 2
    }
}
