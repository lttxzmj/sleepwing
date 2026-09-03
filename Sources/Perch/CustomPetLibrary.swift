import Foundation
import ImageIO
import PerchCore

struct CustomPetManifest: Codable, Equatable, Sendable {
    let id: String
    let displayName: String
    let description: String
    let spriteVersionNumber: Int
    let spritesheetPath: String
    /// Optional first-person voice description; when present, chat replies
    /// use it as the pet's persona.
    let personality: String?
}

struct CustomPetDescriptor: Identifiable, Equatable, Sendable {
    enum Origin: String, Equatable, Sendable {
        case perch
        case codex
    }

    enum VisualQAStatus: Equatable, Sendable {
        case passed
        case missing
        case invalid
    }

    let manifest: CustomPetManifest
    let directoryURL: URL
    let spritesheetURL: URL
    let origin: Origin
    let visualQAStatus: VisualQAStatus

    var id: String { manifest.id }
    var displayName: String { manifest.displayName }
    var description: String { manifest.description }
    var personality: String? { manifest.personality }
    var isInstalledInPerch: Bool { origin == .perch }
    var isReadyForInstall: Bool {
        isInstalledInPerch || visualQAStatus == .passed
    }
}

enum CustomPetLibraryError: Error, Equatable, Sendable {
    case missingManifest
    case invalidManifest
    case missingSpritesheet
    case missingVisualQA
    case invalidVisualQA
    case symbolicLink
    case validation(CustomPetPackageValidationError)
    case cannotSave
}

enum CustomPetLibrary {
    private static let maximumDiscoveredPackagesPerRoot = 64

    static var perchRootURL: URL {
        let fileManager = FileManager.default
        let base = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Perch", isDirectory: true)
            .appendingPathComponent("Pets", isDirectory: true)
    }

    static var codexRootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("pets", isDirectory: true)
    }

    static func discover(fileManager: FileManager = .default) -> [CustomPetDescriptor] {
        guard !Task.isCancelled else { return [] }
        let installed = discover(
            in: perchRootURL,
            origin: .perch,
            fileManager: fileManager
        )
        guard !Task.isCancelled else { return [] }
        let codex = discover(
            in: codexRootURL,
            origin: .codex,
            fileManager: fileManager
        )
        var byID: [String: CustomPetDescriptor] = [:]
        for pet in codex {
            byID[pet.id] = pet
        }
        for pet in installed {
            byID[pet.id] = pet
        }
        return byID.values.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    static func load(
        directoryURL: URL,
        origin: CustomPetDescriptor.Origin,
        requiresMatchingFolderName: Bool
    ) throws -> CustomPetDescriptor {
        let manifestURL = directoryURL.appendingPathComponent("pet.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw CustomPetLibraryError.missingManifest
        }
        guard !isSymbolicLink(directoryURL), !isSymbolicLink(manifestURL) else {
            throw CustomPetLibraryError.symbolicLink
        }
        do {
            try CustomPetPackagePolicy.validateManifestSize(
                fileSize(of: manifestURL)
            )
        } catch let error as CustomPetPackageValidationError {
            throw CustomPetLibraryError.validation(error)
        } catch {
            throw CustomPetLibraryError.invalidManifest
        }

        let manifestData: Data
        let manifest: CustomPetManifest
        do {
            guard let boundedManifest = boundedData(
                at: manifestURL,
                maximumBytes: CustomPetPackagePolicy.maximumManifestBytes
            ) else {
                throw CustomPetLibraryError.validation(.manifestTooLarge)
            }
            manifestData = boundedManifest
            // A decoder is intentionally scoped to this load. Discovery can
            // run off the main actor and overlapping refresh requests must
            // not share a mutable JSONDecoder instance.
            manifest = try JSONDecoder().decode(CustomPetManifest.self, from: manifestData)
        } catch let error as CustomPetLibraryError {
            throw error
        } catch {
            throw CustomPetLibraryError.invalidManifest
        }
        if requiresMatchingFolderName, directoryURL.lastPathComponent != manifest.id {
            throw CustomPetLibraryError.invalidManifest
        }
        do {
            // Validate every path-bearing manifest field before constructing
            // or reading the referenced URL.
            try CustomPetPackagePolicy.validateManifestFields(
                id: manifest.id,
                displayName: manifest.displayName,
                description: manifest.description,
                spriteVersionNumber: manifest.spriteVersionNumber,
                spritesheetPath: manifest.spritesheetPath
            )
        } catch let error as CustomPetPackageValidationError {
            throw CustomPetLibraryError.validation(error)
        }

        let spritesheetURL = directoryURL.appendingPathComponent(manifest.spritesheetPath)
        guard FileManager.default.fileExists(atPath: spritesheetURL.path) else {
            throw CustomPetLibraryError.missingSpritesheet
        }
        guard !isSymbolicLink(spritesheetURL) else {
            throw CustomPetLibraryError.symbolicLink
        }
        do {
            try CustomPetPackagePolicy.validateSpritesheetSize(
                fileSize(of: spritesheetURL)
            )
        } catch let error as CustomPetPackageValidationError {
            throw CustomPetLibraryError.validation(error)
        } catch {
            throw CustomPetLibraryError.missingSpritesheet
        }

        let spritesheetData: Data
        guard let data = boundedData(
                  at: spritesheetURL,
                  maximumBytes: CustomPetPackagePolicy.maximumSpritesheetBytes
              ),
              let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(
                  imageSource,
                  0,
                  nil
              ) as? [CFString: Any],
              let pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            throw CustomPetLibraryError.missingSpritesheet
        }
        spritesheetData = data

        // Reject decompression bombs before asking ImageIO to rasterize. A
        // valid v2 atlas has one exact, modest pixel size.
        guard pixelWidth == PetSpriteContract.atlasWidth,
              pixelHeight == PetSpriteContract.atlasHeight else {
            throw CustomPetLibraryError.validation(.incorrectDimensions)
        }
        guard let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw CustomPetLibraryError.missingSpritesheet
        }
        let hasAlpha: Bool
        switch image.alphaInfo {
        case .premultipliedLast, .premultipliedFirst, .last, .first, .alphaOnly:
            hasAlpha = true
        case .none, .noneSkipLast, .noneSkipFirst:
            hasAlpha = false
        @unknown default:
            hasAlpha = false
        }

        do {
            try CustomPetPackagePolicy.validate(
                id: manifest.id,
                displayName: manifest.displayName,
                spriteVersionNumber: manifest.spriteVersionNumber,
                spritesheetPath: manifest.spritesheetPath,
                manifestBytes: manifestData.count,
                spritesheetBytes: spritesheetData.count,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                hasAlpha: hasAlpha
            )
        } catch let error as CustomPetPackageValidationError {
            throw CustomPetLibraryError.validation(error)
        }

        let qaSummaryURL = directoryURL.appendingPathComponent("qa-summary.json")
        let visualQAStatus = visualQAStatus(at: qaSummaryURL)

        return CustomPetDescriptor(
            manifest: manifest,
            directoryURL: directoryURL,
            spritesheetURL: spritesheetURL,
            origin: origin,
            visualQAStatus: visualQAStatus
        )
    }

    static func uninstall(
        petID: String,
        fileManager: FileManager = .default
    ) throws {
        guard CustomPetPackagePolicy.isValidID(petID) else {
            throw CustomPetLibraryError.validation(.invalidID)
        }
        let destination = perchRootURL.appendingPathComponent(petID, isDirectory: true)
        guard fileManager.fileExists(atPath: destination.path) else { return }
        guard !isSymbolicLink(perchRootURL), !isSymbolicLink(destination) else {
            throw CustomPetLibraryError.symbolicLink
        }
        try fileManager.removeItem(at: destination)
    }

    /// Rewrites only the manifest of an installed pet with a new
    /// personality, then revalidates the package end to end.
    static func updatePersonality(
        petID: String,
        personality: String?,
        fileManager: FileManager = .default
    ) throws -> CustomPetDescriptor {
        let directory = perchRootURL.appendingPathComponent(petID, isDirectory: true)
        let current = try load(
            directoryURL: directory,
            origin: .perch,
            requiresMatchingFolderName: true
        )
        let updated = CustomPetManifest(
            id: current.manifest.id,
            displayName: current.manifest.displayName,
            description: current.manifest.description,
            spriteVersionNumber: current.manifest.spriteVersionNumber,
            spritesheetPath: current.manifest.spritesheetPath,
            personality: personality
        )
        let data = try JSONEncoder.pretty.encode(updated)
        try data.write(
            to: directory.appendingPathComponent("pet.json"),
            options: .atomic
        )
        return try load(
            directoryURL: directory,
            origin: .perch,
            requiresMatchingFolderName: true
        )
    }

    static func install(
        _ pet: CustomPetDescriptor,
        fileManager: FileManager = .default
    ) throws -> CustomPetDescriptor {
        do {
            switch pet.visualQAStatus {
            case .passed:
                break
            case .missing:
                throw CustomPetLibraryError.missingVisualQA
            case .invalid:
                throw CustomPetLibraryError.invalidVisualQA
            }
            try fileManager.createDirectory(
                at: perchRootURL,
                withIntermediateDirectories: true
            )
            let rootValues = try perchRootURL.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard rootValues.isDirectory == true,
                  rootValues.isSymbolicLink != true else {
                throw CustomPetLibraryError.symbolicLink
            }
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: perchRootURL.path
            )
            let destination = perchRootURL.appendingPathComponent(pet.id, isDirectory: true)
            guard !fileManager.fileExists(atPath: destination.path) else {
                throw CustomPetLibraryError.cannotSave
            }
            let staging = perchRootURL.appendingPathComponent(
                ".install-\(UUID().uuidString)",
                isDirectory: true
            )
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
            var shouldCleanStaging = true
            defer {
                if shouldCleanStaging {
                    try? fileManager.removeItem(at: staging)
                }
            }

            let manifestData = try JSONEncoder.pretty.encode(pet.manifest)
            try manifestData.write(
                to: staging.appendingPathComponent("pet.json"),
                options: .atomic
            )
            guard let spritesheetData = boundedData(
                at: pet.spritesheetURL,
                maximumBytes: CustomPetPackagePolicy.maximumSpritesheetBytes
            ) else {
                throw CustomPetLibraryError.validation(.spritesheetTooLarge)
            }
            try spritesheetData.write(
                to: staging.appendingPathComponent(pet.manifest.spritesheetPath),
                options: .atomic
            )
            guard let qaSummaryData = boundedData(
                at: pet.directoryURL.appendingPathComponent("qa-summary.json"),
                maximumBytes: CustomPetPackagePolicy.maximumManifestBytes
            ) else {
                throw CustomPetLibraryError.invalidVisualQA
            }
            try qaSummaryData.write(
                to: staging.appendingPathComponent("qa-summary.json"),
                options: .atomic
            )
            try fileManager.moveItem(at: staging, to: destination)
            shouldCleanStaging = false
            do {
                return try load(
                    directoryURL: destination,
                    origin: .perch,
                    requiresMatchingFolderName: true
                )
            } catch {
                // Installation is transactional from the user's point of
                // view: a package that cannot be loaded must not remain as a
                // broken, partially available pet.
                try? fileManager.removeItem(at: destination)
                throw error
            }
        } catch let error as CustomPetLibraryError {
            throw error
        } catch {
            throw CustomPetLibraryError.cannotSave
        }
    }

    private static func discover(
        in rootURL: URL,
        origin: CustomPetDescriptor.Origin,
        fileManager: FileManager
    ) -> [CustomPetDescriptor] {
        guard let rootValues = try? rootURL.resourceValues(
                  forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
              ),
              rootValues.isDirectory == true,
              rootValues.isSymbolicLink != true else {
            return []
        }
        guard let directories = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return directories
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .prefix(maximumDiscoveredPackagesPerRoot)
            .compactMap { directory in
            guard !Task.isCancelled else { return nil }
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return nil
            }
            return try? load(
                directoryURL: directory,
                origin: origin,
                requiresMatchingFolderName: true
            )
        }
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private static func fileSize(of url: URL) throws -> Int {
        let values = try url.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey]
        )
        guard values.isRegularFile == true, let fileSize = values.fileSize else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        return fileSize
    }

    private static func visualQAStatus(at url: URL) -> CustomPetDescriptor.VisualQAStatus {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard !isSymbolicLink(url),
              let byteCount = try? fileSize(of: url),
              byteCount <= CustomPetPackagePolicy.maximumManifestBytes,
              let data = boundedData(
                  at: url,
                  maximumBytes: CustomPetPackagePolicy.maximumManifestBytes
              ) else {
            return .invalid
        }
        return (try? CustomPetVisualQAPolicy.validate(data)) != nil
            ? .passed
            : .invalid
    }

    /// Reads one byte beyond the limit and stops. File-size metadata alone is
    /// not enough because a package can change between stat and read (TOCTOU).
    private static func boundedData(at url: URL, maximumBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var data = Data()
        let readLimit = maximumBytes + 1
        while data.count < readLimit {
            let remaining = readLimit - data.count
            let chunk: Data
            do {
                guard let next = try handle.read(upToCount: min(64 * 1024, remaining)),
                      !next.isEmpty else { break }
                chunk = next
            } catch {
                return nil
            }
            data.append(chunk)
        }
        return data.count <= maximumBytes ? data : nil
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
