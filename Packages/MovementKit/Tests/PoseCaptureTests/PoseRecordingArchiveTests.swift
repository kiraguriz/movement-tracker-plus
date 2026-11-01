import Foundation
import MotionCore
import Testing
@testable import PoseCapture

@Suite("Pose recording archive")
struct PoseRecordingArchiveTests {
    private func archive(in directory: TemporaryDirectory) -> PoseRecordingArchive {
        PoseRecordingArchive(
            directory: directory.url.appendingPathComponent("private"),
            exportDirectory: directory.url.appendingPathComponent("Documents/PoseCaptures")
        )
    }

    private func appendIdle(to recorder: PoseRecorder) async throws {
        for i in 0..<31 {
            try await recorder.append(PoseFrame(t: Double(i) / 30, joints: [:], imageAspect: 0.5625))
        }
    }

    @Test func idleCaptureIsKeptWithoutAWorkoutOrInventedTruthLabels() async throws {
        let directory = try TemporaryDirectory()
        let archive = archive(in: directory)
        let recorder = try archive.start(header: PoseFixtureHeader(exerciseSpecID: "squat.bodyweight", cameraPosition: .front))
        try await appendIdle(to: recorder)
        let recording = try #require(await archive.finish(recorder))
        let exported = try archive.export(recording)

        #expect(!FileManager.default.fileExists(atPath: recorder.url.path))
        #expect(!recording.url.lastPathComponent.hasPrefix("pending-"))
        #expect(recording.frames == 31)
        #expect(recording.fps == 30)
        let fixture = try PoseFixtureFile.read(from: exported)
        #expect(fixture.frames.count == 31)
        #expect(fixture.header.duration == 1)
        #expect(fixture.header.cameraPosition == .front)
        #expect(fixture.header.labels == PoseLabels())
        #expect(try Data(contentsOf: recording.url) == Data(contentsOf: exported))
        #expect(try await archive.finish(recorder) == recording)
        #expect(try archive.export(recording) == exported)
    }

    @Test func replayProvenanceSurvivesArchivingAndExport() async throws {
        let directory = try TemporaryDirectory()
        let archive = archive(in: directory)
        let recorder = try archive.start(header: PoseFixtureHeader(
            exerciseSpecID: "pushup", labels: PoseLabels(tags: ["replay"])
        ))
        try await appendIdle(to: recorder)
        let recording = try #require(await archive.finish(recorder))
        let header = try PoseFixtureFile.readHeader(from: archive.export(recording))
        #expect(header.cameraPosition == .unknown)
        #expect(header.labels.tags == ["replay"])
        #expect(header.labels.reps == nil)
    }

    @Test func noFramesDoesNotCreateAnExport() async throws {
        let directory = try TemporaryDirectory()
        let archive = archive(in: directory)
        let recorder = try archive.start(header: PoseFixtureHeader(exerciseSpecID: "squat.bodyweight"))
        #expect(try await archive.finish(recorder) == nil)
        #expect(try await archive.finish(recorder) == nil)
        #expect(!FileManager.default.fileExists(atPath: recorder.url.path))
        #expect(!FileManager.default.fileExists(atPath: archive.exportDirectory.path))
    }

    @Test func editingOrDeletingTheExportLeavesTheOriginalUntouched() async throws {
        let directory = try TemporaryDirectory()
        let archive = archive(in: directory)
        let recorder = try archive.start(header: PoseFixtureHeader(exerciseSpecID: "squat.bodyweight", cameraPosition: .back))
        try await appendIdle(to: recorder)
        let recording = try #require(await archive.finish(recorder))
        let exported = try archive.export(recording)
        let original = try Data(contentsOf: recording.url)

        try PoseFixtureFile.updateLabels(at: exported, to: PoseLabels(reps: 0, partials: 2, tags: ["verified"]))
        #expect(throws: (any Error).self) { try archive.export(recording) }
        #expect(try PoseFixtureFile.readHeader(from: exported).labels.partials == 2)
        #expect(try Data(contentsOf: recording.url) == original)

        try FileManager.default.removeItem(at: exported)
        #expect(try Data(contentsOf: recording.url) == original)
        #expect(try archive.export(recording) == exported)
    }

    @Test func exportFailureKeepsTheCaptureAndCanBeRetried() async throws {
        let directory = try TemporaryDirectory()
        let archive = archive(in: directory)
        let recorder = try archive.start(header: PoseFixtureHeader(exerciseSpecID: "squat.bodyweight"))
        try await appendIdle(to: recorder)
        let recording = try #require(await archive.finish(recorder))
        // A file where Documents should be makes the export fail without relying on permissions or disk space.
        let blocked = archive.exportDirectory.deletingLastPathComponent()
        try Data("blocked".utf8).write(to: blocked)
        #expect(throws: (any Error).self) { try archive.export(recording) }
        #expect(try PoseFixtureFile.read(from: recording.url).frames.count == 31)

        try FileManager.default.removeItem(at: blocked)
        let exported = try archive.export(recording)
        #expect(try PoseFixtureFile.read(from: exported).frames.count == 31)
    }
}
