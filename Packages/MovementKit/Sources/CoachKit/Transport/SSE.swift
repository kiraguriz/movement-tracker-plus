import Foundation

/// One dispatched server-sent event.
public struct SSEEvent: Sendable, Equatable {
    public var event: String?
    public var data: String
    public var id: String?

    public init(event: String? = nil, data: String, id: String? = nil) {
        self.event = event
        self.data = data
        self.id = id
    }
}

/// Incremental parser for `text/event-stream`. Feed it bytes in chunks of any size: a chunk may end in the
/// middle of a line, of a multi-byte UTF-8 character, or between the CR and LF of a line break.
///
/// Follows the WHATWG rules: lines end in LF, CR or CRLF; a line starting with `:` is a comment (heartbeats);
/// `data` lines of one event are joined with LF; an empty line dispatches the event; one space after the colon is
/// dropped; a leading byte order mark is ignored. Meta's streams use only `data:` lines, ending in `data: [DONE]`.
///
/// Memory is bounded: an event larger than `maxEventBytes` (one endless line, or endless `data:` lines with no blank
/// line) is dropped whole instead of being buffered, and the parser carries on with the next one.
public struct SSEParser: Sendable {
    /// Far above any real event (a finished response is a few tens of kilobytes).
    public static let defaultMaxEventBytes = 4 * 1024 * 1024

    private let maxEventBytes: Int
    private var eventBytes = 0
    private var eventTooLarge = false
    private var line: [UInt8] = []
    /// Bytes seen on the current line, kept or not: a line whose bytes were all dropped is not a blank line.
    private var lineLength = 0
    private var previousWasCR = false
    private var atStreamStart = true
    private var dataLines: [String] = []
    private var eventName: String?
    private var lastEventID: String?

    public init() {
        maxEventBytes = Self.defaultMaxEventBytes
    }

    init(maxEventBytes: Int) {
        self.maxEventBytes = maxEventBytes
    }

    /// Consumes `chunk` and returns the events it completed.
    public mutating func feed(_ chunk: Data) -> [SSEEvent] {
        var events: [SSEEvent] = []
        for byte in chunk {
            if previousWasCR {
                previousWasCR = false
                if byte == 0x0A { continue }
            }
            switch byte {
            case 0x0A:
                endLine(into: &events)
            case 0x0D:
                endLine(into: &events)
                previousWasCR = true
            default:
                lineLength += 1
                if eventBytes + line.count < maxEventBytes {
                    line.append(byte)
                } else {
                    eventTooLarge = true
                }
            }
        }
        return events
    }

    /// Call when the stream has closed. A last event that was not followed by a blank line is still delivered:
    /// the consumer decides whether a cut-off payload is usable.
    public mutating func finish() -> [SSEEvent] {
        var events: [SSEEvent] = []
        if !line.isEmpty { endLine(into: &events) }
        if !dataLines.isEmpty { dispatch(into: &events) }
        previousWasCR = false
        return events
    }

    private mutating func endLine(into events: inout [SSEEvent]) {
        eventBytes += line.count
        if eventTooLarge {
            // The rest of this event is skipped; its blank line (or the end of the stream) ends the skipping.
            let blank = lineLength == 0
            lineLength = 0
            line = []
            dataLines = []
            if blank { dispatch(into: &events) }
            return
        }
        var text = String(decoding: line, as: UTF8.self)
        line.removeAll(keepingCapacity: true)
        lineLength = 0
        if atStreamStart {
            atStreamStart = false
            if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        }
        if text.isEmpty {
            dispatch(into: &events)
            return
        }
        if text.hasPrefix(":") { return }
        let field: Substring
        var value: Substring
        if let colon = text.firstIndex(of: ":") {
            field = text[text.startIndex..<colon]
            value = text[text.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = text[...]
            value = ""
        }
        switch field {
        case "data": dataLines.append(String(value))
        case "event": eventName = String(value)
        case "id": if !value.contains("\0") { lastEventID = String(value) }
        default: break // retry and unknown fields are ignored
        }
    }

    private mutating func dispatch(into events: inout [SSEEvent]) {
        defer {
            dataLines.removeAll(keepingCapacity: true)
            eventName = nil
            eventBytes = 0
            eventTooLarge = false
        }
        guard !dataLines.isEmpty, !eventTooLarge else { return }
        events.append(SSEEvent(event: eventName, data: dataLines.joined(separator: "\n"), id: lastEventID))
    }
}
