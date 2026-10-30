// Apple Health export, reads and authorization. Depends on Domain only; HealthKit types never leave the adapter.
//
// - HealthSync.swift: object kinds, sync identifiers, the plain-value "write plan"
// - HealthMapper.swift: Domain entities → write plans (workout energy estimate, nutrients, body mass)
// - HealthPorts.swift: HealthWriting, HealthReading, HealthAuthorizing and the authorization state
// - HealthExporter.swift: the actor that drains HealthExportStore into HealthWriting
// - HealthKitBridge.swift: the HealthKit adapter (iOS only, compiled out on macOS)
