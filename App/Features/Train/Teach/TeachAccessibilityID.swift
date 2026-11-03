import Domain
import MotionCore

extension AccessibilityID {
    static let teachEntry = "teach.entry"
    static let teachEntryQuery = "teach.entry.query"
    static let teachFlow = "teach.flow"
    static let teachClose = "teach.close"
    static let teachName = "teach.name"
    static let teachNameContinue = "teach.name.continue"
    static let teachNameExists = "teach.name.exists"
    static let teachNameAdd = "teach.name.add"
    static let teachFraming = "teach.framing"
    static let teachStart = "teach.start"
    static let teachCountdown = "teach.countdown"
    static let teachDots = "teach.dots"
    static let teachDone = "teach.done"
    static let teachSwitchCamera = "teach.camera.switch"
    static let teachRepCount = "teach.confirm.count"
    static let teachFewer = "teach.confirm.fewer"
    static let teachMore = "teach.confirm.more"
    static let teachConfirm = "teach.confirm.continue"
    static let teachVerified = "teach.verified"
    static let teachSave = "teach.save"
    static let teachEquipment = "teach.equipment"
    static let teachFailed = "teach.failed"
    static let teachRetry = "teach.retry"
    static let teachManual = "teach.manual"
    static let teachSaved = "teach.saved"
    static let teachAddToWorkout = "teach.saved.add"
    static let teachFinish = "teach.saved.done"
    static let teachDiscard = "teach.discard.confirm"
    static let teachCameraDenied = "teach.camera.denied"
    static func teachMuscle(_ muscle: MuscleGroup) -> String { "teach.muscle.\(muscle.rawValue)" }

    // Form checks (slice B)
    static let teachChecks = "teach.checks"
    static let teachChecksThinking = "teach.checks.thinking"
    static let teachChecksNone = "teach.checks.none"
    static let teachChecksUse = "teach.checks.use"
    static func teachCheck(_ template: TaughtRuleTemplate) -> String { "teach.check.\(template.rawValue)" }
}
