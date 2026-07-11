import SwiftUI

struct IntervalView: View {
    @ObservedObject var engine: PitchEngine
    @StateObject private var model: IntervalModel

    init(engine: PitchEngine) {
        self.engine = engine
        _model = StateObject(wrappedValue: IntervalModel(engine: engine))
    }

    var body: some View {
        VStack(spacing: 16) {
            header
            modePicker
            unlockChips
            stage
            statsRow
            Spacer(minLength: 0)
            actionArea
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.heldBg.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    // MARK: - Header
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Intervals")
                .font(.system(size: 24, weight: .light, design: .serif))
                .foregroundStyle(Color.heldText)
            Spacer()
            Text(model.mode == .hear ? "name the distance" : "sing the distance")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.heldDim)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.heldLine).frame(height: 1).offset(y: 8)
        }
    }

    private var modePicker: some View {
        Picker("Mode", selection: $model.mode) {
            ForEach(IntervalModel.Mode.allCases, id: \.self) { m in
                Text(m.rawValue).tag(m)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: model.mode) { _, _ in model.cancel() }
    }

    // MARK: - Unlock chips
    private var unlockChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(IntervalModel.intervals.enumerated()), id: \.offset) { i, iv in
                    Text(iv.short)
                        .font(.system(size: 10,
                                      weight: i < model.unlockedCount ? .bold : .regular,
                                      design: .monospaced))
                        .foregroundStyle(i < model.unlockedCount ? Color.heldText : Color.heldDim.opacity(0.5))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .overlay(
                            Capsule().stroke(
                                i < model.unlockedCount ? Color.heldBrass.opacity(0.6) : Color.heldLine,
                                lineWidth: 1)
                        )
                }
            }
        }
        .frame(height: 26)
    }

    // MARK: - Stage
    @ViewBuilder
    private var stage: some View {
        VStack(spacing: 12) {
            switch model.phase {
            case .idle:
                VStack(spacing: 10) {
                    Text(model.mode == .hear
                         ? "Two notes play — name the interval"
                         : "A root plays — sing the named interval above it")
                        .font(.system(size: 15, weight: .semibold, design: .serif))
                        .foregroundStyle(Color.heldText)
                        .multilineTextAlignment(.center)
                    Text("10 of your last 12 correct in Hear unlocks the next interval. "
                         + "Sing scores a steady hold within ±50¢.")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.heldDim)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                }
                .padding(.horizontal, 8)

            case .playing(let second):
                Text(second ? "second note…" : "root…")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.heldDim)
                Image(systemName: "music.note")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.heldBrass)

            case .answering:
                choiceGrid
                Button { model.replay() } label: {
                    Text("replay").font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.heldBrass).underline()
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

            case .hearFeedback(let correct, let answerIndex):
                Image(systemName: correct ? "checkmark.circle" : "xmark.circle")
                    .font(.system(size: 44))
                    .foregroundStyle(correct ? Color.heldGreen : Color.heldRed)
                Text(correct
                     ? model.current.name
                     : "\(IntervalModel.intervals[answerIndex].name) → it was \(model.current.name)")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color.heldText)
                    .multilineTextAlignment(.center)
                hintButton

            case .singRoot:
                Text("root…")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.heldDim)
                singPrompt

            case .singListening:
                singPrompt
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.heldLine)
                        Capsule()
                            .fill(model.stability >= 1 ? Color.heldGreen : Color.heldBrass)
                            .frame(width: max(0, geo.size.width * model.stability))
                    }
                }
                .frame(width: 200, height: 6)
                Text(engine.detectedMidiFloat != nil ? "hold it steady…" : "sing…")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(engine.detectedMidiFloat != nil
                                     ? Color.heldGreen : Color.heldDim)
                hintButton

            case .singResult(let cents, let hit):
                Text(String(format: "%+.0f¢", cents))
                    .font(.system(size: 40, weight: .semibold, design: .monospaced))
                    .foregroundStyle(hit ? Color.heldGreen : Color.heldRed)
                Text(hit ? "HIT — \(model.current.name)" :
                        (cents < 0 ? "flat of the \(model.current.name)" : "sharp of the \(model.current.name)"))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.heldDim)
                Button { model.playTarget() } label: {
                    Text("play the target")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.heldBrass).underline()
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

            case .timeout:
                Text("no stable note captured")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color.heldDim)

            case .failed(let message):
                Text(message)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.heldRed)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(minHeight: 230)
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.15), value: model.phase)
    }

    private var singPrompt: some View {
        VStack(spacing: 4) {
            Text("SING")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.heldDim)
            Text("\(model.current.name) ↑")
                .font(.system(size: 30, weight: .semibold, design: .serif))
                .foregroundStyle(Color.heldBrass)
        }
    }

    private var hintButton: some View {
        Group {
            if model.showHint {
                Text(model.current.hint)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.heldGreen)
            } else {
                Button { model.showHint = true } label: {
                    Text("hint")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.heldDim).underline()
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Choice grid (hear mode)
    private var choiceGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                  spacing: 8) {
            ForEach(model.unlocked, id: \.self) { i in
                Button {
                    model.answerHear(index: i)
                } label: {
                    Text(IntervalModel.intervals[i].short)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.heldText)
                .background(Color.heldPanel)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.heldLine, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - Stats
    private var statsRow: some View {
        HStack(spacing: 12) {
            statCard("\(model.unlockedCount)/\(IntervalModel.intervals.count)", "unlocked")
            statCard(model.hearTrials > 0
                     ? String(format: "%.0f%%", model.hearAccuracy * 100) : "–", "hear")
            statCard(model.singTrials > 0
                     ? String(format: "%.0f%%", model.singAccuracy * 100) : "–", "sing")
        }
    }

    private func statCard(_ value: String, _ label: String) -> some View {
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

    // MARK: - Action
    @ViewBuilder
    private var actionArea: some View {
        switch model.phase {
        case .answering:
            EmptyView()
        default:
            Button {
                switch model.phase {
                case .idle, .hearFeedback, .singResult, .timeout, .failed:
                    model.startTrial()
                default:
                    model.cancel()
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
    }

    private var buttonTitle: String {
        switch model.phase {
        case .idle: return "Start"
        case .hearFeedback, .singResult: return "Next"
        case .timeout, .failed: return "Retry"
        default: return "Cancel"
        }
    }

    private var buttonColor: Color {
        switch model.phase {
        case .idle, .hearFeedback, .singResult, .timeout, .failed: return .heldBrass
        default: return .heldRed
        }
    }
}

#Preview {
    IntervalView(engine: PitchEngine())
}
