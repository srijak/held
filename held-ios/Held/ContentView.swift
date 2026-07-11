import SwiftUI

// MARK: - Palette (matches the desktop version)
extension Color {
    static let heldBg = Color(red: 0.043, green: 0.059, blue: 0.086)      // #0b0f16
    static let heldPanel = Color(red: 0.071, green: 0.094, blue: 0.149)   // #121826
    static let heldLine = Color(red: 0.137, green: 0.169, blue: 0.239)    // #232b3d
    static let heldText = Color(red: 0.851, green: 0.831, blue: 0.784)    // #d9d4c8
    static let heldDim = Color(red: 0.435, green: 0.471, blue: 0.537)     // #6f7889
    static let heldBrass = Color(red: 0.878, green: 0.663, blue: 0.306)   // #e0a94e
    static let heldGreen = Color(red: 0.498, green: 0.788, blue: 0.561)   // #7fc98f
    static let heldRed = Color(red: 0.831, green: 0.455, blue: 0.416)     // #d4746a
}

struct ContentView: View {
    @ObservedObject var engine: PitchEngine

    private var inTune: Bool {
        guard let c = engine.centsFromTarget else { return false }
        return abs(c) <= PitchEngine.inTuneBand
    }

    var body: some View {
        VStack(spacing: 20) {
            header
            noteStage
            TraceView(engine: engine)
                .frame(height: 220)
                .padding(10)
                .background(Color.heldPanel)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.heldLine, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
            targetControls
            statsRow
            Spacer(minLength: 0)
            micButton
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.heldBg.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    // MARK: - Header
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Held")
                .font(.system(size: 24, weight: .light, design: .serif))
                .foregroundStyle(Color.heldText)
            Spacer()
            Text("pitch trainer")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.heldDim)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.heldLine)
                .frame(height: 1)
                .offset(y: 8)
        }
    }

    // MARK: - Note stage
    private var noteStage: some View {
        HStack(alignment: .center, spacing: 12) {
            centsColumn(label: "flat", value: flatCents, active: flatActive)
            VStack(spacing: 4) {
                if let m = engine.detectedMidiFloat {
                    let nearest = Int(m.rounded())
                    HStack(alignment: .top, spacing: 2) {
                        Text(PitchEngine.noteLetter(nearest))
                            .font(.system(size: 88, weight: .semibold, design: .serif))
                        Text("\(PitchEngine.noteOctave(nearest))")
                            .font(.system(size: 32, weight: .regular, design: .serif))
                            .foregroundStyle(Color.heldDim)
                            .padding(.top, 10)
                    }
                    .foregroundStyle(inTune ? Color.heldGreen : Color.heldText)
                    if let f = engine.detectedFreq {
                        let centsOffNearest = Int(((m - m.rounded()) * 100).rounded())
                        Text(String(format: "%.1f Hz · %+d¢ off %@",
                                    f, centsOffNearest, PitchEngine.noteName(nearest)))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Color.heldDim)
                    }
                } else {
                    Text("—")
                        .font(.system(size: 88, weight: .semibold, design: .serif))
                        .foregroundStyle(Color.heldText)
                    Text(engine.micDenied
                         ? "mic blocked — enable in Settings"
                         : (engine.isRunning ? "listening…" : "tap start"))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.heldDim)
                }
            }
            .frame(maxWidth: .infinity)
            centsColumn(label: "sharp", value: sharpCents, active: sharpActive)
        }
        .frame(minHeight: 140)
        .animation(.easeOut(duration: 0.15), value: inTune)
    }

    private var flatCents: String {
        guard let c = engine.centsFromTarget, c < -2 else { return "–" }
        return "\(Int(abs(c).rounded()))¢"
    }
    private var sharpCents: String {
        guard let c = engine.centsFromTarget, c > 2 else { return "–" }
        return "\(Int(c.rounded()))¢"
    }
    private var flatActive: Bool {
        guard let c = engine.centsFromTarget else { return false }
        return c < -PitchEngine.inTuneBand
    }
    private var sharpActive: Bool {
        guard let c = engine.centsFromTarget else { return false }
        return c > PitchEngine.inTuneBand
    }

    private func centsColumn(label: String, value: String, active: Bool) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .monospaced))
                .foregroundStyle(active ? Color.heldRed : (inTune ? Color.heldGreen : Color.heldText))
            Text(label.uppercased())
                .font(.system(size: 9, design: .monospaced))
                .kerning(1.2)
                .foregroundStyle(Color.heldDim)
        }
        .frame(width: 64)
    }

    // MARK: - Target controls
    private var targetControls: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Text("TARGET")
                    .font(.system(size: 9, design: .monospaced))
                    .kerning(1.2)
                    .foregroundStyle(Color.heldDim)
                Button { engine.nudgeTarget(-1) } label: {
                    Image(systemName: "minus")
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                Text(PitchEngine.noteName(engine.targetMidi))
                    .font(.system(size: 24, weight: .semibold, design: .serif))
                    .foregroundStyle(Color.heldBrass)
                    .frame(minWidth: 56)
                Button { engine.nudgeTarget(1) } label: {
                    Image(systemName: "plus")
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.heldPanel)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.heldLine, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Button { engine.playReference() } label: {
                Image(systemName: "speaker.wave.2")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .background(Color.heldPanel)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.heldLine, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .disabled(!engine.isRunning)

            Button { engine.setTargetToVoice() } label: {
                Image(systemName: "scope")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .background(Color.heldPanel)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.heldLine, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .disabled(engine.detectedMidiFloat == nil)
        }
        .foregroundStyle(Color.heldText)
        .buttonStyle(.plain)
    }

    // MARK: - Stats
    private var statsRow: some View {
        HStack(spacing: 12) {
            statCard(value: String(format: "%.1fs", engine.holdSeconds), label: "held in tune")
            statCard(value: String(format: "%.1fs", engine.bestHold), label: "best hold")
        }
    }

    private func statCard(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.heldBrass)
            Text(label.uppercased())
                .font(.system(size: 9, design: .monospaced))
                .kerning(1.2)
                .foregroundStyle(Color.heldDim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.heldPanel)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.heldLine, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Mic button
    private var micButton: some View {
        Button {
            if engine.isRunning {
                engine.stop()
            } else {
                Task { await engine.start() }
            }
        } label: {
            Text(engine.isRunning ? "Stop" : "Start listening")
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.heldBg)
        .background(engine.isRunning ? Color.heldRed : Color.heldBrass)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Trace view
struct TraceView: View {
    @ObservedObject var engine: PitchEngine

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                let now = ProcessInfo.processInfo.systemUptime
                let window = PitchEngine.traceWindow
                let range: Double = 50 // ±50 cents visible
                let midY = size.height / 2

                func yFor(_ cents: Double) -> CGFloat {
                    let clamped = max(-range, min(range, cents))
                    return midY - CGFloat(clamped / range) * (size.height / 2 - 10)
                }
                func xFor(_ t: TimeInterval) -> CGFloat {
                    size.width * CGFloat(1 - (now - t) / window)
                }

                // in-tune band
                let bandTop = yFor(PitchEngine.inTuneBand)
                let bandBot = yFor(-PitchEngine.inTuneBand)
                ctx.fill(
                    Path(CGRect(x: 0, y: bandTop,
                                width: size.width, height: bandBot - bandTop)),
                    with: .color(Color.heldGreen.opacity(0.10))
                )

                // target line (dashed)
                var targetLine = Path()
                targetLine.move(to: CGPoint(x: 0, y: midY))
                targetLine.addLine(to: CGPoint(x: size.width, y: midY))
                ctx.stroke(
                    targetLine,
                    with: .color(Color.heldGreen.opacity(0.6)),
                    style: StrokeStyle(lineWidth: 1, dash: [6, 6])
                )

                // gridlines
                for c in [-50.0, -25.0, 25.0, 50.0] {
                    var line = Path()
                    let y = yFor(c)
                    line.move(to: CGPoint(x: 0, y: y))
                    line.addLine(to: CGPoint(x: size.width, y: y))
                    ctx.stroke(line, with: .color(Color.heldLine.opacity(0.9)),
                               lineWidth: 1)
                }

                // pitch trace
                var path = Path()
                var penDown = false
                for point in engine.trace {
                    guard let cents = point.cents else {
                        penDown = false
                        continue
                    }
                    let p = CGPoint(x: xFor(point.t), y: yFor(cents))
                    if penDown {
                        path.addLine(to: p)
                    } else {
                        path.move(to: p)
                        penDown = true
                    }
                }
                ctx.stroke(
                    path,
                    with: .color(Color.heldBrass),
                    style: StrokeStyle(lineWidth: 2, lineJoin: .round)
                )

                // current position dot
                if let last = engine.trace.last, let cents = last.cents {
                    let dotColor = abs(cents) <= PitchEngine.inTuneBand
                        ? Color.heldGreen : Color.heldBrass
                    let y = yFor(cents)
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: size.width - 10, y: y - 5,
                                               width: 10, height: 10)),
                        with: .color(dotColor)
                    )
                }
            }
        }
    }
}

#Preview {
    ContentView(engine: PitchEngine())
}
