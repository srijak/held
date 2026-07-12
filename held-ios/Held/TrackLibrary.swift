import Foundation
import Combine

/// Fetches the track catalog from a public GitHub repo's raw content and
/// caches downloaded tracks in Documents/Tracks. Offline-first: anything
/// downloaded stays usable with no network.
@MainActor
final class TrackLibrary: ObservableObject {

    @Published var repo: String {
        didSet { UserDefaults.standard.set(repo, forKey: "lib.repo") }
    }
    @Published var branch: String {
        didSet { UserDefaults.standard.set(branch, forKey: "lib.branch") }
    }
    @Published var token: String {
        didSet { Keychain.set(token, key: "lib.token") }
    }
    @Published var entries: [TrackIndexEntry] = []
    @Published var downloadedIDs: Set<String> = []
    @Published var isRefreshing = false
    @Published var downloadingID: String?
    @Published var lastError: String?

    private let session = URLSession.shared

    init() {
        repo = UserDefaults.standard.string(forKey: "lib.repo")
            ?? Secrets.defaultRepo ?? "owner/held-tracks"
        branch = UserDefaults.standard.string(forKey: "lib.branch") ?? "main"
        token = Keychain.get("lib.token") ?? ""
        try? FileManager.default.createDirectory(
            at: Self.tracksDir, withIntermediateDirectories: true)
        loadCachedIndex()
        scanDownloads()
    }

    // MARK: - Paths

    static var tracksDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tracks", isDirectory: true)
    }

    private static var indexCacheURL: URL {
        tracksDir.appendingPathComponent("_index.json")
    }

    private func localURL(for entry: TrackIndexEntry) -> URL {
        Self.tracksDir.appendingPathComponent("\(entry.id).json")
    }

    private func localAudioURL(for entry: TrackIndexEntry) -> URL {
        Self.tracksDir.appendingPathComponent("\(entry.id).m4a")
    }

    private func localBackingURL(for entry: TrackIndexEntry) -> URL {
        Self.tracksDir.appendingPathComponent("\(entry.id).backing.m4a")
    }

    func backingURL(for entry: TrackIndexEntry) -> URL? {
        let url = localBackingURL(for: entry)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Downloaded vocal clip, if this track has one on disk.
    func audioURL(for entry: TrackIndexEntry) -> URL? {
        let url = localAudioURL(for: entry)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// GitHub contents API with the raw media type. Works for public
    /// repos unauthenticated and for private repos with a fine-grained
    /// PAT (Contents: read-only, scoped to the one repo).
    private func apiRequest(_ path: String, noCache: Bool = false) -> URLRequest? {
        let trimmed = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.contains("/"),
              let url = URL(string: "https://api.github.com/repos/\(trimmed)/contents/\(path)?ref=\(branch)")
        else { return nil }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let effective = token.isEmpty ? (Secrets.githubToken ?? "") : token
        if !effective.isEmpty {
            req.setValue("Bearer \(effective)", forHTTPHeaderField: "Authorization")
        }
        if noCache { req.cachePolicy = .reloadIgnoringLocalCacheData }
        return req
    }

    private static func describe(_ status: Int) -> String {
        switch status {
        case 401: return "token rejected (401) — regenerate or re-paste it"
        case 403: return "forbidden (403) — token lacks Contents read on this repo, or rate-limited"
        case 404: return "not found (404) — check owner/name; private repos 404 without a valid token"
        default:  return "HTTP \(status)"
        }
    }

    // MARK: - Index

    func refresh() async {
        guard let req = apiRequest("index.json", noCache: true) else {
            lastError = "set repo as owner/name"
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let (data, resp) = try await session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else {
                lastError = "index fetch: \(Self.describe(status))"
                return
            }
            let index = try JSONDecoder().decode(TrackIndex.self, from: data)
            entries = index.tracks
            try? data.write(to: Self.indexCacheURL)
            lastError = nil
        } catch {
            lastError = "index fetch failed: \(error.localizedDescription)"
        }
    }

    private func loadCachedIndex() {
        guard let data = try? Data(contentsOf: Self.indexCacheURL),
              let index = try? JSONDecoder().decode(TrackIndex.self, from: data)
        else { return }
        entries = index.tracks
    }

    // MARK: - Downloads

    func scanDownloads() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.tracksDir, includingPropertiesForKeys: nil)) ?? []
        downloadedIDs = Set(
            files.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix("_") }
                .map { $0.deletingPathExtension().lastPathComponent }
        )
    }

    func isDownloaded(_ entry: TrackIndexEntry) -> Bool {
        downloadedIDs.contains(entry.id)
    }

    func download(_ entry: TrackIndexEntry) async {
        guard let req = apiRequest(entry.file) else { return }
        downloadingID = entry.id
        defer { downloadingID = nil }
        do {
            let (data, resp) = try await session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else {
                lastError = "download \(entry.title): \(Self.describe(status))"
                return
            }
            // validate before persisting
            _ = try JSONDecoder().decode(MelodyTrack.self, from: data)
            try data.write(to: localURL(for: entry))
            downloadedIDs.insert(entry.id)
            lastError = nil
            // clips are best-effort: synth playback covers their absence
            for (path, dest) in [(entry.audio, localAudioURL(for: entry)),
                                 (entry.backing, localBackingURL(for: entry))] {
                if let path, let areq = apiRequest(path),
                   let (adata, aresp) = try? await session.data(for: areq),
                   (aresp as? HTTPURLResponse)?.statusCode == 200 {
                    try? adata.write(to: dest)
                }
            }
        } catch {
            lastError = "download failed: \(error.localizedDescription)"
        }
    }

    func delete(_ entry: TrackIndexEntry) {
        try? FileManager.default.removeItem(at: localURL(for: entry))
        try? FileManager.default.removeItem(at: localAudioURL(for: entry))
        try? FileManager.default.removeItem(at: localBackingURL(for: entry))
        downloadedIDs.remove(entry.id)
    }

    func loadTrack(_ entry: TrackIndexEntry) -> MelodyTrack? {
        guard let data = try? Data(contentsOf: localURL(for: entry)) else { return nil }
        return try? JSONDecoder().decode(MelodyTrack.self, from: data)
    }
}
