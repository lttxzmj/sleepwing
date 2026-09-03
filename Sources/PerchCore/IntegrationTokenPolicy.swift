import Foundation

public enum IntegrationTokenPolicy {
    public static let randomByteCount = 32
    public static let encodedLength = randomByteCount * 2

    public static func isValid(_ token: String) -> Bool {
        let bytes = Array(token.utf8)
        guard bytes.count == encodedLength else { return false }
        return bytes.allSatisfy { byte in
            (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
        }
    }

    public static func securelyMatches(_ received: String, expected: String) -> Bool {
        guard isValid(expected) else { return false }
        let receivedBytes = Array(received.utf8)
        let expectedBytes = Array(expected.utf8)
        guard receivedBytes.count == expectedBytes.count else { return false }

        var difference: UInt8 = 0
        for index in expectedBytes.indices {
            difference |= receivedBytes[index] ^ expectedBytes[index]
        }
        return difference == 0
    }
}
