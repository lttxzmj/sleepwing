import AppKit
import PerchCore
import SwiftUI

struct PetSpriteAtlasView: View {
    private let source: PetSpriteAtlasSource
    let state: PetAnimationState
    let diameter: CGFloat
    let motionEnabled: Bool
    let fallbackSymbol: String
    let dragDirection: PetDragDirection?
    let lookDirection: PetLookDirection?

    @State private var animationStartedAt = Date()

    init(
        resourceName: String,
        sourceURL: URL? = nil,
        state: PetAnimationState,
        diameter: CGFloat,
        motionEnabled: Bool,
        fallbackSymbol: String,
        dragDirection: PetDragDirection?,
        lookDirection: PetLookDirection?
    ) {
        source = PetSpriteAtlasSource(
            resourceName: resourceName,
            sourceURL: sourceURL
        )
        self.state = state
        self.diameter = diameter
        self.motionEnabled = motionEnabled
        self.fallbackSymbol = fallbackSymbol
        self.dragDirection = dragDirection
        self.lookDirection = lookDirection
    }

    var body: some View {
        Group {
            if motionEnabled {
                TimelineView(PetAnimationTimelineSchedule(
                    animation: animation,
                    animationStartedAt: animationStartedAt
                )) { context in
                    spriteFrame(at: context.date)
                }
            } else {
                spriteFrame(at: animationStartedAt)
            }
        }
        .onChange(of: state) {
            animationStartedAt = .now
        }
        .onChange(of: dragDirection) {
            animationStartedAt = .now
        }
        .onChange(of: source.fingerprint.revisionKey) {
            animationStartedAt = .now
        }
        .task(id: prewarmKey) {
            await PetSpriteAtlas.prewarm(
                source: source,
                animation: PetSpriteContract.animation(for: effectiveState),
                motionEnabled: motionEnabled
            )
        }
    }

    @ViewBuilder
    private func spriteFrame(at date: Date) -> some View {
        let elapsed = motionEnabled
            ? max(0, date.timeIntervalSince(animationStartedAt))
            : 0
        let frameIndex = animation.frameIndex(at: elapsed)
        let frame = renderedFrame(animation: animation, frameIndex: frameIndex)

        Group {
            if let image = PetSpriteAtlas.image(
                source: source,
                row: frame.row,
                column: frame.column
            ) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: fallbackSymbol)
                    .font(.system(size: diameter * 0.58, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }

    private var animation: PetAnimationRow {
        PetSpriteContract.animation(for: effectiveState)
    }

    private var effectiveState: PetAnimationState {
        switch dragDirection {
        case .left: .runningLeft
        case .right: .runningRight
        case nil: state
        }
    }

    private var prewarmKey: String {
        "\(source.fingerprint.revisionKey):\(effectiveState.rawValue):\(motionEnabled)"
    }

    private func renderedFrame(
        animation: PetAnimationRow,
        frameIndex: Int
    ) -> (row: Int, column: Int) {
        if dragDirection == nil, state == .idle, let lookDirection {
            return (lookDirection.row, lookDirection.column)
        }
        return (animation.row, frameIndex)
    }
}

private struct PetAnimationTimelineSchedule: TimelineSchedule {
    let animation: PetAnimationRow
    let animationStartedAt: Date

    func entries(
        from startDate: Date,
        mode: TimelineScheduleMode
    ) -> Entries {
        Entries(
            animation: animation,
            animationStartedAt: animationStartedAt,
            nextDate: startDate
        )
    }

    struct Entries: Sequence, IteratorProtocol {
        let animation: PetAnimationRow
        let animationStartedAt: Date
        var nextDate: Date?

        mutating func next() -> Date? {
            guard let current = nextDate else { return nil }
            let elapsed = Swift.max(
                0,
                current.timeIntervalSince(animationStartedAt)
            )
            if let boundary = animation.nextFrameBoundary(after: elapsed) {
                nextDate = animationStartedAt.addingTimeInterval(boundary)
            } else {
                nextDate = nil
            }
            return current
        }
    }
}

private struct PetSpriteAtlasSource: Equatable {
    let resourceName: String
    let sourceURL: URL?
    let fingerprint: PetSpriteSourceFingerprint

    init(resourceName: String, sourceURL: URL?) {
        self.resourceName = resourceName
        self.sourceURL = sourceURL?.standardizedFileURL
        if let sourceURL = self.sourceURL {
            let values = try? sourceURL.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey]
            )
            fingerprint = PetSpriteSourceFingerprint(
                resourceName: resourceName,
                filePath: sourceURL.path,
                modificationTime: values?.contentModificationDate?.timeIntervalSince1970 ?? 0,
                fileSize: values?.fileSize ?? 0
            )
        } else {
            fingerprint = PetSpriteSourceFingerprint(resourceName: resourceName)
        }
    }
}

@MainActor
private enum PetSpriteAtlas {
    private static let frameCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = PetSpriteCachePolicy.maximumFrameCount
        cache.totalCostLimit = PetSpriteCachePolicy.maximumFrameCost
        return cache
    }()
    private static let atlasCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = PetSpriteCachePolicy.maximumAtlasCount
        cache.totalCostLimit = PetSpriteCachePolicy.maximumAtlasCost
        return cache
    }()
    private static var cacheIndex = PetSpriteCacheIndex()
    private static var revisionByStableSource: [String: String] = [:]
    private static var frameKeysBySource: [String: Set<String>] = [:]

    static func image(
        source: PetSpriteAtlasSource,
        row: Int,
        column: Int
    ) -> NSImage? {
        guard (0 ..< PetSpriteContract.rows).contains(row),
              (0 ..< PetSpriteContract.columns).contains(column) else {
            return nil
        }
        register(source)
        let sourceKey = source.fingerprint.revisionKey
        let key = "\(sourceKey)-\(row)-\(column)" as NSString
        if let cached = frameCache.object(forKey: key) {
            return cached
        }
        guard let atlas = atlasImage(source: source) else { return nil }

        let cellSize = NSSize(
            width: CGFloat(PetSpriteContract.cellWidth),
            height: CGFloat(PetSpriteContract.cellHeight)
        )
        let sourceRect = NSRect(
            x: CGFloat(column * PetSpriteContract.cellWidth),
            y: CGFloat(PetSpriteContract.atlasHeight - ((row + 1) * PetSpriteContract.cellHeight)),
            width: CGFloat(PetSpriteContract.cellWidth),
            height: CGFloat(PetSpriteContract.cellHeight)
        )
        let frame = NSImage(size: cellSize)
        frame.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        atlas.draw(
            in: NSRect(origin: .zero, size: cellSize),
            from: sourceRect,
            operation: .copy,
            fraction: 1
        )
        frame.unlockFocus()
        frameCache.setObject(
            frame,
            forKey: key,
            cost: PetSpriteCachePolicy.frameByteCost
        )
        frameKeysBySource[sourceKey, default: []].insert(key as String)
        return frame
    }

    static func prewarm(
        source: PetSpriteAtlasSource,
        animation: PetAnimationRow,
        motionEnabled: Bool
    ) async {
        let frameCount = motionEnabled ? animation.frameCount : 1
        for column in 0 ..< min(frameCount, PetSpriteContract.columns) {
            guard !Task.isCancelled else { return }
            _ = image(source: source, row: animation.row, column: column)
            await Task.yield()
        }
    }

    private static func atlasImage(source: PetSpriteAtlasSource) -> NSImage? {
        let cacheKey = source.fingerprint.revisionKey as NSString
        if let cached = atlasCache.object(forKey: cacheKey) {
            return cached
        }

        if let sourceURL = source.sourceURL,
           let image = NSImage(contentsOf: sourceURL) {
            atlasCache.setObject(
                image,
                forKey: cacheKey,
                cost: PetSpriteCachePolicy.atlasByteCost
            )
            return image
        }

        if let url = PerchResources.bundle.url(
            forResource: source.resourceName,
            withExtension: "png"
        ),
           let image = NSImage(contentsOf: url) {
            atlasCache.setObject(
                image,
                forKey: cacheKey,
                cost: PetSpriteCachePolicy.atlasByteCost
            )
            return image
        }

        return nil
    }

    private static func register(_ source: PetSpriteAtlasSource) {
        let stableKey = source.fingerprint.stableSourceKey
        let revisionKey = source.fingerprint.revisionKey
        if let previous = revisionByStableSource[stableKey],
           previous != revisionKey {
            cacheIndex.remove(previous)
            invalidate(previous)
        }
        revisionByStableSource[stableKey] = revisionKey
        for evicted in cacheIndex.touch(revisionKey) {
            invalidate(evicted)
        }
    }

    private static func invalidate(_ sourceKey: String) {
        atlasCache.removeObject(forKey: sourceKey as NSString)
        for frameKey in frameKeysBySource.removeValue(forKey: sourceKey) ?? [] {
            frameCache.removeObject(forKey: frameKey as NSString)
        }
        revisionByStableSource = revisionByStableSource.filter {
            $0.value != sourceKey
        }
    }
}
