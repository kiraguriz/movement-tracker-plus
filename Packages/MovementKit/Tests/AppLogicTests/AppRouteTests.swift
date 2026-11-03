import Foundation
import Testing
import Domain
import AppLogic

struct AppRouteTests {
    @Test(arguments: [AppRoute.today, .train, .eat, .me, .coach, .startSet("squat.bodyweight"), .startSet("pushup")])
    func everyRouteSurvivesItsOwnURL(_ route: AppRoute) {
        #expect(AppRoute(url: route.url) == route)
    }

    @Test func theStartLinkNamesTheExercise() {
        #expect(AppRoute.startSet("squat.bodyweight").url.absoluteString == "movementtracker://train/start?exercise=squat.bodyweight")
        #expect(AppRoute(url: URL(string: "MovementTracker://Train/start?exercise=pushup")!) == .startSet("pushup"))
    }

    @Test(arguments: [
        "https://today",
        "movementtracker://settings",
        "movementtracker://today/extra",
        "movementtracker://today?x=1",
        "movementtracker://train/start",
        "movementtracker://train/start?exercise=",
        "movementtracker://train/start?exercise=../x",
        "movementtracker://train/start?exercise=Squat",
        "movementtracker://train/start?exercise=a%20b",
        "movementtracker://train/start?exercise=pushup&exercise=squat.bodyweight",
        "movementtracker://train/start?exercise=pushup&reps=10",
        "movementtracker://train/finish",
        "movementtracker://user:secret@today",
        "movementtracker://today#x",
    ])
    func anythingElseIsRejected(_ link: String) throws {
        let url = try #require(URL(string: link))
        #expect(AppRoute(url: url) == nil)
    }

    @Test func overlongSlugsAreRejected() throws {
        let slug = String(repeating: "a", count: 65)
        let url = try #require(URL(string: "movementtracker://train/start?exercise=\(slug)"))
        #expect(AppRoute(url: url) == nil)
    }
}
