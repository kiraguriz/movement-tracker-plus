import Observation
import Testing
import Domain

// Domain must not export a type named like a system module: a type called `Observation` once broke
// every @Observable class in files that import Domain.
@Observable private final class ObservableNextToDomain { var count = 0 }

@Test func observableMacroCompilesInFilesThatImportDomain() {
    #expect(ObservableNextToDomain().count == 0)
}
