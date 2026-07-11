import SwiftUI

struct SongPracticeView: View {
    @StateObject private var model: SongModel
    @ObservedObject var engine: PitchEngine

    init(track: MelodyTrack, trackID: String, engine: PitchEngine) {
        self.engine = engine
        _model = StateObject(wrappedValue: SongModel(
            track: track, trackID: trackID, pitchEngine: engine))
    }

    var body: some View {
        VStack(spacing: 14) {
            chunkBar
            PianoRoll(model: model)
                .frame(maxHeight: .infinity)
                .padding(8)
                .background(Color.heldPanel)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.heldLine, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            scoreRow
            controlRow
            micGate
        }
        .padding(16)
        .background(Color.heldBg.ignoresSafeArea())
        .navigationTitle(model.track.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.heldBg, for: .navigationBar)
        .preferredColorScheme(.dark)
        .onDisappear { model.stopAll() }
    }

    // MARK: - Chunk bar

    private var chunkBar: some View {
        HStack(spacing: 10) {
            Button { model.prevChunk() } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 36, height: 36).contentShape(Rectangle())
            }
            .disabled(model.chunkIndex == 0)

            VStack(spacing: 2) {
                Text("CHUNK \(model.chunkIndex + 1)/\(model.chunks.count)")
                    .font(.system(size: 11, design: .monospaced)).kerning(1.2)
                    .foregroundStyle(Color.heldText)
                if let best = model.bestChunkScore[model.chunkIndex] {
                    Text("best \(Int(best * 100))%")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.heldBrass)
                } else {
                    Text("unplayed")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.heldDim)
                }
            }
            .frame(maxWidth: .infinity)

            Button { model.nextChunk() } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 36, height: 36).contentShape(Rectangle())
            }
            .disabled(model.chunkIndex >= model.chunks.count - 1)

            transposeControl
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.heldText)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.heldPanel)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.heldLine, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var transposeControl: some View {
        HStack(spacing: 6) {
            Button { model.transpose = max(-24, model.transpose - 1) } label: {
                Image(systemName: "minus").frame(width: 26, height: 30).contentShape(Rectangle())
            }
            VStack(spacing: 0) {
                Text(model.transpose == 0 ? "±0" : String(format: "%+d", model.transpose))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(model.transpose == 0 ? Color.heldDim : Color.heldBrass)
                Text("ST").font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(Color.heldDim)
            }
            .frame(minWidth: 28)
            Button { model.transpose = min(24, model.transpose + 1) } label: {
                Image(systemName: "plus").frame(width: 26, height: 30).contentShape(Rectangle())
            }
        }
    }

    // MARK: - Score row

    private var scoreRow: some View {
        HStack(spacing: 12) {
            statCard(
                value: model.chunkScore.map { "\(Int($0 * 100))%" } ?? "—",
                label: "notes hit",
                highlight: (model.chunkScore ?? 0) >= 0.8
            )
            statCard(
                value: "\(model.targetNotes.count)",
                label: "notes in chunk",
                highlight: false
            )
        }
    }

    private func statCard(value: String, label: String, highlight: Bool) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                .foregroundStyle(highlight ? Color.heldGreen : Color.heldBrass)
            Text(label.uppercased())
                .font(.system(size: 9, design: .monospaced)).kerning(1.2)
                .foregroundStyle(Color.heldDim)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10)
        .background(Color.heldPanel)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.heldLine, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Controls

    private var controlRow: some View {
        HStack(spacing: 12) {
            Button { model.listen() } label: {
                Label("Listen", systemImage: "speaker.wave.2")
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(Color.heldText)
            .background(Color.heldPanel)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.heldLine, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Button {
                if model.phase == .singing || model.phase == .leadIn {
                    model.stopAll()
                } else {
                    model.sing()
                }
            } label: {
                Label(singLabel, systemImage: "mic")
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(Color.heldBg)
            .background(singActive ? Color.heldRed : Color.heldBrass)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .disabled(!engine.isRunning)
            .opacity(engine.isRunning ? 1 : 0.4)

            Button { model.loop.toggle() } label: {
                Image(systemName: "repeat")
                    .frame(width: 48, height: 48).contentShape(Rectangle())
            }
            .foregroundStyle(model.loop ? Color.heldBrass : Color.heldDim)
            .background(Color.heldPanel)
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(model.loop ? Color.heldBrass : Color.heldLine, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private var singActive: Bool {
        model.phase == .singing || model.phase == .leadIn
    }

    private var singLabel: String {
        switch model.phase {
        case .leadIn: return "Ready…"
        case .singing: return "Singing"
        default: return "Sing"
        }
    }

    // MARK: - Mic gate

    @ViewBuilder
    private var micGate: some View {
        if !engine.isRunning {
            Button {
                Task { await engine.start() }
            } label: {
                Text(engine.micDenied ? "Mic blocked — enable in Settings" : "Start listening to sing")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.heldBg)
            .background(Color.heldGreen)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .disabled(engine.micDenied)
        }
    }
}

// MARK: - Piano roll

private struct PianoRoll: View {
    @ObservedObject var model: SongModel

    var body: some View {
        Canvas { ctx, size in
            let chunk = model.chunk
            let notes = chunk.notes
            guard !notes.isEmpty else { return }

            let t0 = chunk.start
            let span = chunk.duration
            let midis = notes.map { model.targetMidi($0) }
            let lo = (midis.min() ?? 48) - 2.5
            let hi = (midis.max() ?? 60) + 2.5

            func x(_ t: Double) -> CGFloat {
                CGFloat((t - t0) / span) * size.width
            }
            func y(_ midi: Double) -> CGFloat {
                size.height - CGFloat((midi - lo) / (hi - lo)) * size.height
            }
            let laneH = max(6, min(18, size.height / CGFloat(hi - lo)))

            // horizontal gridline per whole semitone that hosts a note
            for m in Set(notes.map { Int(model.targetMidi($0).rounded()) }) {
                var line = Path()
                let yy = y(Double(m))
                line.move(to: CGPoint(x: 0, y: yy))
                line.addLine(to: CGPoint(x: size.width, y: yy))
                ctx.stroke(line, with: .color(Color.heldLine.opacity(0.5)), lineWidth: 1)
                ctx.draw(
                    Text(PitchEngine.noteName(m))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Color.heldDim),
                    at: CGPoint(x: 16, y: yy - 8)
                )
            }

            // target note bars
            for note in notes {
                let rect = CGRect(
                    x: x(note.start),
                    y: y(model.targetMidi(note)) - laneH / 2,
                    width: max(3, x(note.end) - x(note.start)),
                    height: laneH
                )
                let color: Color
                if let r = model.results[note.start] {
                    color = r.passed ? .heldGreen : .heldRed
                } else {
                    color = .heldBrass
                }
                ctx.fill(Path(roundedRect: rect, cornerRadius: 3),
                         with: .color(color.opacity(0.75)))
            }

            // sung trace
            var path = Path()
            var penDown = false
            for s in model.sungSamples {
                let midi = s.midi
                guard midi > lo, midi < hi else { penDown = false; continue }
                let p = CGPoint(x: x(t0 + s.t), y: y(midi))
                if penDown { path.addLine(to: p) } else { path.move(to: p); penDown = true }
            }
            ctx.stroke(path, with: .color(Color.heldText.opacity(0.9)),
                       style: StrokeStyle(lineWidth: 2, lineJoin: .round))

            // playhead
            if model.phase != .idle && model.phase != .scored {
                let cx = model.cursor < 0 ? 0 : x(t0 + model.cursor)
                var line = Path()
                line.move(to: CGPoint(x: cx, y: 0))
                line.addLine(to: CGPoint(x: cx, y: size.height))
                let color: Color = model.phase == .listening ? .heldBrass : .heldGreen
                ctx.stroke(line, with: .color(color.opacity(0.9)), lineWidth: 2)
            }

            // lead-in countdown
            if model.phase == .leadIn {
                let remaining = -model.cursor
                ctx.draw(
                    Text(String(format: "%.1f", max(0, remaining)))
                        .font(.system(size: 40, weight: .semibold, design: .monospaced))
                        .foregroundColor(Color.heldGreen.opacity(0.85)),
                    at: CGPoint(x: size.width / 2, y: size.height / 2)
                )
            }
        }
    }
}
