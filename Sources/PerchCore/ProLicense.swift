import CryptoKit
import Foundation

/// Offline Pro-license verification. Zero outbound network is a product
/// promise, so there is no activation server: a license is a small file
/// whose payload is signed with the vendor's ed25519 key, and the app
/// verifies it locally against an embedded public key. Piracy tolerance
/// is a deliberate trade (MONETIZATION_PLAN): in this category people
/// pay to support, not to unlock.
///
/// The file wraps the exact signed bytes in base64, so verification
/// never depends on JSON canonicalization:
///
///     {"payload":"<base64 JSON>","signature":"<base64 ed25519>"}
public enum ProLicense {
    public struct License: Equatable, Sendable {
        public let edition: Edition
        public let email: String
        public let order: String
        public let issued: Date
    }

    public enum Edition: String, Sendable {
        case pro
    }

    /// A license is a short file; anything bigger is read as garbage,
    /// never parsed.
    public static let maximumFileSize = 4 * 1024

    /// Fail-closed verification: any structural, size, signature, or
    /// field problem yields nil — there is no "partially valid" license.
    public static func verify(fileData: Data, publicKey: Data) -> License? {
        guard fileData.count <= maximumFileSize,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: fileData),
              let payload = Data(base64Encoded: envelope.payload),
              let signature = Data(base64Encoded: envelope.signature),
              key.isValidSignature(signature, for: payload),
              let fields = try? JSONDecoder().decode(Payload.self, from: payload),
              let edition = Edition(rawValue: fields.edition),
              !fields.email.isEmpty, fields.email.count <= 254,
              !fields.order.isEmpty, fields.order.count <= 64,
              let issued = ISO8601DateFormatter().date(from: fields.issued)
        else { return nil }
        return License(
            edition: edition,
            email: fields.email,
            order: fields.order,
            issued: issued
        )
    }

    /// Builds a license file from its parts. Lives here (not only in the
    /// signing tool) so issuing and verifying are one tested contract;
    /// shipping it is safe because signing requires the private key,
    /// which never enters this repository.
    public static func issue(
        email: String,
        order: String,
        issued: Date,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws -> Data {
        let payload = try JSONEncoder().encode(Payload(
            edition: Edition.pro.rawValue,
            email: email,
            order: order,
            issued: ISO8601DateFormatter().string(from: issued)
        ))
        let signature = try privateKey.signature(for: payload)
        return try JSONEncoder().encode(Envelope(
            payload: payload.base64EncodedString(),
            signature: signature.base64EncodedString()
        ))
    }

    private struct Envelope: Codable {
        let payload: String
        let signature: String
    }

    private struct Payload: Codable {
        let edition: String
        let email: String
        let order: String
        let issued: String
    }
}
