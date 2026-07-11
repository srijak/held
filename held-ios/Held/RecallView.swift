import SwiftUI

struct RecallView: View {
    @ObservedObject var engine: PitchEngine
    @StateObject private var model: RecallModel
    @State private var showRangeFinder = false

    init(engine: PitchEngine) {
        self.engine = engine
        _model = StateObject(wrappedValue: RecallModel(engine: engine))
    }

    var body: some View {
        VStack(spacing: 20) {
            header
            trialStage
            micStrip
            settings
            statsGrid
            Spacer(minLength: 0)
            actionButton
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.heldBg.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    // MARK: - Header
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Recall")
                .font(.system(size: 24, weight: .light, design: .serif))
                .foregroundStyle(Color.heldText)
            Spacer()
            Text("hear once · wait · sing")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.heldDim)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.heldLine).frame(height: 1).offset(y: 8)
        }
    }

    // MARK: - Trial stage
    private var trialStage: some View {
        VStack(spacing: 10) {
            switch model.phase {
            case .idle:
                stageText("—", sub: "start a trial", color: .heldDim)

            case .reference:
                noteText(model.targetMidi, color: .heldBrass)
                stageLabel("LISTEN — plays once")

            case .delay(let remaining):
                noteText(model.targetMidi, color: .heldText)
                Text("\(remaining)")
                    .font(.system(size: 44, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.heldBrass)
                    .contentTransition(.numericText())
                stageLabel("HOLD IT IN YOUR HEAD")

            case .sing:
                noteText(model.targetMidi, color: .heldBrass)
                stageLabel("SING")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                Text(engine.detectedMidiFloat != nil
                     ? "voice detected" : "waiting for your voice…")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(engine.detectedMidiFloat != nil
                                     ? Color.heldGreen : Color.heldDim)

            case .capturing:
                noteText(model.targetMidi, color: .heldBrass)
                stageLabel("● CAPTURING")
                    .foregroundStyle(Color.heldRed)

            case .result(let cents, let hit):
                noteText(model.targetMidi, color: hit ? .heldGreen : .heldRed)
                Text(String(format: "%+.0f¢", cents))
                    .font(.system(size: 40, weight: .semibold, design: .monospaced))
                    .foregroundStyle(hit ? Color.heldGreen : Color.heldRed)
                stageLabel(hit ? "HIT (within ±25¢)" : verdict(cents))

            case .timeout:
                stageText("…", sub: "no voice detected — try again", color: .heldDim)
            }
        }
        .frame(minHeight: 220)
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.15), value: model.phase)
    }

    private func verdict(_ cents: Double) -> String {
        let direction = cents < 0 ? "FLAT" : "SHARP"
        let semis = abs(cents) / 100
        if semis >= 0.75 {
            return String(format: "%@ by ~%.0f semitone%@",
                          direction, semis.rounded(), semis >= 1.5 ? "s" : "")
        }
        return "\(direction)"
    }

    private func noteText(_ midi: Int, color: Color) -> some View {
        HStack(alignment: .top, spacing: 2) {
            Text(PitchEngine.noteLetter(midi))
                .font(.system(size: 80, weight: .semibold, design: .serif))
            Text("\(PitchEngine.noteOctave(midi))")
                .font(.system(size: 30, design: .serif))
                .foregroundStyle(Color.heldDim)
                .padding(.top, 8)
        }
        .foregroundStyle(color)
    }

    private func stageText(_ big: String, sub: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Text(big)
                .font(.system(size: 80, weight: .semibold, design: .serif))
                .foregroundStyle(color)
            Text(sub)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.heldDim)
        }
    }

    private func stageLabel(_ s: String) -> Text {
        Text(s)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color.heldDim)
    }

    // MARK: - Mic strip
    // Confirms the signal path is alive without revealing pitch:
    // level meter + binary voiced state only.
    private var micStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: engine.isRunning ? "mic.fill" : "mic.slash")
                .font(.system(size: 11))
                .foregroundStyle(micColor)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.heldLine)
                    Capsule()
                        .fill(micColor)
                        .frame(width: max(0, geo.size.width * engine.inputLevel))
                        .animation(.linear(duration: 0.08), value: engine.inputLevel)
                }
            }
            .frame(height: 5)
            Text(micStatus)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(engine.detectedMidiFloat != nil
                                 ? Color.heldGreen : Color.heldDim)
                .frame(width: 96, alignment: .trailing)
        }
        .frame(height: 16)
    }

    private var micColor: Color {
        guard engine.isRunning else { return .heldDim }
        return engine.detectedMidiFloat != nil ? .heldGreen : .heldBrass
    }

    private var micStatus: String {
        guard engine.isRunning else { return "mic off" }
        return engine.detectedMidiFloat != nil ? "voice detected" : "listening"
    }

    // MARK: - Settings
    private var settings: some View {
        HStack(spacing: 12) {
            VStack(spacing: 4) {
                Text("DELAY").settingLabel()
                Picker("Delay", selection: $model.delaySeconds) {
                    Text("3s").tag(3)
                    Text("5s").tag(5)
                    Text("10s").tag(10)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
            }
            rangeStepper(label: "LOW", value: $model.rangeLo)
            rangeStepper(label: "HIGH", value: $model.rangeHi)
        }
        .padding(12)
        .background(Color.heldPanel)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.heldLine, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .bottomTrailing) {
            Button {
                model.cancelTrial()
                showRangeFinder = true
            } label: {
                Text("find my range")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.heldBrass)
                    .underline()
            }
            .buttonStyle(.plain)
            .padding(.trailing, 12)
            .padding(.bottom, -18)
        }
        .sheet(isPresented: $showRangeFinder) {
            RangeFinderView(engine: engine) { lo, hi in
                model.rangeLo = lo
                model.rangeHi = hi
            }
        }
    }

    private func rangeStepper(label: String, value: Binding<Int>) -> some View {
        VStack(spacing: 4) {
            Text(label).settingLabel()
            HStack(spacing: 6) {
                Button { value.wrappedValue = max(36, value.wrappedValue - 1) } label: {
                    Image(systemName: "minus").frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                Text(PitchEngine.noteName(value.wrappedValue))
                    .font(.system(size: 15, weight: .semibold, design: .serif))
                    .foregroundStyle(Color.heldBrass)
                    .frame(minWidth: 38)
                Button { value.wrappedValue = min(84, value.wrappedValue + 1) } label: {
                    Image(systemName: "plus").frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.heldText)
        }
    }

    // MARK: - Stats
    private var statsGrid: some View {
        HStack(spacing: 12) {
            statCard(
                value: "\(model.trials)",
                label: "trials"
            )
            statCard(
                value: model.trials > 0
                    ? String(format: "%.0f%%", model.hitRate * 100) : "–",
                label: "hit rate"
            )
            statCard(
                value: model.medianAbsError.map { String(format: "%.0f¢", $0) } ?? "–",
                label: "median error"
            )
            statCard(
                value: "\(model.bestStreak)",
                label: "best streak"
            )
        }
    }

    private func statCard(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.heldBrass)
            Text(label.uppercased())
                .font(.system(size: 8, design: .monospaced))
                .kerning(1.0)
                .foregroundStyle(Color.heldDim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.heldPanel)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.heldLine, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Action button
    private var actionButton: some View {
        Button {
            switch model.phase {
            case .idle, .result, .timeout:
                model.startTrial()
            default:
                model.cancelTrial()
            }
        } label: {
            Text(buttonTitle)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.heldBg)
        .background(buttonColor)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var buttonTitle: String {
        switch model.phase {
        case .idle: return "Start trial"
        case .result, .timeout: return "Next trial"
        default: return "Cancel"
        }
    }

    private var buttonColor: Color {
        switch model.phase {
        case .idle, .result, .timeout: return .heldBrass
        default: return .heldRed
        }
    }
}

private extension Text {
    func settingLabel() -> some View {
        self.font(.system(size: 8, design: .monospaced))
            .kerning(1.0)
            .foregroundStyle(Color.heldDim)
    }
}

#Preview {
    RecallView(engine: PitchEngine())
}
