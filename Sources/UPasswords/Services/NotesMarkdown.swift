import AppKit

/// 笔记 Markdown 往返。笔记在数据库里是平文字符串(数据结构不变),
/// 链接与字体样式以行内标记持久化:
/// `[文字](URL)`、`**加粗**`、`*斜体*`、`~~删除线~~`、`<u>下划线</u>`、`***粗斜***`。
/// 斜体用 .obliqueness 属性渲染(NSFontManager 无法为系统字体合成斜体)。
/// 标记与正文字符冲突时(如连续星号)可能误判,属已知限制。
enum NotesMarkdown {
    private static let base: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13),
        .foregroundColor: NSColor.textColor,
    ]
    /// 是否包含 CJK 字符(中文无斜体字面,斜体用楷体替代——中文排版惯例)
    static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { s in
            (0x4E00...0x9FFF).contains(s.value)       // CJK 统一表意文字
                || (0x3400...0x4DBF).contains(s.value)
                || (0xF900...0xFAFF).contains(s.value)
        }
    }

    /// 斜体字体:西文 → 系统真斜体(SFNS-Italic);含中文 → 楷体(Kaiti SC)。
    /// 背景:苹方等中文字体没有斜体字面,italic trait 会被 CoreText 静默
    /// 忽略返回正体,.obliqueness 属性也不再渲染,descriptor 矩阵会渲染成
    /// 空白——楷体是中文强调的通行替代(与 Pages/Word 一致)。
    /// serialize 侧以 fontName 含 "kaiti" 识别楷体斜体。
    static func italicFont(for text: String, size: CGFloat, italic: Bool) -> NSFont {
        guard italic else { return NSFont.systemFont(ofSize: size) }
        if containsCJK(text) {
            if let kaiti = NSFont(name: "Kaiti SC", size: size) ?? NSFont(name: "STKaiti", size: size) {
                return kaiti
            }
        }
        let desc = NSFont.systemFont(ofSize: size).fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: desc, size: size) ?? NSFont.systemFont(ofSize: size)
    }

    /// 依优先级排列:链接 → 下划线 → 粗斜 → 粗 → 删 → 斜(同位置先长标记);
    /// `<u>` 标签在 renderToken 里递归渲染内容,支持与其他标记嵌套
    // try! 逻辑保证:模式为静态字面量且已人工验证合法,
    // NSRegularExpression 仅在模式非法时抛错,此处不会发生
    private static let regex = try! NSRegularExpression(
        pattern: "\\[[^\\]]*\\]\\([^)]+\\)|<u>[\\s\\S]+?</u>|\\*\\*\\*[\\s\\S]+?\\*\\*\\*|\\*\\*[\\s\\S]+?\\*\\*|~~[\\s\\S]+?~~|\\*[\\s\\S]+?\\*"
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
        if token.hasPrefix("<u>"), token.hasSuffix("</u>"), token.count >= 7 {
            // 下划线可与其他标记嵌套:递归渲染内容后整段加下划线
            let inner = String(token.dropFirst(3).dropLast(4))
            let out = NSMutableAttributedString(attributedString: render(inner))
            out.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue,
                             range: NSRange(location: 0, length: out.length))
            return out
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
        if bold {
            font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        }
        if italic {
            font = italicFont(for: text, size: font.pointSize, italic: true)
        }
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
            var underline: Bool
            var url: String?
        }
        let fm = NSFontManager.shared
        var runs: [Run] = []
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attrs, range, _ in
            let chunk = attributed.attributedSubstring(from: range).string
            let font = attrs[.font] as? NSFont
            let traits = font.map { fm.traits(of: $0) } ?? []
            let oblique = (attrs[.obliqueness] as? NSNumber)?.doubleValue ?? 0
            // 楷体 = 中文斜体(Kaiti SC 字名含 "kaiti")
            let fontName = font?.fontName.lowercased() ?? ""
            let r = Run(
                text: chunk,
                bold: traits.contains(.boldFontMask),
                italic: oblique != 0 || traits.contains(.italicFontMask) || fontName.contains("kaiti"),
                strike: (attrs[.strikethroughStyle] as? Int ?? 0) != 0,
                underline: (attrs[.underlineStyle] as? Int ?? 0) != 0,
                url: (attrs[.link] as? URL)?.absoluteString
            )
            // 相邻同样式 run 合并,否则会产生 **a****b** 这类渲染不回的串
            if let last = runs.last,
               last.bold == r.bold, last.italic == r.italic, last.strike == r.strike,
               last.underline == r.underline, last.url == r.url {
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
            if r.underline { s = "<u>\(s)</u>" }
            out += s
        }
        return out
    }

    /// 渲染后的可见字符数(字数统计用,不含标记语法)
    static func visibleLength(_ markdown: String) -> Int {
        render(markdown).string.count
    }
}
