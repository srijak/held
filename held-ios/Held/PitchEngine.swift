import Foundation
import AVFoundation
import Combine
import UIKit

@MainActor
final class PitchEngine: ObservableObject {

    struct TracePoint {
        let t: TimeInterval
        let cents: Double?
    }

    // MARK: - Published state
    @Published var isRunning = false
    @Published var micDenied = false
    @Published var detectedMidiFloat: Double?
    @Published var detectedFreq: Double?
    @Published var centsFromTarget: Double?
    @Published var holdSeconds: Double = 0
    @Published var bestHold: Double = 0
    @Published var trace: [TracePoint] = []
    @Published var targetMidi: Int = 57 // A3
    @Published var inputLevel: Double = 0 // 0..1 log-mapped mic level
    @Published var lastError: String?

    static let traceWindow: TimeInterval = 8
    static let inTuneBand: Double = 10   // display band, cents
    static let holdBand: Double = 15     // streak band, cents

    // MARK: - Private
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var playerAttached = false
    private var recentMidi: [Double] = []
    private var holdStart: TimeInterval?

    // MARK: - Music math
    static func midiToFreq(_ m: Double) -> Double { 440 * pow(2, (m - 69) / 12) }
    static func freqToMidiFloat(_ f: Double) -> Double { 69 + 12 * log2(f / 440) }
    static let noteNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
    static func noteName(_ midi: Int) -> String {
        let name = noteNames[((midi % 12) + 12) % 12]
        let octave = midi / 12 - 1
        return "\(name)\(octave)"
    }
    static func noteLetter(_ midi: Int) -> String {
        noteNames[((midi % 12) + 12) % 12]
    }
    static func noteOctave(_ midi: Int) -> Int { midi / 12 - 1 }

    // MARK: - Lifecycle
    func start() async {
        guard !isRunning else { return }

        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else {
            micDenied = true
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            // .measurement disables system voice processing — we want the raw
            // signal. .defaultToSpeaker keeps the reference tone out of the
            // earpiece.
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.defaultToSpeaker]
            )
            try session.setActive(true)

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            let sampleRate = Float(format.sampleRate)

            if !playerAttached {
                engine.attach(playerNode)
                let mono = AVAudioFormat(
                    standardFormatWithSampleRate: format.sampleRate, channels: 1)
                engine.connect(playerNode, to: engine.mainMixerNode, format: mono)
                playerAttached = true
            }

            input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                guard let self else { return }
                guard let ch = buffer.floatChannelData?[0] else { return }
                let n = Int(buffer.frameLength)
                let samples = Array(UnsafeBufferPointer(start: ch, count: n))
                var rms: Float = 0
                for s in samples { rms += s * s }
                rms = (rms / Float(max(1, n))).squareRoot()
                let freq = YIN.detect(buffer: samples, sampleRate: sampleRate)
                Task { @MainActor in
                    self.ingest(freq: freq.map(Double.init), rms: Double(rms))
                }
            }

            try engine.start()
            isRunning = true
            lastError = nil
            UIApplication.shared.isIdleTimerDisabled = true
        } catch {
            lastError = error.localizedDescription
            stop()
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        playerNode.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
        isRunning = false
        holdStart = nil
        holdSeconds = 0
        recentMidi.removeAll()
        detectedMidiFloat = nil
        detectedFreq = nil
        centsFromTarget = nil
        inputLevel = 0
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: - Detection ingest (main actor)
    private func ingest(freq: Double?, rms: Double) {
        // log-mapped mic level for UI feedback (never reveals pitch)
        inputLevel = rms <= 0 ? 0 : min(1, max(0, (log10(rms) + 2.6) / 2.2))

        let now = ProcessInfo.processInfo.systemUptime

        var cents: Double? = nil
        if let freq {
            // median-of-3 smoothing in log-frequency space
            let midiFloat = smooth(Self.freqToMidiFloat(freq))
            detectedMidiFloat = midiFloat
            detectedFreq = Self.midiToFreq(midiFloat)
            cents = (midiFloat - Double(targetMidi)) * 100
            centsFromTarget = cents

            if abs(cents!) <= Self.holdBand {
                if holdStart == nil { holdStart = now }
                holdSeconds = now - holdStart!
                if holdSeconds > bestHold { bestHold = holdSeconds }
            } else {
                holdStart = nil
                holdSeconds = 0
            }
        } else {
            recentMidi.removeAll()
            detectedMidiFloat = nil
            detectedFreq = nil
            centsFromTarget = nil
            holdStart = nil
            holdSeconds = 0
        }

        trace.append(TracePoint(t: now, cents: cents))
        while let first = trace.first, now - first.t > Self.traceWindow {
            trace.removeFirst()
        }
    }

    private func smooth(_ midiFloat: Double) -> Double {
        recentMidi.append(midiFloat)
        if recentMidi.count > 3 { recentMidi.removeFirst() }
        guard recentMidi.count == 3 else { return midiFloat }
        return recentMidi.sorted()[1]
    }

    // MARK: - Actions
    func setTargetToVoice() {
        guard let m = detectedMidiFloat else { return }
        targetMidi = min(84, max(36, Int(m.rounded())))
    }

    func nudgeTarget(_ delta: Int) {
        targetMidi = min(84, max(36, targetMidi + delta))
    }

    func playReference(midi: Int? = nil) {
        guard isRunning else { return }
        let sr = engine.mainMixerNode.outputFormat(forBus: 0).sampleRate
        let freq = Self.midiToFreq(Double(midi ?? targetMidi))
        let duration = 1.6
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
            if t < 0.05 { env = t / 0.05 }
            if t > duration - 0.2 { env = max(0, (duration - t) / 0.2) }
            data[i] = Float(sin(2 * .pi * freq * t) * 0.4 * env)
        }
        playerNode.stop()
        playerNode.scheduleBuffer(buf, at: nil)
        playerNode.play()
    }
}
