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
    private static let breathGapSeconds: Double = 0.35
    private static let targetChunkSeconds: Double = 10.0
    private static let maxChunkSeconds: Double = 12.0

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

    /// Phrase-aware chunking: split at breath gaps, keep phrases whole,
    /// pack them into ~10s chunks. Only split inside a phrase when it
    /// alone exceeds the max — at its largest, most central gap.
    private static func makeChunks(_ notes: [MelodyTrack.Note]) -> [Chunk] {
        guard !notes.isEmpty else { return [] }

        // 1. phrases = runs of notes separated by breath-sized gaps
        var phrases: [[MelodyTrack.Note]] = []
        var cur: [MelodyTrack.Note] = [notes[0]]
        for n in notes.dropFirst() {
            if n.start - cur.last!.end >= breathGapSeconds {
                phrases.append(cur)
                cur = [n]
            } else {
                cur.append(n)
            }
        }
        phrases.append(cur)

        // 2. split any phrase longer than maxChunk at its best internal gap
        func splitLong(_ p: [MelodyTrack.Note]) -> [[MelodyTrack.Note]] {
            guard p.count > 1, p.last!.end - p[0].start > maxChunkSeconds else { return [p] }
            var bestIdx = p.count / 2
            var bestScore = -1.0
            for i in 1..<p.count {
                let gap = max(0, p[i].start - p[i - 1].end)
                let centrality = 1 - abs(Double(i) / Double(p.count) - 0.5)
                let score = (gap + 0.01) * centrality
                if score > bestScore { bestScore = score; bestIdx = i }
            }
            return splitLong(Array(p[..<bestIdx])) + splitLong(Array(p[bestIdx...]))
        }
        let units = phrases.flatMap(splitLong)

        // 3. pack units into chunks up to the target span
        var out: [Chunk] = []
        var acc: [MelodyTrack.Note] = []
        func flush() {
            guard !acc.isEmpty else { return }
            out.append(Chunk(index: out.count, start: acc[0].start,
                             end: acc.last!.end, notes: acc))
            acc = []
        }
        for u in units {
            if acc.isEmpty { acc = u; continue }
            if u.last!.end - acc[0].start > targetChunkSeconds {
                flush()
                acc = u
            } else {
                acc.append(contentsOf: u)
            }
        }
        flush()
        return out.enumerated().map {
            Chunk(index: $0.offset, start: $0.element.start,
                  end: $0.element.end, notes: $0.element.notes)
        }
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

        if !fillFromFrames(data: data, totalFrames: Int(frames), sr: sr) {
            fillFromNotes(data: data, totalFrames: Int(frames), sr: sr)
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

    /// Frame-curve synthesis: follows the raw pYIN pitch track with a
    /// phase-continuous oscillator, so scoops, glides, and vibrato play
    /// back as a voice moves — not as quantized note jumps. Returns
    /// false when the track has no usable frames in this chunk.
    private func fillFromFrames(data: UnsafeMutablePointer<Float>, totalFrames: Int, sr: Double) -> Bool {
        guard let f = track.frames, f.t.count > 2 else { return false }

        // Clip frames to the chunk (with a hair of margin).
        var ft: [Double] = []
        var fm: [Double?] = []
        for (i, t) in f.t.enumerated() where t >= chunk.start - 0.05 && t <= chunk.end + 0.05 {
            ft.append(t)
            fm.append(f.midi[i].map { $0 + Double(transpose) })
        }
        guard ft.count > 2, fm.contains(where: { $0 != nil }) else { return false }

        // Bridge short unvoiced gaps (consonants): a voice glides
        // through them, so interpolate pitch across gaps <= 0.15s.
        var i = 0
        while i < fm.count {
            guard fm[i] == nil else { i += 1; continue }
            let gapStart = i
            while i < fm.count, fm[i] == nil { i += 1 }
            let gapEnd = i
            if gapStart > 0, gapEnd < fm.count,
               ft[gapEnd] - ft[gapStart - 1] <= 0.15,
               let a = fm[gapStart - 1], let b = fm[gapEnd] {
                for j in gapStart..<gapEnd {
                    let frac = (ft[j] - ft[gapStart - 1]) / (ft[gapEnd] - ft[gapStart - 1])
                    fm[j] = a + (b - a) * frac
                }
            }
        }

        let t0 = ft[0]
        let hop = (ft.last! - t0) / Double(ft.count - 1)
        guard hop > 0 else { return false }

        var phase: Double = 0
        var amp: Double = 0
        var voicedTime: Double = 0
        var gains = [Double](repeating: 0, count: Self.harmonicCount)
        var gainF0: Double = -1
        let slew = 1 - exp(-1.0 / (sr * 0.010))   // ~10ms attack/release

        for n in 0..<totalFrames {
            let t = chunk.start + Double(n) / sr
            let p = (t - t0) / hop
            let j = Int(p.rounded(.down))
            var midi: Double? = nil
            if j >= 0, j + 1 < fm.count, let a = fm[j], let b = fm[j + 1] {
                midi = a + (b - a) * (p - Double(j))
            } else if j >= 0, j < fm.count {
                midi = fm[j]
            }

            amp += ((midi != nil ? 1.0 : 0.0) - amp) * slew
            if let m = midi {
                voicedTime += 1 / sr
                var f = PitchEngine.midiToFreq(m)
                f *= Self.vibratoFactor(voicedTime: voicedTime)
                if abs(f - gainF0) > 1.5 || n % 128 == 0 {
                    Self.formantGains(f0: f, into: &gains)
                    gainF0 = f
                }
                phase += 2 * Double.pi * f / sr
                if phase > 2 * Double.pi * 1000 { phase -= 2 * Double.pi * 1000 }
            } else {
                voicedTime = 0
            }
            if amp > 0.0005 {
                data[n] += Float(Self.tone(phase: phase, gains: gains) * amp)
            }
        }
        return true
    }

    // MARK: - Voice-like tone

    /// A static harmonic stack sounds like an organ. Shape the harmonics
    /// with resonance bumps near the first formants of an "ah" vowel
    /// (~730 / 1090 / 2450 Hz) — voice-like, and it concentrates energy
    /// where phone speakers actually reproduce.
    private static let harmonicCount = 8

    nonisolated private static func formantGains(f0: Double, into gains: inout [Double]) {
        func bump(_ f: Double, _ c: Double, _ w: Double) -> Double {
            let d = (f - c) / w
            return exp(-d * d)
        }
        var total = 0.0
        for k in 1...harmonicCount {
            let fk = f0 * Double(k)
            let g = pow(Double(k), -0.8)
                * (1 + 1.3 * bump(fk, 730, 140)
                     + 0.9 * bump(fk, 1090, 170)
                     + 0.35 * bump(fk, 2450, 320))
            gains[k - 1] = g
            total += g
        }
        let norm = 0.55 / max(0.0001, total)
        for k in 0..<harmonicCount { gains[k] *= norm }
    }

    /// Delayed vibrato: onset ~0.25s into sustained voicing, ±7 cents
    /// at 5.3 Hz — well inside the ±50¢ scoring band, so the reference
    /// stays honest while sounding sung rather than held by a machine.
    nonisolated private static func vibratoFactor(voicedTime: Double) -> Double {
        let depth = min(1, max(0, (voicedTime - 0.25) / 0.4)) * 7.0  // cents
        guard depth > 0 else { return 1 }
        let cents = sin(2 * Double.pi * 5.3 * voicedTime) * depth
        return pow(2, cents / 1200)
    }

    nonisolated private static func tone(phase: Double, gains: [Double]) -> Double {
        var out = 0.0
        for k in 0..<harmonicCount {
            out += gains[k] * sin(Double(k + 1) * phase)
        }
        return out
    }

    /// Fallback for tracks without frame data: segmented notes with
    /// legato stretching and a harmonic-rich tone.
    private func fillFromNotes(data: UnsafeMutablePointer<Float>, totalFrames: Int, sr: Double) {
        let sorted = chunk.notes
        for (i, note) in sorted.enumerated() {
            let freq = PitchEngine.midiToFreq(targetMidi(note))
            let n0 = Int((note.start - chunk.start) * sr)
            var nDur = note.duration
            if i + 1 < sorted.count {
                let gap = sorted[i + 1].start - note.end
                if gap > 0, gap < 0.25 { nDur += gap }
            }
            let nFrames = Int(nDur * sr)
            var phase: Double = 0
            var gains = [Double](repeating: 0, count: Self.harmonicCount)
            Self.formantGains(f0: freq, into: &gains)
            for j in 0..<nFrames where n0 + j < totalFrames {
                let t = Double(j) / sr
                var env = 1.0
                if t < 0.02 { env = t / 0.02 }
                if t > nDur - 0.05 { env = max(0, (nDur - t) / 0.05) }
                let f = freq * Self.vibratoFactor(voicedTime: t)
                phase += 2 * Double.pi * f / sr
                data[n0 + j] += Float(Self.tone(phase: phase, gains: gains) * env)
            }
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
