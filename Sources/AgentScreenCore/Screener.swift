import CryptoKit
import Foundation

/// Scores the outside text in agent requests and records a flag for each result at or above the threshold.
/// It only watches; the request has already gone upstream untouched.
public final class Screener {
    /// Security-One reads up to 65,536 tokens per question. 60,000 characters stays under that even for dense text.
    static let chunkLength = 60_000

    public var apiKey: () -> String?
    public var log: FlagLog
    public var session: URLSession
    public var onFlag: ((Flag) -> Void)?
    /// Called after each call to Security-One.
    public var onCheck: ((Check) -> Void)?

    public enum Check: Equatable {
        /// The round trip to Superagent, in seconds.
        case scored(seconds: Double)
        case failed(String)
    }

    // Claude Code resends the whole conversation every turn, so each result is scored once.
    private var seen = Set<String>()
    private let lock = NSLock()

    public init(apiKey: @escaping () -> String?, log: FlagLog, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.log = log
        self.session = session
    }

    public func screen(_ request: HTTPRequest) async {
        guard request.method == "POST",
              let path = request.target.split(separator: "?").first,
              path == "/v1/messages",
              let key = apiKey(), !key.isEmpty else { return }

        let client = SecurityOne(apiKey: key, session: session)
        for result in ToolResults.screenable(inMessagesBody: request.body) {
            let hash = SHA256.hash(data: Data(result.text.utf8)).map { String(format: "%02x", $0) }.joined()
            guard lock.withLock({ seen.insert(hash).inserted }) else { continue }

            do {
                for chunk in Self.chunks(of: result.text) {
                    let start = Date()
                    let score = try await client.injectionProbability(of: String(chunk))
                    onCheck?(.scored(seconds: Date().timeIntervalSince(start)))
                    if score >= SecurityOne.threshold {
                        let flag = Flag(time: Date(), score: score, tool: result.tool, source: result.source,
                                        session: request.header("X-Claude-Code-Session-Id"), excerpt: String(chunk.prefix(500)))
                        try? log.append(flag)
                        onFlag?(flag)
                        break
                    }
                }
            } catch {
                // Forget it so the next turn, which resends it, tries again.
                _ = lock.withLock { seen.remove(hash) }
                onCheck?(.failed("\(error)"))
            }
        }
    }

    static func chunks(of text: String) -> [Substring] {
        var chunks: [Substring] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: chunkLength, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(text[start..<end])
            start = end
        }
        return chunks
    }
}
