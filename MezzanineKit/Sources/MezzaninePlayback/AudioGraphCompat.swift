import AVFAudio

// macOS 27's SDK deprecates the non-throwing graph calls and adds throwing replacements
// (`connectNode(_:to:format:)`, `playAudio()`, `playAudio(at:)`, `installTap(…error:)`).
// The replacements are macOS 27 only, and the app still targets macOS 26, so each call picks
// the new API where it exists and the old one below it. Deprecation warnings only fire for a
// deployment target of 27 or later, so the `else` branches build warning-free today; when the
// target moves to 27, delete the `else` branches and these shims collapse to the new calls.

extension AVAudioEngine {
    func connectNodes(_ source: AVAudioNode, to destination: AVAudioNode, format: AVAudioFormat?) throws {
        if #available(macOS 27.0, *) {
            try connectNode(source, to: destination, format: format)
        } else {
            connect(source, to: destination, format: format)
        }
    }
}

extension AVAudioPlayerNode {
    /// Starts or resumes now, or at `time` (a host or sample time on the engine's timeline).
    func startPlaying(at time: AVAudioTime? = nil) throws {
        if #available(macOS 27.0, *) {
            try playAudio(at: time)
        } else {
            play(at: time)
        }
    }
}
