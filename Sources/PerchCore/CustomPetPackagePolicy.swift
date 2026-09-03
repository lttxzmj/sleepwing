import Foundation

public enum CustomPetPackageValidationError: Error, Equatable, Sendable {
    case invalidID
    case emptyDisplayName
    case displayNameTooLong
    case descriptionTooLong
    case manifestTooLarge
    case spritesheetTooLarge
    case unsupportedSpriteVersion
    case invalidSpritesheetPath
    case incorrectDimensions
    case missingTransparency
}

public enum CustomPetPackagePolicy {
    public static let maximumManifestBytes = 128 * 1_024
    public static let maximumSpritesheetBytes = 20 * 1_024 * 1_024
    public static let maximumDisplayNameCharacters = 64
    public static let maximumDescriptionCharacters = 240

    public static func validateManifestSize(_ bytes: Int) throws {
        guard bytes >= 0, bytes <= maximumManifestBytes else {
            throw CustomPetPackageValidationError.manifestTooLarge
        }
    }

    public static func validateSpritesheetSize(_ bytes: Int) throws {
        guard bytes >= 0, bytes <= maximumSpritesheetBytes else {
            throw CustomPetPackageValidationError.spritesheetTooLarge
        }
    }

    public static func validateDisplayText(
        displayName: String,
        description: String
    ) throws {
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CustomPetPackageValidationError.emptyDisplayName
        }
        guard displayName.count <= maximumDisplayNameCharacters else {
            throw CustomPetPackageValidationError.displayNameTooLong
        }
        guard description.count <= maximumDescriptionCharacters else {
            throw CustomPetPackageValidationError.descriptionTooLong
        }
    }

    public static func validateManifestFields(
        id: String,
        displayName: String,
        description: String,
        spriteVersionNumber: Int,
        spritesheetPath: String
    ) throws {
        guard isValidID(id) else {
            throw CustomPetPackageValidationError.invalidID
        }
        try validateDisplayText(
            displayName: displayName,
            description: description
        )
        guard spriteVersionNumber == PetSpriteContract.spriteVersionNumber else {
            throw CustomPetPackageValidationError.unsupportedSpriteVersion
        }
        guard isValidSpritesheetPath(spritesheetPath) else {
            throw CustomPetPackageValidationError.invalidSpritesheetPath
        }
    }

    public static func validate(
        id: String,
        displayName: String,
        spriteVersionNumber: Int,
        spritesheetPath: String,
        manifestBytes: Int,
        spritesheetBytes: Int,
        pixelWidth: Int,
        pixelHeight: Int,
        hasAlpha: Bool
    ) throws {
        try validateManifestFields(
            id: id,
            displayName: displayName,
            description: "",
            spriteVersionNumber: spriteVersionNumber,
            spritesheetPath: spritesheetPath
        )
        try validateManifestSize(manifestBytes)
        try validateSpritesheetSize(spritesheetBytes)
        guard pixelWidth == PetSpriteContract.atlasWidth,
              pixelHeight == PetSpriteContract.atlasHeight else {
            throw CustomPetPackageValidationError.incorrectDimensions
        }
        guard hasAlpha else {
            throw CustomPetPackageValidationError.missingTransparency
        }
    }

    public static func isValidID(_ id: String) -> Bool {
        guard (1 ... 64).contains(id.count),
              id != "builtin",
              let first = id.first,
              first.isASCII,
              first.isLowercase || first.isNumber else {
            return false
        }
        return id.allSatisfy { character in
            character.isASCII
                && (character.isLowercase
                    || character.isNumber
                    || character == "-"
                    || character == "_")
        }
    }

    public static func isValidSpritesheetPath(_ path: String) -> Bool {
        guard !path.isEmpty,
              path == URL(fileURLWithPath: path).lastPathComponent,
              !path.contains("/"),
              !path.contains("\\"),
              path != ".",
              path != ".." else {
            return false
        }
        let fileExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
        return fileExtension == "png" || fileExtension == "webp"
    }
}
