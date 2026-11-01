import AppLogic
import Foundation

/// Where the coach proxy (`proxy/`) runs. The address is not a secret: the Muse and USDA keys stay in the
/// Worker. Until it is deployed there is no coach, and features show their on-device fallback.
enum CoachEndpoint {
    /// The deployed Worker, for example `https://movement-tracker-proxy.<subdomain>.workers.dev`.
    static var deployed: URL? {
        ServiceEndpoint.parse(Bundle.main.object(forInfoDictionaryKey: "CoachProxyURL") as? String)
    }

    /// The Keychain service that holds the proxy's install token.
    static let tokenService = "io.github.kiraguriz.MovementTracker.coach"

    static func url(for launch: LaunchOptions) -> URL? {
        launch.coachURL ?? deployed
    }
}
