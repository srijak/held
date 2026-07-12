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

    enum QuizSource: String, CaseIterable {
        case vocal, band, reverse
        var title: String {
            switch self {
            case .vocal: return "Vocal"
            case .band: return "Band"
            case .reverse: return "Reverse"
            }
        }
        var needsBacking: Bool { self != .vocal }
    }

    struct Player: Identifiable, Equatable {
        let id: Int
        var name: String
        var score = 0
        var streak = 0
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
    @Published var players: [Player] = [Player(id: 0, name: "Player 1")]
    @Published var currentPlayerIndex = 0
    var isMultiplayer: Bool { players.count > 1 }
    var currentPlayer: Player { players[min(currentPlayerIndex, players.count - 1)] }
    var nextPlayerName: String {
        players[(currentPlayerIndex + 1) % players.count].name
    }
    /// Vocal = first N sung notes. Band = the song's opening from the
    /// backing stem. Reverse = 30s of the backing played backwards.
    @Published var quizSource: QuizSource {
        didSet { UserDefaults.standard.set(quizSource.rawValue, forKey: "quiz.source") }
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
        if let names = UserDefaults.standard.stringArray(forKey: "quiz.playerNames"),
           !names.isEmpty {
            self.players = names.enumerated().map {
                Player(id: $0.offset, name: $0.element)
            }
        }
        let saved = UserDefaults.standard.string(forKey: "quiz.source")
            .flatMap(QuizSource.init(rawValue:)) ?? .vocal
        self.quizSource = saved
        if self.quizSource.needsBacking
            && tracks.filter({ $0.backingURL != nil }).count < 2 {
            self.quizSource = .vocal
        }
    }

    private var eligible: [QuizTrack] {
        quizSource.needsBacking ? tracks.filter { $0.backingURL != nil } : tracks
    }

    var bandSeconds: Double { Double(notesToPlay) + 1 }   // 6s down to 3s

    var backingModeAvailable: Bool {
        tracks.filter { $0.backingURL != nil }.count >= 2
    }

    /// Needs at least two guessable tracks and four titles for options.
    var canPlay: Bool { eligible.count >= 2 && allTitles.count >= 4 }

    /// Set the roster (1 = single player) and reset the match.
    func configurePlayers(_ names: [String]) {
        let cleaned = names.enumerated().map { i, n in
            n.trimmingCharacters(in: .whitespaces).isEmpty ? "Player \(i + 1)" : n
        }
        players = cleaned.enumerated().map { Player(id: $0.offset, name: $0.element) }
        currentPlayerIndex = 0
        streak = 0
        notesToPlay = 5
        UserDefaults.standard.set(cleaned, forKey: "quiz.playerNames")
    }

    /// Advance the turn (multiplayer) and deal the next round with the
    /// incoming player's own difficulty.
    func nextRound() {
        if isMultiplayer, case .answered = phase {
            currentPlayerIndex = (currentPlayerIndex + 1) % players.count
            streak = players[currentPlayerIndex].streak
            notesToPlay = max(2, 5 - streak / 2)
        }
        startRound()
    }

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
        let url = (quizSource.needsBacking ? t.backingURL : nil) ?? t.audioURL
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

            if quizSource == .reverse {
                playReversed(f)
                return
            }
            // Band mode: the song's actual opening — bar one is where
            // arrangements identify themselves. Clip length shrinks with
            // streak. Vocal mode: first N sung notes.
            let t0: Double
            let t1: Double
            if quizSource == .band {
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

    static let reverseSeconds: Double = 30

    /// A file segment can't be scheduled backwards: read the opening
    /// into a PCM buffer and reverse the samples in place.
    private func playReversed(_ f: AVAudioFile) {
        let sr = f.processingFormat.sampleRate
        let count = AVAudioFrameCount(min(Self.reverseSeconds * sr, Double(f.length)))
        guard count > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat,
                                         frameCapacity: count)
        else { return }
        f.framePosition = 0
        guard (try? f.read(into: buf, frameCount: count)) != nil else { return }
        let n = Int(buf.frameLength)
        if let ch = buf.floatChannelData {
            for c in 0..<Int(f.processingFormat.channelCount) {
                let p = ch[c]
                var i = 0
                var j = n - 1
                while i < j {
                    let tmp = p[i]; p[i] = p[j]; p[j] = tmp
                    i += 1; j -= 1
                }
            }
        }
        player.stop()
        player.scheduleBuffer(buf, at: nil)
        player.play()
    }

    func answer(_ title: String) {
        guard case .playing = phase else { return }
        player.stop()
        let correct = title == correctTitle
        if correct {
            streak += 1
            players[currentPlayerIndex].score += 1
            players[currentPlayerIndex].streak = streak
            if streak > bestStreak {
                bestStreak = streak
                UserDefaults.standard.set(bestStreak, forKey: "quiz.bestStreak")
            }
            notesToPlay = max(2, 5 - streak / 2)
        } else {
            streak = 0
            players[currentPlayerIndex].streak = 0
            notesToPlay = 5
        }
        phase = .answered(pickedCorrect: correct, picked: title)
    }

    func stop() {
        player.stop()
    }
}
