import Foundation

/// Puts capture timestamps on one strictly increasing timeline.
///
/// Duplicates and frames slightly out of order are rejected. A capture clock never runs backwards and
/// never leaps far ahead for one frame, so two kinds of damage are repaired instead of being allowed to
/// freeze the engine (which would then ignore every frame until the clock caught up, possibly forever):
///
/// * A run of frames far behind the last accepted one means the clock restarted (a new capture session,
///   a recording replayed into a live session) or an earlier frame carried a corrupt timestamp far in
///   the future. After `resyncFrames` such frames in a row the timeline is shifted so time continues
///   from the last accepted frame.
/// * A frame far ahead is held back until the next frame confirms the leap. A lone corrupt timestamp is
///   dropped; a real stall (the app was suspended) costs one frame.
///
/// `offset` maps the internal timeline back to capture time.
struct FrameClock: Sendable {
    /// Frames this far behind (seconds) are a clock problem, not reordering.
    static let resyncGap = 1.0
    static let resyncFrames = 3
    /// A leap this far ahead (seconds) must be confirmed by the following frame.
    static let leapGap = 5.0

    /// Internal time = capture time + offset.
    private(set) var offset = 0.0
    /// Internal time of the last accepted frame.
    private(set) var last: Double?
    private var step = 1.0 / 30
    private var behind = 0
    private var leap: Double?

    /// The internal time for a frame stamped `t`, or nil if the frame is to be ignored.
    mutating func accept(_ t: Double) -> Double? {
        guard t.isFinite else { return nil }
        let internalTime = t + offset
        guard let last else {
            self.last = internalTime
            return internalTime
        }
        if internalTime > last {
            behind = 0
            let dt = internalTime - last
            if dt > Self.leapGap {
                guard let candidate = leap, internalTime > candidate, internalTime - candidate <= Self.leapGap else {
                    leap = internalTime
                    return nil
                }
            }
            leap = nil
            if dt <= 0.25 { step = min(0.1, max(0.004, dt)) }
            self.last = internalTime
            return internalTime
        }
        leap = nil
        guard last - internalTime > Self.resyncGap else {
            behind = 0
            return nil
        }
        behind += 1
        guard behind >= Self.resyncFrames else { return nil }
        behind = 0
        offset = last + step - t
        self.last = last + step
        return last + step
    }
}
