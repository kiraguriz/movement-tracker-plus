import Foundation

/// A finished capture, kept independently of whether the engine counted a workout set.
public struct PoseRecording: Equatable, Sendable {
    public let url: URL
    public let frames: Int
    public let fps: Double
}

/// Keeps an app-owned original and a separate copy the user can take out through Files. Editing or deleting
/// the exported copy never changes the original referenced by a workout.
public struct PoseRecordingArchive: Sendable {
    public let directory: URL
    public let exportDirectory: URL

    public init(directory: URL, exportDirectory: URL) {
        self.directory = directory
        self.exportDirectory = exportDirectory
    }

    public func start(header: PoseFixtureHeader) throws -> PoseRecorder {
        let url = directory.appendingPathComponent("pending-\(UUID().uuidString).jsonl")
        return try PoseRecorder(url: url, header: header)
    }

    /// Finalizes any nonempty capture, including idle clips and sets the engine missed. No algorithm counts
    /// are written into the human labels. Calling again after a save failure returns the same recording.
    public func finish(_ recorder: PoseRecorder) async throws -> PoseRecording? {
        let header = try await recorder.finish()
        let frames = header.frameCount ?? 0
        guard frames > 0 else {
            if FileManager.default.fileExists(atPath: recorder.url.path) {
                try FileManager.default.removeItem(at: recorder.url)
            }
            return nil
        }
        let name = recorder.url.lastPathComponent.replacingOccurrences(of: "pending-", with: "")
        let destination = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: recorder.url.path) {
            try FileManager.default.moveItem(at: recorder.url, to: destination)
        } else if !FileManager.default.fileExists(atPath: destination.path) {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: destination.path])
        }
        return PoseRecording(url: destination, frames: frames, fps: header.fps ?? 30)
    }

    /// Export failure does not remove the private original, so it can still be associated with the set.
    /// A conflicting export is never overwritten: it might contain the user's corrected labels.
    @discardableResult
    public func export(_ recording: PoseRecording) throws -> URL {
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        let destination = exportDirectory.appendingPathComponent(recording.url.lastPathComponent)
        // Files and other document editors can access this copy while the app is running.
        var coordinationError: NSError?
        var copyError: (any Error)?
        NSFileCoordinator().coordinate(writingItemAt: destination, error: &coordinationError) { url in
            do {
                if !FileManager.default.contentsEqual(atPath: recording.url.path, andPath: url.path) {
                    try FileManager.default.copyItem(at: recording.url, to: url)
                }
            } catch {
                copyError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
        return destination
    }
}
