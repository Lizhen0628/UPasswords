import AppKit

/// 笔记 Markdown 往返。笔记在数据库里是平文字符串(数据结构不变),
/// 链接与字体样式以行内标记持久化:
/// `[文字](URL)`、`**加粗**`、`*斜体*`、`~~删除线~~`、`***粗斜***`。
/// 下划线无通行标记,仍是会话级;标记与正文字符冲突时(如连续星号)可能误判,属已知限制。
enum NotesMarkdown {
    private static let base: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13),
        .foregroundColor: NSColor.textColor,
    ]

    /// 依优先级排列:链接 → 粗斜 → 粗 → 删 → 斜(同位置先长标记)
    // try! 逻辑保证:模式为静态字面量且已人工验证合法,
    // NSRegularExpression 仅在模式非法时抛错,此处不会发生
    private static let regex = try! NSRegularExpression(
        pattern: "\\[[^\\]]*\\]\\([^)]+\\)|\\*\\*\\*[\\s\\S]+?\\*\\*\\*|\\*\\*[\\s\\S]+?\\*\\*|~~[\\s\\S]+?~~|\\*[\\s\\S]+?\\*"
    )

    // MARK: markdown → 富文本(编辑器/详情页显示)

    static func render(_ markdown: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let ns = markdown as NSString
        let full = NSRange(location: 0, length: ns.length)
        var i = 0
        for m in regex.matches(in: markdown, range: full) {
            if m.range.location < i { continue }   // 跳过重叠匹配
            if m.range.location > i {
                out.append(NSAttributedString(
                    string: ns.substring(with: NSRange(location: i, length: m.range.location - i)),
                    attributes: base))
            }
            out.append(renderToken(ns.substring(with: m.range)))
            i = m.range.location + m.range.length
        }
        if i < ns.length {
            out.append(NSAttributedString(string: ns.substring(from: i), attributes: base))
        }
        return out
    }

    private static func renderToken(_ token: String) -> NSAttributedString {
        if token.hasPrefix("[") {
            let inner = token.dropFirst().dropLast()
            if let sep = inner.range(of: "](") {
                let label = String(inner[..<sep.lowerBound])
                let urlPart = String(inner[sep.upperBound...])
                if let url = URL(string: urlPart) {
                    return styled(label, url: url)
                }
            }
        }
        if token.hasPrefix("***"), token.hasSuffix("***"), token.count >= 6 {
            return styled(String(token.dropFirst(3).dropLast(3)), bold: true, italic: true)
        }
        if token.hasPrefix("**"), token.hasSuffix("**"), token.count >= 4 {
            return styled(String(token.dropFirst(2).dropLast(2)), bold: true)
        }
        if token.hasPrefix("~~"), token.hasSuffix("~~"), token.count >= 4 {
            return styled(String(token.dropFirst(2).dropLast(2)), strike: true)
        }
        if token.hasPrefix("*"), token.hasSuffix("*"), token.count >= 2 {
            return styled(String(token.dropFirst(1).dropLast(1)), italic: true)
        }
        return styled(token)
    }

    private static func styled(_ text: String, bold: Bool = false, italic: Bool = false,
                               strike: Bool = false, url: URL? = nil) -> NSAttributedString {
        var attrs = base
        var font = NSFont.systemFont(ofSize: 13)
        let fm = NSFontManager.shared
        if bold { font = fm.convert(font, toHaveTrait: .boldFontMask) }
        if italic { font = fm.convert(font, toHaveTrait: .italicFontMask) }
        attrs[.font] = font
        if strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let url {
            attrs[.link] = url
            attrs[.foregroundColor] = NSColor.controlAccentColor
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return NSAttributedString(string: text, attributes: attrs)
    }

    // MARK: 富文本 → markdown(编辑器打字时回写保存)

    static func serialize(_ attributed: NSAttributedString) -> String {
        struct Run {
            var text: String
            var bold: Bool
            var italic: Bool
            var strike: Bool
            var url: String?
        }
        let fm = NSFontManager.shared
        var runs: [Run] = []
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attrs, range, _ in
            let chunk = attributed.attributedSubstring(from: range).string
            let traits = (attrs[.font] as? NSFont).map { fm.traits(of: $0) } ?? []
            let r = Run(
                text: chunk,
                bold: traits.contains(.boldFontMask),
                italic: traits.contains(.italicFontMask),
                strike: (attrs[.strikethroughStyle] as? Int ?? 0) != 0,
                url: (attrs[.link] as? URL)?.absoluteString
            )
            // 相邻同样式 run 合并,否则会产生 **a****b** 这类渲染不回的串
            if let last = runs.last,
               last.bold == r.bold, last.italic == r.italic, last.strike == r.strike, last.url == r.url {
                runs[runs.count - 1].text += r.text
            } else {
                runs.append(r)
            }
        }
        var out = ""
        for r in runs {
            if let url = r.url {
                out += "[\(r.text)](\(url))"
                continue
            }
            var s = r.text
            if r.strike { s = "~~\(s)~~" }
            if r.italic { s = "*\(s)*" }
            if r.bold { s = "**\(s)**" }
            out += s
        }
        return out
    }

    /// 渲染后的可见字符数(字数统计用,不含标记语法)
    static func visibleLength(_ markdown: String) -> Int {
        render(markdown).string.count
    }
}
