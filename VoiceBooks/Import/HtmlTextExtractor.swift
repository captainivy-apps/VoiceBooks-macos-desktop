import Foundation

/// Lightweight HTML → plain text extraction approximating jsoup's `Jsoup.parse(html).text()`.
enum HtmlTextExtractor {
    static func text(from html: String) -> String {
        var working = html
        working = replace(pattern: "(?is)<!--.*?-->", in: working, with: " ")
        working = replace(pattern: "(?is)<script[^>]*>.*?</script>", in: working, with: " ")
        working = replace(pattern: "(?is)<style[^>]*>.*?</style>", in: working, with: " ")
        working = replace(pattern: "(?is)<head[^>]*>.*?</head>", in: working, with: " ")

        // Block-level boundaries become newlines.
        let blockTags = [
            "br", "p", "div", "li", "ul", "ol", "tr", "td", "th", "table",
            "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "section",
            "article", "header", "footer", "figure", "figcaption", "pre", "hr",
        ]
        for tag in blockTags {
            working = replace(pattern: "(?is)</?\(tag)(\\s[^>]*)?/?>", in: working, with: "\n")
        }

        // Strip all remaining tags.
        working = replace(pattern: "(?is)<[^>]+>", in: working, with: "")

        working = decodeEntities(working)

        // Collapse whitespace: horizontal runs to a single space, 3+ newlines to 2.
        working = replace(pattern: "[\\t\\x0B\\f\\r ]+", in: working, with: " ")
        working = replace(pattern: "\\n[ \\t]*", in: working, with: "\n")
        working = replace(pattern: "\\n{3,}", in: working, with: "\n\n")

        return working.trimmed
    }

    private static func replace(pattern: String, in string: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return string }
        let range = NSRange(string.startIndex..., in: string)
        return regex.stringByReplacingMatches(in: string, options: [], range: range, withTemplate: replacement)
    }

    private static let entities: [String: String] = [
        "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
        "&apos;": "'", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…",
        "&lsquo;": "'", "&rsquo;": "'", "&ldquo;": "\"", "&rdquo;": "\"",
        "&copy;": "©", "&reg;": "®", "&trade;": "™", "&middot;": "·",
        "&bull;": "•", "&deg;": "°", "&laquo;": "«", "&raquo;": "»",
    ]

    private static func decodeEntities(_ string: String) -> String {
        var result = string
        for (entity, value) in entities {
            result = result.replacingOccurrences(of: entity, with: value, options: [.caseInsensitive])
        }
        // Numeric entities.
        if let regex = try? NSRegularExpression(pattern: "&#x([0-9a-fA-F]+);|&#([0-9]+);") {
            let ns = result as NSString
            var output = ""
            var last = 0
            regex.enumerateMatches(in: result, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                guard let match else { return }
                output += ns.substring(with: NSRange(location: last, length: match.range.location - last))
                let hexRange = match.range(at: 1)
                let decRange = match.range(at: 2)
                var scalarValue: UInt32?
                if hexRange.location != NSNotFound {
                    scalarValue = UInt32(ns.substring(with: hexRange), radix: 16)
                } else if decRange.location != NSNotFound {
                    scalarValue = UInt32(ns.substring(with: decRange))
                }
                if let value = scalarValue, let scalar = Unicode.Scalar(value) {
                    output.append(Character(scalar))
                }
                last = match.range.location + match.range.length
            }
            output += ns.substring(from: last)
            result = output
        }
        return result
    }
}
