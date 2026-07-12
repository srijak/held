import SwiftUI
import AVFAudio

struct SongPracticeView: View {
    @StateObject private var model: SongModel
    @ObservedObject var engine: PitchEngine

    init(track: MelodyTrack, trackID: String, engine: PitchEngine,
         audioURL: URL? = nil, backingURL: URL? = nil) {
        self.engine = engine
        _model = StateObject(wrappedValue: SongModel(
            track: track, trackID: trackID, pitchEngine: engine,
            audioURL: audioURL, backingURL: backingURL))
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
            if model.singingAlong, singActive, !headphonesConnected {
                Text("speaker bleeds into the mic — use headphones for Along")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.heldRed)
            }
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
        HStack(spacing: 8) {
            Button { model.listen() } label: {
                Label("Listen", systemImage: "speaker.wave.2")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .labelStyle(.titleOnly)
                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(Color.heldText)
            .background(Color.heldPanel)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.heldLine, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Button {
                if singActive { model.stopAll() } else { model.sing(along: true) }
            } label: {
                Text(singActive && model.singingAlong ? "…" : "Along")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(Color.heldBrass)
            .background(Color.heldPanel)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.heldBrass, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .disabled(!engine.isRunning)
            .opacity(engine.isRunning ? 1 : 0.4)

            Button {
                if singActive { model.stopAll() } else { model.sing() }
            } label: {
                Text(singActive && !model.singingAlong ? singLabel : "Sing")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(Color.heldBg)
            .background(singActive && !model.singingAlong ? Color.heldRed : Color.heldBrass)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .disabled(!engine.isRunning)
            .opacity(engine.isRunning ? 1 : 0.4)

            if model.hasAudio {
                Menu {
                    ForEach(model.availableSources, id: \.self) { src in
                        Button { model.source = src } label: {
                            Label(src.title,
                                  systemImage: model.source == src ? "checkmark" : src.icon)
                        }
                    }
                } label: {
                    Image(systemName: model.source.icon)
                        .frame(width: 42, height: 44).contentShape(Rectangle())
                }
                .foregroundStyle(Color.heldBrass)
                .background(Color.heldPanel)
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.heldLine, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            Button { model.loop.toggle() } label: {
                Image(systemName: "repeat")
                    .frame(width: 42, height: 44).contentShape(Rectangle())
            }
            .foregroundStyle(model.loop ? Color.heldBrass : Color.heldDim)
            .background(Color.heldPanel)
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(model.loop ? Color.heldBrass : Color.heldLine, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private var headphonesConnected: Bool {
        let hp: Set<AVAudioSession.Port> = [.headphones, .bluetoothA2DP,
                                            .bluetoothHFP, .bluetoothLE]
        return AVAudioSession.sharedInstance().currentRoute.outputs
            .contains { hp.contains($0.portType) }
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
            let scrollingPhase = model.phase == .singing || model.phase == .leadIn
                || model.phase == .listening
            let notes = scrollingPhase ? model.spanNotes : chunk.notes
            guard !notes.isEmpty else { return }

            // Sing/Along use a scrolling window with a fixed now-line:
            // one spot to watch, notes flow toward it with lead time.
            // Listen and review keep the static full-chunk layout.
            let scrolling = scrollingPhase
            let windowSpan = 4.0
            let nowFraction = 0.375
            let t0: Double
            let span: Double
            let heardCursor = model.cursor - model.displayLatency
            if scrolling {
                span = windowSpan
                t0 = model.spanStart + heardCursor - windowSpan * nowFraction
            } else {
                t0 = chunk.start
                span = chunk.duration
            }
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

            // target note bars: dim span = where the word is (voice
            // activity), bright core = where pitch is scored
            for note in notes where !scrolling || (note.displayEnd >= t0 && note.displayStart <= t0 + span) {
                let yy = y(model.targetMidi(note)) - laneH / 2
                let color: Color
                if let r = model.results[note.start] {
                    color = r.passed ? .heldGreen : .heldRed
                } else {
                    color = .heldBrass
                }
                if note.displayStart < note.start || note.displayEnd > note.end {
                    let outer = CGRect(
                        x: x(note.displayStart), y: yy,
                        width: max(3, x(note.displayEnd) - x(note.displayStart)),
                        height: laneH)
                    ctx.fill(Path(roundedRect: outer, cornerRadius: 3),
                             with: .color(color.opacity(0.28)))
                }
                let core = CGRect(
                    x: x(note.start), y: yy,
                    width: max(3, x(note.end) - x(note.start)),
                    height: laneH)
                ctx.fill(Path(roundedRect: core, cornerRadius: 3),
                         with: .color(color.opacity(0.75)))
            }

            // sung trace
            var path = Path()
            var penDown = false
            for s in model.sungSamples {
                let midi = s.midi
                let ts = model.spanStart + s.t
                guard midi > lo, midi < hi, ts >= t0, ts <= t0 + span else {
                    penDown = false
                    continue
                }
                let p = CGPoint(x: x(ts), y: y(midi))
                if penDown { path.addLine(to: p) } else { path.move(to: p); penDown = true }
            }
            ctx.stroke(path, with: .color(Color.heldText.opacity(0.9)),
                       style: StrokeStyle(lineWidth: 2, lineJoin: .round))

            // playhead: fixed now-line while scrolling, moving cursor in Listen
            if scrolling {
                let cx = size.width * nowFraction
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
