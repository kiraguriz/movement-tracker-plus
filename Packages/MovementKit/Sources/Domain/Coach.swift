import Foundation

/// What a stored coach insight is. Open-ended on purpose: new kinds need no schema change.
public struct InsightKind: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let setReview: InsightKind = "set_review"
    public static let sessionDebrief: InsightKind = "session_debrief"
    public static let mealEstimate: InsightKind = "meal_estimate"
    public static let dailyTip: InsightKind = "daily_tip"
    public static let weeklyCheck: InsightKind = "weekly_check"
}

/// A cached model output. Looked up by `(kind, inputHash)`, so the same input is never paid for twice.
/// `inputHash` must cover everything that shapes the answer, including the prompt version.
public struct CoachInsight: Equatable, Sendable, Identifiable {
    public var id: EntityID
    public var kind: InsightKind
    /// What the insight is about: a session id, a set id, a local day, or nil.
    public var subjectID: String?
    public var inputHash: String
    public var model: String
    public var promptVersion: String
    public var payload: JSONPayload
    public var inputTokens: Int
    public var outputTokens: Int
    public var createdAt: Date

    public init(
        id: EntityID,
        kind: InsightKind,
        subjectID: String? = nil,
        inputHash: String,
        model: String,
        promptVersion: String,
        payload: JSONPayload,
        inputTokens: Int,
        outputTokens: Int,
        createdAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.subjectID = subjectID
        self.inputHash = inputHash
        self.model = model
        self.promptVersion = promptVersion
        self.payload = payload
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.createdAt = createdAt
    }
}

/// Model tokens spent, for per-kind daily budgets.
public struct TokenUsage: Equatable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var insightCount: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0, insightCount: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.insightCount = insightCount
    }
}

public struct ChatThread: Equatable, Sendable, Identifiable {
    public var id: EntityID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: EntityID, title: String, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum ChatRole: String, Codable, CaseIterable, Sendable {
    case user
    case assistant
    case tool
    case system
}

public enum ChatMessageStatus: String, Codable, CaseIterable, Sendable {
    case sent
    /// Created locally and waiting to go out (or waiting for the reply).
    case pending
    /// The send failed; the message stays so it can be retried.
    case failed
}

public struct ChatMessage: Equatable, Sendable, Identifiable {
    public var id: EntityID
    public var threadID: EntityID
    public var role: ChatRole
    public var content: String
    /// Tool calls and results as CoachKit shaped them.
    public var toolCalls: JSONPayload?
    public var status: ChatMessageStatus
    public var createdAt: Date

    public init(
        id: EntityID,
        threadID: EntityID,
        role: ChatRole,
        content: String,
        toolCalls: JSONPayload? = nil,
        status: ChatMessageStatus = .sent,
        createdAt: Date
    ) {
        self.id = id
        self.threadID = threadID
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.status = status
        self.createdAt = createdAt
    }
}
