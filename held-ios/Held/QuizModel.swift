import Foundation
import AVFoundation

/// Name That Tune: play the first N sung notes of a random track's
/// vocal stem, four title choices. Streak shrinks N (5 down to 2);
/// a miss resets to 5. Powered by the shared track library — every
/// published song becomes quiz content.
@MainActor
final class QuizModel: ObservableObject {

    struct QuizTrack: Identifiable {
        let id: String
        let title: String
        let audioURL: URL
        let backingURL: URL?
        let notes: [MelodyTrack.Note]
    }

    enum Phase: Equatable {
        case idle
        case playing
        case answered(pickedCorrect: Bool, picked: String)
    }

    @Published var phase: Phase = .idle
    @Published var options: [String] = []
    @Published var correctTitle = ""
    @Published var notesToPlay = 5
    @Published var streak = 0
    @Published var bestStreak: Int
    @Published var roundsPlayed = 0
    /// Band mode: same note window, backing stem — the hard version.
    @Published var useBacking: Bool {
        didSet { UserDefaults.standard.set(useBacking, forKey: "quiz.backing") }
    }

    let tracks: [QuizTrack]
    private let allTitles: [String]
    private var current: QuizTrack?
    private var lastID: String?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var attached = false
    private var connectedFormat: AVAudioFormat?
    private var file: AVAudioFile?

    init(tracks: [QuizTrack], allTitles: [String]) {
        self.tracks = tracks
        self.allTitles = Array(Set(allTitles).union(tracks.map(\.title)))
        self.bestStreak = UserDefaults.standard.integer(forKey: "quiz.bestStreak")
        self.useBacking = UserDefaults.standard.bool(forKey: "quiz.backing")
        if self.useBacking && tracks.filter({ $0.backingURL != nil }).count < 2 {
            self.useBacking = false
        }
    }

    private var eligible: [QuizTrack] {
        useBacking ? tracks.filter { $0.backingURL != nil } : tracks
    }

    var bandSeconds: Double { Double(notesToPlay) + 1 }   // 6s down to 3s

    var backingModeAvailable: Bool {
        tracks.filter { $0.backingURL != nil }.count >= 2
    }

    /// Needs at least two guessable tracks and four titles for options.
    var canPlay: Bool { eligible.count >= 2 && allTitles.count >= 4 }

    func startRound() {
        guard canPlay else { return }
        let pool = eligible
        var pick = pool.randomElement()!
        while pool.count > 1 && pick.id == lastID {
            pick = pool.randomElement()!
        }
        lastID = pick.id
        current = pick
        correctTitle = pick.title
        let distractors = allTitles.filter { $0 != pick.title }.shuffled()
        options = (Array(distractors.prefix(3)) + [pick.title]).shuffled()
        phase = .playing
        roundsPlayed += 1
        play()
    }

    /// (Re)plays the current snippet. Unlimited replays — the challenge
    /// scales through note count, not through denying another listen.
    func play() {
        guard let t = current else { return }
        let url = (useBacking ? t.backingURL : nil) ?? t.audioURL
        do {
            let f: AVAudioFile
            if let existing = file, existing.url == url {
                f = existing
            } else {
                f = try AVAudioFile(forReading: url)
                file = f
            }
            if !attached {
                engine.attach(player)
                attached = true
            }
            if connectedFormat != f.processingFormat {
                if connectedFormat != nil { engine.disconnectNodeOutput(player) }
                engine.connect(player, to: engine.mainMixerNode, format: f.processingFormat)
                connectedFormat = f.processingFormat
            }
            if !engine.isRunning {
                let session = AVAudioSession.sharedInstance()
                if session.category != .playAndRecord {
                    try session.setCategory(.playback, options: [.mixWithOthers])
                }
                try session.setActive(true)
                try engine.start()
            }

            // Band mode: the song's actual opening — bar one is where
            // arrangements identify themselves. Clip length shrinks with
            // streak. Vocal mode: first N sung notes.
            let t0: Double
            let t1: Double
            if useBacking {
                t0 = 0
                t1 = bandSeconds
            } else {
                let n = min(notesToPlay, t.notes.count)
                guard n > 0 else { return }
                t0 = max(0, t.notes[0].displayStart - 0.05)
                t1 = t.notes[n - 1].end + 0.1
            }
            let sr = f.processingFormat.sampleRate
            let startFrame = AVAudioFramePosition(t0 * sr)
            let count = AVAudioFrameCount(
                max(0, min((t1 - t0) * sr, Double(f.length) - Double(startFrame))))
            guard count > 0 else { return }
            player.stop()
            player.scheduleSegment(f, startingFrame: startFrame,
                                   frameCount: count, at: nil)
            player.play()
        } catch {}
    }

    func answer(_ title: String) {
        guard case .playing = phase else { return }
        player.stop()
        let correct = title == correctTitle
        if correct {
            streak += 1
            if streak > bestStreak {
                bestStreak = streak
                UserDefaults.standard.set(bestStreak, forKey: "quiz.bestStreak")
            }
            notesToPlay = max(2, 5 - streak / 2)
        } else {
            streak = 0
            notesToPlay = 5
        }
        phase = .answered(pickedCorrect: correct, picked: title)
    }

    func stop() {
        player.stop()
    }
}
