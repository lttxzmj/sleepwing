import Foundation

public enum IntegrationConnectionStage: Equatable, Sendable {
    case receiverUnavailable
    case notConnected
    case checking
    case checkFailed
    case awaitingRealState
    case live
}

public struct IntegrationConnectionSignals: Equatable, Sendable {
    public let isInstalled: Bool
    public let isChecking: Bool
    public let checkFailed: Bool
    public let relayVerified: Bool
    public let lifecycleConnected: Bool

    public init(
        isInstalled: Bool,
        isChecking: Bool,
        checkFailed: Bool,
        relayVerified: Bool,
        lifecycleConnected: Bool
    ) {
        self.isInstalled = isInstalled
        self.isChecking = isChecking
        self.checkFailed = checkFailed
        self.relayVerified = relayVerified
        self.lifecycleConnected = lifecycleConnected
    }
}

public enum IntegrationConnectionPolicy {
    public static func stage(
        receiverReady: Bool,
        signals: IntegrationConnectionSignals
    ) -> IntegrationConnectionStage {
        guard receiverReady else { return .receiverUnavailable }
        if signals.lifecycleConnected { return .live }
        if signals.checkFailed { return .checkFailed }
        guard signals.isInstalled else { return .notConnected }
        if signals.isChecking { return .checking }
        if signals.relayVerified { return .awaitingRealState }
        return .checking
    }

    public static func overallStage(
        receiverReady: Bool,
        providerStages: [IntegrationConnectionStage]
    ) -> IntegrationConnectionStage {
        guard receiverReady else { return .receiverUnavailable }
        let connectedStages = providerStages.filter { $0 != .notConnected }
        guard !connectedStages.isEmpty else { return .notConnected }
        if connectedStages.contains(.checkFailed) { return .checkFailed }
        if connectedStages.contains(.checking) { return .checking }
        if connectedStages.contains(.awaitingRealState) { return .awaitingRealState }
        return .live
    }
}
