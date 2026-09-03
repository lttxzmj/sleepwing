import Foundation

public enum PetSpriteCachePolicy {
    public static let maximumTrackedSources = 8
    public static let maximumAtlasCount = 4
    public static let maximumAtlasCost = 64 * 1_024 * 1_024
    public static let maximumFrameCount = 256
    public static let maximumFrameCost = 48 * 1_024 * 1_024

    public static var atlasByteCost: Int {
        PetSpriteContract.atlasWidth * PetSpriteContract.atlasHeight * 4
    }

    public static var frameByteCost: Int {
        PetSpriteContract.cellWidth * PetSpriteContract.cellHeight * 4
    }
}

public struct PetSpriteSourceFingerprint: Equatable, Hashable, Sendable {
    public let stableSourceKey: String
    public let revisionKey: String

    public init(
        resourceName: String,
        filePath: String? = nil,
        modificationTime: TimeInterval = 0,
        fileSize: Int = 0
    ) {
        if let filePath {
            stableSourceKey = "file:\(filePath)"
            revisionKey = "\(stableSourceKey):\(modificationTime.bitPattern):\(max(0, fileSize))"
        } else {
            stableSourceKey = "bundle:\(resourceName)"
            revisionKey = stableSourceKey
        }
    }
}

public struct PetSpriteCacheIndex: Equatable, Sendable {
    public let capacity: Int
    public private(set) var sourceKeys: [String] = []

    public init(capacity: Int = PetSpriteCachePolicy.maximumTrackedSources) {
        self.capacity = max(1, capacity)
    }

    @discardableResult
    public mutating func touch(_ sourceKey: String) -> [String] {
        sourceKeys.removeAll { $0 == sourceKey }
        sourceKeys.append(sourceKey)
        guard sourceKeys.count > capacity else { return [] }
        let overflow = sourceKeys.count - capacity
        let evicted = Array(sourceKeys.prefix(overflow))
        sourceKeys.removeFirst(overflow)
        return evicted
    }

    public mutating func remove(_ sourceKey: String) {
        sourceKeys.removeAll { $0 == sourceKey }
    }
}
