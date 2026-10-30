import Foundation

/// Removes metadata from images before they leave the phone. A photo from the camera carries its GPS position, the
/// time, the device model and often a serial number; none of that is something the coach should receive, and what
/// the consent screen promises is pixels only. Both functions copy the file's own chunks or segments, so the pixels
/// are not decoded or re-encoded, and return nil when the bytes are not a well-formed image of that kind.
enum ImageSanitizer {
    // MARK: PNG

    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// Chunks that decode the image or set its colours. Text, time, EXIF, profile, density, background and every
    /// private chunk are dropped, and so is anything after `IEND`.
    private static let pngKept: Set<String> = ["IHDR", "PLTE", "tRNS", "IDAT", "IEND", "gAMA", "cHRM", "sRGB"]

    static func png(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 8 + 12, bytes[0..<8].elementsEqual(pngSignature) else { return nil }
        var output = pngSignature
        output.reserveCapacity(bytes.count)
        var position = 8
        var first = true
        var sawData = false
        while position + 12 <= bytes.count {
            let length = Int(bytes[position]) << 24 | Int(bytes[position + 1]) << 16 | Int(bytes[position + 2]) << 8 | Int(bytes[position + 3])
            let end = position + 12 + length
            guard length <= 0x7FFF_FFFF, end <= bytes.count else { return nil }
            let type = String(decoding: bytes[(position + 4)..<(position + 8)], as: UTF8.self)
            if first {
                guard type == "IHDR", length == 13 else { return nil }
                first = false
            }
            if pngKept.contains(type) { output.append(contentsOf: bytes[position..<end]) }
            if type == "IDAT" { sawData = true }
            position = end
            if type == "IEND" { return sawData ? Data(output) : nil }
        }
        return nil
    }

    // MARK: JPEG

    /// What a JPEG may keep besides its image segments: JFIF (`APP0`) and Adobe (`APP14`, which says how to read
    /// the colours). Everything else application-specific, and every comment, is dropped, along with any data
    /// appended after the end of the image. EXIF (`APP1`) is rebuilt with the orientation alone, so a photo
    /// taken sideways still arrives upright.
    static func jpeg(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        var output: [UInt8] = [0xFF, 0xD8]
        output.reserveCapacity(bytes.count)
        var position = 2
        var sawFrame = false
        var sawScan = false
        var sawExif = false

        while position < bytes.count {
            guard bytes[position] == 0xFF else { return nil }
            while position < bytes.count, bytes[position] == 0xFF { position += 1 } // fill bytes before a marker
            guard position < bytes.count else { return nil }
            let marker = bytes[position]
            position += 1

            if marker == 0xD9 { // end of image: anything after it is not part of the picture
                output.append(contentsOf: [0xFF, 0xD9])
                return sawFrame && sawScan ? Data(output) : nil
            }
            // Markers without a length: restart markers, TEM and a second SOI. None belongs between segments.
            if marker == 0x00 || marker == 0x01 || marker == 0xD8 || (0xD0...0xD7).contains(marker) { return nil }

            guard position + 2 <= bytes.count else { return nil }
            let length = Int(bytes[position]) << 8 | Int(bytes[position + 1])
            guard length >= 2, position + length <= bytes.count else { return nil }
            let body = bytes[(position + 2)..<(position + length)]
            let segment = bytes[(position - 2)..<(position + length)] // the marker and the whole segment
            position += length

            switch marker {
            case 0xE1: // APP1: EXIF or XMP
                if !sawExif, let orientation = exifOrientation(body) {
                    sawExif = true
                    if orientation != 1 { output.append(contentsOf: exifSegment(orientation: orientation)) }
                }
            case 0xE0, 0xEE: // APP0 (JFIF), APP14 (Adobe)
                output.append(contentsOf: segment)
            case 0xE2...0xED, 0xEF, 0xFE: // other APPn and comments
                break
            case 0xDA: // start of scan: the header, then entropy-coded data up to the next real marker
                sawScan = true
                output.append(contentsOf: segment)
                while position < bytes.count {
                    let byte = bytes[position]
                    if byte != 0xFF {
                        output.append(byte)
                        position += 1
                        continue
                    }
                    guard position + 1 < bytes.count else { return nil }
                    let next = bytes[position + 1]
                    if next == 0x00 || (0xD0...0xD7).contains(next) { // stuffed byte or restart marker
                        output.append(contentsOf: [0xFF, next])
                        position += 2
                    } else if next == 0xFF { // fill byte
                        position += 1
                    } else {
                        break
                    }
                }
            default: // frame header, tables, restart interval, ...
                if (0xC0...0xCF).contains(marker), marker != 0xC4, marker != 0xC8, marker != 0xCC { sawFrame = true }
                output.append(contentsOf: segment)
            }
        }
        return nil // no end of image
    }

    /// The orientation (1 to 8) in an `APP1` EXIF segment body, or nil when the segment is not EXIF or has none.
    static func exifOrientation(_ body: ArraySlice<UInt8>) -> Int? {
        let b = Array(body)
        guard b.count >= 14, b[0..<6].elementsEqual([0x45, 0x78, 0x69, 0x66, 0x00, 0x00]) else { return nil }
        let tiff = 6
        let little: Bool
        if b[tiff] == 0x49, b[tiff + 1] == 0x49 {
            little = true
        } else if b[tiff] == 0x4D, b[tiff + 1] == 0x4D {
            little = false
        } else {
            return nil
        }
        func u16(_ at: Int) -> Int? {
            guard at >= 0, at + 2 <= b.count else { return nil }
            return little ? Int(b[at]) | Int(b[at + 1]) << 8 : Int(b[at]) << 8 | Int(b[at + 1])
        }
        func u32(_ at: Int) -> Int? {
            guard let low = u16(at), let high = u16(at + 2) else { return nil }
            return little ? low | high << 16 : low << 16 | high
        }
        guard u16(tiff + 2) == 42, let offset = u32(tiff + 4), let entries = u16(tiff + offset), entries <= 512 else { return nil }
        for index in 0..<entries {
            let entry = tiff + offset + 2 + index * 12
            // Tag 0x0112, type SHORT, one value (stored in the first two bytes of the value field).
            if u16(entry) == 0x0112, u16(entry + 2) == 3, u32(entry + 4) == 1, let value = u16(entry + 8), (1...8).contains(value) {
                return value
            }
        }
        return nil
    }

    /// A complete `APP1` segment whose EXIF holds only the orientation.
    static func exifSegment(orientation: Int) -> [UInt8] {
        [
            0xFF, 0xE1, 0x00, 0x22, // marker, length 34
            0x45, 0x78, 0x69, 0x66, 0x00, 0x00, // "Exif\0\0"
            0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08, // big-endian TIFF header, first IFD at 8
            0x00, 0x01, // one entry
            0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, 0x00, UInt8(orientation), 0x00, 0x00, // Orientation, SHORT, 1
            0x00, 0x00, 0x00, 0x00, // no next IFD
        ]
    }
}
