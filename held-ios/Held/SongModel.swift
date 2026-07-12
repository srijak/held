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

    enum Source: String, CaseIterable {
        case vocal, backing, both, synth
        var title: String {
            switch self {
            case .vocal: return "Vocal"
            case .backing: return "Backing"
            case .both: return "Vocal + Backing"
            case .synth: return "Synth"
            }
        }
        var icon: String {
            switch self {
            case .vocal: return "waveform"
            case .backing: return "music.note"
            case .both: return "music.mic"
            case .synth: return "tuningfork"
            }
        }
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
    private(set) var singingAlong = false
    private var latencyOffset: Double = 0
    /// How far the display clock should lag behind the internal clock so
    /// bars/now-line match what the ear is hearing. Audio arrives
    /// outputLatency after render — trivial on speaker, 100-200ms on
    /// Bluetooth, and without this the visuals lead the voice.
    @Published private(set) var displayLatency: Double = 0
    @Published var source: Source {
        didSet { UserDefaults.standard.set(source.rawValue, forKey: "song.source") }
    }
    @Published var sungSamples: [SungSample] = []
    @Published var results: [Double: NoteResult] = [:]   // keyed by note.start
    @Published var chunkScore: Double?                   // 0..1 passed-note ratio
    /// Continuous-run span: playback/singing starts at the selected
    /// phrase and runs to the end of the song (or to the phrase end
    /// when loop is on). Phrases are entry points, not walls.
    @Published private(set) var spanStart: Double = 0
    private var spanEnd: Double = 0
    @Published var bestChunkScore: [Int: Double] = [:]

    let track: MelodyTrack
    let chunks: [Chunk]
    private let trackID: String

    // MARK: - Constants
    static let hitBandCents: Double = 50
    static let legatoMaxGap: Double = 2.0
    static let leadInSeconds: Double = 1.2
    private static let breathGapSeconds: Double = 0.35
    private static let targetChunkSeconds: Double = 10.0
    private static let maxChunkSeconds: Double = 12.0

    // MARK: - Audio / timing
    private let playEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var playerConfigured = false
    private let filePlayerNode = AVAudioPlayerNode()
    private let backingPlayerNode = AVAudioPlayerNode()
    private var configuredNodes = Set<ObjectIdentifier>()
    private var synthTask: Task<Void, Never>?
    private let vocalFile: AVAudioFile?
    private let backingFile: AVAudioFile?
    var hasAudio: Bool { vocalFile != nil || backingFile != nil }
    var availableSources: [Source] {
        var out: [Source] = []
        if vocalFile != nil { out.append(.vocal) }
        if backingFile != nil { out.append(.backing) }
        if vocalFile != nil && backingFile != nil { out.append(.both) }
        out.append(.synth)
        return out
    }
    private var clockStart: TimeInterval = 0
    private var displayTimer: Timer?
    private var pitchSub: AnyCancellable?
    private weak var pitchEngine: PitchEngine?

    init(track: MelodyTrack, trackID: String, pitchEngine: PitchEngine,
         audioURL: URL? = nil, backingURL: URL? = nil) {
        self.track = track
        self.trackID = trackID
        self.pitchEngine = pitchEngine
        self.vocalFile = audioURL.flatMap { try? AVAudioFile(forReading: $0) }
        self.backingFile = backingURL.flatMap { try? AVAudioFile(forReading: $0) }
        let saved = UserDefaults.standard.string(forKey: "song.source")
            .flatMap(Source.init(rawValue:)) ?? .vocal
        self.source = saved
        self.chunks = Self.makeChunks(track.notes)
        self.transpose = UserDefaults.standard.object(forKey: "song.transpose.\(trackID)") as? Int ?? 0
        if !((self.source == .vocal && self.vocalFile != nil)
            || (self.source == .backing && self.backingFile != nil)
            || (self.source == .both && self.vocalFile != nil && self.backingFile != nil)
            || self.source == .synth) {
            self.source = self.vocalFile != nil ? .vocal : .synth
        }
        let saved2 = UserDefaults.standard.dictionary(forKey: "song.scores.\(trackID)") as? [String: Double] ?? [:]
        self.bestChunkScore = Dictionary(uniqueKeysWithValues: saved2.compactMap {
            guard let k = Int($0.key) else { return nil }
            return (k, $0.value)
        })
    }

    var spanNotes: [MelodyTrack.Note] {
        track.notes.filter { $0.start >= spanStart - 0.01 && $0.start < spanEnd + 0.01 }
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
        displayLatency = 0
        spanStart = chunk.start
        spanEnd = chunk.end
        sungSamples = []
        results = [:]
        chunkScore = nil
        phase = .idle
    }

    private func computeSpan() {
        spanStart = chunk.start
        spanEnd = loop ? chunk.end : (track.notes.last?.displayEnd ?? chunk.end)
        // With real audio the timeline is the RECORDING, not the notes:
        // backing runs through intros, breaks, and outros.
        guard source != .synth, !loop else { return }
        var audioDur = 0.0
        if source != .backing, let f = vocalFile {
            audioDur = max(audioDur, Double(f.length) / f.processingFormat.sampleRate)
        }
        if source != .vocal, let f = backingFile {
            audioDur = max(audioDur, Double(f.length) / f.processingFormat.sampleRate)
        }
        guard audioDur > 0 else { return }
        spanEnd = max(spanEnd, audioDur)
        if chunkIndex == 0 { spanStart = 0 }
    }

    // MARK: - Listen (synth playback)

    func listen() {
        stopAll()
        resetAttempt()
        computeSpan()

        let files = playbackFiles()
        if files.isEmpty {
            guard startSynthPlayback(at: nil) else { return }
            displayLatency = AVAudioSession.sharedInstance().outputLatency
            phase = .listening
            startClock(offset: 0, total: spanEnd - spanStart) { [weak self] in
                self?.phase = .idle
                self?.cursor = 0
            }
            return
        }

        let preRoll = min(1.0, spanStart)
        let when = AVAudioTime(
            hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.08))
        guard scheduleFiles(files, preRoll: preRoll, at: when) else { return }
        displayLatency = AVAudioSession.sharedInstance().outputLatency
        phase = .listening
        startClock(offset: -preRoll, total: spanEnd - spanStart) { [weak self] in
            self?.phase = .idle
            self?.cursor = 0
        }
    }

    private func playbackFiles() -> [(AVAudioPlayerNode, AVAudioFile)] {
        var out: [(AVAudioPlayerNode, AVAudioFile)] = []
        if source == .vocal || source == .both, let f = vocalFile {
            out.append((filePlayerNode, f))
        }
        if source == .backing || source == .both, let f = backingFile {
            out.append((backingPlayerNode, f))
        }
        return out
    }

    /// Schedules every file at the same hostTime so multi-stem playback
    /// (vocal + backing) stays sample-locked.
    @discardableResult
    private func scheduleFiles(_ files: [(AVAudioPlayerNode, AVAudioFile)],
                               preRoll: Double, at when: AVAudioTime) -> Bool {
        var ok = false
        for (node, file) in files {
            guard (try? ensureNode(node, format: file.processingFormat)) != nil else { continue }
            let sr = file.processingFormat.sampleRate
            let startT = max(0, spanStart - preRoll)
            let startFrame = AVAudioFramePosition(startT * sr)
            let avail = Double(file.length) - Double(startFrame)
            let count = AVAudioFrameCount(max(0, min((spanEnd - startT + 0.15) * sr, avail)))
            guard count > 0 else { continue }
            node.stop()
            node.scheduleSegment(file, startingFrame: startFrame,
                                 frameCount: count, at: nil)
            node.play(at: when)
            ok = true
        }
        return ok
    }

    /// Target pitch segments: transpose + word-edge (vstart/vend) logic.
    private func legatoSegs() -> [LegatoSynth.Seg] {
        let notes = spanNotes
        guard !notes.isEmpty else { return [] }
        var segs: [LegatoSynth.Seg] = []
        for (i, n) in notes.enumerated() {
            var start = n.start
            if i == 0 || n.start - notes[i - 1].end > Self.legatoMaxGap {
                start = n.displayStart
            }
            var end = n.end
            if i + 1 < notes.count,
               notes[i + 1].start - n.end <= Self.legatoMaxGap {
                end = notes[i + 1].start
            } else {
                end = n.displayEnd
            }
            segs.append(LegatoSynth.Seg(start: start, end: end, midi: targetMidi(n)))
        }
        return segs
    }

    /// Synth playback streams in ~4s blocks: the first renders
    /// synchronously (fast), the rest in a background task appending to
    /// the player queue. A full song is minutes of audio — rendering it
    /// all up front froze the UI for seconds.
    private func startSynthPlayback(at when: AVAudioTime?) -> Bool {
        guard (try? ensurePlayer()) != nil else { return false }
        let segs = legatoSegs()
        guard !segs.isEmpty else { return false }
        let sr = playEngine.mainMixerNode.outputFormat(forBus: 0).sampleRate
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)
        else { return false }
        let synth = LegatoSynth(segs: segs, sr: sr, startTime: spanStart)
        var remaining = Int(((spanEnd - spanStart) + 0.3) * sr)
        let blockFrames = Int(4.0 * sr)

        guard let first = Self.renderBlock(synth, frames: min(blockFrames, remaining),
                                           format: fmt) else { return false }
        remaining -= Int(first.frameLength)
        playerNode.stop()
        playerNode.scheduleBuffer(first, at: nil)
        if let when { playerNode.play(at: when) } else { playerNode.play() }

        synthTask?.cancel()
        if remaining > 0 {
            let node = playerNode
            synthTask = Task.detached(priority: .userInitiated) {
                var left = remaining
                while left > 0, !Task.isCancelled {
                    guard let buf = Self.renderBlock(
                        synth, frames: min(blockFrames, left), format: fmt)
                    else { return }
                    left -= Int(buf.frameLength)
                    await MainActor.run {
                        if !Task.isCancelled { node.scheduleBuffer(buf, at: nil) }
                    }
                }
            }
        }
        return true
    }

    nonisolated private static func renderBlock(
        _ synth: LegatoSynth, frames: Int, format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard frames > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(frames))
        else { return nil }
        buf.frameLength = AVAudioFrameCount(frames)
        let data = buf.floatChannelData![0]
        for i in 0..<frames { data[i] = 0 }
        synth.render(into: data, frames: frames)
        return buf
    }

    // MARK: - Voice-like tone

    /// A static harmonic stack sounds like an organ. Shape the harmonics
    /// with resonance bumps near the first formants of an "ah" vowel
    /// (~730 / 1090 / 2450 Hz) — voice-like, and it concentrates energy
    /// where phone speakers actually reproduce.
    fileprivate static let harmonicCount = 8

    nonisolated fileprivate static func formantGains(f0: Double, into gains: inout [Double]) {
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
    nonisolated fileprivate static func vibratoFactor(voicedTime: Double) -> Double {
        let depth = min(1, max(0, (voicedTime - 0.25) / 0.4)) * 7.0  // cents
        guard depth > 0 else { return 1 }
        let cents = sin(2 * Double.pi * 5.3 * voicedTime) * depth
        return pow(2, cents / 1200)
    }

    nonisolated fileprivate static func tone(phase: Double, gains: [Double]) -> Double {
        var out = 0.0
        for k in 0..<harmonicCount {
            out += gains[k] * sin(Double(k + 1) * phase)
        }
        return out
    }

    private func ensureNode(_ node: AVAudioPlayerNode, format: AVAudioFormat) throws {
        if !configuredNodes.contains(ObjectIdentifier(node)) {
            playEngine.attach(node)
            playEngine.connect(node, to: playEngine.mainMixerNode, format: format)
            configuredNodes.insert(ObjectIdentifier(node))
        }
        try startEngineIfNeeded()
    }

    private func ensurePlayer() throws {
        if !playerConfigured {
            playEngine.attach(playerNode)
            let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)
            playEngine.connect(playerNode, to: playEngine.mainMixerNode, format: fmt)
            playerConfigured = true
        }
        try startEngineIfNeeded()
    }

    private func startEngineIfNeeded() throws {
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
    /// `along: true` plays the reference (real vocal or synth, per the
    /// source toggle) in sync while the mic scores — a headphones
    /// feature: on speaker the playback bleeds into the detector.
    func sing(along: Bool = false) {
        guard let engine = pitchEngine, engine.isRunning else { return }
        stopAll()
        resetAttempt()
        singingAlong = along
        computeSpan()
        phase = .leadIn

        // You sing in time with what you HEAR. Over Bluetooth that
        // arrives late, so shift sung samples back by the round trip
        // or every note scores "late" through no fault of the singer.
        let session = AVAudioSession.sharedInstance()
        latencyOffset = along ? session.outputLatency + session.inputLatency : 0
        displayLatency = along ? session.outputLatency : 0

        if along { scheduleAlongPlayback() }

        pitchSub = engine.$detectedMidiFloat.sink { [weak self] midi in
            guard let self, self.phase == .singing, let midi else { return }
            let t = ProcessInfo.processInfo.systemUptime - self.clockStart - self.latencyOffset
            self.sungSamples.append(SungSample(t: t, midi: midi))
        }

        startClock(offset: -Self.leadInSeconds, total: spanEnd - spanStart) { [weak self] in
            self?.finishSing()
        }
    }

    /// Sample-accurate start at the end of the count-in via hostTime.
    private func scheduleAlongPlayback() {
        let when = AVAudioTime(
            hostTime: mach_absolute_time()
                + AVAudioTime.hostTime(forSeconds: Self.leadInSeconds))
        let files = playbackFiles()
        if files.isEmpty {
            _ = startSynthPlayback(at: when)
        } else {
            // run-in plays during the count-in: audio position spanStart
            // still lands exactly at clock zero
            let preRoll = min(1.0, spanStart, Self.leadInSeconds)
            let runIn = AVAudioTime(
                hostTime: mach_absolute_time()
                    + AVAudioTime.hostTime(forSeconds: Self.leadInSeconds - preRoll))
            scheduleFiles(files, preRoll: preRoll, at: runIn)
        }
    }

    private func finishSing() {
        pitchSub = nil
        finalizeScores()
        phase = .scored
        if loop {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                guard let self, self.phase == .scored, self.loop else { return }
                self.sing(along: self.singingAlong)
            }
        }
    }

    private func scoreNote(_ note: MelodyTrack.Note) -> NoteResult {
        let w0 = note.start - spanStart + 0.08   // ignore onset scoop
        let w1 = note.end - spanStart
        let windowDur = max(0.01, w1 - w0)
        let samples = sungSamples.filter { $0.t >= w0 && $0.t <= w1 }
        let target = targetMidi(note)
        let hits = samples.filter {
            abs($0.midi - target) * 100 <= Self.hitBandCents
        }
        let expected = max(1.0, windowDur / 0.09)
        return NoteResult(
            noteID: note.start,
            hitRatio: min(1.0, Double(hits.count) / expected),
            voicedRatio: min(1.0, Double(samples.count) / expected)
        )
    }

    private func finalizeScores() {
        let notes = spanNotes
        for note in notes where results[note.start] == nil {
            results[note.start] = scoreNote(note)
        }
        guard !notes.isEmpty else { chunkScore = nil; return }
        let passed = notes.filter { results[$0.start]?.passed == true }.count
        chunkScore = Double(passed) / Double(notes.count)

        // persist best score per phrase touched by this run
        var dirty = false
        for (i, phrase) in chunks.enumerated()
        where phrase.start >= spanStart - 0.01 && phrase.start < spanEnd {
            let pnotes = phrase.notes
            guard !pnotes.isEmpty,
                  pnotes.allSatisfy({ results[$0.start] != nil }) else { continue }
            let p = Double(pnotes.filter { results[$0.start]?.passed == true }.count)
                / Double(pnotes.count)
            if p > (bestChunkScore[i] ?? 0) {
                bestChunkScore[i] = p
                dirty = true
            }
        }
        if dirty {
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
                self.onTick(t)
                if t >= total {
                    timer.invalidate()
                    self.displayTimer = nil
                    done()
                }
            }
        }
    }

    /// While a run is in flight: keep the phrase selector following the
    /// playhead, and score each note live as it passes the now-line.
    private func onTick(_ t: Double) {
        guard phase == .singing || phase == .listening else { return }
        let now = spanStart + t
        if let idx = chunks.lastIndex(where: { $0.start <= now + 0.01 }),
           idx != chunkIndex, now <= spanEnd {
            chunkIndex = idx
        }
        if phase == .singing {
            for note in spanNotes
            where results[note.start] == nil && note.end < now - 0.05 {
                results[note.start] = scoreNote(note)
            }
        }
    }

    func stopAll() {
        displayTimer?.invalidate()
        displayTimer = nil
        pitchSub = nil
        synthTask?.cancel()
        synthTask = nil
        playerNode.stop()
        filePlayerNode.stop()
        backingPlayerNode.stop()
        if phase == .listening || phase == .leadIn || phase == .singing {
            phase = .idle
            cursor = 0
        }
    }
}


/// Streamed clean-reference synthesizer: a pure state machine rendering
/// successive blocks, so phase, glide, and amplitude carry seamlessly
/// across buffer seams. Vibrato and formant gains update per 64-sample
/// block instead of per sample — inaudible at 1.5ms granularity, ~10x
/// cheaper.
private final class LegatoSynth: @unchecked Sendable {
    struct Seg { let start: Double; let end: Double; let midi: Double }

    private let segs: [Seg]
    private let sr: Double
    private var t: Double
    private var idx = 0
    private var phase = 0.0
    private var amp = 0.0
    private var smoothed = 0.0
    private var voicedTime = 0.0
    private var haveVoice = false
    private var gains = [Double](repeating: 0, count: SongModel.harmonicCount)
    private var gainF0 = -1.0
    private let ampSlew: Double

    init(segs: [Seg], sr: Double, startTime: Double) {
        self.segs = segs
        self.sr = sr
        self.t = startTime
        self.ampSlew = 1 - exp(-1.0 / (sr * 0.012))
    }

    func render(into data: UnsafeMutablePointer<Float>, frames: Int) {
        var n = 0
        while n < frames {
            let block = min(64, frames - n)
            while idx + 1 < segs.count, t >= segs[idx + 1].start { idx += 1 }
            var target: Double?
            if idx < segs.count, t >= segs[idx].start, t < segs[idx].end {
                target = segs[idx].midi
            }
            var inc = 0.0
            if let m = target {
                if !haveVoice {
                    smoothed = m - 0.8   // onset scoop from below
                    haveVoice = true
                    voicedTime = 0
                }
                let glideK = 1 - exp(-Double(block) / (sr * 0.030))
                smoothed += (m - smoothed) * glideK
                voicedTime += Double(block) / sr
                var f = PitchEngine.midiToFreq(smoothed)
                f *= SongModel.vibratoFactor(voicedTime: voicedTime)
                if abs(f - gainF0) > 1.5 {
                    SongModel.formantGains(f0: f, into: &gains)
                    gainF0 = f
                }
                inc = 2 * Double.pi * f / sr
            } else {
                haveVoice = false
            }
            let ampTarget: Double = target != nil ? 1.0 : 0.0
            for i in 0..<block {
                amp += (ampTarget - amp) * ampSlew
                if inc > 0 { phase += inc }
                if amp > 0.0005 {
                    data[n + i] += Float(SongModel.tone(phase: phase, gains: gains) * amp)
                }
            }
            if phase > 2 * Double.pi * 1000 { phase -= 2 * Double.pi * 1000 }
            t += Double(block) / sr
            n += block
        }
    }
}
