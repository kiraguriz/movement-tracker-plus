import Domain
import Foundation

/// What a tool looked at, for "Coach looked at: 3 sessions".
public enum ToolSubject: String, Codable, Sendable {
    case sessions
    case setDetail = "set_detail"
    case nutritionDay = "nutrition_day"
    case bodyTrend = "body_trend"
    case goal
    case plan
    case mealLog = "meal_log"
    case goalChange = "goal_change"
}

/// A record of one tool call, kept with the assistant message.
public struct ToolRun: Codable, Sendable, Equatable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case ok
        case invalidArguments = "invalid_arguments"
        case unknownTool = "unknown_tool"
        case failed
        /// Not run because the model asked for more calls than one round allows.
        case skipped
    }

    /// The model's call id.
    public var id: String
    public var name: String
    public var subject: ToolSubject?
    public var status: Status
    /// How many things the tool looked at or proposed: sessions found, meals, measurements, 1 for a goal or a
    /// proposal. 0 when nothing was found.
    public var count: Int
    /// A short reason when the call did not succeed (written for the model, safe to show in a debug view).
    public var message: String?

    public init(id: String, name: String, subject: ToolSubject?, status: Status, count: Int = 0, message: String? = nil) {
        self.id = id
        self.name = name
        self.subject = subject
        self.status = status
        self.count = count
        self.message = message
    }

    /// True for the read tools that succeeded: the ones "Coach looked at" lists.
    public var isRead: Bool {
        guard status == .ok, let subject else { return false }
        switch subject {
        case .sessions, .setDetail, .nutritionDay, .bodyTrend, .goal: return true
        case .plan, .mealLog, .goalChange: return false
        }
    }
}

public struct PlanProposal: Codable, Sendable, Equatable {
    public struct Exercise: Codable, Sendable, Equatable {
        public var name: String
        public var sets: Int
        public var reps: Int
        public var restSec: Int
        public var note: String
    }

    public struct Session: Codable, Sendable, Equatable {
        public var name: String
        public var exercises: [Exercise]
    }

    public var title: String
    public var rationale: String
    /// The weekly template: one entry per training day.
    public var sessions: [Session]
}

public struct MealLogProposal: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable {
        public var name: String
        public var grams: Double
        /// An English USDA search phrase to look the food up with.
        public var usdaQuery: String
    }

    public var day: LocalDay
    public var slot: MealSlot
    public var items: [Item]
}

public struct GoalChangeProposal: Codable, Sendable, Equatable {
    public var kind: GoalKind
    public var targetWeightKg: Double?
    public var weeklyRatePercent: Double?
    public var workoutsPerWeek: Int?
    public var reason: String
}

/// Something the coach suggested that changes data. Nothing is written until the user confirms it in the app.
public struct ChatProposal: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case plan
        case mealLog = "meal_log"
        case goalChange = "goal_change"
    }

    /// The model's call id: use it to track confirmation.
    public var id: String
    public var kind: Kind
    public var plan: PlanProposal?
    public var mealLog: MealLogProposal?
    public var goalChange: GoalChangeProposal?
}

/// What CoachKit stores in `ChatMessage.toolCalls` of an assistant message.
public struct AssistantMetadata: Codable, Sendable, Equatable {
    public var version: Int
    public var tools: [ToolRun]
    public var proposals: [ChatProposal]

    /// "Coach looked at" entries: successful read tools, in call order.
    public var looked: [ToolRun] { tools.filter(\.isRead) }
}

extension ChatMessage {
    /// The tools and proposals CoachKit recorded for this assistant message, if any.
    public var coachMetadata: AssistantMetadata? {
        try? toolCalls?.decode(AssistantMetadata.self)
    }
}
