import Foundation
import AVFoundation
import Combine

/// Practice model for one melody track.
///
/// Call-and-response by design: **Listen** plays the chunk as synth tones,
/// **Sing** scrolls the cursor silently while the mic scores you. The two
/// never overlap, so the detector never hears the speaker — same reasoning
/// as the Recall tab (a reference playing while you sing would train
/// matching, not production, and would pollute the trace).
@MainActor
final class SongModel: ObservableObject {

    struct Chunk: Identifiable {
        let index: Int
        let start: Double
        let end: Double
        let notes: [MelodyTrack.Note]
        var id: Int { index }
        var duration: Double { end - start }
    }

    struct NoteResult {
        let noteID: Double
        let hitRatio: Double   // voiced frames within band / frames in window
        let voicedRatio: Double
        var passed: Bool { hitRatio >= 0.6 }
    }

    struct SungSample {
        let t: Double          // seconds relative to chunk start
        let midi: Double
    }

    enum Phase: Equatable {
        case idle
        case listening   // synth playing the chunk
        case leadIn      // sing countdown
        case singing
        case scored
    }

    // MARK: - Published
    @Published var phase: Phase = .idle
    @Published var chunkIndex = 0
    @Published var cursor: Double = 0            // seconds into current chunk
    @Published var transpose: Int {
        didSet { UserDefaults.standard.set(transpose, forKey: "song.transpose.\(trackID)") }
    }
    @Published var loop: Bool = false
    @Published var sungSamples: [SungSample] = []
    @Published var results: [Double: NoteResult] = [:]   // keyed by note.start
    @Published var chunkScore: Double?                   // 0..1 passed-note ratio
    @Published var bestChunkScore: [Int: Double] = [:]

    let track: MelodyTrack
    let chunks: [Chunk]
    private let trackID: String

    // MARK: - Constants
    static let hitBandCents: Double = 50
    static let leadInSeconds: Double = 1.2
    private static let maxChunkSeconds: Double = 9.0

    // MARK: - Audio / timing
    private let playEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var playerConfigured = false
    private var clockStart: TimeInterval = 0
    private var displayTimer: Timer?
    private var pitchSub: AnyCancellable?
    private weak var pitchEngine: PitchEngine?

    init(track: MelodyTrack, trackID: String, pitchEngine: PitchEngine) {
        self.track = track
        self.trackID = trackID
        self.pitchEngine = pitchEngine
        self.chunks = Self.makeChunks(track.notes)
        self.transpose = UserDefaults.standard.object(forKey: "song.transpose.\(trackID)") as? Int ?? 0
        let saved = UserDefaults.standard.dictionary(forKey: "song.scores.\(trackID)") as? [String: Double] ?? [:]
        self.bestChunkScore = Dictionary(uniqueKeysWithValues: saved.compactMap {
            guard let k = Int($0.key) else { return nil }
            return (k, $0.value)
        })
    }

    var chunk: Chunk {
        guard !chunks.isEmpty else {
            return Chunk(index: 0, start: 0, end: 1, notes: [])
        }
        return chunks[max(0, min(chunkIndex, chunks.count - 1))]
    }

    /// Notes of the current chunk with transpose applied.
    var targetNotes: [MelodyTrack.Note] { chunk.notes }
    func targetMidi(_ note: MelodyTrack.Note) -> Double {
        note.midiFloat + Double(transpose)
    }

    // MARK: - Chunking

    private static func makeChunks(_ notes: [MelodyTrack.Note]) -> [Chunk] {
        guard !notes.isEmpty else { return [] }
        var out: [Chunk] = []
        var current: [MelodyTrack.Note] = []
        var chunkStart = notes[0].start

        func flush(end: Double) {
            guard !current.isEmpty else { return }
            out.append(Chunk(index: out.count, start: chunkStart, end: end, notes: current))
            current = []
        }

        for note in notes {
            if current.isEmpty {
                chunkStart = note.start
                current = [note]
                continue
            }
            if note.end - chunkStart > maxChunkSeconds {
                flush(end: current.last!.end)
                chunkStart = note.start
                current = [note]
            } else {
                current.append(note)
            }
        }
        flush(end: current.last!.end)
        return out
    }

    // MARK: - Chunk navigation

    func selectChunk(_ i: Int) {
        stopAll()
        chunkIndex = max(0, min(chunks.count - 1, i))
        resetAttempt()
    }

    func nextChunk() { selectChunk(chunkIndex + 1) }
    func prevChunk() { selectChunk(chunkIndex - 1) }

    private func resetAttempt() {
        cursor = 0
        sungSamples = []
        results = [:]
        chunkScore = nil
        phase = .idle
    }

    // MARK: - Listen (synth playback)

    func listen() {
        stopAll()
        resetAttempt()
        do { try ensurePlayer() } catch { return }

        let sr = playEngine.mainMixerNode.outputFormat(forBus: 0).sampleRate
        let dur = chunk.duration + 0.3
        let frames = AVAudioFrameCount(sr * dur)
        guard
            let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1),
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)
        else { return }
        buf.frameLength = frames
        let data = buf.floatChannelData![0]
        for i in 0..<Int(frames) { data[i] = 0 }

        for note in chunk.notes {
            let freq = PitchEngine.midiToFreq(targetMidi(note))
            let n0 = Int((note.start - chunk.start) * sr)
            let nDur = note.duration
            let nFrames = Int(nDur * sr)
            for j in 0..<nFrames where n0 + j < Int(frames) {
                let t = Double(j) / sr
                var env = 1.0
                if t < 0.03 { env = t / 0.03 }
                if t > nDur - 0.08 { env = max(0, (nDur - t) / 0.08) }
                data[n0 + j] += Float(sin(2 * .pi * freq * t) * 0.35 * env)
            }
        }

        playerNode.stop()
        playerNode.scheduleBuffer(buf, at: nil)
        playerNode.play()
        phase = .listening
        startClock(offset: 0, total: chunk.duration) { [weak self] in
            self?.phase = .idle
            self?.cursor = 0
        }
    }

    private func ensurePlayer() throws {
        if !playerConfigured {
            playEngine.attach(playerNode)
            let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)
            playEngine.connect(playerNode, to: playEngine.mainMixerNode, format: fmt)
            playerConfigured = true
        }
        if !playEngine.isRunning {
            let session = AVAudioSession.sharedInstance()
            if session.category != .playAndRecord {
                try session.setCategory(.playback, options: [.mixWithOthers])
            }
            try session.setActive(true)
            try playEngine.start()
        }
    }

    // MARK: - Sing

    /// Requires pitchEngine.isRunning (the view enforces the Start gate).
    func sing() {
        guard let engine = pitchEngine, engine.isRunning else { return }
        stopAll()
        resetAttempt()
        phase = .leadIn

        pitchSub = engine.$detectedMidiFloat.sink { [weak self] midi in
            guard let self, self.phase == .singing, let midi else { return }
            let t = ProcessInfo.processInfo.systemUptime - self.clockStart
            self.sungSamples.append(SungSample(t: t, midi: midi))
        }

        startClock(offset: -Self.leadInSeconds, total: chunk.duration) { [weak self] in
            self?.finishSing()
        }
    }

    private func finishSing() {
        pitchSub = nil
        score()
        phase = .scored
        if loop {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                guard let self, self.phase == .scored, self.loop else { return }
                self.sing()
            }
        }
    }

    private func score() {
        var passed = 0
        results = [:]
        for note in chunk.notes {
            let w0 = note.start - chunk.start + 0.08   // ignore onset scoop
            let w1 = note.end - chunk.start
            let windowDur = max(0.01, w1 - w0)
            let samples = sungSamples.filter { $0.t >= w0 && $0.t <= w1 }
            let target = targetMidi(note)
            let hits = samples.filter {
                abs($0.midi - target) * 100 <= Self.hitBandCents
            }
            // sample cadence ≈ one per audio tap (~86ms); expected count:
            let expected = max(1.0, windowDur / 0.09)
            let hitRatio = min(1.0, Double(hits.count) / expected)
            let voicedRatio = min(1.0, Double(samples.count) / expected)
            let r = NoteResult(noteID: note.start, hitRatio: hitRatio, voicedRatio: voicedRatio)
            results[note.start] = r
            if r.passed { passed += 1 }
        }
        let s = chunk.notes.isEmpty ? 0 : Double(passed) / Double(chunk.notes.count)
        chunkScore = s
        if s > (bestChunkScore[chunkIndex] ?? 0) {
            bestChunkScore[chunkIndex] = s
            let dict = Dictionary(uniqueKeysWithValues: bestChunkScore.map { (String($0.key), $0.value) })
            UserDefaults.standard.set(dict, forKey: "song.scores.\(trackID)")
        }
    }

    // MARK: - Clock

    /// Drives `cursor` from `offset` (negative = lead-in) to `total`.
    private func startClock(offset: Double, total: Double, done: @escaping () -> Void) {
        clockStart = ProcessInfo.processInfo.systemUptime - offset
        displayTimer?.invalidate()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                let t = ProcessInfo.processInfo.systemUptime - self.clockStart
                self.cursor = t
                if self.phase == .leadIn && t >= 0 { self.phase = .singing }
                if t >= total {
                    timer.invalidate()
                    self.displayTimer = nil
                    done()
                }
            }
        }
    }

    func stopAll() {
        displayTimer?.invalidate()
        displayTimer = nil
        pitchSub = nil
        playerNode.stop()
        if phase == .listening || phase == .leadIn || phase == .singing {
            phase = .idle
            cursor = 0
        }
    }
}
