import Foundation
import Combine

/// Delayed-recall trial state machine.
///
/// Flow: random target in range -> reference plays ONCE -> enforced
/// silent delay (no replay) -> SING -> capture first 500ms of voicing
/// -> score the median against the target.
///
/// The delay is the difficulty knob: 3s -> 5s -> 10s. This trains pitch
/// memory and production; the hold-tuner trains sustain. Different
/// skills, different tabs.
@MainActor
final class RecallModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case reference
        case delay(remaining: Int)
        case sing
        case capturing
        case result(cents: Double, hit: Bool)
        case timeout
    }

    // MARK: - Published state
    @Published var phase: Phase = .idle
    @Published var targetMidi: Int = 57

    @Published var delaySeconds: Int {
        didSet { UserDefaults.standard.set(delaySeconds, forKey: "recall.delay") }
    }
    @Published var rangeLo: Int {
        didSet { UserDefaults.standard.set(rangeLo, forKey: "recall.lo") }
    }
    @Published var rangeHi: Int {
        didSet { UserDefaults.standard.set(rangeHi, forKey: "recall.hi") }
    }

    // Session stats
    @Published var trials = 0
    @Published var hits = 0
    @Published var streak = 0
    @Published var bestStreak: Int {
        didSet { UserDefaults.standard.set(bestStreak, forKey: "recall.bestStreak") }
    }
    @Published var absErrors: [Double] = []

    var hitRate: Double { trials > 0 ? Double(hits) / Double(trials) : 0 }
    var medianAbsError: Double? {
        guard !absErrors.isEmpty else { return nil }
        return absErrors.sorted()[absErrors.count / 2]
    }

    static let hitBand: Double = 25      // |cents| for a hit
    static let captureWindow: Double = 0.5
    static let onsetTimeout: Double = 5.0

    private let engine: PitchEngine
    private var trialTask: Task<Void, Never>?

    init(engine: PitchEngine) {
        self.engine = engine
        let d = UserDefaults.standard
        self.delaySeconds = d.object(forKey: "recall.delay") as? Int ?? 3
        self.rangeLo = d.object(forKey: "recall.lo") as? Int ?? 45      // A2
        self.rangeHi = d.object(forKey: "recall.hi") as? Int ?? 64      // E4
        self.bestStreak = d.integer(forKey: "recall.bestStreak")
    }

    // MARK: - Trial control
    func startTrial() {
        trialTask?.cancel()
        trialTask = Task { await runTrial() }
    }

    func cancelTrial() {
        trialTask?.cancel()
        phase = .idle
    }

    func resetSession() {
        cancelTrial()
        trials = 0
        hits = 0
        streak = 0
        absErrors = []
    }

    private func runTrial() async {
        if !engine.isRunning { await engine.start() }
        guard engine.isRunning else { phase = .idle; return }

        let lo = min(rangeLo, rangeHi), hi = max(rangeLo, rangeHi)
        targetMidi = Int.random(in: lo...hi)

        // 1. Reference — plays exactly once, no replay path exists.
        phase = .reference
        engine.playReference(midi: targetMidi)
        if await sleepCancelled(1.8) { return }

        // 2. Enforced silent delay.
        var remaining = delaySeconds
        while remaining > 0 {
            phase = .delay(remaining: remaining)
            if await sleepCancelled(1.0) { return }
            remaining -= 1
        }

        // 3. Wait for voicing onset.
        phase = .sing
        var samples: [Double] = []
        let onsetDeadline = Date().addingTimeInterval(Self.onsetTimeout)
        while Date() < onsetDeadline {
            if let m = engine.detectedMidiFloat {
                samples.append(m)
                break
            }
            if await sleepCancelled(0.03) { return }
        }
        guard !samples.isEmpty else {
            phase = .timeout
            return
        }

        // 4. Capture the first 500ms of voicing. The first landing is
        // what's scored — no listening to yourself and correcting.
        phase = .capturing
        let captureDeadline = Date().addingTimeInterval(Self.captureWindow)
        while Date() < captureDeadline {
            if let m = engine.detectedMidiFloat { samples.append(m) }
            if await sleepCancelled(0.03) { return }
        }

        // 5. Score: median of the capture, in cents from target.
        let median = samples.sorted()[samples.count / 2]
        let cents = (median - Double(targetMidi)) * 100
        let hit = abs(cents) <= Self.hitBand

        trials += 1
        absErrors.append(abs(cents))
        if hit {
            hits += 1
            streak += 1
            bestStreak = max(bestStreak, streak)
        } else {
            streak = 0
        }
        phase = .result(cents: cents, hit: hit)
    }

    /// Sleep helper; returns true if the task was cancelled.
    private func sleepCancelled(_ seconds: Double) async -> Bool {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        return Task.isCancelled
    }
}
