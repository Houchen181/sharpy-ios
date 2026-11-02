import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var step = 0

    var body: some View {
        VStack(spacing: 0) {
            if step > 0 {
                ProgressView(value: Double(step), total: 4)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
            }
            Group {
                switch step {
                case 0: welcome
                case 1: TopicsStep(onNext: { step = 2 })
                case 2: levelStep
                case 3: goalStep
                default: ReminderStep(onDone: finish)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)).combined(with: .opacity))
        }
        .animation(.snappy, value: step)
        .background(Palette.page)
    }

    private var welcome: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "brain.head.profile")
                .font(.system(size: 76, weight: .semibold))
                .foregroundStyle(Palette.brand.gradient)
            VStack(spacing: 12) {
                Text("Stay sharp in the age of AI")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                Text("A few minutes of real thinking a day. Questions from trusted sources, with convincing traps mixed in, and every answer backed by a citation.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            Button("Get started") { step = 1 }
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(24)
    }

    private var levelStep: some View {
        StepScaffold(
            title: "How deep should we go?",
            subtitle: "You can change this any time.",
            buttonTitle: "Continue",
            action: { step = 3 }
        ) {
            VStack(spacing: 12) {
                ForEach(Level.allCases) { level in
                    SelectableRow(selected: settings.level == level) {
                        settings.level = level
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(level.title).font(.headline)
                            Text(level.blurb).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var goalStep: some View {
        StepScaffold(
            title: "Pick a daily goal",
            subtitle: "Small and steady beats big and rare.",
            buttonTitle: "Continue",
            action: { step = 4 }
        ) {
            VStack(spacing: 12) {
                ForEach(AppSettings.goals, id: \.self) { goal in
                    SelectableRow(selected: settings.dailyGoal == goal) {
                        settings.dailyGoal = goal
                    } label: {
                        HStack {
                            Text(goalName(goal)).font(.headline)
                            Spacer()
                            Text("\(goal) questions · ~\(goal / 2) min").foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func goalName(_ goal: Int) -> String {
        switch goal {
        case ..<6: "Casual"
        case ..<11: "Regular"
        default: "Serious"
        }
    }

    private func finish() {
        settings.onboarded = true
    }
}

/// Title, subtitle, content and a bottom button: the shape of every onboarding step.
struct StepScaffold<Content: View>: View {
    let title: String
    let subtitle: String
    let buttonTitle: String
    var enabled = true
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.title.bold())
                Text(subtitle).foregroundStyle(.secondary)
            }
            .padding(.top, 24)
            ScrollView { content.padding(.vertical, 4) }
                .scrollBounceBehavior(.basedOnSize)
            Button(buttonTitle, action: action)
                .buttonStyle(PrimaryButtonStyle(color: enabled ? Palette.brand : .gray))
                .disabled(!enabled)
        }
        .padding(24)
    }
}

struct SelectableRow<Label: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Button(action: action) {
            HStack {
                label
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Palette.brand : Color.secondary)
            }
            .padding(16)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(selected ? Palette.brand : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }
}

/// Topic entry with suggestions; shared by onboarding and the profile editor.
struct TopicPicker: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var draft = ""
    @FocusState private var focused: Bool

    static let suggestions = [
        "Machine learning", "Immunology", "Quantum computing", "Macroeconomics", "Neuroscience",
        "World history", "Climate science", "Organic chemistry", "Statistics", "Cybersecurity",
        "Astrophysics", "Genetics", "Corporate finance", "Philosophy of mind", "Python programming",
        "Public health", "Linguistics", "Constitutional law",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                TextField("Add a topic, e.g. “protein folding”", text: $draft)
                    .textInputAutocapitalization(.sentences)
                    .submitLabel(.done)
                    .focused($focused)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).count < 2 || settings.topics.count >= AppSettings.maxTopics)
            }
            .padding(14)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))

            if !settings.topics.isEmpty {
                Text("Your topics (\(settings.topics.count)/\(AppSettings.maxTopics))").font(.subheadline.weight(.semibold))
                FlowLayout {
                    ForEach(settings.topics, id: \.self) { topic in
                        Button {
                            settings.topics.removeAll { $0 == topic }
                        } label: {
                            Chip(text: topic, selected: true, systemImage: "xmark")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(topic)")
                    }
                }
            }

            Text("Suggestions").font(.subheadline.weight(.semibold))
            FlowLayout {
                ForEach(Self.suggestions.filter { s in !settings.topics.contains(s) }, id: \.self) { topic in
                    Button {
                        settings.addTopic(topic)
                    } label: {
                        Chip(text: topic, systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                    .disabled(settings.topics.count >= AppSettings.maxTopics)
                }
            }
        }
    }

    private func add() {
        settings.addTopic(draft)
        draft = ""
        focused = false
    }
}

private struct TopicsStep: View {
    @EnvironmentObject private var settings: AppSettings
    let onNext: () -> Void

    var body: some View {
        StepScaffold(
            title: "What do you want to stay sharp in?",
            subtitle: "Your field, a hobby, or something you've always wanted to learn. Up to five.",
            buttonTitle: "Continue",
            enabled: !settings.topics.isEmpty,
            action: onNext
        ) {
            TopicPicker()
        }
    }
}

private struct ReminderStep: View {
    @EnvironmentObject private var settings: AppSettings
    let onDone: () -> Void

    var body: some View {
        StepScaffold(
            title: "When should we nudge you?",
            subtitle: "One reminder a day. If your streak is at risk, one more in the evening. Nothing else.",
            buttonTitle: "Turn on reminders",
            action: {
                Task {
                    settings.remindersOn = await Reminders.requestPermission()
                    onDone()
                }
            }
        ) {
            VStack(spacing: 16) {
                DatePicker("Reminder time", selection: $settings.reminderTime, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 14))
                Button("Not now") {
                    settings.remindersOn = false
                    onDone()
                }
                .foregroundStyle(.secondary)
            }
        }
    }
}
