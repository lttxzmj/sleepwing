import Foundation

/// Minimal codec for pi's RPC mode (JSONL over stdio) — only the frames
/// the pet-chat channel needs are modeled; unknown records parse to nil
/// and get skipped. Framing follows the protocol contract: records are
/// separated by LF alone (generic line readers also split on U+2028 and
/// U+2029, which are legal inside JSON strings), and a trailing CR is
/// tolerated.
public enum PiRpcProtocol {
    public enum Incoming: Equatable, Sendable {
        case response(id: String?, command: String, success: Bool, text: String?)
        case agentSettled
    }

    public static func encodeNewSession(id: String) -> Data {
        encode(["id": id, "type": "new_session"])
    }

    public static func encodePrompt(id: String, message: String) -> Data {
        encode(["id": id, "type": "prompt", "message": message])
    }

    public static func encodeGetLastAssistantText(id: String) -> Data {
        encode(["id": id, "type": "get_last_assistant_text"])
    }

    private static func encode(_ object: [String: String]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        data.append(0x0A)
        return data
    }

    /// Removes complete LF-terminated records from `buffer`, leaving any
    /// partial trailing record in place for the next read.
    public static func drainRecords(from buffer: inout Data) -> [Data] {
        var records: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var record = buffer.subdata(in: buffer.startIndex..<newline)
            if record.last == 0x0D { record.removeLast() }
            if !record.isEmpty { records.append(record) }
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        return records
    }

    public static func parse(_ record: Data) -> Incoming? {
        guard let object = (try? JSONSerialization.jsonObject(with: record))
            as? [String: Any],
            let type = object["type"] as? String else { return nil }
        switch type {
        case "agent_settled":
            return .agentSettled
        case "response":
            guard let command = object["command"] as? String else { return nil }
            let id = (object["id"] as? String)
                ?? (object["id"] as? Int).map(String.init)
            return .response(
                id: id,
                command: command,
                success: object["success"] as? Bool ?? false,
                text: (object["data"] as? [String: Any])?["text"] as? String
            )
        default:
            return nil
        }
    }
}
