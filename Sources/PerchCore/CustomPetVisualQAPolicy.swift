import Foundation

public enum CustomPetVisualQAValidationError: Error, Equatable, Sendable {
    case invalidSummary
    case failedReview
}

/// Validates the bounded attestation written by Perch Pet Skill's
/// deterministic packager. Perch still revalidates the atlas itself; this
/// record only proves that the required human/agent visual pass was declared.
public enum CustomPetVisualQAPolicy {
    private struct Summary: Decodable {
        struct VisualQA: Decodable {
            let status: String
            let evidenceType: String
            let evidenceSHA256: String
        }

        let ok: Bool
        let contract: String
        let spriteVersionNumber: Int
        let visualQA: VisualQA
    }

    public static func validate(_ data: Data) throws {
        guard data.count <= CustomPetPackagePolicy.maximumManifestBytes,
              let summary = try? JSONDecoder().decode(Summary.self, from: data) else {
            throw CustomPetVisualQAValidationError.invalidSummary
        }
        let allowedEvidenceTypes = ["host-review", "hatch-pet-run-summary"]
        let digest = summary.visualQA.evidenceSHA256
        guard summary.ok,
              summary.contract == "perch-motion-v2",
              summary.spriteVersionNumber == PetSpriteContract.spriteVersionNumber,
              summary.visualQA.status == "passed",
              allowedEvidenceTypes.contains(summary.visualQA.evidenceType),
              digest.count == 64,
              digest.allSatisfy({ $0.isHexDigit }) else {
            throw CustomPetVisualQAValidationError.failedReview
        }
    }
}
