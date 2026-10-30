import Foundation
import MotionCore
import Synchronization

/// The last few seconds of pose frames, so a counted rep's bottom frame can be found after the engine reports
/// the rep (it reports about a quarter of a second after the rep ends, long after the bottom).
///
/// Written from the frame pump's task and read from the main actor once per rep, so it is a small lock-guarded
/// window rather than an actor: no hop per frame. Memory is bounded by `horizon` (about 600 frames of a few
/// hundred bytes each at 30 fps).
nonisolated final class FrameStore: Sendable {
    private struct Window {
        var frames: [PoseFrame] = []
        var head = 0
    }

    /// Seconds of capture time kept. Longer than the engine's longest rep without a pause at the bottom.
    private let horizon: TimeInterval
    private let window = Mutex(Window())

    init(horizon: TimeInterval = 20) {
        self.horizon = horizon
    }

    func append(_ frame: PoseFrame) {
        window.withLock { window in
            window.frames.append(frame)
            while window.head < window.frames.count, window.frames[window.head].t < frame.t - horizon {
                window.head += 1
            }
            // Drop the expired prefix now and then instead of on every frame.
            if window.head >= 256 {
                window.frames.removeFirst(window.head)
                window.head = 0
            }
        }
    }

    /// The kept frame closest in time to `t`, or nil when nothing is kept.
    func frame(nearest t: TimeInterval) -> PoseFrame? {
        window.withLock { window in
            var best: PoseFrame?
            var bestDistance = Double.infinity
            for index in window.head..<window.frames.count {
                let distance = abs(window.frames[index].t - t)
                if distance < bestDistance {
                    best = window.frames[index]
                    bestDistance = distance
                }
            }
            return best
        }
    }
}

/// The newest frame waiting to be drawn, so the frame pump never waits for the main thread.
///
/// The pump calls `put` for every frame; only the call that finds no draw pending returns true, and that caller
/// schedules one hop to the main actor, which `take`s whatever is newest by then. A busy main thread therefore
/// costs skipped drawings, never delayed counting, and at most one hop is ever outstanding.
nonisolated final class LatestFrame: Sendable {
    private struct Slot {
        var frame: PoseFrame?
        var isDrawPending = false
    }

    private let slot = Mutex(Slot())

    /// Keeps `frame` as the newest. True when the caller has to schedule a draw.
    func put(_ frame: PoseFrame) -> Bool {
        slot.withLock { slot in
            slot.frame = frame
            guard !slot.isDrawPending else { return false }
            slot.isDrawPending = true
            return true
        }
    }

    /// The newest frame, once; the next `put` asks for a new draw.
    func take() -> PoseFrame? {
        slot.withLock { slot in
            slot.isDrawPending = false
            defer { slot.frame = nil }
            return slot.frame
        }
    }
}
