import UIKit
import SwiftUI

struct LibraryView: View {
    @StateObject private var library = TrackLibrary()
    @ObservedObject var engine: PitchEngine
    @State private var editingRepo = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                header
                repoRow
                tokenRow
                if let err = library.lastError {
                    Text(err)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.heldRed)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                trackList
            }
            .padding(16)
            .background(Color.heldBg.ignoresSafeArea())
            .preferredColorScheme(.dark)
            .task {
                if library.entries.isEmpty { await library.refresh() }
            }
        }
        .tint(Color.heldBrass)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Songs")
                .font(.system(size: 24, weight: .light, design: .serif))
                .foregroundStyle(Color.heldText)
            Spacer()
            Text("melody library")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.heldDim)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.heldLine).frame(height: 1).offset(y: 8)
        }
    }

    private var repoRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "shippingbox")
                .foregroundStyle(Color.heldDim)
            if editingRepo {
                TextField("owner/held-tracks", text: $library.repo)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color.heldText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit {
                        editingRepo = false
                        Task { await library.refresh() }
                    }
            } else {
                Text(library.repo)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color.heldText)
                    .onTapGesture { editingRepo = true }
            }
            Spacer()
            Button {
                editingRepo = false
                Task { await library.refresh() }
            } label: {
                if library.isRefreshing {
                    ProgressView().tint(Color.heldBrass)
                        .frame(width: 32, height: 32)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 32, height: 32).contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.heldBrass)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color.heldPanel)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.heldLine, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var tokenRow: some View {
        HStack(spacing: 10) {
            Image(systemName: library.token.isEmpty ? "key.slash" : "key.fill")
                .foregroundStyle(library.token.isEmpty ? Color.heldDim : Color.heldBrass)
            SecureField("GitHub token (private repo)", text: $library.token)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Color.heldText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { Task { await library.refresh() } }
            if library.token.isEmpty {
                Button {
                    if let s = UIPasteboard.general.string?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                       !s.isEmpty {
                        library.token = s
                        Task { await library.refresh() }
                    }
                } label: {
                    Text("Paste")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.heldBrass)
                        .foregroundStyle(Color.heldBg)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if !library.token.isEmpty {
                Button {
                    library.token = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.heldDim)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color.heldPanel)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.heldLine, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var trackList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if library.entries.isEmpty && !library.isRefreshing {
                    Text("no tracks — set the repo above and refresh")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.heldDim)
                        .padding(.top, 40)
                }
                ForEach(library.entries) { entry in
                    trackRow(entry)
                }
            }
        }
        .refreshable { await library.refresh() }
    }

    @ViewBuilder
    private func trackRow(_ entry: TrackIndexEntry) -> some View {
        let downloaded = library.isDownloaded(entry)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(.system(size: 16, weight: .semibold, design: .serif))
                    .foregroundStyle(Color.heldText)
                HStack(spacing: 8) {
                    if let artist = entry.artist {
                        Text(artist)
                    }
                    Text(String(format: "%.0fs", entry.durationS))
                    Text(entry.rangeLabel)
                    Text(String(repeating: "◆", count: max(1, min(5, entry.difficulty ?? 3))))
                        .foregroundStyle(Color.heldBrass.opacity(0.8))
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.heldDim)
            }
            Spacer()
            if downloaded {
                NavigationLink {
                    if let track = library.loadTrack(entry) {
                        SongPracticeView(track: track, trackID: entry.id, engine: engine)
                    } else {
                        Text("failed to load track")
                            .foregroundStyle(Color.heldRed)
                    }
                } label: {
                    Text("Practice")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Color.heldBrass)
                        .foregroundStyle(Color.heldBg)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
            } else {
                Button {
                    Task { await library.download(entry) }
                } label: {
                    if library.downloadingID == entry.id {
                        ProgressView().tint(Color.heldBrass)
                            .frame(width: 36, height: 32)
                    } else {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 20))
                            .frame(width: 36, height: 32).contentShape(Rectangle())
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.heldBrass)
            }
        }
        .padding(12)
        .background(Color.heldPanel)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.heldLine, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            if downloaded {
                Button(role: .destructive) {
                    library.delete(entry)
                } label: {
                    Label("Remove download", systemImage: "trash")
                }
            }
        }
    }
}
