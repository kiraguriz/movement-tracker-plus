import Domain
import Foundation

// MARK: - Output

/// What Muse returns for Today's one sentence (strict schema `DailyTip`).
public struct DailyTip: Codable, Sendable, Equatable {
    public var sentence: String

    public init(sentence: String) {
        self.sentence = sentence
    }

    public static let schema: JSONValue = Schema.object([
        "sentence": Schema.string("One plain sentence of at most 20 words that explains today's suggestion."),
    ])
}

// MARK: - Input

/// What Muse is told about today's suggestion. Every number in it comes from the on-device plan (sets and reps), and
/// recovery appears only as coarse words ("below usual"), never as a measurement, and only when the caller passes it.
public struct DailyTipInput: Sendable, Equatable {
    public struct Lift: Sendable, Equatable {
        public var id: ExerciseID
        public var name: String
        public var sets: Int
        public var reps: Int

        public init(id: ExerciseID, name: String, sets: Int, reps: Int) {
            self.id = id
            self.name = name
            self.sets = sets
            self.reps = reps
        }
    }

    public struct Recovery: Sendable, Equatable {
        /// `ready`, `steady` or `easy`.
        public var band: String
        /// Signal name to `above`, `typical` or `below` (relative to the user's usual); unavailable signals are left out.
        public var signals: [String: String]
    }

    public var day: LocalDay
    public var kind: String
    public var bucket: String?
    public var lifts: [Lift]
    public var reasons: [String]
    public var recovery: Recovery?

    public init(day: LocalDay, kind: String, bucket: String?, lifts: [Lift], reasons: [String], recovery: Recovery?) {
        self.day = day
        self.kind = kind
        self.bucket = bucket
        self.lifts = lifts
        self.reasons = reasons
        self.recovery = recovery
    }

    /// - Parameters:
    ///   - names: display names by exercise id; an id without one is named by the id.
    ///   - readiness: pass it only when the user allowed Muse to see a recovery summary. Without it neither the band
    ///     nor any reason that comes from sleep, HRV or resting heart rate is included.
    public init(
        day: LocalDay, recommendation: TodayRecommendation, names: [ExerciseID: String] = [:], readiness: ReadinessResult? = nil
    ) {
        let shareable = readiness != nil
        self.init(
            day: day,
            kind: recommendation.kind.rawValue,
            bucket: recommendation.bucket?.rawValue,
            lifts: recommendation.lifts.map {
                Lift(id: $0.exerciseID, name: names[$0.exerciseID] ?? $0.exerciseID.rawValue, sets: $0.prescription.sets, reps: $0.prescription.reps)
            },
            reasons: recommendation.reasons.compactMap { reason in
                switch reason {
                case .sleepShort, .hrvBelow, .restingHeartRateAbove: shareable ? Self.code(reason) : nil
                default: Self.code(reason)
                }
            },
            recovery: readiness.map { readiness in
                var signals: [String: String] = [:]
                for reading in readiness.readings {
                    switch reading.state {
                    case .above: signals[reading.signal.rawValue] = "above"
                    case .typical: signals[reading.signal.rawValue] = "typical"
                    case .below: signals[reading.signal.rawValue] = "below"
                    case .unavailable: break
                    }
                }
                return Recovery(band: readiness.band.rawValue, signals: signals)
            }
        )
    }

    private static func code(_ reason: TodayReason) -> String {
        switch reason {
        case .firstSession: "first_session"
        case .rested(let bucket): "\(bucket.rawValue)_rested"
        case .progress: "add_a_rep"
        case .weekDone: "weekly_target_done"
        case .notRecovered: "still_recovering"
        case .loadHigh: "heavy_training_lately"
        case .sleepShort: "short_sleep"
        case .hrvBelow: "hrv_below_usual"
        case .restingHeartRateAbove: "resting_heart_rate_above_usual"
        case .todayDone: "done_today"
        }
    }

    var json: JSONValue {
        .compact([
            "day": .string(day.string),
            "suggestion": .compact([
                "kind": .string(kind),
                "bucket": bucket.map(JSONValue.string),
                "exercises": .array(lifts.map {
                    ["id": .string($0.id.rawValue), "name": .string($0.name), "sets": .int($0.sets), "reps": .int($0.reps)]
                }),
                "reasons": .array(reasons.map(JSONValue.string)),
            ]),
            "recovery": recovery.map { recovery in
                .compact([
                    "band": .string(recovery.band),
                    "signals": .object(recovery.signals.mapValues(JSONValue.string)),
                ])
            },
        ])
    }

    /// The only numbers the sentence may contain.
    var allowedNumbers: Set<String> {
        Set(lifts.flatMap { [String($0.sets), String($0.reps)] })
    }
}

// MARK: - Validation

extension DailyTip {
    static let maximumLength = 220
    /// Words a training sentence has no business using. Lowercase; matched as substrings.
    static let forbidden = ["diagnos", "disease", "illness", "syndrome", "disorder", "cardiac", "medical advice", "诊断", "疾病", "病症", "综合征"]

    func validated(for input: DailyTipInput) throws -> DailyTip {
        let text = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CoachError.malformedOutput("sentence is empty.") }
        guard text.count <= Self.maximumLength else {
            throw CoachError.malformedOutput("sentence is longer than \(Self.maximumLength) characters. Write one short sentence.")
        }
        guard !text.contains(where: \.isNewline) else { throw CoachError.malformedOutput("sentence must be one line.") }
        let lowered = text.lowercased()
        if let word = Self.forbidden.first(where: { lowered.contains($0) }) {
            throw CoachError.malformedOutput("sentence uses \"\(word)\". Do not use medical language.")
        }
        let allowed = input.allowedNumbers
        for number in Self.numbers(in: text) where !allowed.contains(number) {
            let list = allowed.sorted().joined(separator: ", ")
            throw CoachError.malformedOutput("sentence mentions the number \(number), which is not in the data. Use only these numbers: \(list.isEmpty ? "none" : list).")
        }
        return DailyTip(sentence: text)
    }

    /// Every run of digits (with an optional decimal part), as written.
    static func numbers(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var previousWasDigit = false
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            if character.isASCII && character.isNumber {
                current.append(character)
                previousWasDigit = true
            } else if previousWasDigit, character == "." || character == ",",
                      index + 1 < characters.count, characters[index + 1].isASCII, characters[index + 1].isNumber {
                current.append(".")
                previousWasDigit = false
            } else {
                if !current.isEmpty { result.append(current) }
                current = ""
                previousWasDigit = false
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

// MARK: - Service

extension CoachService {
    /// Today's sentence, at most one per local day. A stored Muse sentence of the same language for this day is
    /// returned without a call even when the input has changed since. There is no on-device fallback here and nothing
    /// is stored when Muse fails: this throws, and the caller keeps showing its own text.
    public func dailyTip(_ input: DailyTipInput, locale: CoachLocale) async throws -> InsightResult<DailyTip> {
        let subject = input.day.string
        let saved = (try? await runner.insights.insights(subjectID: subject, kind: .dailyTip)) ?? []
        for insight in saved {
            if let envelope = try? insight.envelope(DailyTip.self), envelope.origin == .muse, envelope.locale == locale.rawValue {
                return InsightResult(
                    output: envelope.output, origin: .muse, fromCache: true, insight: insight, whatMuseSaw: envelope.saw,
                    offlineReason: nil, storeFailed: false, usage: .zero
                )
            }
        }
        return try await runner.run(dailyTipPlan(input, locale: locale))
    }

    func dailyTipPlan(_ input: DailyTipInput, locale: CoachLocale) -> InsightPlan<DailyTip> {
        // The proxy has no feature of its own for this yet, so it travels as a debrief.
        let feature = CoachFeature.debrief
        let json = input.json
        let effort = ReasoningEffort.low
        return InsightPlan(
            kind: .dailyTip,
            feature: feature,
            subjectID: input.day.string,
            promptVersion: PromptVersion.dailyTip,
            locale: locale,
            model: .sparkLatest,
            effort: effort,
            maxOutputTokens: CoachFeature.minimumOutputTokens,
            stream: false,
            developerText: Prompts.dailyTip(locale: locale),
            userParts: [.inputText("Explain today's suggestion in one sentence.\n\nData (JSON):\n\(json.canonicalString)")],
            format: StructuredFormat(name: "DailyTip", schema: DailyTip.schema),
            saw: WhatMuseSaw(
                feature: feature.rawValue, model: MuseModel.sparkLatest.rawValue, promptVersion: PromptVersion.dailyTip,
                effort: effort.rawValue, locale: locale.rawValue, input: json, images: []
            ),
            inputHash: InsightHasher.hash(
                feature: feature, promptVersion: PromptVersion.dailyTip, model: .sparkLatest, effort: effort, locale: locale,
                subjectID: input.day.string, input: json, images: []
            ),
            validate: { try $0.validated(for: input) },
            fallback: nil
        )
    }
}
