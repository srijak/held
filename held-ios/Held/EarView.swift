import SwiftUI

struct EarView: View {
    @StateObject private var model = EarModel()

    var body: some View {
        VStack(spacing: 20) {
            header
            ladderChips
            stage
            statsGrid
            verdictLine
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
            Text("Ear")
                .font(.system(size: 24, weight: .light, design: .serif))
                .foregroundStyle(Color.heldText)
            Spacer()
            Text("was the second higher or lower?")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.heldDim)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.heldLine).frame(height: 1).offset(y: 8)
        }
    }

    // MARK: - Ladder
    private var ladderChips: some View {
        HStack(spacing: 6) {
            ForEach(Array(EarModel.levels.enumerated()), id: \.offset) { i, cents in
                Text("\(cents)¢")
                    .font(.system(size: 10, weight: i == model.levelIndex ? .bold : .regular,
                                  design: .monospaced))
                    .foregroundStyle(chipColor(i))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(i == model.levelIndex ? Color.heldPanel : Color.clear)
                    .overlay(
                        Capsule().stroke(
                            i == model.levelIndex ? Color.heldBrass : Color.heldLine,
                            lineWidth: 1)
                    )
                    .clipShape(Capsule())
            }
        }
    }

    private func chipColor(_ i: Int) -> Color {
        if i == model.levelIndex { return .heldBrass }
        return i <= model.bestLevelIndex ? .heldText : .heldDim
    }

    // MARK: - Stage
    @ViewBuilder
    private var stage: some View {
        VStack(spacing: 14) {
            switch model.phase {
            case .idle:
                VStack(spacing: 12) {
                    Text("Two tones, one question")
                        .font(.system(size: 17, weight: .semibold, design: .serif))
                        .foregroundStyle(Color.heldText)
                    Text("You'll hear two notes. Say whether the second was "
                         + "higher or lower. The difference shrinks as you get "
                         + "them right. Reliably clearing 100¢ — one semitone — "
                         + "rules out tone deafness outright.")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Color.heldDim)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                }
                .padding(.horizontal, 8)

            case .playing(let second):
                HStack(spacing: 32) {
                    noteGlyph(active: !second, label: "1")
                    noteGlyph(active: second, label: "2")
                }
                Text(second ? "second tone…" : "first tone…")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.heldDim)

            case .answering:
                Text("Which way did it go?")
                    .font(.system(size: 15, weight: .semibold, design: .serif))
                    .foregroundStyle(Color.heldText)
                HStack(spacing: 14) {
                    answerButton(title: "LOWER", symbol: "arrow.down") {
                        model.answer(higher: false)
                    }
                    answerButton(title: "HIGHER", symbol: "arrow.up") {
                        model.answer(higher: true)
                    }
                }
                Button {
                    model.replay()
                } label: {
                    Text("replay pair")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.heldBrass)
                        .underline()
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

            case .feedback(let correct, let wasHigher, let delta):
                Image(systemName: correct ? "checkmark.circle" : "xmark.circle")
                    .font(.system(size: 52))
                    .foregroundStyle(correct ? Color.heldGreen : Color.heldRed)
                Text("second was \(delta)¢ \(wasHigher ? "higher" : "lower")")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color.heldText)
            }
        }
        .frame(minHeight: 190)
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.15), value: model.phase)
    }

    private func noteGlyph(active: Bool, label: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "music.note")
                .font(.system(size: 44))
                .foregroundStyle(active ? Color.heldBrass : Color.heldLine)
                .scaleEffect(active ? 1.15 : 1.0)
                .animation(.easeOut(duration: 0.2), value: active)
            Text(label)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.heldDim)
        }
    }

    private func answerButton(title: String, symbol: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 22))
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.heldText)
        .background(Color.heldPanel)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.heldLine, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Stats
    private var statsGrid: some View {
        HStack(spacing: 12) {
            statCard("\(model.trials)", "trials")
            statCard(model.trials > 0
                     ? String(format: "%.0f%%", model.accuracy * 100) : "–",
                     "accuracy")
            statCard("\(EarModel.levels[model.bestLevelIndex])¢", "best Δ")
            statCard(model.thresholdCents.map { "\($0)¢" } ?? "–", "threshold")
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

    // The verdict is data-driven and only appears once earned.
    @ViewBuilder
    private var verdictLine: some View {
        if let t = model.thresholdCents, t <= 100 {
            Text(t <= 50
                 ? "threshold \(t)¢ — you hear differences well below a semitone. not tone deaf."
                 : "threshold \(t)¢ — you reliably hear a semitone. amusia ruled out.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.heldGreen)
                .multilineTextAlignment(.center)
        }
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
                case .idle, .feedback:
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
        case .feedback: return "Next pair"
        default: return "Cancel"
        }
    }

    private var buttonColor: Color {
        switch model.phase {
        case .idle, .feedback: return .heldBrass
        default: return .heldRed
        }
    }
}

#Preview {
    EarView()
}
