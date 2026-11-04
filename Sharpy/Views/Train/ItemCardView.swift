import SwiftUI

/// The question and its choices. Single-answer kinds submit on tap; "select all"
/// toggles `picks` until the learner taps Check. Once answered, right picks, missed
/// answers and wrong picks are each marked.
struct ItemCardView: View {
    let item: QuizItem
    /// The submitted answer, or nil while the learner is still choosing.
    let answer: Set<Int>?
    /// Choices ticked so far on a "select all" item.
    let picks: Set<Int>
    let onTap: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Chip(text: item.topic)
                Spacer()
                Text(item.kind.label)
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
            }
            Text(item.prompt)
                .font(item.kind == .spotTheError ? .title3.weight(.semibold) : .title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            if item.kind == .trueFalse {
                HStack(spacing: 12) {
                    choice(0, systemImage: "checkmark")
                    choice(1, systemImage: "xmark")
                }
            } else {
                VStack(spacing: 10) {
                    ForEach(item.choices.indices, id: \.self) { choice($0, systemImage: nil) }
                }
            }
        }
    }

    private enum Mark {
        /// Not answered yet; `picked` marks a ticked "select all" choice.
        case idle(picked: Bool)
        /// A correct choice the learner picked.
        case answer
        /// A correct choice the learner left out ("select all" only).
        case missed
        case wrongPick
        case dimmed
    }

    private func mark(_ i: Int) -> Mark {
        guard let answer else { return .idle(picked: picks.contains(i)) }
        let correct = item.correctAnswers
        switch (correct.contains(i), answer.contains(i)) {
        case (true, true): return .answer
        case (true, false): return item.kind == .selectAll ? .missed : .answer
        case (false, true): return .wrongPick
        case (false, false): return .dimmed
        }
    }

    /// In "spot the error" the right pick is the false statement, so it's marked as the error.
    private var answerColor: Color { item.kind == .spotTheError ? Palette.trap : Palette.correct }

    private func choice(_ i: Int, systemImage: String?) -> some View {
        let m = mark(i)
        let tint: Color
        let filled: Bool
        switch m {
        case .idle(let picked):
            tint = Palette.brand
            filled = picked
        case .answer:
            tint = answerColor
            filled = true
        case .missed:
            tint = Palette.trap
            filled = false
        case .wrongPick:
            tint = Palette.wrong
            filled = true
        case .dimmed:
            tint = .secondary
            filled = false
        }
        var idle = false, dimmed = false, missed = false
        switch m {
        case .idle(false): idle = true
        case .dimmed: dimmed = true
        case .missed: missed = true
        default: break
        }
        let dash: [CGFloat] = missed ? [6, 4] : []

        return Button { onTap(i) } label: {
            HStack(alignment: .top, spacing: 10) {
                if item.kind == .selectAll {
                    Image(systemName: checkbox(m)).font(.title3).foregroundStyle(idle ? Color.secondary : tint)
                } else if let systemImage {
                    Image(systemName: systemImage).font(.headline)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.choices[i])
                        .font(item.kind == .trueFalse ? .title3.weight(.semibold) : .body.weight(.medium))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if case .answer = m, item.kind == .spotTheError {
                        Text("This is the error").font(.caption.weight(.bold)).foregroundStyle(Palette.trap)
                    }
                    if missed {
                        Text("Also correct: you missed this one").font(.caption.weight(.bold)).foregroundStyle(Palette.trap)
                    }
                }
                if item.kind != .trueFalse { Spacer(minLength: 0) }
                if item.kind != .selectAll {
                    if case .answer = m {
                        Image(systemName: item.kind == .spotTheError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(answerColor)
                    } else if case .wrongPick = m {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.wrong)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: item.kind == .trueFalse ? .center : .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, item.kind == .trueFalse ? 22 : 14)
            .background(
                RoundedRectangle(cornerRadius: 14).fill(filled ? tint.opacity(0.12) : Palette.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(idle ? Color.secondary.opacity(0.25) : (dimmed ? .clear : tint),
                            style: StrokeStyle(lineWidth: 2, dash: dash))
            )
            .foregroundStyle(idle ? Color.primary : (dimmed ? Color.secondary : tint))
            .opacity(dimmed ? 0.6 : 1)
        }
        .buttonStyle(.plain)
        .disabled(answer != nil)
        .accessibilityAddTraits(picks.contains(i) ? .isSelected : [])
    }

    private func checkbox(_ m: Mark) -> String {
        switch m {
        case .idle(let picked): picked ? "checkmark.square.fill" : "square"
        case .answer: "checkmark.square.fill"
        case .missed: "square.dashed"
        case .wrongPick: "xmark.square.fill"
        case .dimmed: "square"
        }
    }
}

/// What the learner sees after answering: verdict, explanation, misconception and sources.
struct FeedbackView: View {
    let item: QuizItem
    let correct: Bool
    let reported: Bool
    let onReport: (String) -> Void

    private var verdict: (String, String, Color) {
        switch (correct, item.isTrap) {
        case (true, true): ("Trap caught!", "shield.lefthalf.filled", Palette.trap)
        case (true, false): ("Correct", "checkmark.circle.fill", Palette.correct)
        case (false, true): ("That was a trap", "exclamationmark.triangle.fill", Palette.wrong)
        case (false, false): ("Not quite", "xmark.circle.fill", Palette.wrong)
        }
    }

    var body: some View {
        let (title, icon, color) = verdict
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(title, systemImage: icon).font(.title3.bold()).foregroundStyle(color)
                Spacer()
                if correct {
                    Text("+\(item.isTrap ? 15 : 10) XP").font(.subheadline.weight(.bold)).foregroundStyle(Palette.trap)
                }
            }
            Text(item.explanation).font(.body).fixedSize(horizontal: false, vertical: true)
            if item.isTrap && !item.misconception.isEmpty {
                Label("Common misconception: \(item.misconception)", systemImage: "lightbulb")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Sources").font(.caption.weight(.bold)).textCase(.uppercase).foregroundStyle(.secondary)
                ForEach(item.sources, id: \.url) { SourceRow(source: $0) }
            }
            HStack {
                Spacer()
                if reported {
                    Label("Removed. You won't see this question again.", systemImage: "checkmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Menu {
                        Button("The answer is wrong") { onReport("wrong_answer") }
                        Button("The source doesn't support it") { onReport("unsupported") }
                        Button("The question is confusing") { onReport("confusing") }
                    } label: {
                        Label("Something's wrong", systemImage: "flag").font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(color.opacity(0.3), lineWidth: 1))
    }
}

struct SessionSummaryView: View {
    let result: SessionResult
    let streak: Int
    let close: () -> Void

    @State private var appeared = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: result.metGoalNow ? "flame.fill" : "checkmark.seal.fill")
                .font(.system(size: 80))
                .foregroundStyle((result.metGoalNow ? Palette.flame : Palette.correct).gradient)
                .scaleEffect(appeared ? 1 : 0.4)
                .animation(.spring(response: 0.5, dampingFraction: 0.55), value: appeared)
            VStack(spacing: 8) {
                Text(result.metGoalNow ? "\(streak)-day streak!" : "Workout complete").font(.largeTitle.bold())
                Text(result.metGoalNow ? "Daily goal met. See you tomorrow." : "Every rep keeps your thinking sharp.")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                stat("\(result.xp)", "XP", "bolt.fill", Palette.trap)
                stat(result.answered > 0 ? "\(Int((Double(result.correct) / Double(result.answered) * 100).rounded()))%" : "–",
                     "Accuracy", "target", Palette.correct)
                stat("\(result.trapsCaught)/\(result.trapsSeen)", "Traps caught", "shield.lefthalf.filled", Palette.brand)
            }
            Spacer()
            Button("Done", action: close).buttonStyle(PrimaryButtonStyle())
        }
        .padding(24)
        .onAppear { appeared = true }
        .sensoryFeedback(.success, trigger: appeared)
    }

    private func stat(_ value: String, _ label: String, _ icon: String, _ color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(color)
            Text(value).font(.title2.bold()).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 14))
    }
}
