import Domain
import Foundation
import Synchronization
import Testing

#if canImport(ImageIO)
import ImageIO
#endif

@testable import CoachKit

private let secrets = ["SECRETMAKER", "SECRETGPS", "SECRETXMP", "SECRETICC", "SECRETIPTC", "SECRETCOMMENT", "SECRETTRAILER", "SECRETTEXT"]

private func contains(_ data: Data, _ text: String) -> Bool { data.range(of: Data(text.utf8)) != nil }

private func orientation(of body: Data) -> Int? { ImageSanitizer.exifOrientation(ArraySlice([UInt8](body))) }

// MARK: - Builders

private enum Build {
    static func u16(_ value: Int, little: Bool) -> [UInt8] {
        let bytes = [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        return little ? bytes.reversed() : bytes
    }

    static func u32(_ value: Int, little: Bool) -> [UInt8] {
        let bytes = [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        return little ? bytes.reversed() : bytes
    }

    /// The body of an `APP1` EXIF segment: a Make string that is a secret, and optionally an orientation.
    static func exifBody(orientation: Int?, little: Bool = false, secret: String = "SECRETMAKER") -> Data {
        let secretBytes = Array(secret.utf8) + [0]
        let entries = orientation == nil ? 1 : 2
        let dataOffset = 8 + 2 + entries * 12 + 4
        var tiff: [UInt8] = (little ? [0x49, 0x49] : [0x4D, 0x4D]) + u16(42, little: little) + u32(8, little: little)
        tiff += u16(entries, little: little)
        tiff += u16(0x010F, little: little) + u16(2, little: little) + u32(secretBytes.count, little: little) + u32(dataOffset, little: little)
        if let orientation {
            tiff += u16(0x0112, little: little) + u16(3, little: little) + u32(1, little: little) + u16(orientation, little: little) + [0, 0]
        }
        tiff += u32(0, little: little)
        tiff += secretBytes
        return Data(Array("Exif".utf8) + [0, 0] + tiff)
    }

    static func segment(_ marker: UInt8, _ body: Data) -> Data {
        Data([0xFF, marker]) + Data(u16(body.count + 2, little: false)) + body
    }

    static func app(_ number: Int, _ payload: String) -> Data { segment(UInt8(0xE0 + number), Data(payload.utf8)) }

    static let soi = Data([0xFF, 0xD8])
    static let eoi = Data([0xFF, 0xD9])

    /// SOI, `before` segments, then the fixture's frame and scan, `entropy`, EOI and whatever trails.
    static func jpeg(before: [Data] = [], afterFrame: [Data] = [], entropy: Data = Data(repeating: 0x22, count: 40), trailing: Data = Data()) -> Data {
        soi + before.reduce(Data(), +) + Fixture.frameHeader + afterFrame.reduce(Data(), +) + Fixture.scanHeader + entropy + eoi + trailing
    }

    /// The segments of a JPEG up to its first scan: marker and body.
    static func segments(of jpeg: Data) -> [(marker: UInt8, body: Data)] {
        let bytes = [UInt8](jpeg)
        var result: [(UInt8, Data)] = []
        var position = 2
        while position + 4 <= bytes.count, bytes[position] == 0xFF {
            let marker = bytes[position + 1]
            let length = Int(bytes[position + 2]) << 8 | Int(bytes[position + 3])
            result.append((marker, Data(bytes[(position + 4)..<(position + 2 + length)])))
            if marker == 0xDA { break }
            position += 2 + length
        }
        return result
    }

    static func pngWith(chunks: [(String, String)], after: Data = Data(), beforeData: Bool = true) -> Data {
        let extra = chunks.reduce(Data()) { $0 + Fixture.pngChunk($1.0, Data($1.1.utf8)) }
        let idat = Fixture.pngChunk("IDAT", Data(repeating: 0x11, count: 32))
        return Fixture.pngSignature + Fixture.pngHeader + (beforeData ? extra + idat : idat + extra) + Fixture.pngChunk("IEND", Data()) + after
    }
}

// MARK: - JPEG

@Suite("Image sanitizer: JPEG")
struct JPEGSanitizerTests {
    @Test func aJPEGWithNoMetadataComesBackByteForByte() {
        #expect(ImageSanitizer.jpeg(Fixture.jpeg()) == Fixture.jpeg())
    }

    @Test(arguments: [(1, false), (3, false), (6, false), (8, false), (6, true), (8, true)])
    func exifIsRemovedAndOnlyTheOrientationIsKept(orientationValue: Int, little: Bool) throws {
        let body = Build.exifBody(orientation: orientationValue, little: little)
        #expect(orientation(of: body) == orientationValue)
        let source = Build.jpeg(before: [Fixture.jfif, Build.segment(0xE1, body)])
        #expect(contains(source, "SECRETMAKER"))
        let clean = try #require(ImageSanitizer.jpeg(source))
        #expect(!contains(clean, "SECRETMAKER"))
        let exif = Build.segments(of: clean).filter { $0.marker == 0xE1 }
        if orientationValue == 1 {
            #expect(exif.isEmpty, "an upright photo needs no EXIF at all")
        } else {
            #expect(exif.count == 1)
            let kept = try #require(exif.first)
            #expect(orientation(of: kept.body) == orientationValue)
            #expect(kept.body.count == 32, "the rebuilt EXIF is the orientation alone")
        }
    }

    @Test func exifBeforeOrAfterJFIFIsHandledTheSame() throws {
        let body = Build.exifBody(orientation: 6)
        let exifFirst = try #require(ImageSanitizer.jpeg(Build.jpeg(before: [Build.segment(0xE1, body), Fixture.jfif])))
        let jfifFirst = try #require(ImageSanitizer.jpeg(Build.jpeg(before: [Fixture.jfif, Build.segment(0xE1, body)])))
        #expect(Build.segments(of: exifFirst).map(\.marker).contains(0xE1))
        #expect(Build.segments(of: jfifFirst).map(\.marker).contains(0xE1))
        #expect(!contains(exifFirst, "SECRETMAKER") && !contains(jfifFirst, "SECRETMAKER"))
    }

    @Test func aSecondExifSegmentIsNotKeptEvenIfItHasAnOrientation() throws {
        let first = Build.segment(0xE1, Build.exifBody(orientation: 6))
        let second = Build.segment(0xE1, Build.exifBody(orientation: 3, secret: "SECRETGPS"))
        let clean = try #require(ImageSanitizer.jpeg(Build.jpeg(before: [Fixture.jfif, first, second])))
        #expect(!contains(clean, "SECRETGPS"))
        #expect(Build.segments(of: clean).filter { $0.marker == 0xE1 }.count == 1)
    }

    @Test func xmpProfilesIPTCCommentsAndOtherApplicationSegmentsAreDropped() throws {
        let source = Build.jpeg(before: [
            Fixture.jfif,
            Build.segment(0xE1, Data("http://ns.adobe.com/xap/1.0/\0<x:xmpmeta>SECRETXMP</x:xmpmeta>".utf8)),
            Build.app(2, "ICC_PROFILE\0SECRETICC"),
            Build.app(3, "SECRETGPS"),
            Build.app(13, "Photoshop 3.0\0SECRETIPTC"),
            Build.segment(0xFE, Data("SECRETCOMMENT".utf8)),
            Build.app(15, "SECRETTEXT"),
        ])
        let clean = try #require(ImageSanitizer.jpeg(source))
        for secret in secrets { #expect(!contains(clean, secret), "\(secret) survived") }
        #expect(Build.segments(of: clean).map(\.marker) == [0xE0, 0xC0, 0xDA])
    }

    @Test func adobeColourInformationIsKeptBecauseItDecidesHowToReadTheColours() throws {
        let adobe = Build.segment(0xEE, Data("Adobe".utf8) + Data([0x00, 0x64, 0x00, 0x00, 0x00, 0x00, 0x01]))
        let clean = try #require(ImageSanitizer.jpeg(Build.jpeg(before: [Fixture.jfif, adobe])))
        #expect(Build.segments(of: clean).map(\.marker) == [0xE0, 0xEE, 0xC0, 0xDA])
    }

    @Test func anythingAfterTheEndOfTheImageIsDropped() throws {
        let trailer = Data("SECRETTRAILER".utf8) + Data([0xFF, 0xD8, 0xFF, 0xD9])
        let clean = try #require(ImageSanitizer.jpeg(Build.jpeg(before: [Fixture.jfif], trailing: trailer)))
        #expect(!contains(clean, "SECRETTRAILER"))
        #expect(clean.suffix(2) == Data([0xFF, 0xD9]))
        #expect(clean == Fixture.jpeg(count: 40))
    }

    @Test func stuffedBytesRestartMarkersAndFillBytesInTheScanSurvive() throws {
        let entropy = Data([0x12, 0xFF, 0x00, 0x34, 0xFF, 0xD0, 0x56, 0xFF, 0xD7, 0x78, 0xFF, 0x00])
        let source = Build.jpeg(before: [Fixture.jfif], entropy: entropy)
        #expect(ImageSanitizer.jpeg(source) == source)
        let filled = Build.jpeg(before: [Fixture.jfif], entropy: Data([0x12, 0xFF, 0xFF, 0xFF, 0x00, 0x34]))
        let clean = try #require(ImageSanitizer.jpeg(filled))
        #expect(clean.range(of: Data([0x12, 0xFF, 0x00, 0x34])) != nil, "a run of fill bytes before a stuffed zero collapses to one marker prefix")
    }

    @Test func aProgressiveJPEGWithSeveralScansKeepsEveryScan() throws {
        let sof2 = Data([0xFF, 0xC2, 0x00, 0x0B, 0x08, 0x00, 0x01, 0x00, 0x01, 0x01, 0x01, 0x11, 0x00])
        let dht = Build.segment(0xC4, Data(repeating: 0x01, count: 20))
        let source = Build.soi + Fixture.jfif + sof2 + dht + Fixture.scanHeader + Data(repeating: 0x33, count: 20)
            + dht + Fixture.scanHeader + Data(repeating: 0x44, count: 20) + Build.eoi
        #expect(ImageSanitizer.jpeg(source) == source)
    }

    @Test(arguments: 0..<8)
    func malformedInputIsNilAndNeverACrash(index: Int) {
        let good = Fixture.jpeg()
        let cases: [Data] = [
            Data(),
            Data([0xFF, 0xD8]),
            Data("not a jpeg at all".utf8),
            Fixture.png(),
            Data(good.dropLast(2)), // no end of image
            Data(good.prefix(30)), // cut in a segment
            Build.soi + Build.segment(0xE0, Data(repeating: 0, count: 14)) + Build.eoi, // no frame, no scan
            Build.soi + Data([0xFF, 0xE1, 0xFF, 0xFF, 0x00]) + Build.eoi, // a length that runs past the data
        ]
        #expect(ImageSanitizer.jpeg(cases[index]) == nil)
    }

    @Test(arguments: 0..<300)
    func randomDamageToAGoodJPEGNeverCrashesAndNeverLetsASecretThrough(seed: Int) {
        var generator = SplitMix64(seed: UInt64(seed))
        var bytes = [UInt8](Build.jpeg(before: [Fixture.jfif, Build.segment(0xE1, Build.exifBody(orientation: 6)), Build.app(13, "SECRETIPTC")], trailing: Data("SECRETTRAILER".utf8)))
        for _ in 0..<Int.random(in: 1...6, using: &generator) {
            let at = Int.random(in: 0..<bytes.count, using: &generator)
            switch Int.random(in: 0..<3, using: &generator) {
            case 0: bytes[at] = UInt8.random(in: 0...255, using: &generator)
            case 1: bytes.remove(at: at)
            default: bytes.insert(UInt8.random(in: 0...255, using: &generator), at: at)
            }
        }
        if let clean = ImageSanitizer.jpeg(Data(bytes)) {
            #expect(!contains(clean, "SECRETIPTC") && !contains(clean, "SECRETTRAILER") && !contains(clean, "SECRETMAKER"))
            #expect(clean.prefix(2) == Build.soi && clean.suffix(2) == Build.eoi)
        }
    }
}

// MARK: - PNG

@Suite("Image sanitizer: PNG")
struct PNGSanitizerTests {
    @Test func aPNGWithNoMetadataComesBackByteForByte() {
        #expect(ImageSanitizer.png(Fixture.png()) == Fixture.png())
    }

    @Test func textTimeExifProfileAndPrivateChunksAreDropped() throws {
        let source = Build.pngWith(chunks: [
            ("tEXt", "Author\0SECRETTEXT"), ("iTXt", "XML:com.adobe.xmp\0SECRETXMP"), ("zTXt", "Comment\0\0SECRETCOMMENT"),
            ("eXIf", "SECRETMAKER"), ("tIME", "2026"), ("iCCP", "p\0\0SECRETICC"), ("pHYs", "dpi"), ("bKGD", "x"), ("prVt", "SECRETGPS"),
        ])
        let clean = try #require(ImageSanitizer.png(source))
        for secret in secrets { #expect(!contains(clean, secret), "\(secret) survived") }
        #expect(clean == Fixture.png())
    }

    @Test func chunksThatDecodeTheImageAreKept() throws {
        let source = Build.pngWith(chunks: [("PLTE", "abc"), ("tRNS", "a"), ("gAMA", "gama"), ("cHRM", "chrm"), ("sRGB", "s"), ("tEXt", "SECRETTEXT")])
        let clean = try #require(ImageSanitizer.png(source))
        #expect(!contains(clean, "SECRETTEXT"))
        for kept in ["PLTE", "tRNS", "gAMA", "cHRM", "sRGB", "IDAT", "IEND"] { #expect(contains(clean, kept)) }
    }

    @Test func metadataAfterTheImageDataIsDroppedToo() throws {
        let clean = try #require(ImageSanitizer.png(Build.pngWith(chunks: [("tEXt", "Author\0SECRETTEXT")], beforeData: false)))
        #expect(clean == Fixture.png())
    }

    @Test func anythingAfterIENDIsDropped() throws {
        let clean = try #require(ImageSanitizer.png(Build.pngWith(chunks: [], after: Data("SECRETTRAILER".utf8))))
        #expect(clean == Fixture.png())
    }

    @Test(arguments: 0..<9)
    func malformedInputIsNil(index: Int) {
        let good = Fixture.png()
        let noData = Fixture.pngSignature + Fixture.pngHeader + Fixture.pngChunk("IEND", Data())
        let wrongFirst = Fixture.pngSignature + Fixture.pngChunk("tEXt", Data("x".utf8)) + Fixture.pngHeader + Fixture.pngChunk("IDAT", Data([1])) + Fixture.pngChunk("IEND", Data())
        let shortHeader = Fixture.pngSignature + Fixture.pngChunk("IHDR", Data(count: 12)) + Fixture.pngChunk("IDAT", Data([1])) + Fixture.pngChunk("IEND", Data())
        var hugeLength = [UInt8](good)
        hugeLength.replaceSubrange(8..<12, with: [0x7F, 0xFF, 0xFF, 0xFF])
        let cases: [Data] = [
            Data(), Data(good.prefix(8)), Data("not a png at all, just text".utf8), Fixture.jpeg(),
            Data(good.dropLast(12)), noData, wrongFirst, shortHeader, Data(hugeLength),
        ]
        #expect(ImageSanitizer.png(cases[index]) == nil)
    }

    @Test(arguments: 0..<300)
    func randomDamageNeverCrashesAndNeverLetsASecretThrough(seed: Int) {
        var generator = SplitMix64(seed: UInt64(seed) &+ 1_000)
        var bytes = [UInt8](Build.pngWith(chunks: [("tEXt", "Author\0SECRETTEXT"), ("eXIf", "SECRETMAKER")], after: Data("SECRETTRAILER".utf8)))
        for _ in 0..<Int.random(in: 1...6, using: &generator) {
            let at = Int.random(in: 0..<bytes.count, using: &generator)
            switch Int.random(in: 0..<3, using: &generator) {
            case 0: bytes[at] = UInt8.random(in: 0...255, using: &generator)
            case 1: bytes.remove(at: at)
            default: bytes.insert(UInt8.random(in: 0...255, using: &generator), at: at)
            }
        }
        if let clean = ImageSanitizer.png(Data(bytes)) {
            #expect(!contains(clean, "SECRETTEXT") && !contains(clean, "SECRETMAKER") && !contains(clean, "SECRETTRAILER"))
        }
    }
}

// MARK: - Real encoder output

#if canImport(ImageIO)
@Suite("Image sanitizer: ImageIO output")
struct ImageIOSanitizerTests {
    private static func pixels(_ image: CGImage) -> [UInt8] {
        let width = image.width, height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        buffer.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return buffer
    }

    private static func source() throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: 16, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        for column in 0..<16 {
            context.setFillColor(CGColor(red: Double(column) / 16, green: 0.4, blue: 1 - Double(column) / 16, alpha: 1))
            context.fill(CGRect(x: column, y: 0, width: 1, height: 8))
        }
        return try #require(context.makeImage())
    }

    private static func encode(_ image: CGImage, type: String, properties: [CFString: Any]) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private static func metadata() -> [CFString: Any] {
        [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 41.8708, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 87.6505, kCGImagePropertyGPSLongitudeRef: "W",
            ] as [CFString: Any],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "SECRETMAKER", kCGImagePropertyTIFFModel: "SECRETMODEL"] as [CFString: Any],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2026:10:29 08:00:00", kCGImagePropertyExifBodySerialNumber: "SECRETSERIAL",
            ] as [CFString: Any],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCaptionAbstract: "SECRETIPTC"] as [CFString: Any],
        ]
    }

    private func properties(of data: Data) throws -> [CFString: Any] {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    private func decode(_ data: Data) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetCount(source) == 1)
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func closeEnough(_ lhs: [UInt8], _ rhs: [UInt8], tolerance: Int = 8) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { abs(Int($0) - Int($1)) <= tolerance }
    }

    @Test func aCameraStyleJPEGLosesItsLocationAndDeviceButStaysDecodableAndUpright() throws {
        let image = try Self.source()
        let original = try Self.encode(image, type: "public.jpeg", properties: Self.metadata())
        // Prove the encoder wrote the metadata, or this test says nothing.
        #expect(contains(original, "SECRETMAKER"), "the encoder should have written the make")
        let before = try properties(of: original)
        #expect(before[kCGImagePropertyGPSDictionary] != nil)

        let clean = try #require(ImageSanitizer.jpeg(original))
        for secret in ["SECRETMAKER", "SECRETMODEL", "SECRETSERIAL", "SECRETIPTC"] { #expect(!contains(clean, secret)) }
        let after = try properties(of: clean)
        #expect(after[kCGImagePropertyGPSDictionary] == nil)
        #expect((after[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake] == nil)
        #expect((after[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal] == nil)
        #expect((after[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifBodySerialNumber] == nil)
        #expect(after[kCGImagePropertyIPTCDictionary] == nil)
        #expect((after[kCGImagePropertyOrientation] as? Int) == 6)
        #expect(after[kCGImagePropertyPixelWidth] as? Int == 16 && after[kCGImagePropertyPixelHeight] as? Int == 8)
        // Same entropy-coded data: the pixels are what they were.
        #expect(closeEnough(Self.pixels(try decode(clean)), Self.pixels(try decode(original))))
        #expect(clean.count < original.count)
    }

    @Test func aJPEGWithNoOrientationHasNoneAfterwards() throws {
        let original = try Self.encode(try Self.source(), type: "public.jpeg", properties: [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "SECRETMAKER"] as [CFString: Any]])
        let clean = try #require(ImageSanitizer.jpeg(original))
        #expect(!contains(clean, "SECRETMAKER"))
        let orientation = try properties(of: clean)[kCGImagePropertyOrientation] as? Int
        #expect(orientation == nil || orientation == 1)
        _ = try decode(clean)
    }

    @Test func aPNGLosesItsTextAndMetadataButStaysDecodable() throws {
        let image = try Self.source()
        let original = try Self.encode(image, type: "public.png", properties: [
            kCGImagePropertyPNGDictionary: [
                kCGImagePropertyPNGDescription: "SECRETTEXT", kCGImagePropertyPNGSoftware: "SECRETMAKER", kCGImagePropertyPNGAuthor: "SECRETGPS",
            ] as [CFString: Any],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "SECRETMAKER"] as [CFString: Any],
        ])
        #expect(contains(original, "SECRETTEXT"), "the encoder should have written the description")
        let clean = try #require(ImageSanitizer.png(original))
        for secret in ["SECRETTEXT", "SECRETMAKER", "SECRETGPS"] { #expect(!contains(clean, secret)) }
        let decoded = try decode(clean)
        #expect(decoded.width == 16 && decoded.height == 8)
        #expect(closeEnough(Self.pixels(decoded), Self.pixels(try decode(original))))
    }
}
#endif

// MARK: - What the plans send, hash and say they saw

private func imageDataURLs(_ request: HTTPRequest) -> [String] {
    (request.jsonBody?["input"]?.arrayValue ?? []).flatMap { item in
        (item["content"]?.arrayValue ?? []).compactMap { $0["image_url"]?.stringValue }
    }
}

private func payload(_ url: String) -> Data? {
    guard let comma = url.firstIndex(of: ",") else { return nil }
    return Data(base64Encoded: String(url[url.index(after: comma)...]))
}

@Suite("Images in insight plans", .timeLimit(.minutes(1)))
struct ImagePlanTests {
    private let coachPath = "/v1/coach/responses"

    private func dirtyPNG() -> Data { Build.pngWith(chunks: [("tEXt", "Author\0SECRETTEXT"), ("eXIf", "SECRETMAKER")]) }

    private func dirtyJPEG(orientation: Int = 6, secret: String = "SECRETMAKER") -> Data {
        Build.jpeg(before: [Fixture.jfif, Build.segment(0xE1, Build.exifBody(orientation: orientation, secret: secret)), Build.app(13, "SECRETIPTC")])
    }

    @Test func setReviewSendsHashesAndDescribesTheCleanPicture() async throws {
        let rig = ClientRig(sequence([Fixture.setReviewReply()]))
        let store = FakeInsightStore()
        let images = [SkeletonImage(role: .bestRepBottom, rep: 3, png: dirtyPNG())]
        let result = try await rig.service(insights: store).reviewSet(Fixture.setReviewInput(images: images), locale: .en)

        let sent = try #require(rig.transport.requests(path: coachPath).first)
        let urls = imageDataURLs(sent)
        #expect(urls.count == 1)
        #expect(payload(urls[0]) == Fixture.png())
        #expect(!(sent.body.map { contains($0, "SECRETTEXT") } ?? true))
        #expect(result.whatMuseSaw?.images.map(\.byteCount) == [Fixture.png().count])
        let saved = try #require(await store.saved.first)
        #expect(!saved.payload.string.contains("SECRETTEXT"))
    }

    @Test func thePictureAloneDecidesTheCacheKeyNotItsMetadata() async throws {
        let rig = ClientRig(sequence([Fixture.setReviewReply()]))
        let service = rig.service()
        _ = try await service.reviewSet(Fixture.setReviewInput(images: [SkeletonImage(role: .bestRepBottom, rep: 3, png: dirtyPNG())]), locale: .en)
        let again = try await service.reviewSet(Fixture.setReviewInput(images: [SkeletonImage(role: .bestRepBottom, rep: 3, png: Fixture.png())]), locale: .en)
        #expect(again.fromCache)
        #expect(rig.transport.requests(path: coachPath).count == 1)
    }

    @Test func aMealPhotoGoesOutWithoutItsLocationDeviceOrCaptionButKeepsItsOrientation() async throws {
        let rig = ClientRig(sequence([.json(Wire.response(text: Fixture.goodMealJSON.canonicalString))]))
        let store = FakeInsightStore()
        let photo = MealPhotoInput(jpeg: dirtyJPEG(), subjectID: "2026-10-29", unitSystem: .metric)
        let result = try await rig.service(insights: store).estimateMeal(photo, locale: .en)

        let sent = try #require(rig.transport.requests(path: coachPath).first)
        let url = try #require(imageDataURLs(sent).first)
        let sentJPEG = try #require(payload(url))
        #expect(!contains(sentJPEG, "SECRETMAKER") && !contains(sentJPEG, "SECRETIPTC"))
        let exif = Build.segments(of: sentJPEG).filter { $0.marker == 0xE1 }
        #expect(exif.count == 1)
        let keptExif = try #require(exif.first)
        #expect(orientation(of: keptExif.body) == 6)
        #expect(result.whatMuseSaw?.images.map(\.byteCount) == [sentJPEG.count])
        #expect(sentJPEG.count < dirtyJPEG().count)
    }

    @Test func twoPhotosOfTheSameMealWithDifferentMetadataShareAnEstimate() async throws {
        let rig = ClientRig(sequence([.json(Wire.response(text: Fixture.goodMealJSON.canonicalString))]))
        let service = rig.service()
        _ = try await service.estimateMeal(MealPhotoInput(jpeg: dirtyJPEG(secret: "SECRETMAKER"), subjectID: "d"), locale: .en)
        let again = try await service.estimateMeal(MealPhotoInput(jpeg: dirtyJPEG(secret: "SECRETGPS"), subjectID: "d"), locale: .en)
        #expect(again.fromCache)
        #expect(rig.transport.requests(path: coachPath).count == 1)
    }

    @Test func orientationIsPartOfThePictureSoARotatedPhotoIsAskedAboutAgain() async throws {
        let rig = ClientRig(sequence([.json(Wire.response(text: Fixture.goodMealJSON.canonicalString))]))
        let service = rig.service()
        _ = try await service.estimateMeal(MealPhotoInput(jpeg: dirtyJPEG(orientation: 6), subjectID: "d"), locale: .en)
        let rotated = try await service.estimateMeal(MealPhotoInput(jpeg: dirtyJPEG(orientation: 3), subjectID: "d"), locale: .en)
        #expect(!rotated.fromCache)
    }

    @Test func malformedImagesAreRefusedBeforeAnythingIsSent() async {
        let rig = ClientRig(sequence([Fixture.setReviewReply()]))
        let service = rig.service()
        let truncatedPNG = Data(Fixture.png().dropLast(12))
        let error = await caught { try await service.reviewSet(Fixture.setReviewInput(images: [SkeletonImage(role: .bestRepBottom, png: truncatedPNG)]), locale: .en) }
        guard case .invalidInput? = error as? CoachError else { Issue.record("got \(String(describing: error))"); return }
        let meal = await caught { try await service.estimateMeal(MealPhotoInput(jpeg: Data(Fixture.jpeg().dropLast(2))), locale: .en) }
        guard case .invalidInput? = meal as? CoachError else { Issue.record("got \(String(describing: meal))"); return }
        #expect(rig.transport.requests.isEmpty)
    }
}

// MARK: - Citations that cannot exist

@Suite("Citations", .timeLimit(.minutes(1)))
struct CitationTests {
    private let coachPath = "/v1/coach/responses"

    private func review(fixing refs: [Int]) -> JSONValue {
        var object = Fixture.goodReviewJSON.objectValue!
        if refs.isEmpty {
            object["fixNext"] = .array([])
        } else {
            let fix: JSONValue = .object(["cue": "Sit deeper", "why": "It was shallow.", "repRefs": .array(refs.map { .int($0) })])
            object["fixNext"] = .array([fix])
        }
        return .object(object)
    }

    private var noMeasurements: SetReviewInput {
        var input = Fixture.setReviewInput()
        input.reps = 0
        input.measurements = []
        input.averageScore = nil
        input.velocityLoss = nil
        return input
    }

    @Test func aSetWithNoMeasuredRepsRejectsAFixThatCitesRepOne() async throws {
        let rig = ClientRig(sequence([Wire.streamReply(text: review(fixing: [1]).canonicalString), Wire.streamReply(text: review(fixing: []).canonicalString)]))
        let result = try await rig.service().reviewSet(noMeasurements, locale: .en)
        #expect(result.origin == .muse)
        #expect(result.output.fixNext.isEmpty)
        let sent = rig.transport.requests(path: coachPath)
        #expect(sent.count == 2)
        guard sent.count == 2 else { return }
        let correction = (sent[1].jsonBody?["input"]?.arrayValue?.last?["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined()
        #expect(correction.contains("no measured reps"))
    }

    @Test func aSetWithNoMeasuredRepsAcceptsAReviewWithNoFixes() async throws {
        let rig = ClientRig(sequence([Wire.streamReply(text: review(fixing: []).canonicalString)]))
        let result = try await rig.service().reviewSet(noMeasurements, locale: .en)
        #expect(result.origin == .muse && result.output.fixNext.isEmpty)
        #expect(rig.transport.requests(path: coachPath).count == 1)
    }

    @Test(arguments: [0, -1, 7])
    func repNumbersOutsideOneToSixAreRejected(rep: Int) async throws {
        let rig = ClientRig(sequence([Wire.streamReply(text: review(fixing: [rep]).canonicalString), Fixture.setReviewReply()]))
        let result = try await rig.service().reviewSet(Fixture.setReviewInput(), locale: .en)
        #expect(result.output.fixNext.first?.repRefs == [2, 4])
        #expect(rig.transport.requests(path: coachPath).count == 2)
    }

    @Test func aDebriefConcernCannotCiteAnOmittedEmptyExercise() async throws {
        let squat = SessionDebriefInput.ExerciseBlock(id: "squat.bodyweight", name: "Bodyweight Squat", sets: [])
        let pushup = SessionDebriefInput.ExerciseBlock(id: "pushup", name: "Push-up", sets: [.init(number: 1, reps: 10)])
        let input = SessionDebriefInput(sessionID: "0195f000-0000-7000-8000-0000000000a1", localDay: Fixture.day, exercises: [squat, pushup])
        #expect(input.exercises.map(\.id) == [pushup.id])
        func answer(citingSquat: Bool) -> Reply {
            var debrief = Fixture.goodDebriefJSON.objectValue!
            debrief["perExercise"] = [["exerciseID": "pushup", "verdict": "first_time", "note": "n"]]
            debrief["concerns"] = citingSquat
                ? [["exerciseID": "squat.bodyweight", "setNumbers": [1], "detail": "d"]]
                : []
            debrief["nextSession"] = ["focus": "f", "suggestions": [], "restDaysSuggested": 1]
            return Wire.streamReply(text: JSONValue.object(debrief).canonicalString)
        }
        let rig = ClientRig(sequence([answer(citingSquat: true), answer(citingSquat: false)]))
        let result = try await rig.service().debriefSession(input, locale: .en)
        #expect(result.origin == .muse)
        #expect(result.output.concerns.isEmpty)
        let sent = rig.transport.requests(path: coachPath)
        #expect(sent.count == 2)
        guard sent.count == 2 else { return }
        let correction = (sent[1].jsonBody?["input"]?.arrayValue?.last?["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined()
        #expect(correction.contains("squat.bodyweight\" is not in the session"))
    }
}

// MARK: - Cancellation before the stand-in

@Suite("Cancellation and the offline stand-in", .timeLimit(.minutes(1)))
struct OfflineCancellationTests {
    /// The proxy cannot be reached at the very moment the caller gives up. That failure normally ends in the
    /// on-device stand-in, but the caller asked to stop: it gets the cancellation and nothing is stored.
    @Test func aCancelledCallerDoesNotGetAStoredOfflineReview() async {
        let running = Mutex<Task<InsightResult<SetReview>, any Error>?>(nil)
        let rig = ClientRig(retry: .none) { _, _ in
            running.withLock { $0 }?.cancel()
            return .failure(URLError(.notConnectedToInternet))
        }
        let store = FakeInsightStore()
        let service = rig.service(insights: store)
        let task = Task { try await service.reviewSet(Fixture.setReviewInput(), locale: .en) }
        running.withLock { $0 = task }
        let error = await caught { try await task.value }
        #expect(error is CancellationError)
        #expect(await store.saved.isEmpty)
    }

    @Test func aCallerThatStaysGetsTheStoredStandInForTheSameFailure() async throws {
        let rig = ClientRig(retry: .none) { _, _ in .failure(URLError(.notConnectedToInternet)) }
        let store = FakeInsightStore()
        let result = try await rig.service(insights: store).reviewSet(Fixture.setReviewInput(), locale: .en)
        #expect(result.origin == .offline)
        #expect(await store.saved.count == 1)
    }
}
