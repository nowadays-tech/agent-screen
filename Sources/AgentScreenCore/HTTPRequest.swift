import Foundation

/// One HTTP/1.1 request as read off a client connection.
public struct HTTPRequest {
    public var method: String
    public var target: String
    public var headers: [(name: String, value: String)]
    public var body: Data

    public func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public enum ParseResult {
        case incomplete
        case invalid
        case request(HTTPRequest, consumed: Int)
    }

    private static let crlf = Data("\r\n".utf8)
    private static let headerEnd = Data("\r\n\r\n".utf8)

    /// Parses one request from the front of `buffer`, which must start at index 0.
    public static func parse(_ buffer: Data) -> ParseResult {
        guard let end = buffer.range(of: headerEnd) else { return .incomplete }
        guard let head = String(data: buffer[..<end.lowerBound], encoding: .utf8) else { return .invalid }

        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3 else { return .invalid }

        var headers: [(name: String, value: String)] = []
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            headers.append((String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }

        var request = HTTPRequest(method: String(requestLine[0]), target: String(requestLine[1]), headers: headers, body: Data())
        let bodyStart = end.upperBound

        if request.header("Transfer-Encoding")?.lowercased().contains("chunked") == true {
            guard let (body, consumed) = decodeChunked(buffer, from: bodyStart) else { return .incomplete }
            request.body = body
            return .request(request, consumed: consumed)
        }

        let length = Int(request.header("Content-Length") ?? "0") ?? -1
        guard length >= 0 else { return .invalid }
        guard buffer.count >= bodyStart + length else { return .incomplete }
        request.body = buffer.subdata(in: bodyStart..<bodyStart + length)
        return .request(request, consumed: bodyStart + length)
    }

    /// Returns the decoded body and the index just past it, or nil when more bytes are needed.
    private static func decodeChunked(_ buffer: Data, from start: Int) -> (Data, Int)? {
        var body = Data()
        var position = start
        while true {
            guard let lineEnd = buffer.range(of: crlf, in: position..<buffer.count) else { return nil }
            let sizeField = String(decoding: buffer[position..<lineEnd.lowerBound], as: UTF8.self)
            guard let size = Int(sizeField.split(separator: ";").first ?? "", radix: 16) else { return nil }
            position = lineEnd.upperBound

            if size == 0 {
                // No trailers ends with a bare CRLF; trailers end with a blank line.
                if buffer.count >= position + 2, buffer[position..<position + 2] == crlf { return (body, position + 2) }
                guard let trailersEnd = buffer.range(of: headerEnd, in: position..<buffer.count) else { return nil }
                return (body, trailersEnd.upperBound)
            }

            guard buffer.count >= position + size + 2 else { return nil }
            body.append(buffer[position..<position + size])
            position += size + 2
        }
    }
}
