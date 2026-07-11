import Foundation
import Combine

/// Interval training, two drills:
///  - Hear: root + second note play, name the interval (multiple choice
///    from the unlocked set).
///  - Sing: root plays, produce the named interval above it; the mic
///    scores a stable hold against the target.
///
/// Progressive unlock, ordered by distinctiveness: 10 of the last 12
/// hear-answers correct unlocks the next interval. Sing mode uses a
/// generous ±50 cent hit band and stable-hold capture — this drills
/// production, it is not the exam (Recall is the exam).
@MainActor
final class IntervalModel: ObservableObject {

    struct IntervalDef {
        let name: String
        let short: String
        let semitones: Int
        let hint: String
    }

    /// In unlock order.
    static let intervals: [IntervalDef] = [
        .init(name: "Unison",        short: "U",  semitones: 0,  hint: "same note twice"),
        .init(name: "Perfect 5th",   short: "P5", semitones: 7,  hint: "Twinkle Twinkle (twin–kle)"),
        .init(name: "Octave",        short: "P8", semitones: 12, hint: "Somewhere Over the Rainbow (some–where)"),
        .init(name: "Major 3rd",     short: "M3", semitones: 4,  hint: "Oh When the Saints (oh–when)"),
        .init(name: "Perfect 4th",   short: "P4", semitones: 5,  hint: "Here Comes the Bride (here–comes)"),
        .init(name: "Minor 3rd",     short: "m3", semitones: 3,  hint: "Greensleeves (a–las)"),
        .init(name: "Major 2nd",     short: "M2", semitones: 2,  hint: "Happy Birthday (hap–py)"),
        .init(name: "Major 6th",     short: "M6", semitones: 9,  hint: "My Bonnie (my–bon)"),
        .init(name: "Minor 2nd",     short: "m2", semitones: 1,  hint: "Jaws theme"),
        .init(name: "Minor 7th",     short: "m7", semitones: 10, hint: "Star Trek TOS theme"),
        .init(name: "Major 7th",     short: "M7", semitones: 11, hint: "Take On Me (take–on)"),
        .init(name: "Tritone",       short: "TT", semitones: 6,  hint: "The Simpsons (the–simp)"),
    ]

    enum Mode: String, CaseIterable { case hear = "Hear", sing = "Sing" }

    enum Phase: Equatable {
        case idle
        case playing(second: Bool)
        case answering
        case hearFeedback(correct: Bool, answerIndex: Int)
        case singRoot
        case singListening
        case singResult(cents: Double, hit: Bool)
        case timeout
        case failed(String)
    }

    // MARK: - Published
    @Published var mode: Mode = .hear
    @Published var phase: Phase = .idle
    @Published var unlockedCount: Int {
        didSet { UserDefaults.standard.set(unlockedCount, forKey: "iv.unlocked") }
    }
    @Published var currentIndex = 1      // interval being asked (index into intervals)
    @Published var hearTrials = 0
    @Published var hearCorrect = 0
    @Published var singTrials = 0
    @Published var singHits = 0
    @Published var stability: Double = 0 // sing capture progress
    @Published var showHint = false

    var unlocked: [Int] { Array(0..<unlockedCount) }
    var current: IntervalDef { Self.intervals[currentIndex] }
    var hearAccuracy: Double { hearTrials > 0 ? Double(hearCorrect) / Double(hearTrials) : 0 }
    var singAccuracy: Double { singTrials > 0 ? Double(singHits) / Double(singTrials) : 0 }

    static let singHitBand: Double = 50   // cents
    static let holdSeconds: Double = 1.0

    // MARK: - Private
    private let engine: PitchEngine
    private let tone = TonePlayer()
    private var task: Task<Void, Never>?
    private var rootMidi: Double = 57
    private var recentHear: [Bool] = []

    init(engine: PitchEngine) {
        self.engine = engine
        let stored = UserDefaults.standard.integer(forKey: "iv.unlocked")
        unlockedCount = min(max(stored, 3), Self.intervals.count) // start with U, P5, P8
    }

    // MARK: - Trial control
    func startTrial() {
        task?.cancel()
        showHint = false
        currentIndex = unlocked.randomElement() ?? 0
        task = Task {
            switch mode {
            case .hear: await runHear()
            case .sing: await runSing()
            }
        }
    }

    func replay() {
        guard mode == .hear, phase == .answering else { return }
        task?.cancel()
        task = Task { await playHearPair() }
    }

    func playTarget() {
        // available in sing feedback: hear what the target was
        let target = rootMidi + Double(current.semitones)
        task?.cancel()
        task = Task { await tone.play(midiFloat: target, duration: 1.0) }
    }

    func cancel() {
        task?.cancel()
        stability = 0
        phase = .idle
    }

    // MARK: - Hear drill
    private func runHear() async {
        rootMidi = Double(Int.random(in: 48...(72 - current.semitones)))
        await playHearPair()
    }

    private func playHearPair() async {
        phase = .playing(second: false)
        await tone.play(midiFloat: rootMidi)
        if Task.isCancelled { return }
        try? await Task.sleep(nanoseconds: 250_000_000)
        if Task.isCancelled { return }
        phase = .playing(second: true)
        await tone.play(midiFloat: rootMidi + Double(current.semitones))
        if Task.isCancelled { return }
        phase = .answering
    }

    func answerHear(index: Int) {
        guard phase == .answering else { return }
        let correct = (index == currentIndex)
        hearTrials += 1
        if correct { hearCorrect += 1 }

        recentHear.append(correct)
        if recentHear.count > 12 { recentHear.removeFirst() }
        if recentHear.count == 12,
           recentHear.filter({ $0 }).count >= 10,
           unlockedCount < Self.intervals.count {
            unlockedCount += 1
            recentHear = []
        }
        phase = .hearFeedback(correct: correct, answerIndex: index)
    }

    // MARK: - Sing drill
    private func runSing() async {
        if !engine.isRunning { await engine.start() }
        guard engine.isRunning else {
            phase = .failed(engine.micDenied
                ? "mic access denied — enable in Settings"
                : (engine.lastError ?? "mic failed to start"))
            return
        }

        // root sampled so root AND target sit inside the trained range
        let d = UserDefaults.standard
        let lo = d.object(forKey: "recall.lo") as? Int ?? 45
        let hi = d.object(forKey: "recall.hi") as? Int ?? 64
        let span = current.semitones
        let maxRoot = max(lo, hi - span)
        rootMidi = Double(Int.random(in: min(lo, maxRoot)...maxRoot))

        phase = .singRoot
        engine.playReference(midi: Int(rootMidi))
        try? await Task.sleep(nanoseconds: 1_800_000_000)
        if Task.isCancelled { return }

        phase = .singListening
        let target = rootMidi + Double(span)
        guard let sung = await captureStableHold(deadline: 8.0) else {
            if !Task.isCancelled { phase = .timeout }
            return
        }

        let cents = (sung - target) * 100
        let hit = abs(cents) <= Self.singHitBand
        singTrials += 1
        if hit { singHits += 1 }
        phase = .singResult(cents: cents, hit: hit)
    }

    /// Stable-hold capture (training-grade): median once held within
    /// ±0.5 semitone for the hold window. Nil on cancel or deadline.
    private func captureStableHold(deadline: Double) async -> Double? {
        var window: [(t: TimeInterval, m: Double)] = []
        stability = 0
        let hardDeadline = Date().addingTimeInterval(deadline)

        while Date() < hardDeadline {
            if Task.isCancelled { return nil }
            let now = ProcessInfo.processInfo.systemUptime

            if let m = engine.detectedMidiFloat {
                window.append((now, m))
            } else if let last = window.last, now - last.t > 0.3 {
                window = []
                stability = 0
            }
            window.removeAll { now - $0.t > Self.holdSeconds }

            if window.count >= 6, let first = window.first {
                let span = now - first.t
                let sorted = window.map(\.m).sorted()
                let median = sorted[sorted.count / 2]
                if window.allSatisfy({ abs($0.m - median) <= 0.5 }) {
                    stability = min(1, span / Self.holdSeconds)
                    if span >= Self.holdSeconds * 0.98 {
                        stability = 0
                        return median
                    }
                } else {
                    stability = 0
                }
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        stability = 0
        return nil
    }
}
