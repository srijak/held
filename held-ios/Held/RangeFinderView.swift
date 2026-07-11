import SwiftUI

struct RangeFinderView: View {
    @ObservedObject var engine: PitchEngine
    let apply: (Int, Int) -> Void

    @StateObject private var model: RangeFinderModel
    @Environment(\.dismiss) private var dismiss

    init(engine: PitchEngine, apply: @escaping (Int, Int) -> Void) {
        self.engine = engine
        self.apply = apply
        _model = StateObject(wrappedValue: RangeFinderModel(engine: engine))
    }

    var body: some View {
        VStack(spacing: 24) {
            Text("Find your range")
                .font(.system(size: 22, weight: .light, design: .serif))
                .foregroundStyle(Color.heldText)
                .padding(.top, 24)

            stage
            Spacer(minLength: 0)
            actionButton
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.heldBg.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onDisappear { model.cancel() }
    }

    // MARK: - Stage
    @ViewBuilder
    private var stage: some View {
        switch model.step {
        case .intro:
            instruction(
                title: "Two notes, held steady",
                body: "First your lowest comfortable note — one you could "
                    + "sing a word on, not vocal fry. Then your highest "
                    + "without strain. Hold each for about two seconds. "
                    + "Warm up first if you want a number worth keeping."
            )

        case .starting:
            VStack(spacing: 12) {
                ProgressView()
                    .tint(Color.heldBrass)
                Text("starting mic…")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.heldDim)
            }

        case .failed(let message):
            instruction(title: "Couldn't start", body: message)
                .foregroundStyle(Color.heldRed)

        case .low:
            capturePrompt(
                label: "SLIDE DOWN — LOWEST COMFORTABLE NOTE",
                sub: "hold it steady…"
            )

        case .lowCaptured(let lo):
            VStack(spacing: 8) {
                bigNote(lo, color: .heldGreen)
                Text("LOW CAPTURED")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.heldGreen)
            }

        case .high:
            capturePrompt(
                label: "SLIDE UP — HIGHEST WITHOUT STRAIN",
                sub: "hold it steady…"
            )

        case .done(let lo, let hi):
            let suggestion = RangeFinderModel.suggestedRange(lo: lo, hi: hi)
            VStack(spacing: 14) {
                HStack(spacing: 20) {
                    labeledNote("FULL LOW", lo)
                    labeledNote("FULL HIGH", hi)
                }
                Rectangle().fill(Color.heldLine).frame(height: 1)
                Text("TRAINING RANGE (edges trimmed)")
                    .font(.system(size: 10, design: .monospaced))
                    .kerning(1.2)
                    .foregroundStyle(Color.heldDim)
                HStack(spacing: 8) {
                    Text(PitchEngine.noteName(suggestion.lo))
                    Text("–").foregroundStyle(Color.heldDim)
                    Text(PitchEngine.noteName(suggestion.hi))
                }
                .font(.system(size: 34, weight: .semibold, design: .serif))
                .foregroundStyle(Color.heldBrass)

                RangeKeyboardView(
                    lo: lo, hi: hi,
                    trainLo: suggestion.lo, trainHi: suggestion.hi
                )
                .frame(height: 74)

                HStack(spacing: 14) {
                    legendSwatch(Color.heldBrass, "training")
                    legendSwatch(Color.heldGreen.opacity(0.35), "full range")
                }
            }
            .padding(20)
            .background(Color.heldPanel)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.heldLine, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func capturePrompt(label: String, sub: String) -> some View {
        VStack(spacing: 14) {
            Text(label)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.heldBrass)
                .multilineTextAlignment(.center)
            if let note = model.liveNote {
                bigNote(note, color: .heldText)
            } else {
                Text("—")
                    .font(.system(size: 72, weight: .semibold, design: .serif))
                    .foregroundStyle(Color.heldDim)
            }
            // stability progress toward the 1.5s lock
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.heldLine)
                    Capsule()
                        .fill(model.stability >= 1 ? Color.heldGreen : Color.heldBrass)
                        .frame(width: geo.size.width * model.stability)
                }
            }
            .frame(width: 200, height: 6)
            Text(sub)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.heldDim)
        }
    }

    private func bigNote(_ midi: Int, color: Color) -> some View {
        HStack(alignment: .top, spacing: 2) {
            Text(PitchEngine.noteLetter(midi))
                .font(.system(size: 72, weight: .semibold, design: .serif))
            Text("\(PitchEngine.noteOctave(midi))")
                .font(.system(size: 28, design: .serif))
                .foregroundStyle(Color.heldDim)
                .padding(.top, 8)
        }
        .foregroundStyle(color)
    }

    private func labeledNote(_ label: String, _ midi: Int) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, design: .monospaced))
                .kerning(1.0)
                .foregroundStyle(Color.heldDim)
            Text(PitchEngine.noteName(midi))
                .font(.system(size: 24, weight: .semibold, design: .serif))
                .foregroundStyle(Color.heldText)
        }
    }

    private func instruction(title: String, body text: String) -> some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.system(size: 17, weight: .semibold, design: .serif))
                .foregroundStyle(Color.heldText)
            Text(text)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Color.heldDim)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
        }
        .padding(.horizontal, 8)
    }

    private func legendSwatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 10, height: 10)
            Text(label)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Color.heldDim)
        }
    }

    // MARK: - Action button
    private var actionButton: some View {
        Group {
            if case .done(let lo, let hi) = model.step {
                HStack(spacing: 12) {
                    Button {
                        model.start()
                    } label: {
                        Text("Retry")
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.heldBrass)
                    .background(Color.heldPanel)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.heldBrass, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                    Button {
                        let s = RangeFinderModel.suggestedRange(lo: lo, hi: hi)
                        apply(s.lo, s.hi)
                        dismiss()
                    } label: {
                        Text("Use as range")
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.heldBg)
                    .background(Color.heldBrass)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            } else {
                singleActionButton
            }
        }
    }

    private var singleActionButton: some View {
        Button {
            switch model.step {
            case .intro, .failed:
                model.start()
            case .done(let lo, let hi):
                let s = RangeFinderModel.suggestedRange(lo: lo, hi: hi)
                apply(s.lo, s.hi)
                dismiss()
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

    private var buttonTitle: String {
        switch model.step {
        case .intro: return "Start"
        case .failed: return "Retry"
        default: return "Restart"
        }
    }

    private var buttonColor: Color {
        switch model.step {
        case .intro, .failed: return .heldBrass
        default: return .heldRed
        }
    }
}

// MARK: - Range keyboard
/// Piano strip: full captured range tinted green, trimmed training
/// range in brass, C notes labeled for octave landmarks.
struct RangeKeyboardView: View {
    let lo: Int
    let hi: Int
    let trainLo: Int
    let trainHi: Int

    private static let whiteClasses: Set<Int> = [0, 2, 4, 5, 7, 9, 11]

    var body: some View {
        Canvas { ctx, size in
            let dLo = max(36, lo - 2)
            let dHi = min(84, hi + 2)
            let whites = (dLo...dHi).filter { Self.whiteClasses.contains($0 % 12) }
            guard whites.count > 1 else { return }

            let w = size.width / CGFloat(whites.count)
            let labelSpace: CGFloat = 14
            let whiteH = size.height - labelSpace

            // white keys
            for (i, midi) in whites.enumerated() {
                let rect = CGRect(
                    x: CGFloat(i) * w + 0.5, y: 0,
                    width: w - 1, height: whiteH
                )
                let path = Path(roundedRect: rect, cornerRadius: 2)
                ctx.fill(path, with: .color(fill(midi, black: false)))
                ctx.stroke(path, with: .color(Color.heldLine), lineWidth: 1)
                if midi % 12 == 0 {
                    ctx.draw(
                        Text("C\(midi / 12 - 1)")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(Color.heldDim),
                        at: CGPoint(x: rect.midX, y: whiteH + labelSpace / 2 + 1)
                    )
                }
            }

            // black keys
            for (i, midi) in whites.enumerated() {
                let next = midi + 1
                guard next <= dHi, !Self.whiteClasses.contains(next % 12) else { continue }
                let bw = w * 0.58
                let rect = CGRect(
                    x: CGFloat(i + 1) * w - bw / 2, y: 0,
                    width: bw, height: whiteH * 0.62
                )
                let path = Path(roundedRect: rect, cornerRadius: 2)
                ctx.fill(path, with: .color(fill(next, black: true)))
                ctx.stroke(path, with: .color(Color.heldBg), lineWidth: 1)
            }
        }
    }

    private func fill(_ midi: Int, black: Bool) -> Color {
        if midi >= trainLo && midi <= trainHi {
            return black ? Color.heldBrass.opacity(0.7) : .heldBrass
        }
        if midi >= lo && midi <= hi {
            return black
                ? Color.heldGreen.opacity(0.45)
                : Color.heldGreen.opacity(0.30)
        }
        return black ? Color.heldBg : Color.heldPanel
    }
}

#Preview {
    RangeFinderView(engine: PitchEngine()) { _, _ in }
}
