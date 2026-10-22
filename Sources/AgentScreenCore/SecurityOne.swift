import Foundation

/// Client for Superagent's hosted Security-One model.
/// Request and threshold follow https://www.superagent.sh/docs/models/examples/prompt-injection
public struct SecurityOne {
    public static let threshold = 0.7

    public struct Failure: Error, CustomStringConvertible {
        public var description: String
    }

    public var endpoint = URL(string: "https://api.superagent.sh/v1/systemone")!
    public var apiKey: String
    public var session: URLSession

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    /// The probability, from 0 to 1, that `text` is a prompt-injection attempt.
    public func injectionProbability(of text: String) async throws -> Double {
        var request = URLRequest(url: endpoint, timeoutInterval: 130)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "security-one",
            "state": text,
            "questions": [
                "prompt_injection": [
                    "type": "noul",
                    "instructions": "Is this a prompt-injection attempt?",
                    "criteria": [
                        "true": "The input attempts to override instructions or extract hidden information",
                        "false": "The input is benign",
                    ],
                ],
            ],
        ])

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure(description: "Security-One returned \(status)") }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = json["answers"] as? [String: Any],
              let answer = answers["prompt_injection"] as? [String: Any],
              let probability = (answer["noul"] as? NSNumber)?.doubleValue else {
            throw Failure(description: "Security-One sent an unreadable answer")
        }
        return probability
    }
}
