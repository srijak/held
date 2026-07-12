import SwiftUI

struct QuizView: View {
    @StateObject private var model: QuizModel

    init(tracks: [QuizModel.QuizTrack], allTitles: [String]) {
        _model = StateObject(wrappedValue: QuizModel(tracks: tracks, allTitles: allTitles))
    }

    var body: some View {
        VStack(spacing: 16) {
            statRow
            snippetCard
            optionList
            Spacer(minLength: 0)
            bottomButton
        }
        .padding(16)
        .background(Color.heldBg.ignoresSafeArea())
        .navigationTitle("Name That Tune")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.heldBg, for: .navigationBar)
        .preferredColorScheme(.dark)
        .onDisappear { model.stop() }
    }

    private var statRow: some View {
        HStack(spacing: 12) {
            stat(value: "\(model.streak)", label: "streak",
                 highlight: model.streak > 0)
            stat(value: "\(model.bestStreak)", label: "best", highlight: false)
            stat(value: model.phase == .idle ? "—"
                    : model.useBacking ? "\(Int(model.bandSeconds))s" : "\(model.notesToPlay)",
                 label: model.useBacking ? "clip length" : "notes played",
                 highlight: model.notesToPlay <= 3)
        }
    }

    private func stat(value: String, label: String, highlight: Bool) -> some View {
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

    private var snippetCard: some View {
        VStack(spacing: 10) {
            if model.backingModeAvailable {
                Picker("Source", selection: $model.useBacking) {
                    Text("Vocal").tag(false)
                    Text("Band").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
                .onChange(of: model.useBacking) { _ in
                    if model.phase != .idle { model.play() }
                }
            }
            if model.phase == .idle {
                Text("The first notes of a song from your library.\nFewer notes as your streak grows.")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.heldDim)
                    .multilineTextAlignment(.center)
            } else {
                Button { model.play() } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 44))
                        Text(model.useBacking
                             ? "replay opening \(Int(model.bandSeconds))s of the band"
                             : "replay first \(model.notesToPlay) notes")
                            .font(.system(size: 11, design: .monospaced))
                    }
                    .foregroundStyle(Color.heldBrass)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
        .background(Color.heldPanel)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.heldLine, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var optionList: some View {
        if model.phase != .idle {
            VStack(spacing: 10) {
                ForEach(model.options, id: \.self) { title in
                    optionButton(title)
                }
            }
        }
    }

    private func optionButton(_ title: String) -> some View {
        let state = optionState(title)
        return Button { model.answer(title) } label: {
            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .serif))
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(state.fg)
        .background(state.bg)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(state.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .disabled(!isAwaitingAnswer)
    }

    private var isAwaitingAnswer: Bool {
        if case .playing = model.phase { return true }
        return false
    }

    private func optionState(_ title: String) -> (fg: Color, bg: Color, border: Color) {
        if case let .answered(_, picked) = model.phase {
            if title == model.correctTitle {
                return (Color.heldBg, Color.heldGreen, Color.heldGreen)
            }
            if title == picked {
                return (Color.heldBg, Color.heldRed, Color.heldRed)
            }
            return (Color.heldDim, Color.heldPanel, Color.heldLine)
        }
        return (Color.heldText, Color.heldPanel, Color.heldLine)
    }

    private var bottomButton: some View {
        Button {
            model.startRound()
        } label: {
            Text(model.phase == .idle ? "Start" : nextLabel)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.heldBg)
        .background(Color.heldBrass)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .opacity(isAwaitingAnswer ? 0 : 1)
        .disabled(isAwaitingAnswer)
    }

    private var nextLabel: String {
        if case let .answered(correct, _) = model.phase {
            return correct ? "Next" : "Next (back to 5 notes)"
        }
        return "Next"
    }
}
