import Foundation

/// A tool result that carries outside text into an agent's context.
public struct ToolResult: Equatable {
    public var tool: String
    public var source: String
    public var text: String
}

public enum ToolResults {
    /// Bash output counts as outside text only when the command talks to GitHub, Multica, or the web.
    /// Not `git`: most of its output is local code, which should not leave the machine.
    private static let outsideCommand = try! NSRegularExpression(pattern: #"(^|[\s;&|(])(gh|multica|curl|wget)\s"#)

    /// Pulls the screenable tool results out of an Anthropic Messages API request body.
    /// Screened: WebFetch, WebSearch, MCP tools, and Bash commands that reach outside the machine.
    /// Skipped: everything else, such as Read and Skill, whose text is local or instructions by design.
    public static func screenable(inMessagesBody body: Data) -> [ToolResult] {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let messages = json["messages"] as? [[String: Any]] else { return [] }

        var calls: [String: (name: String, input: [String: Any])] = [:]
        var results: [ToolResult] = []

        for message in messages {
            guard let blocks = message["content"] as? [[String: Any]] else { continue }
            for block in blocks {
                switch block["type"] as? String {
                case "tool_use":
                    if let id = block["id"] as? String, let name = block["name"] as? String {
                        calls[id] = (name, block["input"] as? [String: Any] ?? [:])
                    }
                case "tool_result":
                    guard let id = block["tool_use_id"] as? String, let call = calls[id],
                          let source = source(of: call.name, input: call.input) else { continue }
                    let text = self.text(of: block["content"])
                    if !text.isEmpty { results.append(ToolResult(tool: call.name, source: source, text: text)) }
                default:
                    continue
                }
            }
        }
        return results
    }

    /// What the tool read from, or nil when the tool is not screened.
    private static func source(of tool: String, input: [String: Any]) -> String? {
        switch tool {
        case "WebFetch": return input["url"] as? String ?? ""
        case "WebSearch": return input["query"] as? String ?? ""
        case "Bash":
            guard let command = input["command"] as? String,
                  outsideCommand.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) != nil else { return nil }
            return String(command.prefix(200))
        default:
            return tool.hasPrefix("mcp__") ? tool : nil
        }
    }

    private static func text(of content: Any?) -> String {
        if let string = content as? String { return string }
        let blocks = content as? [[String: Any]] ?? []
        return blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
    }
}
