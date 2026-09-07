// Vendor-side license tool. Not part of any build target; run directly:
//
//   swift Scripts/license-sign.swift keygen
//       Creates ~/.perch-license-key (owner-only) and prints the public
//       key hex to embed in the app. Refuses to overwrite an existing key.
//
//   swift Scripts/license-sign.swift sign <email> <order-id>
//       Prints a license file to stdout; redirect it to <order>.perchlicense.
//
//   swift Scripts/license-sign.swift verify <license-file> <public-key-hex>
//       Vendor-side support check: does a customer's license file verify
//       against the shipped public key? Exits nonzero on any failure.
//
// The private key never enters the repository. Verification logic lives
// in PerchCore/ProLicense.swift so both sides share one tested contract.
import CryptoKit
import Foundation

let keyPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".perch-license-key")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let arguments = CommandLine.arguments
switch arguments.dropFirst().first {
case "keygen":
    guard !FileManager.default.fileExists(atPath: keyPath.path) else {
        fail("key already exists at \(keyPath.path); refusing to overwrite")
    }
    let key = Curve25519.Signing.PrivateKey()
    try key.rawRepresentation.write(to: keyPath, options: [])
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: keyPath.path
    )
    print("private key: \(keyPath.path) (keep offline, back it up)")
    print("public key hex (embed in app):")
    print(key.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined())
case "sign":
    guard arguments.count == 4 else { fail("usage: sign <email> <order-id>") }
    guard let raw = try? Data(contentsOf: keyPath),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        fail("no usable key at \(keyPath.path); run keygen first")
    }
    // Verification bounds live in ProLicense; mirror them here so a bad
    // order row fails at signing time, not at the customer's machine.
    let email = arguments[2], order = arguments[3]
    guard !email.isEmpty, email.count <= 254, email.contains("@") else {
        fail("invalid email")
    }
    guard !order.isEmpty, order.count <= 64 else { fail("invalid order id") }
    let payload = try JSONEncoder().encode([
        "edition": "pro",
        "email": email,
        "order": order,
        "issued": ISO8601DateFormatter().string(from: Date()),
    ])
    let signature = try key.signature(for: payload)
    let envelope = try JSONEncoder().encode([
        "payload": payload.base64EncodedString(),
        "signature": signature.base64EncodedString(),
    ])
    print(String(decoding: envelope, as: UTF8.self))
case "verify":
    guard arguments.count == 4 else {
        fail("usage: verify <license-file> <public-key-hex>")
    }
    let hex = arguments[3]
    var keyBytes = [UInt8]()
    var index = hex.startIndex
    while index < hex.endIndex {
        guard let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex),
              let byte = UInt8(hex[index ..< next], radix: 16) else {
            fail("invalid public key hex")
        }
        keyBytes.append(byte)
        index = next
    }
    guard let fileData = try? Data(contentsOf: URL(fileURLWithPath: arguments[2])),
          fileData.count <= 4 * 1024 else {
        fail("unreadable or oversized license file")
    }
    // Mirrors ProLicense.verify: fail closed on any structural, size,
    // signature, or field problem.
    guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: Data(keyBytes)),
          let envelope = try? JSONDecoder().decode([String: String].self, from: fileData),
          let payloadB64 = envelope["payload"], let signatureB64 = envelope["signature"],
          let payload = Data(base64Encoded: payloadB64),
          let signature = Data(base64Encoded: signatureB64),
          key.isValidSignature(signature, for: payload),
          let fields = try? JSONDecoder().decode([String: String].self, from: payload),
          fields["edition"] == "pro",
          let email = fields["email"], !email.isEmpty, email.count <= 254,
          let order = fields["order"], !order.isEmpty, order.count <= 64,
          let issued = fields["issued"],
          ISO8601DateFormatter().date(from: issued) != nil else {
        fail("INVALID: license does not verify")
    }
    print("VALID: pro license for \(email), order \(order), issued \(issued)")
default:
    fail("usage: swift Scripts/license-sign.swift keygen | sign <email> <order-id> | verify <license-file> <public-key-hex>")
}
