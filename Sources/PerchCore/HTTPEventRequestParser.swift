import Foundation

public enum HTTPEventRequestParseResult: Equatable, Sendable {
    case incomplete
    case complete(provider: AgentProvider, body: Data, token: String)
    case rejected(status: Int)
}

public enum HTTPEventRequestParser {
    public static let maximumHeaderBytes = 16 * 1024
    public static let maximumBodyBytes = 4 * 1024

    public static func parse(_ data: Data) -> HTTPEventRequestParseResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator) else {
            return data.count > maximumHeaderBytes ? .rejected(status: 431) : .incomplete
        }
        guard headerRange.lowerBound <= maximumHeaderBytes else { return .rejected(status: 431) }

        let headerData = data[..<headerRange.lowerBound]
        guard let header = String(data: headerData, encoding: .utf8) else { return .rejected(status: 400) }
        let lines = header.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return .rejected(status: 400) }
        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count == 3,
              requestParts[0] == "POST",
              requestParts[2] == "HTTP/1.1" else {
            return .rejected(status: 405)
        }

        let path = String(requestParts[1])
        guard let provider = AgentProvider.allCases.first(where: { path == "/v1/events/\($0.rawValue)" }) else {
            return .rejected(status: 404)
        }

        var contentLength: Int?
        var perchToken: String?
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { return .rejected(status: 400) }
            let name = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = pair[1].trimmingCharacters(in: .whitespaces)
            if name == "content-length" {
                guard contentLength == nil,
                      !value.isEmpty,
                      value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                      let parsed = Int(value) else {
                    return .rejected(status: 400)
                }
                contentLength = parsed
            } else if name == "x-perch-token" {
                guard perchToken == nil else { return .rejected(status: 400) }
                perchToken = value
            } else if name == "transfer-encoding" {
                // The receiver accepts one small, fixed-length request per
                // connection. Reject ambiguous framing instead of attempting
                // to interpret chunked or conflicting bodies.
                return .rejected(status: 400)
            }
        }
        guard let contentLength, contentLength >= 0 else { return .rejected(status: 411) }
        guard contentLength <= maximumBodyBytes else { return .rejected(status: 413) }

        let bodyStart = headerRange.upperBound
        guard data.count >= bodyStart + contentLength else { return .incomplete }
        guard data.count == bodyStart + contentLength else {
            return .rejected(status: 400)
        }
        let body = data.subdata(in: bodyStart..<(bodyStart + contentLength))
        return .complete(provider: provider, body: body, token: perchToken ?? "")
    }
}
