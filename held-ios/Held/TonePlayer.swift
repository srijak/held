import Foundation
import AVFoundation

/// Playback-only tone generator for ear training. Independent of
/// PitchEngine so the Ear tab never needs mic permission or a running
/// input tap. Coexists with the mic session when it is active.
@MainActor
final class TonePlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var configured = false

    private func ensureRunning() throws {
        if !configured {
            engine.attach(player)
            let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)
            engine.connect(player, to: engine.mainMixerNode, format: fmt)
            configured = true
        }
        if !engine.isRunning {
            let session = AVAudioSession.sharedInstance()
            // If PitchEngine already holds .playAndRecord, ride along;
            // otherwise a plain playback session is all we need.
            if session.category != .playAndRecord {
                try session.setCategory(.playback, options: [.mixWithOthers])
            }
            try session.setActive(true)
            try engine.start()
        }
    }

    /// Plays a sine tone at a (possibly fractional) MIDI pitch and
    /// returns after it finishes.
    func play(midiFloat: Double, duration: Double = 0.8) async {
        do { try ensureRunning() } catch { return }

        let sr = engine.mainMixerNode.outputFormat(forBus: 0).sampleRate
        let freq = 440 * pow(2, (midiFloat - 69) / 12)
        let frames = AVAudioFrameCount(sr * duration)
        guard
            let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1),
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)
        else { return }
        buf.frameLength = frames
        let data = buf.floatChannelData![0]
        for i in 0..<Int(frames) {
            let t = Double(i) / sr
            var env = 1.0
            if t < 0.04 { env = t / 0.04 }
            if t > duration - 0.12 { env = max(0, (duration - t) / 0.12) }
            data[i] = Float(sin(2 * .pi * freq * t) * 0.4 * env)
        }
        player.stop()
        player.scheduleBuffer(buf, at: nil, options: [], completionHandler: nil)
        player.play()
        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
    }
}
