import SwiftUI

struct QuizView: View {
    @StateObject private var model: QuizModel
    @State private var playerCount = 1
    @State private var names = ["", "", "", ""]

    init(tracks: [QuizModel.QuizTrack], allTitles: [String]) {
        _model = StateObject(wrappedValue: QuizModel(tracks: tracks, allTitles: allTitles))
    }

    var body: some View {
        VStack(spacing: 16) {
            if model.phase == .idle {
                playerSetup
            } else if model.isMultiplayer {
                scoreboard
            }
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
        .onAppear {
            playerCount = model.players.count
            for (i, p) in model.players.prefix(4).enumerated() { names[i] = p.name }
        }
    }

    // MARK: - Players

    private var playerSetup: some View {
        VStack(spacing: 10) {
            HStack {
                Text("PLAYERS")
                    .font(.system(size: 10, design: .monospaced)).kerning(1.2)
                    .foregroundStyle(Color.heldDim)
                Spacer()
                Picker("", selection: $playerCount) {
                    ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 180)
            }
            if playerCount > 1 {
                ForEach(0..<playerCount, id: \.self) { i in
                    TextField("Player \(i + 1)", text: $names[i])
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Color.heldText)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(Color.heldBg)
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.heldLine, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                Text("pass the phone — each player keeps their own streak")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.heldDim)
            }
        }
        .padding(12)
        .background(Color.heldPanel)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.heldLine, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var scoreboard: some View {
        HStack(spacing: 8) {
            ForEach(model.players) { p in
                let active = p.id == model.currentPlayerIndex
                HStack(spacing: 6) {
                    Text(p.name)
                        .font(.system(size: 12, weight: active ? .bold : .regular,
                                      design: .serif))
                    Text("\(p.score)")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                }
                .foregroundStyle(active ? Color.heldBg : Color.heldText)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(active ? Color.heldBrass : Color.heldPanel)
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .stroke(active ? Color.heldBrass : Color.heldLine, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            Spacer()
        }
    }

    private var statRow: some View {
        HStack(spacing: 12) {
            stat(value: "\(model.streak)", label: "streak",
                 highlight: model.streak > 0)
            stat(value: "\(model.bestStreak)", label: "best", highlight: false)
            stat(value: clipStat.0, label: clipStat.1,
                 highlight: model.notesToPlay <= 3 && model.quizSource != .reverse)
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

    private var replayLabel: String {
        switch model.quizSource {
        case .vocal: return "replay first \(model.notesToPlay) notes"
        case .band: return "replay opening \(Int(model.bandSeconds))s of the band"
        case .reverse: return "replay \(Int(QuizModel.reverseSeconds))s, reversed"
        }
    }

    private var clipStat: (String, String) {
        if model.phase == .idle { return ("—", "clip") }
        switch model.quizSource {
        case .vocal: return ("\(model.notesToPlay)", "notes played")
        case .band: return ("\(Int(model.bandSeconds))s", "clip length")
        case .reverse: return ("\(Int(QuizModel.reverseSeconds))s", "reversed")
        }
    }

    private var snippetCard: some View {
        VStack(spacing: 10) {
            if model.backingModeAvailable {
                Picker("Source", selection: $model.quizSource) {
                    ForEach(QuizModel.QuizSource.allCases, id: \.self) { src in
                        Text(src.title).tag(src)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
                .onChange(of: model.quizSource) { _ in
                    if model.phase != .idle { model.play() }
                }
            }
            if model.phase == .idle {
                Text("The first notes of a song from your library.\nFewer notes as your streak grows.")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.heldDim)
                    .multilineTextAlignment(.center)
            } else {
                if model.isMultiplayer {
                    Text("\(model.currentPlayer.name)'s turn")
                        .font(.system(size: 13, weight: .bold, design: .serif))
                        .foregroundStyle(Color.heldBrass)
                }
                Button { model.play() } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 44))
                        Text(replayLabel)
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
            if model.phase == .idle {
                model.configurePlayers(Array(names.prefix(playerCount)))
                model.startRound()
            } else {
                model.nextRound()
            }
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
            if model.isMultiplayer {
                return "Pass to \(model.nextPlayerName)"
            }
            return correct ? "Next" : "Next (back to 5 notes)"
        }
        return "Next"
    }
}
