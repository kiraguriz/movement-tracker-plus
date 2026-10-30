#if DEBUG
import CoachKit
import Foundation

/// A canned, in-process stand-in for the coach proxy, for UI tests and offline walkthroughs. Debug builds only:
/// this file is not compiled into Release, and `-MTCoachStub` is ignored there.
///
/// It sits under the real `CoachClient` as an `HTTPTransport`, so the client, the chat tool loop, the insight cache
/// and the screens all run as they do against the proxy. What it answers is scripted, never a model:
///
/// - `POST /v1/coach/responses`, feature `chat`: an SSE stream. The first request of a turn answers with tool calls
///   (reads and a proposal, chosen by words in the user's message); once the tool results are in the request, it
///   streams a short answer built from those results.
/// - feature `meal_photo`: one JSON response with a fixed three-item estimate. The photo is not looked at.
/// - `GET /v1/food/search`: a small USDA-shaped catalog, with a per-100-ml item and one with missing nutrients.
/// - `set_review`, `debrief`: answered as a paused service, so those screens use their on-device fallback.
///
/// The UI marks every stub-backed screen (`StubBadge`) so nothing reads as Muse output.
nonisolated enum CoachStub {
    static let baseURL = URL(string: "https://coach-stub.invalid")!

    /// `failure` is the value of `-MTCoachStubFail` (`offline`, `budget` or `paused`) or nil.
    static func makeClient(failure: String?) -> CoachClient {
        CoachClient(
            baseURL: baseURL,
            tokenStore: InMemoryTokenStore(token: "stub-install-token"),
            transport: StubTransport(failure: failure.flatMap(StubTransport.Failure.init(rawValue:))),
            retry: .none
        )
    }
}

nonisolated struct StubTransport: HTTPTransport {
    nonisolated enum Failure: String, Sendable {
        case offline, budget, paused
    }

    var failure: Failure?

    // MARK: HTTPTransport

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let route = Route(request)
        switch route {
        case .install:
            return Self.json(201, ["token": "stub-install-token", "expiresAt": "2099-01-01T00:00:00.000Z"])
        case .health:
            return Self.json(200, ["ok": true, "killSwitch": .bool(failure == .paused)])
        default:
            break
        }
        if let rejected = try rejection() { return rejected }
        switch route {
        case .food:
            try await Task.sleep(for: .milliseconds(220))
            return Self.json(200, StubFoods.page(for: request.url))
        case .coach("meal_photo"):
            try await Task.sleep(for: .milliseconds(900))
            return Self.json(200, Self.response(items: [Self.message(StubChat.mealEstimateJSON(language: StubChat.language(of: request)))]))
        case .coach:
            return Self.pausedFeature
        case .other, .install, .health:
            return Self.json(404, Self.errorBody("not_found", "No such stub route."))
        }
    }

    func openStream(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
        let route = Route(request)
        if let rejected = try rejection() {
            return HTTPStreamResponse(
                status: rejected.status, headers: rejected.headers,
                body: AsyncThrowingStream { $0.yield(rejected.body); $0.finish() }
            )
        }
        guard case .coach("chat") = route else {
            let paused = Self.pausedFeature
            return HTTPStreamResponse(status: paused.status, headers: paused.headers, body: AsyncThrowingStream { $0.yield(paused.body); $0.finish() })
        }
        let script = StubChat.script(for: request)
        let body = AsyncThrowingStream<Data, any Error> { continuation in
            let task = Task {
                for step in script {
                    do { try await Task.sleep(for: .milliseconds(step.delayMilliseconds)) } catch { break }
                    continuation.yield(step.chunk)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return HTTPStreamResponse(status: 200, headers: ["content-type": "text/event-stream"], body: body)
    }

    // MARK: Failures

    /// The response for `-MTCoachStubFail`, or nil when the stub should answer normally. `offline` throws.
    private func rejection() throws -> HTTPResponse? {
        switch failure {
        case nil:
            return nil
        case .offline:
            throw URLError(.notConnectedToInternet)
        case .budget:
            return Self.json(429, Self.errorBody("daily_budget_exceeded", "Daily budget used."), headers: ["retry-after": "3600"])
        case .paused:
            return Self.json(503, Self.errorBody("service_paused", "The service is paused."), headers: ["retry-after": "300"])
        }
    }

    private static var pausedFeature: HTTPResponse {
        json(503, errorBody("service_paused", "The stub does not write this feature."), headers: ["retry-after": "300"])
    }

    // MARK: Routes

    nonisolated enum Route {
        case install, health, food, coach(String), other

        init(_ request: HTTPRequest) {
            let path = request.url.path
            if path.hasSuffix("/v1/install") {
                self = .install
            } else if path.hasSuffix("/v1/health") {
                self = .health
            } else if path.hasSuffix("/v1/food/search") {
                self = .food
            } else if path.hasSuffix("/v1/coach/responses") {
                self = .coach(request.header("X-Coach-Feature") ?? "")
            } else {
                self = .other
            }
        }
    }

    // MARK: JSON helpers

    static func json(_ status: Int, _ body: JSONValue, headers: [String: String] = [:]) -> HTTPResponse {
        HTTPResponse(status: status, headers: headers.merging(["content-type": "application/json"]) { first, _ in first }, body: body.canonicalData())
    }

    static func errorBody(_ code: String, _ message: String) -> JSONValue {
        ["error": ["code": .string(code), "message": .string(message)]]
    }

    static func message(_ text: String, id: String = "msg_stub") -> JSONValue {
        ["type": "message", "role": "assistant", "id": .string(id), "content": [["type": "output_text", "text": .string(text)]]]
    }

    static func response(items: [JSONValue], status: String = "completed") -> JSONValue {
        [
            "id": "resp_stub", "object": "response", "status": .string(status), "model": "coach-stub",
            "output": .array(items),
            "usage": ["input_tokens": 0, "output_tokens": 0, "input_tokens_details": ["cached_tokens": 0], "output_tokens_details": ["reasoning_tokens": 0]],
        ]
    }
}

// MARK: - Chat

/// The scripted chat turns.
nonisolated enum StubChat {
    nonisolated struct Step: Sendable {
        var delayMilliseconds: Int
        var chunk: Data
    }

    nonisolated enum Scenario {
        case training, mealLog, goalChange, plan

        init(userText: String) {
            let text = userText.lowercased()
            func has(_ words: [String]) -> Bool { words.contains { text.contains($0) } }
            if has(["log", "breakfast", "ate ", "eggs", "记录", "早餐", "吃了"]) {
                self = .mealLog
            } else if has(["plan", "program", "计划", "安排"]) {
                self = .plan
            } else if has(["goal", "cut", "lose", "bulk", "目标", "减脂", "减重"]) {
                self = .goalChange
            } else {
                self = .training
            }
        }
    }

    static func language(of request: HTTPRequest) -> CoachLanguage {
        let body = request.body.flatMap { try? JSONValue(jsonData: $0) }
        let developer = (body?["input"]?.arrayValue ?? [])
            .filter { $0["role"]?.stringValue == "developer" }
            .flatMap { $0["content"]?.arrayValue ?? [] }
            .compactMap { $0["text"]?.stringValue }
            .joined()
        return developer.contains("Simplified Chinese") ? .zh : .en
    }

    nonisolated enum CoachLanguage {
        case en, zh
    }

    // MARK: Script

    static func script(for request: HTTPRequest) -> [Step] {
        let body = request.body.flatMap { try? JSONValue(jsonData: $0) }
        let input = body?["input"]?.arrayValue ?? []
        let language = language(of: request)

        let lastUser = input.lastIndex { $0["type"]?.stringValue == "message" && $0["role"]?.stringValue == "user" }
        let userText = lastUser.map { index in
            (input[index]["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined()
        } ?? ""
        let afterUser = lastUser.map { Array(input[($0 + 1)...]) } ?? []
        let scenario = Scenario(userText: userText)

        let calls = afterUser.filter { $0["type"]?.stringValue == "function_call" }
        guard !calls.isEmpty else { return toolRound(scenario, language: language) }

        var outputs: [String: JSONValue] = [:]
        var names: [String: String] = [:]
        for call in calls { names[call["call_id"]?.stringValue ?? ""] = call["name"]?.stringValue }
        for item in afterUser where item["type"]?.stringValue == "function_call_output" {
            guard let id = item["call_id"]?.stringValue, let name = names[id],
                  let text = item["output"]?.stringValue, let value = try? JSONValue(jsonString: text) else { continue }
            outputs[name] = value
        }
        return answerRound(scenario, language: language, outputs: outputs)
    }

    // MARK: Rounds

    private static func call(_ name: String, _ arguments: JSONValue) -> JSONValue {
        let id = "call_stub_" + UUID().uuidString.prefix(8).lowercased()
        return [
            "type": "function_call", "id": .string("fc_" + id), "call_id": .string(id), "name": .string(name),
            "arguments": .string(arguments.canonicalString), "status": "completed",
        ]
    }

    private static func toolRound(_ scenario: Scenario, language: CoachLanguage) -> [Step] {
        var calls: [JSONValue]
        switch scenario {
        case .training:
            calls = [call("get_sessions", ["days": 14]), call("get_goal", [:])]
        case .mealLog:
            calls = [call("get_nutrition", ["day": "today"]), call("propose_meal_log", mealLogArguments(language))]
        case .goalChange:
            calls = [call("get_goal", [:]), call("get_body_trend", ["days": 30]), call("propose_goal_change", goalChangeArguments(language))]
        case .plan:
            calls = [call("get_sessions", ["days": 14]), call("propose_plan", planArguments(language))]
        }
        var steps: [Step] = [Step(delayMilliseconds: 350, chunk: event(["type": "response.created", "response": ["id": "resp_stub", "status": "in_progress"]]))]
        for (index, item) in calls.enumerated() {
            steps.append(Step(delayMilliseconds: 40, chunk: event(["type": "response.output_item.done", "output_index": .int(index), "item": item])))
        }
        steps.append(Step(delayMilliseconds: 40, chunk: event(["type": "response.completed", "response": StubTransport.response(items: calls)])))
        steps.append(Step(delayMilliseconds: 0, chunk: Data("data: [DONE]\n\n".utf8)))
        return steps
    }

    private static func answerRound(_ scenario: Scenario, language: CoachLanguage, outputs: [String: JSONValue]) -> [Step] {
        let text = answerText(scenario, language: language, outputs: outputs)
        var steps: [Step] = [
            Step(delayMilliseconds: 250, chunk: event(["type": "response.created", "response": ["id": "resp_stub", "status": "in_progress"]])),
            Step(delayMilliseconds: 0, chunk: Data(": keepalive\n\n".utf8)),
        ]
        for piece in pieces(of: text) {
            steps.append(Step(delayMilliseconds: 45, chunk: event([
                "type": "response.output_text.delta", "item_id": "msg_stub", "output_index": 0, "content_index": 0, "delta": .string(piece),
            ])))
        }
        let message = StubTransport.message(text)
        // The finished text stays on screen with the stop button for a moment, so a screenshot or a UI test can see it.
        steps.append(Step(delayMilliseconds: 20, chunk: event(["type": "response.output_item.done", "output_index": 0, "item": message])))
        steps.append(Step(delayMilliseconds: 1200, chunk: event(["type": "response.completed", "response": StubTransport.response(items: [message])])))
        steps.append(Step(delayMilliseconds: 0, chunk: Data("data: [DONE]\n\n".utf8)))
        return steps
    }

    /// The text in pieces of a few words, spaces kept, so the screen shows it growing.
    private static func pieces(of text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var words = 0
        for character in text {
            current.append(character)
            if character == " " || character == "\n" {
                words += 1
                if words == 3 { result.append(current); current = ""; words = 0 }
            } else if character.unicodeScalars.contains(where: { $0.value >= 0x2E80 }), current.count >= 4 {
                // Chinese has no spaces: cut every few characters.
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func event(_ json: JSONValue) -> Data {
        Data("data: \(json.canonicalString)\n\n".utf8)
    }

    // MARK: Answers (built from the tool results the request carries)

    private static func answerText(_ scenario: Scenario, language: CoachLanguage, outputs: [String: JSONValue]) -> String {
        let zh = language == .zh
        switch scenario {
        case .training, .plan:
            let sessions = outputs["get_sessions"]?["sessions"]?.arrayValue ?? []
            let reps = sessions.reduce(0) { $0 + ($1["totalReps"]?.intValue ?? 0) }
            let kcal = outputs["get_goal"]?["goal"]?["kcal"]?.intValue
            if scenario == .plan {
                let seen = sessions.isEmpty ? (zh ? "我还没看到最近的训练记录，所以先从基础开始。" : "I don't see recent workouts yet, so this starts from the basics.")
                    : (zh ? "最近 14 天你有 \(sessions.count) 次训练，这个安排在此基础上递进。" : "You trained \(sessions.count) time\(sessions.count == 1 ? "" : "s") in the last 14 days, so this builds on that.")
                return zh
                    ? "\(seen)我给你准备了一份每周两天的计划，放在下面的卡片里。你确认之前不会保存任何内容。"
                    : "\(seen) I put a two-day week in the card below. Nothing is saved until you decide."
            }
            if sessions.isEmpty {
                let goal = kcal.map { zh ? "你的目标是每天 \($0) 千卡。" : "Your goal is \($0) kcal a day." } ?? ""
                return zh
                    ? "最近 14 天没有训练记录，所以暂时没有可以比较的数据。\(goal)记录一两组训练，我就能告诉你最该先改的地方。"
                    : "There are no workouts logged in the last 14 days, so there is nothing to compare yet. \(goal) Log a set or two and I can tell you what to fix first."
            }
            let goal = kcal.map { zh ? "你的每日目标是 \($0) 千卡。" : "Your daily target is \($0) kcal." } ?? ""
            return zh
                ? "最近 14 天你完成了 \(sessions.count) 次训练，共 \(reps) 次动作。\(goal)下次训练时先把深度做稳，再加次数。"
                : "You logged \(sessions.count) session\(sessions.count == 1 ? "" : "s") in the last 14 days, \(reps) reps in total. \(goal) Next time, hold depth steady before you add reps."
        case .mealLog:
            let logged = outputs["get_nutrition"]?["meals"]?.arrayValue?.count ?? 0
            let seen = logged == 0 ? (zh ? "今天还没有记录任何餐食。" : "Nothing is logged for today yet.")
                : (zh ? "今天已经记录了 \(logged) 项。" : "You already have \(logged) item\(logged == 1 ? "" : "s") logged today.")
            return zh
                ? "\(seen)我把早餐整理成了一张卡片，份量是估计值，你可以先改再确认。确认之前不会记录。"
                : "\(seen) I put the breakfast in a card below. The amounts are estimates, so adjust them before you confirm. Nothing is logged until you do."
        case .goalChange:
            let weight = outputs["get_body_trend"]?["weight"]?["latest"]?.doubleValue
            let seen = weight.map { zh ? "你最近的体重是 \(String(format: "%.1f", $0)) 公斤。" : "Your latest weight is \(String(format: "%.1f", $0)) kg." } ?? ""
            return zh
                ? "\(seen)我建议把每周减重速度调到 0.75%，卡片里会按计算器重新算出热量和营养素。确认后才会生效。"
                : "\(seen) I suggest a slightly faster pace of 0.75% a week. The card shows the calories and macros the planner recomputes. It only applies when you confirm."
        }
    }

    // MARK: Tool arguments

    private static func mealLogArguments(_ language: CoachLanguage) -> JSONValue {
        let zh = language == .zh
        return [
            "day": "today", "slot": "breakfast",
            "items": [
                ["name": .string(zh ? "炒蛋" : "Scrambled eggs"), "grams": 120, "usdaQuery": "egg whole scrambled"],
                ["name": .string(zh ? "全麦吐司" : "Whole wheat toast"), "grams": 50, "usdaQuery": "bread whole wheat toasted"],
            ],
        ]
    }

    private static func goalChangeArguments(_ language: CoachLanguage) -> JSONValue {
        let zh = language == .zh
        return [
            "change": [
                "kind": "lose", "targetWeightKg": nil, "weeklyRatePercent": 0.75, "workoutsPerWeek": 4,
                "reason": .string(zh ? "你的体重趋势平稳，可以稍微加快减重速度，同时保持每周 4 次训练。" : "Your weight trend is steady, so a slightly faster pace is reasonable while you keep training four times a week."),
            ],
        ]
    }

    private static func planArguments(_ language: CoachLanguage) -> JSONValue {
        let zh = language == .zh
        func exercise(_ name: String, sets: Int, reps: Int, rest: Int, note: String = "") -> JSONValue {
            ["name": .string(name), "sets": .int(sets), "reps": .int(reps), "restSec": .int(rest), "note": .string(note)]
        }
        return [
            "plan": [
                "title": .string(zh ? "每周两天全身训练" : "Two-day full-body week"),
                "rationale": .string(zh ? "两天训练覆盖下肢、推和拉，恢复时间充足，适合在现有基础上起步。" : "Two days cover legs, push and pull with room to recover, which suits where you are now."),
                "sessions": [
                    [
                        "name": .string(zh ? "第 1 天：下肢与推" : "Day 1: legs and push"),
                        "exercises": [
                            exercise(zh ? "深蹲" : "Bodyweight Squat", sets: 3, reps: 12, rest: 60, note: zh ? "蹲到大腿与地面平行。" : "Down to parallel."),
                            exercise(zh ? "俯卧撑" : "Push-up", sets: 3, reps: 10, rest: 60),
                            exercise(zh ? "肩上推举" : "Overhead Press", sets: 3, reps: 8, rest: 90),
                        ],
                    ],
                    [
                        "name": .string(zh ? "第 2 天：拉与核心" : "Day 2: pull and core"),
                        "exercises": [
                            exercise(zh ? "引体向上" : "Pull-up", sets: 3, reps: 6, rest: 90),
                            exercise(zh ? "杠铃划船" : "Barbell Row", sets: 3, reps: 8, rest: 90),
                            exercise(zh ? "平板支撑" : "Plank", sets: 3, reps: 30, rest: 45, note: zh ? "以秒计。" : "Hold for seconds."),
                        ],
                    ],
                ],
            ],
        ]
    }

    // MARK: Meal photo

    /// The estimate JSON the model would return for a breakfast plate.
    static func mealEstimateJSON(language: CoachLanguage) -> String {
        let zh = language == .zh
        let estimate: JSONValue = [
            "items": [
                ["name": .string(zh ? "炒蛋" : "Scrambled eggs"), "gramsEstimate": 120, "confidence": 0.82, "usdaQuery": "egg whole scrambled"],
                ["name": .string(zh ? "全麦吐司" : "Whole wheat toast"), "gramsEstimate": 50, "confidence": 0.74, "usdaQuery": "bread whole wheat toasted"],
                ["name": .string(zh ? "橙汁" : "Orange juice"), "gramsEstimate": 200, "confidence": 0.6, "usdaQuery": "orange juice"],
            ],
            "notes": .string(zh ? "份量按盘子大小估计；鸡蛋上的黄油或油会增加热量。" : "Portions are estimated from the plate. Butter or oil on the eggs would add calories."),
        ]
        return estimate.canonicalString
    }
}

// MARK: - Food search

nonisolated enum StubFoods {
    nonisolated struct Entry {
        var fdcID: Int
        var name: String
        var brand: String?
        var dataType: String
        var perMilliliter = false
        var kcal: Double?
        var protein: Double?
        var carbs: Double?
        var fat: Double?
        var servings: [(String, Double)] = []
    }

    static let catalog: [Entry] = [
        Entry(fdcID: 2_345_001, name: "Egg, whole, cooked, scrambled", brand: nil, dataType: "Survey (FNDDS)", kcal: 149, protein: 9.99, carbs: 1.61, fat: 11.0, servings: [("1 egg", 61), ("1 cup", 220)]),
        Entry(fdcID: 748_967, name: "Eggs, Grade A, Large, egg whole", brand: nil, dataType: "Foundation", kcal: 148, protein: 12.4, carbs: 0.96, fat: 9.96),
        Entry(fdcID: 2_345_002, name: "Bread, whole wheat, toasted", brand: nil, dataType: "Survey (FNDDS)", kcal: 313, protein: 12.9, carbs: 52.6, fat: 4.9, servings: [("1 slice", 25), ("1 slice, large", 36)]),
        Entry(fdcID: 1_105_073, name: "Bananas, ripe and slightly ripe, raw", brand: nil, dataType: "Foundation", kcal: 89, protein: 1.09, carbs: 22.8, fat: 0.33),
        Entry(fdcID: 2_345_003, name: "Apple, raw", brand: nil, dataType: "Survey (FNDDS)", kcal: 52, protein: 0.26, carbs: 13.8, fat: 0.17, servings: [("1 small", 165), ("1 cup, sliced", 110)]),
        Entry(fdcID: 169_705, name: "Oats, whole grain, rolled, old fashioned", brand: nil, dataType: "SR Legacy", kcal: 379, protein: 13.2, carbs: 67.7, fat: 6.52),
        Entry(fdcID: 171_477, name: "Chicken, breast, meat only, cooked, roasted", brand: nil, dataType: "SR Legacy", kcal: 165, protein: 31.0, carbs: 0, fat: 3.57),
        Entry(fdcID: 168_878, name: "Rice, white, long-grain, regular, cooked", brand: nil, dataType: "SR Legacy", kcal: 130, protein: 2.69, carbs: 28.2, fat: 0.28),
        Entry(fdcID: 170_903, name: "Yogurt, Greek, plain, nonfat", brand: nil, dataType: "SR Legacy", kcal: 59, protein: 10.2, carbs: 3.6, fat: 0.39),
        Entry(fdcID: 170_567, name: "Nuts, almonds", brand: nil, dataType: "SR Legacy", kcal: 579, protein: 21.2, carbs: 21.6, fat: 49.9),
        Entry(fdcID: 175_167, name: "Fish, salmon, Atlantic, farmed, cooked, dry heat", brand: nil, dataType: "SR Legacy", kcal: 206, protein: 22.1, carbs: 0, fat: 12.4),
        Entry(fdcID: 2_001_144, name: "Orange juice, ready to drink", brand: "SUNRISE GROVES", dataType: "Branded", perMilliliter: true, kcal: 45, protein: 0.7, carbs: 10.4, fat: 0.2),
        Entry(fdcID: 2_001_145, name: "Sparkling water, lime", brand: "CLEARWAVE", dataType: "Branded", perMilliliter: true, kcal: 0, protein: nil, carbs: nil, fat: nil),
        Entry(fdcID: 2_001_146, name: "Protein bar, chocolate peanut", brand: "TRAILHEAD", dataType: "Branded", kcal: 372, protein: 33.0, carbs: 36.0, fat: nil, servings: [("1 bar", 60)]),
        Entry(fdcID: 2_001_147, name: "Whole milk", brand: "MEADOW", dataType: "Branded", perMilliliter: true, kcal: 61, protein: 3.2, carbs: 4.8, fat: 3.3),
    ]

    /// Words a Chinese query maps to, so the stub shows results in a Chinese walkthrough.
    private static let aliases: [String: String] = [
        "鸡蛋": "egg", "蛋": "egg", "面包": "bread", "吐司": "bread", "香蕉": "banana", "苹果": "apple", "燕麦": "oats",
        "鸡胸": "chicken", "鸡肉": "chicken", "米饭": "rice", "酸奶": "yogurt", "杏仁": "almonds", "三文鱼": "salmon",
        "橙汁": "orange juice", "牛奶": "milk", "蛋白棒": "protein bar",
    ]

    static func page(for url: URL) -> JSONValue {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let rawQuery = items.first { $0.name == "q" }?.value ?? ""
        let page = Int(items.first { $0.name == "page" }?.value ?? "") ?? 1
        var query = rawQuery.lowercased()
        for (word, english) in aliases where query.contains(word) { query = english }
        let tokens = query.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        let matches = catalog.filter { entry in
            let haystack = (entry.name + " " + (entry.brand ?? "")).lowercased()
            return !tokens.isEmpty && tokens.allSatisfy { haystack.contains($0) }
        }
        let first = tokens.first ?? ""
        let ranked = matches.sorted { lhs, rhs in
            let l = lhs.name.lowercased().hasPrefix(first), r = rhs.name.lowercased().hasPrefix(first)
            return l != r ? l : lhs.fdcID < rhs.fdcID
        }
        return [
            "query": .string(rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)),
            "page": .int(page), "totalPages": 1, "totalHits": .int(ranked.count),
            "results": .array(page == 1 ? ranked.map(json) : []),
        ]
    }

    private static func json(_ entry: Entry) -> JSONValue {
        func number(_ value: Double?) -> JSONValue { value.map { .double($0) } ?? .null }
        var members: [String: JSONValue] = [
            "fdcId": .int(entry.fdcID), "name": .string(entry.name), "dataType": .string(entry.dataType),
            "per100g": ["kcal": number(entry.kcal), "protein": number(entry.protein), "carbs": number(entry.carbs), "fat": number(entry.fat)],
        ]
        if let brand = entry.brand { members["brand"] = .string(brand) }
        if entry.perMilliliter { members["basis"] = "ml" }
        if !entry.servings.isEmpty {
            members["servings"] = .array(entry.servings.map { ["label": .string($0.0), "grams": .double($0.1)] })
        }
        return .object(members)
    }
}
#endif
