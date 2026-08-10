import Foundation

public enum AgentCommandHistory {
    public static let defaultLimit = 12

    public static func normalizedCommand(_ value: String) -> String? {
        let command = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty,
              !command.contains(where: \.isNewline),
              !command.contains("\0") else {
            return nil
        }
        return command
    }

    public static func recording(
        _ value: String,
        in history: [String],
        limit: Int = defaultLimit
    ) -> [String] {
        guard let command = normalizedCommand(value), limit > 0 else { return history }

        var seen = Set([command])
        var result = [command]
        result.append(contentsOf: history
            .compactMap(normalizedCommand)
            .filter { seen.insert($0).inserted })
        return Array(result.prefix(limit))
    }

    public static func encode(_ history: [String]) -> String {
        var seen = Set<String>()
        return history
            .compactMap(normalizedCommand)
            .filter { seen.insert($0).inserted }
            .joined(separator: "\n")
    }

    public static func decode(_ value: String, limit: Int = defaultLimit) -> [String] {
        guard limit > 0 else { return [] }

        var seen = Set<String>()
        let commands = value
            .split(whereSeparator: \.isNewline)
            .compactMap { normalizedCommand(String($0)) }
            .filter { seen.insert($0).inserted }
        return Array(commands.prefix(limit))
    }
}
