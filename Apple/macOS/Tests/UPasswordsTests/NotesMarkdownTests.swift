import XCTest
@testable import UPasswords

final class NotesMarkdownTests: XCTestCase {

    /// 列表标记与行内样式混排的 markdown 渲染 → 序列化往返应无损。
    func testRoundTripWithListMarkersAndInlineStyles() {
        let md = "普通**加粗**尾\n1.\t有序**列表粗**\n•\t无序*斜体*与~~删除~~"
        let round = NotesMarkdown.serialize(NotesMarkdown.render(md))
        XCTAssertEqual(round, md)
    }

    /// 链接在 渲染 → 序列化 往返中必须无损(编辑器应用链接后保存重开的链路)。
    func testLinkRoundTrip() {
        let md = "前缀[链接文字](https://baidu.com)后缀"
        let rendered = NotesMarkdown.render(md)
        // 渲染层:链接属性 + 可见样式(前景色/下划线)必须存在
        XCTAssertNotNil(rendered.attribute(.link, at: 3, effectiveRange: nil))
        XCTAssertNotEqual(rendered.attribute(.foregroundColor, at: 3, effectiveRange: nil)
            as? NSColor, NSColor.textColor)
        // 序列化往返无损
        XCTAssertEqual(NotesMarkdown.serialize(rendered), md)
    }

    /// 详情页用 Text(AttributedString(render(...))) 展示:转换后 .link 必须保留。
    func testLinkSurvivesAttributedStringConversion() {
        let rendered = NotesMarkdown.render("前缀[链接](https://baidu.com)后缀")
        let converted = AttributedString(rendered)
        let hasLink = converted.runs.contains { $0.link != nil }
        XCTAssertTrue(hasLink, "AttributedString 转换后必须保留链接属性")
    }

    /// 模拟编辑器内真实状态:列表标记为普通样式、行内文字加粗,
    /// 序列化必须输出 "标记 **粗体**" 而不是吞掉标记或丢样式。
    func testSerializeKeepsStylesAlongsideListMarkers() {
        let plain = NSAttributedString(string: "1.\t", attributes: [:])
        let bold = NSAttributedString(string: "加粗项", attributes: [
            .font: NSFontManager.shared.convert(NSFont.systemFont(ofSize: 13), toHaveTrait: .boldFontMask),
        ])
        let storage = NSMutableAttributedString()
        storage.append(plain)
        storage.append(bold)

        let md = NotesMarkdown.serialize(storage)
        XCTAssertEqual(md, "1.\t**加粗项**")
        let font = NotesMarkdown.render(md).attribute(.font, at: 3, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false,
                      "重新渲染后第 4 个字符应为粗体")
    }

    /// 下划线 <u> 标记与斜体(obliqueness)必须持久化并能往返。
    func testUnderlineAndItalicPersistAndRoundTrip() {
        let md = "普通<u>下划线</u>与*斜体*和~~删除~~尾"
        let round = NotesMarkdown.serialize(NotesMarkdown.render(md))
        XCTAssertEqual(round, md)
    }

    /// 模拟编辑器内真实状态:obliqueness 斜体、underlineStyle 下划线,
    /// 序列化要输出对应标记(此前斜体无法经 NSFontManager 合成、下划线被丢弃)。
    func testSerializeObliquenessItalicAndUnderline() {
        let storage = NSMutableAttributedString()
        storage.append(NSAttributedString(string: "a"))
        storage.append(NSAttributedString(string: "斜", attributes: [.obliqueness: 0.25]))
        storage.append(NSAttributedString(string: "线", attributes: [
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]))
        XCTAssertEqual(NotesMarkdown.serialize(storage), "a*斜*<u>线</u>")
    }

    /// 斜体字体选择:西文 → 系统真斜体(SFNS-Italic);中文 → 楷体(中文排版
    /// 惯例,苹方等中文字体的 italic trait 会被 CoreText 静默忽略)。
    func testItalicFontSelection() {
        let latin = NotesMarkdown.italicFont(for: "English 123", size: 13, italic: true)
        XCTAssertTrue(NSFontManager.shared.traits(of: latin).contains(.italicFontMask), "西文应取系统真斜体")

        let cjk = NotesMarkdown.italicFont(for: "斜体中文", size: 13, italic: true)
        XCTAssertTrue(cjk.fontName.lowercased().contains("kaiti"), "中文应使用楷体替代斜体")

        let off = NotesMarkdown.italicFont(for: "中文English", size: 13, italic: false)
        XCTAssertEqual(off, NSFont.systemFont(ofSize: 13), "取消斜体应回到系统正体")
    }

    /// 中文斜体回归测试:楷体替代必须产生可见渲染差异;
    /// 取消斜体后渲染应与正体一致。
    func testItalicFallbackForCJKFont() {
        func snap(_ font: NSFont) -> Data {
            let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
            tv.textStorage?.setAttributedString(
                NSAttributedString(string: "测试斜体文本", attributes: [.font: font]))
            tv.layout()
            let rep = tv.bitmapImageRepForCachingDisplay(in: tv.bounds)!
            tv.cacheDisplay(in: tv.bounds, to: rep)
            // 用原始像素字节对比(TIFF 容器字节含非确定性元数据)
            let cg = rep.cgImage!
            return cg.dataProvider!.data! as Data
        }
        let regular = snap(.systemFont(ofSize: 13))
        let it = NotesMarkdown.italicFont(for: "测试斜体文本", size: 13, italic: true)
        XCTAssertNotEqual(snap(it), regular, "中文斜体(楷体)必须产生可见渲染差异")
        let back = NotesMarkdown.italicFont(for: "测试斜体文本", size: 13, italic: false)
        XCTAssertEqual(snap(back), regular, "取消斜体后应恢复正体渲染")
    }

    /// 下划线内嵌其他标记:渲染应递归解析(粗体保留)。
    func testUnderlineTokenRecursesInnerMarkers() {
        let rendered = NotesMarkdown.render("<u>**粗线**</u>")
        XCTAssertEqual(rendered.string, "粗线")
        let range = NSRange(location: 0, length: rendered.length)
        XCTAssertNotEqual(rendered.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int ?? 0, 0)
        let font = rendered.attribute(.font, at: 1, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false)
        XCTAssertTrue(range.length == 2)
    }
}
