import Foundation

/// Schema produced by extract_melody.py / publish_track.py.
struct MelodyTrack: Codable, Identifiable {
    struct Note: Codable, Identifiable {
        let start: Double
        let end: Double
        let midi: Int
        let midiFloat: Double

        var id: Double { start }
        var duration: Double { end - start }

        enum CodingKeys: String, CodingKey {
            case start, end, midi
            case midiFloat = "midi_float"
        }
    }

    struct Frames: Codable {
        let t: [Double]
        let midi: [Double?]
    }

    let source: String?
    let title: String?
    let artist: String?
    let notes: [Note]
    let frames: Frames?

    var id: String { title ?? source ?? "track" }
    var displayTitle: String { title ?? source ?? "Untitled" }
    var duration: Double { frames?.t.last ?? notes.last?.end ?? 0 }
}

/// One row of index.json in the tracks repo.
struct TrackIndexEntry: Codable, Identifiable, Equatable {
    let id: String
    let file: String
    let title: String
    let artist: String?
    let durationS: Double
    let noteCount: Int
    let midiLo: Int
    let midiHi: Int
    let difficulty: Int?

    enum CodingKeys: String, CodingKey {
        case id, file, title, artist, difficulty
        case durationS = "duration_s"
        case noteCount = "note_count"
        case midiLo = "midi_lo"
        case midiHi = "midi_hi"
    }

    var rangeLabel: String {
        "\(PitchEngine.noteName(midiLo))–\(PitchEngine.noteName(midiHi))"
    }
}

struct TrackIndex: Codable {
    let version: Int
    let tracks: [TrackIndexEntry]
}
