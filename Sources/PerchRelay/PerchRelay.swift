import Foundation
import PerchCore

@main
enum PerchRelay {
    static func main() {
        guard CommandLine.arguments.count >= 2,
              let provider = AgentProvider(rawValue: CommandLine.arguments[1]) else {
            return
        }

        let rawData: Data
        if CommandLine.arguments.count >= 3 {
            rawData = Data(CommandLine.arguments[2].utf8)
        } else {
            rawData = readStandardInput(
                maximumBytes: HookPayloadSanitizer.maximumRawPayloadBytes
            )
        }

        guard let canonical = try? HookPayloadSanitizer.sanitize(provider: provider, rawData: rawData) else {
            return
        }
        FileHandle.standardOutput.write(canonical)
    }

    /// Hooks are outside Perch's trust boundary. Read one byte beyond the
    /// accepted limit so oversized stdin is rejected without first buffering
    /// an arbitrarily large payload in the relay process.
    private static func readStandardInput(maximumBytes: Int) -> Data {
        var data = Data()
        let readLimit = maximumBytes + 1
        while data.count < readLimit {
            let remaining = readLimit - data.count
            guard let chunk = try? FileHandle.standardInput.read(
                upToCount: min(16 * 1024, remaining)
            ), !chunk.isEmpty else {
                break
            }
            data.append(chunk)
        }
        return data
    }
}
