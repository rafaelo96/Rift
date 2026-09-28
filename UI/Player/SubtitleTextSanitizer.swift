import Foundation

enum SubtitleTextSanitizer {
    static func plainText(from rawText: String) -> String {
        let source = rawText
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
        var result = ""
        var index = source.startIndex

        while index < source.endIndex {
            if source[index] == "<",
               let end = source[index...].firstIndex(of: ">") {
                let tag = source[source.index(after: index)..<end]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                if tag == "br" || tag == "br/" || tag == "br /" {
                    result.append("\n")
                    index = source.index(after: end)
                    continue
                }
                let tagName = tag
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    .split(whereSeparator: { $0.isWhitespace })
                    .first
                    .map(String.init) ?? ""
                if ["i", "b", "u", "s", "font"].contains(tagName) {
                    index = source.index(after: end)
                    continue
                }
            }

            if source[index] == "{",
               let end = source[index...].firstIndex(of: "}"),
               source[source.index(after: index)..<end].contains("\\") {
                index = source.index(after: end)
                continue
            }

            result.append(source[index])
            index = source.index(after: index)
        }

        let decoded = result
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")

        return decoded
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
