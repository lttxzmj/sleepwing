// Vendor-side license tool. Not part of any build target; run directly:
//
//   swift Scripts/license-sign.swift keygen
//       Creates ~/.perch-license-key (owner-only) and prints the public
//       key hex to embed in the app. Refuses to overwrite an existing key.
//
//   swift Scripts/license-sign.swift sign <email> <order-id>
//       Prints a license file to stdout; redirect it to <order>.perchlicense.
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
default:
    fail("usage: swift Scripts/license-sign.swift keygen | sign <email> <order-id>")
}
