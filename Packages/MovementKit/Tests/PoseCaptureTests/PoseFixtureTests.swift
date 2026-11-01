import Foundation
import MotionCore
import Testing
@testable import PoseCapture

private func sampleFrames(count: Int = 12, start: Double = 1000) -> [PoseFrame] {
    (0..<count).map { i in
        let t = start + Double(i) / 30
        return PoseFrame(
            t: t,
            joints: [
                .nose: Keypoint(x: 0.3 + 0.001234567 * Double(i), y: 0.9, confidence: 0.987654),
                .leftKnee: Keypoint(x: 0.41234567, y: 0.30000049, confidence: 0.5),
            ],
            imageAspect: 0.5625
        )
    }
}

private func header(labels: PoseLabels = PoseLabels()) -> PoseFixtureHeader {
    PoseFixtureHeader(
        exerciseSpecID: "squat.bodyweight", cameraPosition: .front, fps: 30, deviceModel: "iPhone18,1",
        created: Date(timeIntervalSince1970: 1_800_000_000), labels: labels
    )
}

@Suite("Pose fixtures")
struct PoseFixtureTests {
    @Test func roundTripKeepsHeaderLabelsAndFrames() throws {
        let labels = PoseLabels(reps: 10, partials: 2, notes: "room 2, low light", tags: ["room-2", "front"])
        let original = PoseFixture(header: header(labels: labels), frames: sampleFrames())
        let data = try PoseFixtureFile.encode(original)
        let decoded = try PoseFixtureFile.decode(data)

        #expect(decoded.header == original.header)
        #expect(decoded.header.labels == labels)
        #expect(decoded.header.cameraPosition == .front)
        #expect(decoded.header.created == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(decoded.frames.count == original.frames.count)
        #expect(decoded.frames == original.frames.map(PoseFixtureFile.rounded))
    }

    @Test func fileHasAHeaderLineThenOneFramePerLine() throws {
        let data = try PoseFixtureFile.encode(PoseFixture(header: header(), frames: sampleFrames(count: 3)))
        let text = try #require(String(data: data, encoding: .utf8))
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 5)                                   // header, 3 frames, trailing empty
        #expect(lines.last == "")
        #expect(lines[0].contains("\"format\":\"movement-tracker.pose\""))
        #expect(lines[0].contains("\"version\":1"))
        #expect(lines[0].contains("\"exerciseSpecID\":\"squat.bodyweight\""))
        #expect(lines[0].contains("\"cameraPosition\":\"front\""))
        #expect(lines[0].contains("\"deviceModel\":\"iPhone18,1\""))
        #expect(lines[0].contains("\"fps\":30"))
        #expect(lines[1].contains("\"imageAspect\":0.5625"))
    }

    @Test func coordinatesAreRoundedToFourDecimals() throws {
        let data = try PoseFixtureFile.encode(PoseFixture(header: header(), frames: sampleFrames(count: 1)))
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("[0.4123,0.3,0.5]"))
        #expect(text.contains("0.9877"))
        #expect(!text.contains("0.41234567"))
    }

    @Test func encodingIsDeterministic() throws {
        let fixture = PoseFixture(header: header(), frames: sampleFrames())
        #expect(try PoseFixtureFile.encode(fixture) == PoseFixtureFile.encode(fixture))
    }

    @Test func absentJointsStayAbsent() throws {
        let frame = PoseFrame(t: 1, joints: [.nose: Keypoint(x: 0.5, y: 0.5, confidence: 1)], imageAspect: 1)
        let decoded = try PoseFixtureFile.decode(PoseFixtureFile.encode(PoseFixture(header: header(), frames: [frame])))
        #expect(decoded.frames[0].joints.keys.sorted { $0.rawValue < $1.rawValue } == [.nose])
        let empty = PoseFrame(t: 2, joints: [:], imageAspect: 1)
        let again = try PoseFixtureFile.decode(PoseFixtureFile.encode(PoseFixture(header: header(), frames: [empty])))
        #expect(again.frames[0].joints.isEmpty)
    }

    @Test func missingLabelsDecodeAsEmpty() throws {
        let line = #"{"cameraPosition":"back","created":"2027-01-01T00:00:00Z","format":"movement-tracker.pose","labels":{},"version":1}"#
        let fixture = try PoseFixtureFile.decode(Data((line + "\n").utf8))
        #expect(fixture.header.labels == PoseLabels())
        #expect(fixture.header.labels.tags == [])
        #expect(fixture.frames.isEmpty)
    }

    @Test func rejectsFilesThatAreNotFixtures() {
        #expect(throws: PoseFixtureError.empty) { try PoseFixtureFile.decode(Data()) }
        #expect(throws: PoseFixtureError.self) { try PoseFixtureFile.decode(Data("not json\n".utf8)) }
        let other = #"{"cameraPosition":"back","created":"2027-01-01T00:00:00Z","format":"something.else","labels":{},"version":1}"#
        #expect(throws: PoseFixtureError.notAFixture(format: "something.else")) {
            try PoseFixtureFile.decode(Data(other.utf8))
        }
        let future = #"{"cameraPosition":"back","created":"2027-01-01T00:00:00Z","format":"movement-tracker.pose","labels":{},"version":99}"#
        #expect(throws: PoseFixtureError.unsupportedVersion(99)) { try PoseFixtureFile.decode(Data(future.utf8)) }
    }

    @Test func aTruncatedLastLineIsIgnoredButACorruptMiddleLineIsNot() throws {
        let data = try PoseFixtureFile.encode(PoseFixture(header: header(), frames: sampleFrames(count: 4)))
        let text = try #require(String(data: data, encoding: .utf8))
        var lines = text.split(separator: "\n").map(String.init)

        // A recording that stopped mid-write: the last line is cut off and has no terminator.
        var truncated = lines
        truncated[truncated.count - 1] = String(truncated[truncated.count - 1].prefix(20))
        let cut = try PoseFixtureFile.decode(Data(truncated.joined(separator: "\n").utf8))
        #expect(cut.frames.count == 3)

        lines[2] = "{broken"
        #expect(throws: PoseFixtureError.self) { try PoseFixtureFile.decode(Data((lines.joined(separator: "\n") + "\n").utf8)) }
    }

    @Test func aCorruptLastLineThatWasWrittenOutCompletelyIsAnError() throws {
        // Every line the recorder writes ends with a newline, so a last line that has one was not cut off:
        // dropping it silently would lose a frame (or a whole set's worth after a bad edit) without a word.
        let data = try PoseFixtureFile.encode(PoseFixture(header: header(), frames: sampleFrames(count: 3)))
        var lines = try #require(String(data: data, encoding: .utf8)).split(separator: "\n").map(String.init)
        lines[lines.count - 1] = #"{"imageAspect":0.5625,"joints":{},"t":"soon"}"#
        let terminated = Data((lines.joined(separator: "\n") + "\n").utf8)
        #expect(throws: PoseFixtureError.self) { try PoseFixtureFile.decode(terminated) }
        // The same bytes without the final newline look like an interrupted write and are tolerated.
        let cut = try PoseFixtureFile.decode(Data(lines.joined(separator: "\n").utf8))
        #expect(cut.frames.count == 2)
    }

    @Test func aBadFrameErrorNamesTheRealLineAndTheValue() throws {
        let data = try PoseFixtureFile.encode(PoseFixture(header: header(), frames: sampleFrames(count: 4)))
        var lines = try #require(String(data: data, encoding: .utf8)).split(separator: "\n").map(String.init)
        lines[3] = #"{"imageAspect":0.5625,"joints":{"nose":[0.5,"high",0.9]},"t":1.5}"#
        // Blank lines are skipped but still count: the bad line is the 7th in the file.
        let text = [lines[0], "", lines[1], lines[2], "", lines[3], lines[4]].joined(separator: "\n") + "\n"
        do {
            _ = try PoseFixtureFile.decode(Data(text.utf8))
            Issue.record("a bad frame was accepted")
        } catch let PoseFixtureError.badFrame(line, reason) {
            #expect(line == 6)
            #expect(reason.contains("joints"), "\(reason)")
            #expect(reason.contains("nose"), "\(reason)")
            #expect(PoseFixtureError.badFrame(line: line, reason: reason).errorDescription?.hasPrefix("Line 6 is not a pose frame") == true)
        }
    }

    @Test func aBadHeaderErrorSaysWhichKeyIsWrong() {
        let missing = #"{"cameraPosition":"back","format":"movement-tracker.pose","labels":{},"version":1}"#
        do {
            _ = try PoseFixtureFile.decode(Data((missing + "\n").utf8))
            Issue.record("a header without a date was accepted")
        } catch let PoseFixtureError.badHeader(reason) {
            #expect(reason.contains("created"), "\(reason)")
        } catch {
            Issue.record("unexpected \(error)")
        }
        let wrongType = #"{"cameraPosition":"sideways","created":"2027-01-01T00:00:00Z","format":"movement-tracker.pose","labels":{},"version":1}"#
        do {
            _ = try PoseFixtureFile.decode(Data((wrongType + "\n").utf8))
            Issue.record("an unknown camera position was accepted")
        } catch let PoseFixtureError.badHeader(reason) {
            #expect(reason.contains("cameraPosition"), "\(reason)")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func aFileWithOnlyAHeaderAndNoNewlineCanBeRelabelled() throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("header-only.jsonl")
        try PoseFixtureFile.encodeHeader(header()).write(to: url)       // no terminator, no frames
        try PoseFixtureFile.updateLabels(at: url, to: PoseLabels(reps: 5))
        let read = try PoseFixtureFile.read(from: url)
        #expect(read.header.labels.reps == 5)
        #expect(read.frames.isEmpty)
        #expect(try PoseFixtureFile.readHeader(from: url).labels.reps == 5)
    }

    @Test func windowsLineEndingsAreAccepted() throws {
        let data = try PoseFixtureFile.encode(PoseFixture(header: header(), frames: sampleFrames(count: 3)))
        let crlf = try #require(String(data: data, encoding: .utf8)).replacingOccurrences(of: "\n", with: "\r\n")
        #expect(try PoseFixtureFile.decode(Data(crlf.utf8)).frames.count == 3)
    }

    // MARK: Recorder

    @Test func recorderWritesAFileTheReaderCanRead() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("set.jsonl")
        let recorder = try PoseRecorder(url: url, header: header(), flushEveryFrames: 5)
        for frame in sampleFrames(count: 12) { try await recorder.append(frame) }
        #expect(await recorder.frameCount == 12)
        // Flushed every 5 frames: a crash now still leaves a readable file with 10 frames.
        let midway = try PoseFixtureFile.read(from: url)
        #expect(midway.frames.count == 10)

        await recorder.setLabels(PoseLabels(reps: 3, partials: 1, tags: ["demo"]))
        let final = try await recorder.finish()
        #expect(final.frameCount == 12)
        #expect(final.labels.reps == 3)
        let duration = try #require(final.duration)
        #expect(abs(duration - 11.0 / 30) < 1e-3)

        let read = try PoseFixtureFile.read(from: url)
        #expect(read.frames.count == 12)
        #expect(read.header.labels == PoseLabels(reps: 3, partials: 1, tags: ["demo"]))
        #expect(read.header.frameCount == 12)
        #expect(try PoseFixtureFile.readHeader(from: url) == read.header)
        #expect(read.frames == sampleFrames(count: 12).map(PoseFixtureFile.rounded))
    }

    @Test func recorderFillsInFPSWhenTheHeaderHasNone() async throws {
        let directory = try TemporaryDirectory()
        var bare = header()
        bare.fps = nil
        let recorder = try PoseRecorder(url: directory.file("a.jsonl"), header: bare)
        for frame in sampleFrames(count: 31) { try await recorder.append(frame) }
        let final = try await recorder.finish()
        #expect(abs(try #require(final.fps) - 30) < 0.01)
    }

    @Test func recorderRefusesFramesAfterFinishAndFinishIsIdempotent() async throws {
        let directory = try TemporaryDirectory()
        let recorder = try PoseRecorder(url: directory.file("b.jsonl"), header: header())
        try await recorder.append(sampleFrames(count: 1)[0])
        let first = try await recorder.finish()
        let second = try await recorder.finish()
        #expect(first == second)
        await #expect(throws: PoseFixtureError.finished) { try await recorder.append(sampleFrames(count: 1)[0]) }
    }

    @Test func finishDoesNotChangeLabelsAfterTheFileIsFinalized() async throws {
        let directory = try TemporaryDirectory()
        let recorder = try PoseRecorder(url: directory.file("final.jsonl"), header: header())
        let first = try await recorder.finish(labels: PoseLabels(reps: 0))
        await recorder.setLabels(PoseLabels(reps: 100))
        #expect(try await recorder.finish(labels: PoseLabels(reps: 99)) == first)
        #expect(try PoseFixtureFile.readHeader(from: recorder.url) == first)
    }

    @Test func failedFinalHeaderWriteCanBeRetriedAndDoesNotAcceptMoreFrames() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("retry.jsonl")
        let recorder = try PoseRecorder(url: url, header: header(), flushEveryFrames: 1)
        try await recorder.append(sampleFrames(count: 1)[0])
        let provisional = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        await #expect(throws: (any Error).self) { try await recorder.finish() }
        #expect(await !recorder.isFinished)
        await #expect(throws: PoseFixtureError.finished) { try await recorder.append(sampleFrames(count: 1)[0]) }

        try provisional.write(to: url)
        let finished = try await recorder.finish()
        #expect(await recorder.isFinished)
        #expect(finished.frameCount == 1)
        #expect(try PoseFixtureFile.readHeader(from: url) == finished)
    }

    @Test func aRecorderDroppedWithoutFinishStillKeepsItsFrames() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("dropped.jsonl")
        do {
            let recorder = try PoseRecorder(url: url, header: header(), flushEveryFrames: 30)
            for frame in sampleFrames(count: 7) { try await recorder.append(frame) }
        }                                                           // fewer than 30 frames: nothing was flushed yet
        let read = try PoseFixtureFile.read(from: url)
        #expect(read.frames.count == 7)
        #expect(read.header.frameCount == nil)                      // never finished: no final header
    }

    @Test func recorderCreatesMissingDirectories() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("nested/deeper/c.jsonl")
        let recorder = try PoseRecorder(url: url, header: header())
        try await recorder.finish()
        #expect(try PoseFixtureFile.read(from: url).frames.isEmpty)
    }

    @Test func labelsCanBeSetAfterTheSetEndsWithoutRewritingFrames() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("d.jsonl")
        let recorder = try PoseRecorder(url: url, header: header())
        for frame in sampleFrames(count: 6) { try await recorder.append(frame) }
        try await recorder.finish()
        let before = try Data(contentsOf: url)

        try PoseFixtureFile.updateLabels(at: url, to: PoseLabels(reps: 8, partials: 0, notes: "counted by hand"))
        let read = try PoseFixtureFile.read(from: url)
        #expect(read.header.labels.reps == 8)
        #expect(read.header.labels.notes == "counted by hand")
        #expect(read.frames.count == 6)
        #expect(read.header.frameCount == 6)

        // Only the first line changed.
        let after = try Data(contentsOf: url)
        let beforeBody = before.drop { $0 != UInt8(ascii: "\n") }
        let afterBody = after.drop { $0 != UInt8(ascii: "\n") }
        #expect(Data(beforeBody) == Data(afterBody))
    }

    @Test func readHeaderOnlyReadsTheFirstLine() throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("e.jsonl")
        try PoseFixtureFile.write(PoseFixture(header: header(labels: PoseLabels(reps: 4)), frames: sampleFrames(count: 200)), to: url)
        #expect(try PoseFixtureFile.readHeader(from: url).labels.reps == 4)
    }
}

@Suite("Replay")
struct ReplayPoseSourceTests {
    private func fixture(frames: [PoseFrame]) -> PoseFixture {
        PoseFixture(header: header(), frames: frames)
    }

    @Test func realTimePacingFollowsRecordedTimestamps() async {
        let frames = sampleFrames(count: 5, start: 1000).enumerated().map { i, f in
            var f = f
            f.t = 1000 + [0.0, 0.1, 0.1, 0.5, 2.0][i]
            return f
        }
        let clock = TestClock(startingAt: .seconds(100))
        let source = ReplayPoseSource(fixture: fixture(frames: frames), pacing: .realTime(), clock: clock)
        var received: [PoseFrame] = []
        for await frame in source.frames() { received.append(frame) }

        #expect(received == frames)
        let deadlines = clock.requestedDeadlines
        #expect(deadlines.count == 5)
        for (deadline, offset) in zip(deadlines, [0.0, 0.1, 0.1, 0.5, 2.0]) {
            #expect(abs(deadline - (100 + offset)) < 1e-6)
        }
        #expect(abs(clock.now.offset.testSeconds - 102) < 1e-6)
    }

    @Test func speedScalesTheWaits() async {
        let frames = sampleFrames(count: 4, start: 50)
        let clock = TestClock(startingAt: .seconds(0))
        let source = ReplayPoseSource(fixture: fixture(frames: frames), pacing: .realTime(speed: 2), clock: clock)
        for await _ in source.frames() {}
        let expected = [0.0, 1.0 / 30, 2.0 / 30, 3.0 / 30].map { $0 / 2 }
        for (deadline, offset) in zip(clock.requestedDeadlines, expected) {
            #expect(abs(deadline - offset) < 1e-6)
        }
    }

    @Test func badSpeedFallsBackToRealTime() async {
        let clock = TestClock(startingAt: .seconds(0))
        let source = ReplayPoseSource(fixture: fixture(frames: sampleFrames(count: 3, start: 0)), pacing: .realTime(speed: -1), clock: clock)
        for await _ in source.frames() {}
        #expect(abs(clock.requestedDeadlines.last! - 2.0 / 30) < 1e-6)
    }

    @Test func fastReplayDoesNotWait() async {
        let clock = TestClock()
        let frames = sampleFrames(count: 50)
        let source = ReplayPoseSource(fixture: fixture(frames: frames), pacing: .fast, clock: clock)
        var count = 0
        for await _ in source.frames() { count += 1 }
        #expect(count == 50)
        #expect(clock.requestedDeadlines.isEmpty)
    }

    @Test func everyFrameArrivesInOrderAndReplayCanRestart() async {
        let frames = sampleFrames(count: 30)
        let source = ReplayPoseSource(fixture: fixture(frames: frames), pacing: .fast)
        var first: [Double] = [], second: [Double] = []
        for await f in source.frames() { first.append(f.t) }
        for await f in source.frames() { second.append(f.t) }
        #expect(first == frames.map(\.t))
        #expect(second == first)
    }

    @Test func emptyFixtureFinishesImmediately() async {
        let source = ReplayPoseSource(fixture: fixture(frames: []), pacing: .realTime(), clock: TestClock())
        var count = 0
        for await _ in source.frames() { count += 1 }
        #expect(count == 0)
        #expect(source.frameCount == 0 && source.duration == 0)
    }

    @Test func durationAndHeaderAreExposed() {
        let source = ReplayPoseSource(fixture: fixture(frames: sampleFrames(count: 31)), pacing: .fast)
        #expect(abs(source.duration - 1) < 1e-9)
        #expect(source.frameCount == 31)
        #expect(source.header.exerciseSpecID == "squat.bodyweight")
    }

    @Test func theScheduleStartsWhenReplayIsRequestedNotWhenItIsFirstRead() async {
        let frames = sampleFrames(count: 3, start: 10)
        let clock = TestClock(startingAt: .seconds(100))
        let source = ReplayPoseSource(fixture: fixture(frames: frames), pacing: .realTime(), clock: clock)
        let stream = source.frames()
        clock.jump(by: .seconds(5))                 // the consumer is slow to start reading
        for await _ in stream {}
        for (deadline, offset) in zip(clock.requestedDeadlines, [0.0, 1.0 / 30, 2.0 / 30]) {
            #expect(abs(deadline - (100 + offset)) < 1e-6)
        }
    }

    @Test func leavingTheStreamCancelsTheWaitInsideTheReplay() async throws {
        let clock = HangingClock()
        var frames = sampleFrames(count: 3, start: 0)
        frames[1].t = 3_600                          // an hour away: the replay is parked in a sleep
        let source = ReplayPoseSource(fixture: fixture(frames: frames), pacing: .realTime(), clock: clock)
        do {
            var iterator = source.frames().makeAsyncIterator()
            let first = await iterator.next()
            #expect(first?.t == 0)
            // The replay is now waiting for frame 1.
            for _ in 0..<200 where clock.sleeping == 0 { try await Task.sleep(for: .milliseconds(5)) }
            #expect(clock.sleeping == 1)
        }                                            // the iterator and the stream go away here
        for _ in 0..<400 where clock.cancelledSleeps == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(clock.cancelledSleeps == 1)
        #expect(clock.sleeping == 0)
    }

    @Test func stoppingEarlyCancelsTheReplay() async throws {
        // On this clock a frame that is due now arrives at once and any later one waits until it is cancelled. Giving
        // the first three frames one timestamp makes the replay deliver them and then park on the fourth, so the test
        // needs no real time.
        let clock = HangingClock()
        var frames = sampleFrames(count: 600)
        frames[1].t = frames[0].t
        frames[2].t = frames[0].t
        let source = ReplayPoseSource(fixture: fixture(frames: frames), pacing: .realTime(), clock: clock)
        var received: [PoseFrame] = []
        for await frame in source.frames() {
            received.append(frame)
            if received.count == 3 { break }
        }
        #expect(received == Array(frames.prefix(3)))
        // Leaving the loop ended the stream, which cancelled the replay out of its wait for frame 3.
        for _ in 0..<400 where clock.cancelledSleeps == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(clock.cancelledSleeps == 1)
        #expect(clock.sleeping == 0)
    }
}
