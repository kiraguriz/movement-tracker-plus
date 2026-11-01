import Foundation
import MotionCore

/// Which camera produced a recording.
public enum CameraPosition: String, Codable, Sendable {
    case front, back
    /// A video file or generated motion: no camera in the loop.
    case unknown
}

/// What a person says is true about a recording. Set after the set ends, when the user has counted.
public struct PoseLabels: Codable, Equatable, Sendable {
    /// The real number of full reps.
    public var reps: Int?
    /// The real number of partial reps (dips that should not count).
    public var partials: Int?
    public var notes: String?
    /// Free-form markers such as `idle`, `two-people`, `room-2`.
    public var tags: [String]

    public init(reps: Int? = nil, partials: Int? = nil, notes: String? = nil, tags: [String] = []) {
        self.reps = reps
        self.partials = partials
        self.notes = notes
        self.tags = tags
    }

    private enum CodingKeys: String, CodingKey { case reps, partials, notes, tags }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reps = try c.decodeIfPresent(Int.self, forKey: .reps)
        partials = try c.decodeIfPresent(Int.self, forKey: .partials)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
    }
}

/// The first line of a fixture file.
public struct PoseFixtureHeader: Codable, Equatable, Sendable {
    public static let formatName = "movement-tracker.pose"
    public static let currentVersion = 1

    public var format: String
    public var version: Int
    /// The `ExerciseSpec.id` the set was recorded for, for example `squat.bodyweight`.
    public var exerciseSpecID: String?
    public var cameraPosition: CameraPosition
    public var fps: Double?
    public var deviceModel: String?
    public var created: Date
    public var labels: PoseLabels
    /// Filled in when the recording is finished.
    public var frameCount: Int?
    public var duration: Double?

    public init(
        exerciseSpecID: String?, cameraPosition: CameraPosition = .unknown, fps: Double? = nil,
        deviceModel: String? = nil, created: Date = Date(), labels: PoseLabels = PoseLabels(),
        frameCount: Int? = nil, duration: Double? = nil
    ) {
        format = Self.formatName
        version = Self.currentVersion
        self.exerciseSpecID = exerciseSpecID
        self.cameraPosition = cameraPosition
        self.fps = fps
        self.deviceModel = deviceModel
        self.created = created
        self.labels = labels
        self.frameCount = frameCount
        self.duration = duration
    }
}

/// A whole recording in memory.
public struct PoseFixture: Equatable, Sendable {
    public var header: PoseFixtureHeader
    public var frames: [PoseFrame]

    public init(header: PoseFixtureHeader, frames: [PoseFrame]) {
        self.header = header
        self.frames = frames
    }
}

public enum PoseFixtureError: Error, Equatable, LocalizedError, Sendable {
    case empty
    case badHeader(String)
    case notAFixture(format: String)
    case unsupportedVersion(Int)
    case badFrame(line: Int, reason: String)
    case finished

    public var errorDescription: String? {
        switch self {
        case .empty: "The fixture file is empty."
        case let .badHeader(reason): "The fixture header is not valid: \(reason)"
        case let .notAFixture(format): "Not a pose fixture (format '\(format)')."
        case let .unsupportedVersion(v): "Pose fixture version \(v) is not supported (this build reads version \(PoseFixtureHeader.currentVersion))."
        case let .badFrame(line, reason): "Line \(line) is not a pose frame: \(reason)"
        case .finished: "The recording is already finished."
        }
    }
}

/// Reading and writing the JSONL fixture format: a header line, then one `PoseFrame` per line with
/// coordinates rounded to four decimals.
///
/// ```
/// {"cameraPosition":"front","created":"…","exerciseSpecID":"squat.bodyweight","format":"movement-tracker.pose",…}
/// {"imageAspect":0.5625,"joints":{"leftHip":[0.4012,0.5133,0.9]},"t":1052.3341}
/// ```
public enum PoseFixtureFile {
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Four decimal places.
    static func round4(_ value: Double) -> Double {
        (value * 10_000).rounded() / 10_000
    }

    /// The frame as stored: coordinates, confidences, time and aspect rounded to four decimals.
    static func rounded(_ frame: PoseFrame) -> PoseFrame {
        var joints: [Joint: Keypoint] = [:]
        joints.reserveCapacity(frame.joints.count)
        for (joint, k) in frame.joints {
            joints[joint] = Keypoint(x: round4(k.x), y: round4(k.y), confidence: round4(k.confidence))
        }
        return PoseFrame(t: round4(frame.t), joints: joints, imageAspect: round4(frame.imageAspect))
    }

    static func encodeLine(_ frame: PoseFrame) throws -> Data {
        try makeEncoder().encode(rounded(frame))
    }

    static func encodeHeader(_ header: PoseFixtureHeader) throws -> Data {
        try makeEncoder().encode(header)
    }

    private static let newline = UInt8(ascii: "\n")

    /// A non-empty line of a file with its 1-based line number, so errors point at the real line even
    /// when the file has blank lines.
    private struct Line {
        var number: Int
        var data: Data
    }

    /// The non-empty lines of a file, without line terminators.
    private static func lines(of data: Data) -> [Line] {
        var result: [Line] = []
        for (index, piece) in data.split(separator: newline, omittingEmptySubsequences: false).enumerated() {
            var piece = piece
            if piece.last == UInt8(ascii: "\r") { piece = piece.dropLast() }
            if !piece.isEmpty { result.append(Line(number: index + 1, data: Data(piece))) }
        }
        return result
    }

    /// What went wrong, in words that locate the problem: a `DecodingError` says which key or element,
    /// where `localizedDescription` only says the data "isn't in the correct format".
    static func describe(_ error: any Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }
        func path(_ context: DecodingError.Context) -> String {
            let text = context.codingPath.map { key in key.intValue.map { "[\($0)]" } ?? ".\(key.stringValue)" }.joined()
            return text.hasPrefix(".") ? String(text.dropFirst()) : text
        }
        func detail(_ message: String, _ context: DecodingError.Context) -> String {
            var text = message
            if let underlying = context.underlyingError as NSError?,
               let more = underlying.userInfo[NSDebugDescriptionErrorKey] as? String {
                text += " (\(more))"
            }
            let location = path(context)
            return location.isEmpty ? text : "\(text) at '\(location)'"
        }
        switch decoding {
        case let .keyNotFound(key, context):
            return detail("missing '\(key.stringValue)'", context)
        case let .valueNotFound(_, context), let .typeMismatch(_, context), let .dataCorrupted(context):
            return detail(context.debugDescription, context)
        @unknown default:
            return "\(decoding)"
        }
    }

    private static func parseHeader(_ line: Data) throws -> PoseFixtureHeader {
        let header: PoseFixtureHeader
        do {
            header = try makeDecoder().decode(PoseFixtureHeader.self, from: line)
        } catch {
            throw PoseFixtureError.badHeader(describe(error))
        }
        guard header.format == PoseFixtureHeader.formatName else { throw PoseFixtureError.notAFixture(format: header.format) }
        guard header.version >= 1, header.version <= PoseFixtureHeader.currentVersion else {
            throw PoseFixtureError.unsupportedVersion(header.version)
        }
        return header
    }

    /// Reads only the header line.
    public static func readHeader(from url: URL) throws -> PoseFixtureHeader {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var buffer = Data()
        while buffer.firstIndex(of: newline) == nil, let chunk = try handle.read(upToCount: 4096), !chunk.isEmpty {
            buffer.append(chunk)
        }
        guard let first = lines(of: buffer).first else { throw PoseFixtureError.empty }
        return try parseHeader(first.data)
    }

    /// Reads a whole fixture. A last line that is cut off (a recording that stopped mid-write has no line
    /// terminator on its last line) is ignored; a malformed line anywhere else, or a malformed last line
    /// that was written out completely, throws.
    public static func read(from url: URL) throws -> PoseFixture {
        try decode(Data(contentsOf: url))
    }

    public static func decode(_ data: Data) throws -> PoseFixture {
        let all = lines(of: data)
        guard let first = all.first else { throw PoseFixtureError.empty }
        let header = try parseHeader(first.data)
        let endsWithNewline = data.last == newline || data.last == UInt8(ascii: "\r")
        let decoder = makeDecoder()
        var frames: [PoseFrame] = []
        frames.reserveCapacity(all.count - 1)
        for (position, line) in all.enumerated().dropFirst() {
            do {
                frames.append(try decoder.decode(PoseFrame.self, from: line.data))
            } catch {
                if position == all.count - 1, !endsWithNewline { break }
                throw PoseFixtureError.badFrame(line: line.number, reason: describe(error))
            }
        }
        return PoseFixture(header: header, frames: frames)
    }

    /// The whole fixture as file data (header line, then one frame per line, each ending in a newline).
    public static func encode(_ fixture: PoseFixture) throws -> Data {
        var data = try encodeHeader(fixture.header)
        data.append(newline)
        for frame in fixture.frames {
            data.append(try encodeLine(frame))
            data.append(newline)
        }
        return data
    }

    public static func write(_ fixture: PoseFixture, to url: URL) throws {
        try encode(fixture).write(to: url, options: .atomic)
    }

    /// Replaces the labels of a finished fixture without touching its frames, for labelling a set after
    /// the fact.
    public static func updateLabels(at url: URL, to labels: PoseLabels) throws {
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { throw PoseFixtureError.empty }
        let split = data.firstIndex(of: newline) ?? data.endIndex
        var header = try parseHeader(Data(data[data.startIndex..<split]))
        header.labels = labels
        var out = try encodeHeader(header)
        out.append(data[split...])
        try out.write(to: url, options: .atomic)
    }

    // Used by the recorder to replace the first line of a file with a new header.
    static func replaceHeader(in data: Data, with header: PoseFixtureHeader) throws -> Data {
        guard !data.isEmpty else { throw PoseFixtureError.empty }
        let split = data.firstIndex(of: newline) ?? data.endIndex
        var out = try encodeHeader(header)
        out.append(data[split...])
        return out
    }
}

/// Writes a fixture while a set is being recorded. The header goes first with the labels known at the
/// start, frames are appended and flushed about once a second (so a crash leaves a readable file), and
/// `finish` rewrites the header with the final labels, frame count and duration.
///
/// ```swift
/// let recorder = try PoseRecorder(url: url, header: PoseFixtureHeader(exerciseSpecID: "squat.bodyweight", cameraPosition: .front))
/// for await frame in frames { try await recorder.append(frame) }
/// await recorder.setLabels(PoseLabels(reps: 10, partials: 1))     // after the set, once the user has counted
/// try await recorder.finish()
/// ```
public actor PoseRecorder {
    public nonisolated let url: URL
    public private(set) var header: PoseFixtureHeader
    public private(set) var frameCount = 0
    public private(set) var isFinished = false

    private var handle: FileHandle?
    private var pending = Data()
    private var firstTime: TimeInterval?
    private var lastTime: TimeInterval?
    private let flushEvery: Int

    /// Creates (or replaces) the file and writes the provisional header.
    public init(url: URL, header: PoseFixtureHeader, flushEveryFrames: Int = 30) throws {
        self.url = url
        self.header = header
        flushEvery = max(1, flushEveryFrames)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var first = try PoseFixtureFile.encodeHeader(header)
        first.append(UInt8(ascii: "\n"))
        guard FileManager.default.createFile(atPath: url.path, contents: first) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        handle = try FileHandle(forWritingTo: url)
        try handle?.seekToEnd()
    }

    deinit {
        // A recorder that is dropped without `finish` (the screen went away mid-set) still hands over the
        // frames it was holding; the header keeps the labels it started with.
        if let handle, !pending.isEmpty { try? handle.write(contentsOf: pending) }
        try? handle?.close()
    }

    public func setLabels(_ labels: PoseLabels) {
        guard !isFinished else { return }
        header.labels = labels
    }

    public func append(_ frame: PoseFrame) throws {
        guard !isFinished, handle != nil else { throw PoseFixtureError.finished }
        pending.append(try PoseFixtureFile.encodeLine(frame))
        pending.append(UInt8(ascii: "\n"))
        frameCount += 1
        if firstTime == nil { firstTime = frame.t }
        lastTime = frame.t
        if frameCount % flushEvery == 0 { try flush() }
    }

    /// Writes buffered frames to disk.
    public func flush() throws {
        guard !pending.isEmpty, let handle else { return }
        try handle.write(contentsOf: pending)
        pending.removeAll(keepingCapacity: true)
    }

    /// Flushes, closes the file and rewrites its header with the final labels, count and duration.
    /// Returns the final header. Calling it again returns the same header.
    @discardableResult
    public func finish(labels: PoseLabels? = nil) throws -> PoseFixtureHeader {
        guard !isFinished else { return header }
        if let labels { header.labels = labels }
        try flush()
        try handle?.close()
        handle = nil

        header.frameCount = frameCount
        if let firstTime, let lastTime {
            header.duration = PoseFixtureFile.round4(lastTime - firstTime)
            if header.fps == nil, frameCount > 1, lastTime > firstTime {
                header.fps = PoseFixtureFile.round4(Double(frameCount - 1) / (lastTime - firstTime))
            }
        }
        let data = try Data(contentsOf: url)
        try PoseFixtureFile.replaceHeader(in: data, with: header).write(to: url, options: .atomic)
        isFinished = true
        return header
    }
}
