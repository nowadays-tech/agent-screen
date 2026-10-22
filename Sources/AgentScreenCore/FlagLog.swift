import Foundation

/// A tool result that Security-One scored at or above the threshold.
public struct Flag: Codable, Equatable {
    public var time: Date
    public var score: Double
    public var tool: String
    public var source: String
    public var session: String?
    public var excerpt: String
}

/// Flags as JSON lines in one file. Flags are the only events it records.
public struct FlagLog {
    public var url: URL

    public init(url: URL) {
        self.url = url
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public func append(_ flag: Flag) throws {
        var line = try Self.encoder.encode(flag)
        line.append(UInt8(ascii: "\n"))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    /// The newest flags first.
    public func recent(_ limit: Int) -> [Flag] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let lines = data.split(separator: UInt8(ascii: "\n"))
        return lines.suffix(limit).reversed().compactMap { try? Self.decoder.decode(Flag.self, from: Data($0)) }
    }
}
