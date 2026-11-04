import Foundation

/// A failure whose message is fit to show the learner.
struct GenerationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Research → write → check, all on the phone with the learner's own provider.
/// Only items whose answer key an independent pass reproduced from the cited
/// evidence survive; typically 6–10 of the 10 drafted.
enum QuestionWriter {
    static let writerSystem = """
        You write practice items for Sharpy. Every item must be answerable from the numbered evidence you are given and nothing else.
        Some items are traps: statements that sound right but are wrong in one specific way, such as a swapped number or date, a wrong attribution, reversed cause and effect, an overgeneralization, or a popular misconception.
        A good trap is plausible to someone who half-remembers the topic, yet the evidence clearly refutes it. Never build a trap from vague wording or trick grammar; the error must be a real factual error that the explanation can point to.
        Write plainly. Explanations teach the idea in one to three sentences and state the correct fact.
        """

    static let checkerSystem = """
        You check practice items for Sharpy before learners see them. Use only the numbered evidence.
        For each item, work out which choice the evidence supports, without assuming the item's author was right.
        For true/false items answer [0] for True and [1] for False. For "which statement is wrong" items, answer with the wrong statement. For "select all that apply" items, list every choice the evidence supports, and only those.
        Set ok to false if the evidence does not settle the item, if a single-answer item has more than one defensible choice, or if the wording is misleading.
        """

    static let draftSchema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["items"],
        "properties": [
            "items": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["kind", "prompt", "choices", "answer_indices", "is_trap",
                                 "explanation", "misconception", "difficulty", "fact_ids"],
                    "properties": [
                        "kind": ["type": "string", "enum": ["true_false", "multiple_choice", "select_all", "spot_the_error"]],
                        "prompt": ["type": "string"],
                        "choices": ["type": "array", "items": ["type": "string"]],
                        "answer_indices": ["type": "array", "items": ["type": "integer"]],
                        "is_trap": ["type": "boolean"],
                        "explanation": ["type": "string"],
                        "misconception": ["type": "string"],
                        "difficulty": ["type": "integer"],
                        "fact_ids": ["type": "array", "items": ["type": "integer"]],
                    ],
                ],
            ],
        ],
    ]

    static let checkSchema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["results"],
        "properties": [
            "results": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["item", "answer_indices", "ok", "note"],
                    "properties": [
                        "item": ["type": "integer"],
                        "answer_indices": ["type": "array", "items": ["type": "integer"]],
                        "ok": ["type": "boolean"],
                        "note": ["type": "string"],
                    ],
                ],
            ],
        ],
    ]

    struct Draft: Decodable {
        let kind: ItemKind
        let prompt: String
        let choices: [String]
        let answerIndices: [Int]
        let isTrap: Bool
        let explanation: String
        let misconception: String
        let difficulty: Int
        let factIds: [Int]
    }

    private struct Drafts: Decodable {
        let items: [Draft]
    }

    private struct Verdicts: Decodable {
        struct Verdict: Decodable {
            let item: Int
            let answerIndices: [Int]
            let ok: Bool
        }
        let results: [Verdict]
    }

    /// One batch of checked questions on `topic`. `avoid` lists questions the learner
    /// already has, so a new batch covers new ground; `variety` rotates the sources
    /// read by non-Claude models.
    static func batch(topic: String, level: Level, avoid: [String], variety: Int, client: LLMClient,
                      progress: @escaping @Sendable (String) -> Void) async throws -> [QuizItem] {
        var ask = """
            Topic: \(topic)
            Learner: \(level.learner).

            Find 14 facts this learner should know or would find illuminating, spread across different subtopics. Mix core ideas with a few surprising ones, and include several facts that people commonly get wrong.
            """
        if !avoid.isEmpty {
            ask += "\nThe learner already has questions on the points below; find facts about other things.\n"
                + avoid.prefix(20).map { "- \($0)" }.joined(separator: "\n")
        }

        let facts: [Evidence]
        if client.config.nativeWebSearch {
            progress("Searching trusted sources for “\(topic)”…")
            facts = try await Research.web(ask, maxSearches: 5, client: client)
        } else {
            progress("Reading Wikipedia on “\(topic)”…")
            let docs = try await Feeds.wikipediaReading(about: topic, variety: variety)
            guard !docs.isEmpty else {
                throw GenerationError(message: "Couldn't find Wikipedia articles about “\(topic)”. Try a better-known name for it.")
            }
            progress("Picking facts from \(docs.count) articles on “\(topic)”…")
            facts = try await Research.read(docs, ask: ask, client: client)
        }
        guard facts.count >= 4 else {
            throw GenerationError(message: "Couldn't find enough well-sourced material on “\(topic)”. Try a more specific or better-known topic.")
        }

        progress("Writing questions from \(facts.count) sourced facts…")
        let evidence = Research.block(facts)
        let draft = try await client.json(Drafts.self, schemaName: "practice_items", system: writerSystem, user: """
            Topic: \(topic)
            Learner: \(level.learner).

            Evidence:
            \(evidence)

            Write 10 items:
            - 3 "true_false": the prompt is one statement; choices exactly ["True", "False"]; answer_indices [0] if the statement is true, [1] if false. At least 2 must be false traps (is_trap true).
            - 3 "multiple_choice" (single answer): the prompt is a question; exactly 4 choices, one correct, the others plausible; answer_indices holds the correct one. Set is_trap true when the most tempting wrong choice is a common misconception.
            - 2 "select_all": the prompt is a question ending "Select all that apply."; 4 or 5 choices, of which 2 or 3 are correct and the rest are plausible but wrong; answer_indices lists every correct choice. Set is_trap true when a wrong choice is a common misconception.
            - 2 "spot_the_error": the prompt is "One of these statements is wrong. Which one?"; 3 or 4 statements, all true except one subtle trap; answer_indices points to the wrong one; is_trap true.
            misconception: for traps, name the misconception in a few words; otherwise "".
            difficulty: 1 (core idea) to 3 (expert detail).
            fact_ids: the evidence numbers the item depends on.
            """, schema: draftSchema, effort: .high)

        let drafts = draft.items.filter(wellFormed)
        guard !drafts.isEmpty else { return [] }

        progress("Double-checking every answer against the sources…")
        var items: [String] = []
        for (i, d) in drafts.enumerated() {
            let choices = d.choices.enumerated().map { "   \($0.offset). \($0.element)" }.joined(separator: "\n")
            items.append("Item \(i): (\(d.kind.rawValue))\n\(d.prompt)\n\(choices)")
        }
        let check = try await client.json(Verdicts.self, schemaName: "checks", system: checkerSystem, user: """
            Evidence:
            \(evidence)

            Items:
            \(items.joined(separator: "\n\n"))
            """, schema: checkSchema, effort: .medium)

        let byID = Dictionary(uniqueKeysWithValues: facts.map { ($0.id, $0) })
        var out: [QuizItem] = []
        for (i, d) in drafts.enumerated() {
            guard let verdict = check.results.first(where: { $0.item == i }), verdict.ok,
                  Set(verdict.answerIndices) == Set(d.answerIndices) else { continue }
            var sources: [ItemSource] = []
            for id in d.factIds {
                for source in byID[id]?.sources ?? [] where !sources.contains(where: { $0.url == source.url }) {
                    sources.append(source)
                }
            }
            guard !sources.isEmpty else { continue }
            let answers = d.answerIndices.sorted()
            out.append(shuffled(QuizItem(
                id: UUID().uuidString, topic: topic, kind: d.kind,
                prompt: d.prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                choices: d.choices.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
                answerIndex: answers[0], answerIndices: answers, isTrap: d.isTrap,
                explanation: d.explanation.trimmingCharacters(in: .whitespacesAndNewlines),
                misconception: d.misconception.trimmingCharacters(in: .whitespacesAndNewlines),
                difficulty: min(3, max(1, d.difficulty)), sources: Array(sources.prefix(3)))))
        }
        return out
    }

    static func wellFormed(_ d: Draft) -> Bool {
        guard !d.prompt.trimmingCharacters(in: .whitespaces).isEmpty,
              !d.explanation.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let answers = Set(d.answerIndices)
        guard answers.count == d.answerIndices.count, answers.allSatisfy({ $0 >= 0 && $0 < d.choices.count }) else { return false }
        switch d.kind {
        case .trueFalse: return d.choices.count == 2 && answers.count == 1
        case .multipleChoice: return d.choices.count == 4 && answers.count == 1
        // At least one right and one wrong choice, so neither "tick all" nor "tick none" works.
        case .selectAll: return (4...5).contains(d.choices.count) && answers.count >= 2 && answers.count < d.choices.count
        case .spotTheError: return (3...4).contains(d.choices.count) && answers.count == 1
        }
    }

    /// Shuffles the choices of every kind except true/false, keeping the key right.
    static func shuffled(_ item: QuizItem) -> QuizItem {
        guard item.kind != .trueFalse else { return item }
        let order = Array(item.choices.indices).shuffled()
        let answers = item.correctAnswers.compactMap { order.firstIndex(of: $0) }.sorted()
        return QuizItem(id: item.id, topic: item.topic, kind: item.kind, prompt: item.prompt,
                        choices: order.map { item.choices[$0] }, answerIndex: answers[0], answerIndices: answers,
                        isTrap: item.isTrap, explanation: item.explanation, misconception: item.misconception,
                        difficulty: item.difficulty, sources: item.sources)
    }
}
