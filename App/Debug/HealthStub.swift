#if DEBUG
import Domain
import Foundation
import HealthBridge
import SwiftUI

/// What the stub bridge was asked to do, for the readout in Me. Debug builds only: this file is not compiled into
/// Release, and `-MTHealthStub` is ignored there.
@Observable
final class HealthStubLog {
    static let readoutIdentifier = "me.healthStub"

    private(set) var state = HealthAuthorizationState.notDetermined
    /// Write calls per entity: a meal that was edited counts twice.
    private(set) var workouts = 0
    private(set) var meals = 0
    private(set) var weights = 0
    /// Delete calls that came with at least one object to delete.
    private(set) var removals = 0

    /// One line the UI tests parse: `Health stub · workouts 1 · meals 0 · weights 0 · removals 0`.
    var readout: String {
        "Health stub · workouts \(workouts) · meals \(meals) · weights \(weights) · removals \(removals)"
    }

    func setState(_ state: HealthAuthorizationState) {
        self.state = state
    }

    func recordWrite(of entity: HealthEntityKind) {
        switch entity {
        case .workout: workouts += 1
        case .meal: meals += 1
        case .bodyMeasurement: weights += 1
        }
    }

    func recordRemoval(of objects: [HealthObjectRef]) {
        if !objects.isEmpty { removals += 1 }
    }
}

/// An in-process stand-in for `HealthKitBridge`: it saves nothing, records what it was asked, and answers the
/// authorization request without the system sheet. `-MTHealthStub denied` makes that answer "denied".
nonisolated struct HealthStubBridge: HealthWriting, HealthAuthorizing {
    let log: HealthStubLog
    let grantsAccess: Bool

    func authorizationState() async -> HealthAuthorizationState {
        await log.state
    }

    func requestAuthorization() async throws -> HealthAuthorizationState {
        await log.setState(grantsAccess ? .authorized : .denied)
        return await log.state
    }

    func write(_ plan: HealthWritePlan) async throws -> HealthWriteReceipt {
        guard await log.state.canWrite else { throw HealthAccessError.notAuthorized }
        await log.recordWrite(of: plan.entity)
        return HealthWriteReceipt(uuids: Dictionary(plan.writtenKinds.map { ($0, UUID().uuidString) }) { first, _ in first })
    }

    func remove(_ objects: [HealthObjectRef]) async throws {
        await log.recordRemoval(of: objects)
    }
}

/// The stub's counters, shown at the bottom of Me so a UI test can read them. Nothing is shown unless the stub is running.
struct HealthStubReadout: View {
    @Environment(\.appEnvironment) private var environment

    var body: some View {
        if let log = environment.healthStub {
            Text(verbatim: log.readout)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.orange.opacity(0.2), in: .capsule)
                .foregroundStyle(.orange)
                .padding(.bottom, 4)
                .accessibilityIdentifier(HealthStubLog.readoutIdentifier)
        }
    }
}
#endif
