import Foundation
import Darwin

enum SSHConfigParser {
    static func loadDefault() throws -> [SSHConfigEntry] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        var visited = Set<String>()
        return parse(try loadRecursively(url, visited: &visited))
    }

    static func parse(_ contents: String) -> [SSHConfigEntry] {
        struct Draft {
            var aliases: [String]
            var hostName: String?
            var port: Int?
            var user: String?
            var identityFile: String?
        }

        var drafts: [Draft] = []
        var current: Draft?

        func commit(_ draft: Draft?, into drafts: inout [Draft]) {
            guard let draft, !draft.aliases.isEmpty else { return }
            drafts.append(draft)
        }

        for rawLine in contents.components(separatedBy: .newlines) {
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let pieces = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let first = pieces.first else { continue }
            let keyword = first.lowercased()
            let value = pieces.dropFirst().joined(separator: " ")

            if keyword == "host" {
                commit(current, into: &drafts)
                let aliases = pieces.dropFirst().filter(isConcreteAlias).map(String.init)
                current = Draft(aliases: aliases)
                continue
            }

            guard current != nil else { continue }
            switch keyword {
            case "hostname":
                if current?.hostName == nil { current?.hostName = value }
            case "port":
                if current?.port == nil { current?.port = Int(value) }
            case "user":
                if current?.user == nil { current?.user = value }
            case "identityfile":
                if current?.identityFile == nil { current?.identityFile = expandTilde(value) }
            default:
                break
            }
        }
        commit(current, into: &drafts)

        var seen = Set<String>()
        return drafts.flatMap { draft in
            draft.aliases.compactMap { alias in
                guard seen.insert(alias).inserted else { return nil }
                return SSHConfigEntry(
                    alias: alias,
                    hostName: draft.hostName ?? alias,
                    port: draft.port ?? 22,
                    user: draft.user ?? NSUserName(),
                    identityFile: draft.identityFile
                )
            }
        }
    }

    private static func isConcreteAlias(_ value: Substring) -> Bool {
        !value.hasPrefix("!") && !value.contains("*") && !value.contains("?")
    }

    private static func stripComment(_ line: String) -> String {
        var quoted = false
        for index in line.indices {
            if line[index] == "\"" { quoted.toggle() }
            if line[index] == "#", !quoted { return String(line[..<index]) }
        }
        return line
    }

    private static func expandTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    private static func loadRecursively(_ url: URL, visited: inout Set<String>) throws -> String {
        let canonicalPath = url.standardizedFileURL.path
        guard visited.insert(canonicalPath).inserted else { return "" }
        let contents = try String(contentsOf: url, encoding: .utf8)
        var result = ""

        for rawLine in contents.components(separatedBy: .newlines) {
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            let pieces = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if pieces.first?.lowercased() == "include" {
                for pattern in pieces.dropFirst() {
                    for includedURL in matchingFiles(String(pattern), relativeTo: url.deletingLastPathComponent()) {
                        result += (try? loadRecursively(includedURL, visited: &visited)) ?? ""
                        result += "\n"
                    }
                }
            }
            result += rawLine + "\n"
        }
        return result
    }

    private static func matchingFiles(_ pattern: String, relativeTo directory: URL) -> [URL] {
        var expanded = expandTilde(pattern)
        if !expanded.hasPrefix("/") {
            expanded = directory.appendingPathComponent(expanded).path
        }

        var result = glob_t()
        defer { globfree(&result) }
        guard glob(expanded, GLOB_TILDE, nil, &result) == 0,
              let paths = result.gl_pathv else { return [] }

        return (0..<Int(result.gl_pathc)).compactMap { index in
            guard let path = paths[index] else { return nil }
            return URL(fileURLWithPath: String(cString: path))
        }.sorted { $0.path < $1.path }
    }
}
