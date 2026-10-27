import Foundation

// `sotto`: a local command-line tool bundled in Sotto.app (Contents/Helpers/sotto).
// `history` reads your dictation history read-only; nothing is sent anywhere.

let usage = """
    Usage:
      sotto history last [-n COUNT] [--json]         Newest transcripts (default 1)
      sotto history search QUERY... [-n COUNT] [--json]
                                                     Full-text search (default 20 results)
      sotto agent-hook --agent claude|cursor --event stop|notification
                                                     Coding-agent voice relay hook (reads JSON on stdin)
      sotto --help

    History is read from ~/Library/Application Support/Sotto/history.sqlite, read-only.
    """

struct Options {
    var positional: [String] = []
    var count: Int?
    var json = false
    var database: URL?
    var flags: [String: String] = [:]
}

func parse(_ arguments: ArraySlice<String>) throws -> Options {
    var options = Options()
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
        switch argument {
        case "-n", "--count":
            guard let value = iterator.next(), let count = Int(value), count > 0 else {
                throw CLIError.usage("\(argument) needs a positive number")
            }
            options.count = min(count, 10_000)
        case "--json":
            options.json = true
        case "--db":
            guard let path = iterator.next() else { throw CLIError.usage("--db needs a path") }
            options.database = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        case "--agent", "--event", "--timeout":
            guard let value = iterator.next() else { throw CLIError.usage("\(argument) needs a value") }
            options.flags[argument] = value
        case "-h", "--help":
            print(usage)
            exit(0)
        default:
            if argument.hasPrefix("-") { throw CLIError.usage("unknown option \(argument)") }
            options.positional.append(argument)
        }
    }
    return options
}

enum CLIError: Error {
    case usage(String)
}

func printEntries(_ entries: [HistoryReader.Entry], json: Bool) throws {
    if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(entries), as: UTF8.self))
        return
    }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    for (index, entry) in entries.enumerated() {
        if entries.count > 1 {
            let meta = [formatter.string(from: entry.date), entry.app, entry.mode.map { "\($0) mode" }]
                .compactMap { $0 }
                .joined(separator: " · ")
            print((index > 0 ? "\n" : "") + "── \(meta)")
        }
        print(entry.text)
    }
}

func runHistory(_ options: Options) throws {
    var positional = options.positional.dropFirst()  // "history"
    guard let command = positional.popFirst() else { throw CLIError.usage("history needs `last` or `search`") }
    let reader = try HistoryReader(url: options.database ?? HistoryReader.defaultURL)
    switch command {
    case "last":
        guard positional.isEmpty else { throw CLIError.usage("`history last` takes no query") }
        try printEntries(reader.last(options.count ?? 1), json: options.json)
    case "search":
        let query = positional.joined(separator: " ")
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { throw CLIError.usage("`history search` needs a query") }
        let entries = try reader.search(query, limit: options.count ?? 20)
        if entries.isEmpty, !options.json {
            FileHandle.standardError.write(Data("No transcripts match “\(query)”.\n".utf8))
            exit(1)
        }
        try printEntries(entries, json: options.json)
    default:
        throw CLIError.usage("unknown history command `\(command)`")
    }
}

do {
    let options = try parse(CommandLine.arguments.dropFirst())
    switch options.positional.first {
    case "history":
        try runHistory(options)
    case "agent-hook":
        exit(AgentHook.run(options))
    case nil:
        print(usage)
    default:
        throw CLIError.usage("unknown command `\(options.positional[0])`")
    }
} catch CLIError.usage(let message) {
    FileHandle.standardError.write(Data("sotto: \(message)\n\n\(usage)\n".utf8))
    exit(2)
} catch {
    FileHandle.standardError.write(Data("sotto: \(error)\n".utf8))
    exit(1)
}
