import Foundation

/// The text of a transcribed clip.
public struct Transcription: Sendable, Equatable, Decodable {
    public var sessionId: String?
    public var transcript: String
    public var audioDurationMs: Int

    public var text: String { transcript }
}

/// Facts about a WAV file read from its header.
public struct WAVInfo: Sendable, Equatable {
    public var sampleRate: Int
    public var channels: Int
    public var bitsPerSample: Int
    public var isPCM: Bool
    public var dataBytes: Int

    public var durationSeconds: Double {
        let bytesPerSecond = Double(sampleRate * channels * bitsPerSample / 8)
        return bytesPerSecond > 0 ? Double(dataBytes) / bytesPerSecond : 0
    }

    /// Reads the `fmt ` and `data` chunks. Returns nil when the bytes are not a RIFF/WAVE file with both.
    public static func parse(_ data: Data) -> WAVInfo? {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, bytes[0..<4].elementsEqual("RIFF".utf8), bytes[8..<12].elementsEqual("WAVE".utf8) else { return nil }
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }

        var format: (rate: Int, channels: Int, bits: Int, pcm: Bool)?
        var position = 12
        while position + 8 <= bytes.count {
            let id = String(decoding: bytes[position..<position + 4], as: UTF8.self)
            let size = u32(position + 4)
            let body = position + 8
            if id == "fmt ", body + 16 <= bytes.count {
                format = (u32(body + 4), u16(body + 2), u16(body + 14), u16(body) == 1)
            } else if id == "data" {
                guard let format else { return nil }
                // A streamed file may declare a size larger than what is present: count what is there.
                let available = max(0, min(size, bytes.count - body))
                return WAVInfo(sampleRate: format.rate, channels: format.channels, bitsPerSample: format.bits, isPCM: format.pcm, dataBytes: available)
            }
            position = body + size + (size % 2)
        }
        return nil
    }

    /// The proxy takes 16 kHz mono 16-bit PCM WAV of at most 60 s in a body of at most 2 MiB.
    static func validateForTranscription(_ data: Data) throws {
        guard let info = parse(data) else { throw CoachError.invalidInput("The audio is not a WAV file.") }
        guard info.isPCM, info.channels == 1, info.bitsPerSample == 16, info.sampleRate == 16_000 else {
            throw CoachError.invalidInput("The audio must be 16 kHz mono 16-bit PCM WAV.")
        }
        guard info.durationSeconds <= 60 else { throw CoachError.invalidInput("The audio is longer than 60 seconds.") }
        guard data.count <= 2 * 1024 * 1024 - 4096 else { throw CoachError.payloadTooLarge("The audio is too large.") }
        guard info.dataBytes > 0 else { throw CoachError.invalidInput("The audio is empty.") }
    }
}

/// `multipart/form-data` for the transcription call.
enum MultipartBody {
    struct Part {
        var name: String
        var filename: String?
        var contentType: String
        var data: Data
    }

    static func make(boundary: String, parts: [Part]) -> Data {
        var body = Data()
        for part in parts {
            var disposition = "Content-Disposition: form-data; name=\"\(part.name)\""
            if let filename = part.filename { disposition += "; filename=\"\(filename)\"" }
            body.append(Data("--\(boundary)\r\n\(disposition)\r\nContent-Type: \(part.contentType)\r\n\r\n".utf8))
            body.append(part.data)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }
}
