import SwiftUI

/// Port-typed dependencies, built at the composition root and injected through the SwiftUI environment.
struct AppEnvironment: Sendable {
    static func live() -> AppEnvironment { AppEnvironment() }
    static func preview() -> AppEnvironment { AppEnvironment() }
}

extension EnvironmentValues {
    @Entry var appEnvironment = AppEnvironment.preview()
}
