import Foundation
import Combine

/// Pitch discrimination (2AFC): two tones play, answer whether the
/// second was higher or lower. The difference shrinks as you succeed.
///
/// The ladder in cents: 600 -> 300 -> 100 -> 50 -> 25 -> 12.
/// Promotion: 4 of the last 5 at the current level correct.
/// Demotion: 2 consecutive misses.
///
/// Reliably passing 100 cents (one semitone) is the clinical line —
/// congenital amusia means failing at or above a semitone. Most
/// untrained listeners reach 25–50 cents.
@MainActor
final class EarModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case playing(second: Bool)
        case answering
        case feedback(correct: Bool, wasHigher: Bool, deltaCents: Int)
    }

    static let levels = [600, 300, 100, 50, 25, 12] // cents

    @Published var phase: Phase = .idle
    @Published var levelIndex: Int {
        didSet { UserDefaults.standard.set(levelIndex, forKey: "ear.level") }
    }
    @Published var bestLevelIndex: Int {
        didSet { UserDefaults.standard.set(bestLevelIndex, forKey: "ear.bestLevel") }
    }
    @Published var trials = 0
    @Published var correctCount = 0

    // lifetime per-level tallies, for the threshold estimate
    @Published var levelTrials: [Int] {
        didSet { UserDefaults.standard.set(levelTrials, forKey: "ear.levelTrials") }
    }
    @Published var levelCorrect: [Int] {
        didSet { UserDefaults.standard.set(levelCorrect, forKey: "ear.levelCorrect") }
    }

    var currentDelta: Int { Self.levels[levelIndex] }
    var accuracy: Double { trials > 0 ? Double(correctCount) / Double(trials) : 0 }

    /// Smallest level with >=75% accuracy over >=8 lifetime trials.
    var thresholdCents: Int? {
        for i in stride(from: Self.levels.count - 1, through: 0, by: -1) {
            if levelTrials[i] >= 8,
               Double(levelCorrect[i]) / Double(levelTrials[i]) >= 0.75 {
                return Self.levels[i]
            }
        }
        return nil
    }

    private let tone = TonePlayer()
    private var task: Task<Void, Never>?
    private var recentAtLevel: [Bool] = []
    private var baseMidi: Double = 60
    private var secondHigher = true

    init() {
        let d = UserDefaults.standard
        let count = Self.levels.count
        levelIndex = min(d.integer(forKey: "ear.level"), count - 1)
        bestLevelIndex = min(d.integer(forKey: "ear.bestLevel"), count - 1)
        levelTrials = (d.array(forKey: "ear.levelTrials") as? [Int])
            .flatMap { $0.count == count ? $0 : nil } ?? Array(repeating: 0, count: count)
        levelCorrect = (d.array(forKey: "ear.levelCorrect") as? [Int])
            .flatMap { $0.count == count ? $0 : nil } ?? Array(repeating: 0, count: count)
    }

    // MARK: - Trial control
    func startTrial() {
        task?.cancel()
        baseMidi = Double(Int.random(in: 48...72))       // C3–C5, hearing range
        secondHigher = Bool.random()
        task = Task { await playPair() }
    }

    func replay() {
        guard phase == .answering else { return }
        task?.cancel()
        task = Task { await playPair() }
    }

    func cancel() {
        task?.cancel()
        phase = .idle
    }

    private func playPair() async {
        let delta = Double(currentDelta) / 100.0
        let second = baseMidi + (secondHigher ? delta : -delta)

        phase = .playing(second: false)
        await tone.play(midiFloat: baseMidi)
        if Task.isCancelled { return }
        try? await Task.sleep(nanoseconds: 300_000_000)
        if Task.isCancelled { return }

        phase = .playing(second: true)
        await tone.play(midiFloat: second)
        if Task.isCancelled { return }

        phase = .answering
    }

    // MARK: - Answering
    func answer(higher: Bool) {
        guard phase == .answering else { return }
        let delta = currentDelta
        let correct = (higher == secondHigher)

        trials += 1
        if correct { correctCount += 1 }
        levelTrials[levelIndex] += 1
        if correct { levelCorrect[levelIndex] += 1 }

        recentAtLevel.append(correct)
        if recentAtLevel.count > 5 { recentAtLevel.removeFirst() }

        // ladder movement
        if recentAtLevel.count >= 5,
           recentAtLevel.filter({ $0 }).count >= 4,
           levelIndex < Self.levels.count - 1 {
            levelIndex += 1
            bestLevelIndex = max(bestLevelIndex, levelIndex)
            recentAtLevel = []
        } else if recentAtLevel.count >= 2,
                  recentAtLevel.suffix(2).allSatisfy({ !$0 }),
                  levelIndex > 0 {
            levelIndex -= 1
            recentAtLevel = []
        }

        phase = .feedback(correct: correct, wasHigher: secondHigher, deltaCents: delta)
    }
}
