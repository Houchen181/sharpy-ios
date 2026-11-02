import Foundation
import SwiftData

/// Content for screenshot runs (-ui-demo). Every quote below is copied from the
/// linked page, so screenshots show the app exactly as it behaves for real.
enum DemoData {
    private static let antibiotic = ItemSource(
        url: "https://en.wikipedia.org/wiki/Antibiotic",
        title: "Antibiotic",
        publisher: "Wikipedia",
        quote: "A limited number of antibiotics also possess antiprotozoal activity, but antibiotics are not effective against viruses or fungi."
    )
    private static let plasmaCell = ItemSource(
        url: "https://en.wikipedia.org/wiki/Plasma_cell",
        title: "Plasma cell",
        publisher: "Wikipedia",
        quote: "Plasma cells, also called plasma B cells or effector B cells, are white blood cells that originate in the lymphoid organs as B cells and secrete large quantities of proteins called antibodies"
    )
    private static let fed = ItemSource(
        url: "https://en.wikipedia.org/wiki/Federal_Reserve",
        title: "Federal Reserve",
        publisher: "Wikipedia",
        quote: "It was created on December 23, 1913, with the enactment of the Federal Reserve Act, after a series of financial panics led to the desire for central control of the American monetary system."
    )
    private static let fedObjectives = ItemSource(
        url: "https://en.wikipedia.org/wiki/Federal_Reserve",
        title: "Federal Reserve",
        publisher: "Wikipedia",
        quote: "Congress established three key objectives for monetary policy in the Federal Reserve Act: maximizing employment, stabilizing prices, and moderating long-term interest rates."
    )
    private static let holevo = ItemSource(
        url: "https://en.wikipedia.org/wiki/Holevo%27s_theorem",
        title: "Holevo's theorem",
        publisher: "Wikipedia",
        quote: "it gives an upper bound on the accessible information, which is amount of information that can be known about a quantum state."
    )

    static let items: [QuizItem] = [
        QuizItem(
            id: "demo-antibiotics",
            topic: "Immunology",
            kind: .trueFalse,
            prompt: "Antibiotics work against viruses as well as bacteria, which is why they can shorten a common cold.",
            choices: ["True", "False"],
            answerIndex: 1,
            isTrap: true,
            explanation: "Antibiotics act on bacteria. They are not effective against viruses, and colds are caused by viruses, so antibiotics don't help a cold.",
            misconception: "Antibiotics fight any infection",
            difficulty: 1,
            sources: [antibiotic]
        ),
        QuizItem(
            id: "demo-plasma",
            topic: "Immunology",
            kind: .multipleChoice,
            prompt: "Which cells secrete large quantities of antibodies?",
            choices: ["Helper T cells", "Plasma cells", "Neutrophils", "Macrophages"],
            answerIndex: 1,
            isTrap: true,
            explanation: "Plasma cells are B cells that have differentiated to secrete antibodies. Helper T cells coordinate the response but don't make antibodies themselves.",
            misconception: "T cells make antibodies",
            difficulty: 1,
            sources: [plasmaCell]
        ),
        QuizItem(
            id: "demo-fed-goals",
            topic: "Macroeconomics",
            kind: .selectAll,
            prompt: "Which objectives did Congress set for monetary policy in the Federal Reserve Act? Select all that apply.",
            choices: [
                "Maximizing employment",
                "Balancing the federal budget",
                "Stabilizing prices",
                "Moderating long-term interest rates",
                "Fixing the dollar's exchange rate",
            ],
            answerIndex: 0,
            answerIndices: [0, 2, 3],
            isTrap: true,
            explanation: "The Act names three objectives for monetary policy: maximizing employment, stabilizing prices and moderating long-term interest rates. Balancing the budget and fixing the exchange rate aren't among them.",
            misconception: "The Fed sets the budget",
            difficulty: 2,
            sources: [fedObjectives]
        ),
        QuizItem(
            id: "demo-fed",
            topic: "Macroeconomics",
            kind: .spotTheError,
            prompt: "One of these statements is wrong. Which one?",
            choices: [
                "The Federal Reserve is the central banking system of the United States.",
                "The Federal Reserve was created in the 1930s in response to the Great Depression.",
                "Maximum employment and stable prices are often called the Fed's dual mandate.",
            ],
            answerIndex: 1,
            isTrap: true,
            explanation: "The Fed was created on December 23, 1913, by the Federal Reserve Act, after a series of financial panics. The Great Depression later expanded its role.",
            misconception: "The Fed was a Depression-era creation",
            difficulty: 2,
            sources: [fed]
        ),
        QuizItem(
            id: "demo-holevo",
            topic: "Quantum computing",
            kind: .trueFalse,
            prompt: "Holevo's theorem puts an upper bound on how much information can be learned about a quantum state.",
            choices: ["True", "False"],
            answerIndex: 0,
            isTrap: false,
            explanation: "Holevo's bound limits the accessible information in a quantum state, which is why a qubit can't be read out as an unlimited store of classical bits.",
            misconception: "",
            difficulty: 2,
            sources: [holevo]
        ),
    ]

    static let feed = DiscoverFeed(
        date: DayKey.string(),
        cards: [
            DiscoverCard(
                id: "demo-linguistics",
                kind: "field_primer",
                eyebrow: "Field of the day · Linguistics",
                title: "How language is built, layer by layer",
                body: "Linguistics is the scientific study of language. It takes language apart into layers, from speech sounds up to how context shapes what a sentence means.",
                bullets: [
                    "Syntax covers the rules governing the structure of sentences; semantics covers meaning.",
                    "Morphology studies the structure of words.",
                    "Pragmatics studies how the context of use contributes to meaning.",
                ],
                whyItMatters: "The same layers show up in how children learn to talk and how computers process text.",
                imageURL: nil,
                sources: [ItemSource(
                    url: "https://en.wikipedia.org/wiki/Linguistics",
                    title: "Linguistics",
                    publisher: "Wikipedia",
                    quote: "Linguistics is the scientific study of language."
                )],
                check: CheckQuestion(
                    question: "Which branch studies how context contributes to meaning?",
                    choices: ["Phonology", "Pragmatics", "Morphology", "Syntax"],
                    answerIndex: 1,
                    explanation: "Pragmatics is about how the context of use contributes to meaning."
                )
            ),
            DiscoverCard(
                id: "demo-iss",
                kind: "on_this_day",
                eyebrow: "On this day",
                title: "The first crew moves into the ISS",
                body: "On 2 November 2000, American astronaut William Shepherd and Russian cosmonauts Sergei Krikalev and Yuri Gidzenko arrived as Expedition 1, the station's first resident crew. They stayed 136 days, and people have lived aboard without a break ever since.",
                bullets: [],
                whyItMatters: "It began the longest continuous human presence in space.",
                imageURL: nil,
                sources: [ItemSource(
                    url: "https://en.wikipedia.org/wiki/Expedition_1",
                    title: "Expedition 1",
                    publisher: "Wikipedia",
                    quote: "The three-person crew stayed aboard the station for 136 days, from 2 November 2000 to 19 March 2001."
                )],
                check: nil
            ),
        ]
    )

    static let updates: [FieldUpdate] = [
        FieldUpdate(
            id: "demo-treg",
            topic: "Immunology",
            headline: "A distal IRF4 element drives human regulatory T cell instability",
            summary: "In a lab model, inflammatory cytokines made human regulatory T cells silence FOXP3, lose suppressive function and turn proinflammatory. Profiling pointed to a regulatory element distal to IRF4; cutting it out made the cells resistant to this reprogramming, while forcing IRF4 together with BATF pushed them to destabilize.",
            whyItMatters: "The authors see implications for designing more stable regulatory T cell therapies.",
            quote: "its excision conferred resistance to inflammatory cytokine-induced reprogramming",
            url: "https://doi.org/10.1038/s41590-026-02655-8",
            venue: "Nature Immunology",
            peerReviewed: true,
            date: "2026-09-21",
            authors: "Patrick Ho, Alexander Vu, Joey Leung et al."
        ),
        FieldUpdate(
            id: "demo-gkp",
            topic: "Quantum computing",
            headline: "A single error measure for logic gates in approximate GKP codes",
            summary: "The authors define a composable logical gate error that captures both deviation from the target gate and leakage out of the code space. Applied to approximate GKP codes, Pauli gates improve steadily with squeezing, but some Clifford implementations keep a constant error even with infinite squeezing.",
            whyItMatters: "Results that hold for ideal GKP codes may not carry over to the codes labs can actually build.",
            quote: "It shows that findings applicable to ideal GKP codes do not always translate to the realm of physically realizable approximate GKP codes.",
            url: "https://doi.org/10.22331/q-2026-10-08-2230",
            venue: "Quantum",
            peerReviewed: true,
            date: "2026-10-08",
            authors: "Lukas Brenner, Beatriz Dias, Robert Koenig"
        ),
        FieldUpdate(
            id: "demo-faultscope",
            topic: "Quantum computing",
            headline: "FaultScope traces logical errors back to individual noisy parts",
            summary: "FaultScope, a Rust simulator for quantum error correction circuits, estimates logical error rates and how they change with each component's error rate, from the same decoded shots. That attributes errors to specific noisy components. In the authors' benchmarks it was the fastest simulator tested at every size.",
            whyItMatters: "It helps identify noise hotspots for targeted noise reduction.",
            quote: "FaultScope has the lowest runtime among the tested simulators at every size.",
            url: "https://arxiv.org/abs/2610.41528v1",
            venue: "arXiv",
            peerReviewed: false,
            date: "2026-10-30",
            authors: "Yuguo Shao, Zhenyu Chen, Ningfeng Wang et al."
        ),
    ]

    /// A 12-day streak with today half done, for the Train and Profile screenshots.
    static func seed(_ context: ModelContext) {
        let calendar = Calendar.current
        for offset in 1...12 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: .now) else { continue }
            let log = DayLog(day: DayKey.string(for: day))
            log.answered = 10
            log.correct = 7 + offset % 3
            log.xp = log.correct * 10 + 10
            log.trapsSeen = 4
            log.trapsCaught = 2 + offset % 3
            log.goalMet = true
            context.insert(log)
        }
        // A missed day further back, so the calendar shows a gap.
        for offset in 14...19 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: .now) else { continue }
            let log = DayLog(day: DayKey.string(for: day))
            log.answered = 10
            log.correct = 8
            log.xp = 90
            log.trapsSeen = 3
            log.trapsCaught = 2
            log.goalMet = true
            context.insert(log)
        }
        // Half of a 10-question goal, so the tour's 5-question session completes the day.
        let today = DayLog(day: DayKey.string())
        today.answered = 5
        today.correct = 4
        today.xp = 45
        today.trapsSeen = 2
        today.trapsCaught = 1
        context.insert(today)
        for item in items.prefix(2) {
            let record = ItemRecord(item: item, now: calendar.date(byAdding: .day, value: -3, to: .now) ?? .now)
            record.lastAnswered = record.firstSeen
            record.timesWrong = 1
            record.box = 1
            record.due = calendar.date(byAdding: .day, value: -1, to: .now)
            context.insert(record)
        }
        try? context.save()
    }
}
