import Domain
import MotionCore
import SwiftUI

/// The content of the Live Set cover: the live camera, then the review of the set that was counted. "Next set"
/// goes back to the camera inside the same cover, so the user never leaves the full-screen flow between sets.
struct LiveSetFlow: View {
    let request: LiveSetRequest
    let train: TrainModel
    let environment: AppEnvironment

    @Environment(UserSession.self) private var session
    @State private var model: LiveSetModel
    @State private var review: SetReviewModel?
    @State private var isEnding = false
    @State private var errorMessage: String?

    init(request: LiveSetRequest, train: TrainModel, environment: AppEnvironment) {
        self.request = request
        self.train = train
        self.environment = environment
        _model = State(initialValue: LiveSetModel(environment: environment, exercise: request.exercise, spec: request.spec))
    }

    var body: some View {
        ZStack {
            if let review {
                SetReviewView(
                    model: review,
                    units: session.units,
                    onNextSet: nextSet,
                    onFinish: train.finishFromLiveSet,
                    onClose: close
                )
                .transition(.move(edge: .bottom))
            } else {
                LiveSetView(model: model, onEnd: end, onClose: close)
                    .transition(.opacity)
            }
        }
        .animation(.snappy, value: review == nil)
        .errorAlert($errorMessage)
        .onDisappear {
            let live = model
            Task { await live.stop() }
        }
    }

    private func close() {
        train.liveSet = nil
    }

    private func end() {
        guard !isEnding else { return }
        isEnding = true
        Task {
            defer { isEnding = false }
            guard let result = await model.endSet() else {
                close()
                return
            }
            guard result.summary.reps > 0 else {
                // The idle/partial/missed-rep capture is already archived. It is a fixture, not a workout set.
                if result.recordingFailure != nil {
                    train.errorMessage = String(localized: "The pose recording could not be saved.")
                }
                close()
                return
            }
            do {
                let logged = try await train.logCameraSet(result, request: request)
                review = SetReviewModel(environment: environment, subject: subject(for: logged, result: result))
                if result.recordingFailure != nil {
                    errorMessage = String(localized: "The pose recording could not be saved.")
                }
            } catch {
                errorMessage = TrainModel.message(for: error)
            }
        }
    }

    private func nextSet() {
        model = LiveSetModel(environment: environment, exercise: request.exercise, spec: request.spec)
        review = nil
    }

    private func subject(for logged: LoggedSet, result: LiveSetResult) -> SetReviewSubject {
        let entry = train.workout?.exercises.first { $0.entry.id == request.entryID }
        let sets = entry?.sets.sorted { $0.set.position < $1.set.position } ?? []
        let number = (sets.firstIndex { $0.id == logged.id } ?? sets.count - 1) + 1
        return SetReviewSubject(
            exercise: request.exercise,
            spec: request.spec,
            logged: logged,
            setNumber: max(1, number),
            localDay: train.workout?.session.localDay ?? environment.today,
            bottomFrames: result.bottomFrames,
            level: session.profile?.activityLevel ?? .beginner,
            goal: session.goal?.kind,
            unitSystem: session.unitSystem
        )
    }
}
