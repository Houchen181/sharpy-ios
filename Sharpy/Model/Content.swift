import Foundation

/// How deep the questions go. Banks are shared per topic + level on the server.
enum Level: String, CaseIterable, Codable, Identifiable {
    case curious, student, pro

    var id: String { rawValue }

    var title: String {
        switch self {
        case .curious: "Curious"
        case .student: "Student"
        case .pro: "Professional"
        }
    }

    var blurb: String {
        switch self {
        case .curious: "I'm interested but have no formal training."
        case .student: "I'm studying it or took courses in it."
        case .pro: "I work in this field. Go past the textbook."
        }
    }
}

/// A page Claude found through web search, with the exact excerpt it cited.
struct ItemSource: Codable, Hashable {
    let url: String
    let title: String
    let publisher: String
    let quote: String
}

enum ItemKind: String, Codable {
    case trueFalse = "true_false"
    case multipleChoice = "multiple_choice"
    case selectAll = "select_all"
    case spotTheError = "spot_the_error"

    var label: String {
        switch self {
        case .trueFalse: "True or false?"
        case .multipleChoice: "Pick one"
        case .selectAll: "Select all that apply"
        case .spotTheError: "Spot the error"
        }
    }
}

struct QuizItem: Codable, Identifiable, Hashable {
    let id: String
    let topic: String
    let kind: ItemKind
    let prompt: String
    /// ["True", "False"] for true/false items.
    let choices: [String]
    let answerIndex: Int
    /// Every correct choice; only "select all" items have more than one.
    var answerIndices: [Int]? = nil
    /// A convincing wrong statement, or a question baited with a common misconception.
    let isTrap: Bool
    let explanation: String
    let misconception: String
    let difficulty: Int
    let sources: [ItemSource]

    var correctAnswers: Set<Int> { Set(answerIndices ?? [answerIndex]) }
}

struct CheckQuestion: Codable, Hashable {
    let question: String
    let choices: [String]
    let answerIndex: Int
    let explanation: String
}

struct DiscoverCard: Codable, Identifiable, Hashable {
    let id: String
    let kind: String
    let eyebrow: String
    let title: String
    let body: String
    let bullets: [String]
    let whyItMatters: String
    let imageURL: String?
    let sources: [ItemSource]
    let check: CheckQuestion?
}

struct DiscoverFeed: Codable {
    let date: String
    let cards: [DiscoverCard]
}

/// A new paper in one of the learner's topics, summarized from its abstract.
struct FieldUpdate: Codable, Identifiable, Hashable {
    let id: String
    let topic: String
    let headline: String
    let summary: String
    let whyItMatters: String
    let quote: String
    let url: String
    let venue: String
    let peerReviewed: Bool
    let date: String
    let authors: String
}
