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

        guard let canonical = try? HookPayloadSanitizer.sanitize(
            provider: provider,
            rawData: rawData,
            controllingTTY: controllingTTYName()
        ) else {
            return
        }
        FileHandle.standardOutput.write(canonical)
    }

    /// The hook's stdio is piped, but it inherits the agent's controlling
    /// terminal; that device basename is the only signal that can route a
    /// task click back to the exact terminal tab hosting the session.
    /// `ttyname` on an opened `/dev/tty` reports the alias itself on macOS,
    /// so the real device has to come from the process's own `e_tdev`.
    private static func controllingTTYName() -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        let device = info.kp_eproc.e_tdev
        guard device != -1, let name = devname(device, mode_t(S_IFCHR)) else {
            return nil
        }
        return String(cString: name)
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
