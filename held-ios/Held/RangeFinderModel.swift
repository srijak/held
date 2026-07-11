import Foundation
import Combine

/// Guided vocal range test.
///
/// Two captures: lowest comfortable note, then highest. A note only
/// counts when held stably (±0.5 semitone of its median) for 1.5s —
/// this rejects vocal fry, squeaks, and drive-by glissando frames.
/// The suggested training range trims 2 semitones off each end:
/// recall trials at the edge of the range measure strain, not memory.
@MainActor
final class RangeFinderModel: ObservableObject {

    enum Step: Equatable {
        case intro
        case starting
        case failed(String)
        case low
        case lowCaptured(Int)
        case high
        case done(lo: Int, hi: Int)
    }

    @Published var step: Step = .intro
    @Published var liveNote: Int?
    @Published var stability: Double = 0   // 0..1 progress toward lock

    static let holdSeconds: Double = 1.5
    static let toleranceSemitones: Double = 0.5

    private let engine: PitchEngine
    private var task: Task<Void, Never>?

    init(engine: PitchEngine) { self.engine = engine }

    func start() {
        task?.cancel()
        task = Task { await run() }
    }

    func cancel() {
        task?.cancel()
        step = .intro
        stability = 0
        liveNote = nil
    }

    /// Trimmed suggestion; relaxes the trim rather than produce a
    /// uselessly narrow range.
    static func suggestedRange(lo: Int, hi: Int) -> (lo: Int, hi: Int) {
        var a = lo + 2, b = hi - 2
        if b - a < 7 { a = lo + 1; b = hi - 1 }
        if b - a < 5 { a = lo; b = hi }
        return (a, b)
    }

    private func run() async {
        // Acknowledge the tap immediately, before any async work.
        step = .starting
        if !engine.isRunning { await engine.start() }
        guard engine.isRunning else {
            step = .failed(
                engine.micDenied
                    ? "mic access denied — enable in Settings"
                    : (engine.lastError ?? "mic failed to start")
            )
            return
        }

        step = .low
        guard let lo = await captureStableNote() else { return }
        step = .lowCaptured(lo)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        if Task.isCancelled { return }

        step = .high
        guard let hi = await captureStableNote() else { return }
        step = .done(lo: min(lo, hi), hi: max(lo, hi))
        stability = 0
        liveNote = nil
    }

    /// Listens until a pitch has been held within tolerance for the
    /// full hold window. Returns the median note, or nil if cancelled.
    private func captureStableNote() async -> Int? {
        var window: [(t: TimeInterval, m: Double)] = []
        stability = 0

        while true {
            if Task.isCancelled { return nil }
            let now = ProcessInfo.processInfo.systemUptime

            if let m = engine.detectedMidiFloat {
                window.append((now, m))
                liveNote = Int(m.rounded())
            } else if let last = window.last, now - last.t > 0.3 {
                // long unvoiced gap: start over
                window = []
                stability = 0
                liveNote = nil
            }

            window.removeAll { now - $0.t > Self.holdSeconds }

            if window.count >= 8, let first = window.first {
                let span = now - first.t
                let sorted = window.map(\.m).sorted()
                let median = sorted[sorted.count / 2]
                let stable = window.allSatisfy {
                    abs($0.m - median) <= Self.toleranceSemitones
                }
                if stable {
                    stability = min(1, span / Self.holdSeconds)
                    if span >= Self.holdSeconds * 0.98 {
                        return Int(median.rounded())
                    }
                } else {
                    stability = 0
                }
            }

            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }
}
