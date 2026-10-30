import Foundation

/// What the user must fix before counting starts. Each state has a localization key for the prompt.
public enum FramingState: String, CaseIterable, Codable, Sendable {
    /// Nobody (or too little of anybody) is in view.
    case noPerson
    /// The body touches the frame edge: move away from the camera.
    case stepBack
    /// The subject is smaller than a third of the frame height: come closer.
    case moveCloser
    /// A required joint is not confident: get the whole body in view.
    case wholeBody
    /// The exercise is assessed from the side and the body faces the camera.
    case turnSideways
    /// The exercise needs a front view and the body is sideways.
    case faceCamera
    /// Everything is fine; waiting out the confirmation time.
    case holdStill
    /// Counting is live.
    case ready

    public var localizationKey: String { "framing.\(rawValue)" }
    public var isReady: Bool { self == .ready }
}

/// A snapshot of what the camera sees, reduced to the facts framing depends on.
public struct FramingObservation: Equatable, Sendable {
    /// Joints at or above the confidence gate.
    public var confidentJointCount: Int
    /// Every joint the spec requires is confident on the followed side.
    public var requiredJointsConfident: Bool
    /// Larger of the subject's width and height as a fraction of the frame height.
    public var subjectExtent: Double
    /// A joint the exercise requires sits at the frame border.
    public var touchesEdge: Bool
    public var view: CameraView

    public init(
        confidentJointCount: Int, requiredJointsConfident: Bool, subjectExtent: Double,
        touchesEdge: Bool, view: CameraView
    ) {
        self.confidentJointCount = confidentJointCount
        self.requiredJointsConfident = requiredJointsConfident
        self.subjectExtent = subjectExtent
        self.touchesEdge = touchesEdge
        self.view = view
    }
}

/// The pre-counting framing state machine (brief §6.7), driven by frame timestamps.
///
/// All conditions must hold for `holdSeconds` before `ready`. Once ready, a problem has to last
/// `lossSeconds` before the state leaves `ready`, so a brief occlusion does not interrupt a set, while
/// a person who really walks away pauses counting.
public struct FramingCheck: Sendable {
    public private(set) var state: FramingState = .noPerson

    private let requiredView: ViewRequirement
    private let parameters: MotionConfig.FramingParameters
    private var okSince: Double?
    private var problemSince: Double?

    public init(requiredView: ViewRequirement, parameters: MotionConfig.FramingParameters = .init()) {
        self.requiredView = requiredView
        self.parameters = parameters
    }

    /// The state this observation shows ignoring all timing; `holdStill` means "all good".
    func immediateState(_ o: FramingObservation) -> FramingState {
        if o.confidentJointCount < parameters.minPersonJoints { return .noPerson }
        if o.touchesEdge { return .stepBack }
        if o.subjectExtent < parameters.minSubjectFraction { return .moveCloser }
        if !o.requiredJointsConfident { return .wholeBody }
        switch requiredView {
        case .side where o.view == .front: return .turnSideways
        case .front where o.view == .side: return .faceCamera
        default: return .holdStill
        }
    }

    @discardableResult
    public mutating func update(_ observation: FramingObservation, at t: TimeInterval) -> FramingState {
        let immediate = immediateState(observation)
        if immediate == .holdStill {
            problemSince = nil
            let since = okSince ?? t
            okSince = since
            if state != .ready { state = t - since >= parameters.holdSeconds ? .ready : .holdStill }
        } else {
            okSince = nil
            if state == .ready {
                let since = problemSince ?? t
                problemSince = since
                if t - since >= parameters.lossSeconds {
                    state = immediate
                    problemSince = nil
                }
            } else {
                state = immediate
            }
        }
        return state
    }
}
