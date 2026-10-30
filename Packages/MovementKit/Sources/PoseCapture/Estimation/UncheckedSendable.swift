/// Carries a value the compiler cannot prove safe across an isolation boundary. Only for values whose use is
/// confined by construction: a `CVPixelBuffer` handed to a task that the caller blocks on, or one handed from a
/// sample buffer straight to the single task that reads the file.
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
