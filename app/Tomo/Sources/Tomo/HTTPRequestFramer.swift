import Foundation

/// Bounded framing for the single-request, connection-close HTTP service.
/// Never dispatch an incomplete JSON body to a write endpoint.
enum HTTPRequestFramer {
    enum Result: Equatable {
        case incomplete
        case complete(Data)
        case rejected(Int)
    }

    static let maxHeaderBytes = 16_384
    static let maxBodyBytes = 1_048_576

    static func inspect(_ buffer: Data) -> Result {
        guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > maxHeaderBytes ? .rejected(431) : .incomplete
        }
        guard separator.upperBound <= maxHeaderBytes,
              let header = String(data: buffer[..<separator.lowerBound], encoding: .utf8) else {
            return .rejected(431)
        }
        let lines = header.components(separatedBy: "\r\n")
        let request = (lines.first ?? "").split(separator: " ")
        guard request.count == 3, ["HTTP/1.0", "HTTP/1.1"].contains(String(request[2])) else {
            return .rejected(400)
        }
        var length: Int?
        for line in lines.dropFirst() {
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"),
                  let colon = line.firstIndex(of: ":") else { return .rejected(400) }
            let name = String(line[..<colon]).lowercased()
            guard !name.isEmpty, !name.contains(where: { $0.isWhitespace }) else { return .rejected(400) }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            // This server explicitly does not implement chunked request bodies.
            if name == "transfer-encoding" { return .rejected(501) }
            if name == "content-length" {
                guard length == nil, !value.isEmpty,
                      value.allSatisfy({ $0.isASCII && $0.isNumber }),
                      let parsed = Int(value) else { return .rejected(400) }
                guard parsed <= maxBodyBytes else { return .rejected(413) }
                length = parsed
            }
        }
        let expected = separator.upperBound + (length ?? 0)
        guard buffer.count <= expected else { return .rejected(400) }
        return buffer.count == expected ? .complete(buffer) : .incomplete
    }
}
