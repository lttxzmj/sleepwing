import Foundation

public struct LocalReceiverRecoveryPolicy: Sendable {
    public private(set) var consecutiveFailures = 0

    private let baseDelay: TimeInterval
    private let maximumDelay: TimeInterval

    public init(
        baseDelay: TimeInterval = 1,
        maximumDelay: TimeInterval = 8
    ) {
        self.baseDelay = baseDelay
        self.maximumDelay = maximumDelay
    }

    public mutating func registerFailure() -> TimeInterval {
        let exponent = min(consecutiveFailures, 3)
        let delay = min(maximumDelay, baseDelay * Double(1 << exponent))
        consecutiveFailures += 1
        return delay
    }

    public mutating func registerReady() {
        consecutiveFailures = 0
    }
}
