import XCTest
import AppKit
@testable import UPasswords

final class IconTests: XCTestCase {

    // MARK: - host 规范化

    func testHostNormalization() {
        XCTAssertEqual(IconService.host(fromWebsite: "https://www.GitHub.com/user/repo"), "github.com")
        XCTAssertEqual(IconService.host(fromWebsite: "https://github.com"), "github.com")
        XCTAssertEqual(IconService.host(fromWebsite: "github.com/path"), "github.com")
        XCTAssertEqual(IconService.host(fromWebsite: "  alipay.com  "), "alipay.com")
        XCTAssertEqual(IconService.host(fromWebsite: "http://weibo.cn"), "weibo.cn")
        XCTAssertNil(IconService.host(fromWebsite: ""))
        XCTAssertNil(IconService.host(fromWebsite: "   "))
        XCTAssertNil(IconService.host(fromWebsite: "github com"))
        XCTAssertNil(IconService.host(fromWebsite: "localhost"))
    }

    // MARK: - 内置品牌匹配

    func testBrandMatchByDomain() {
        XCTAssertEqual(BrandIcons.match(host: "www.alipay.com", title: "支付")?.key, "alipay")
        XCTAssertEqual(BrandIcons.match(host: "alipay.com", title: "")?.key, "alipay")
        XCTAssertEqual(BrandIcons.match(host: "mail.qq.com", title: "")?.key, "qq")
        XCTAssertEqual(BrandIcons.match(host: "github.com", title: "")?.key, "github")
        XCTAssertEqual(BrandIcons.match(host: "gist.github.com", title: "")?.key, "github")
        // 相似但不同的域不误匹配
        XCTAssertNotEqual(BrandIcons.match(host: "notalipay.com", title: "")?.key, "alipay")
    }

    func testBrandMatchByTitle() {
        XCTAssertEqual(BrandIcons.match(host: nil, title: "微信支付")?.key, "wechat")
        XCTAssertEqual(BrandIcons.match(host: nil, title: "My GitHub Account")?.key, "github")
        XCTAssertEqual(BrandIcons.match(host: "example.org", title: "支付宝账户")?.key, "alipay")
        XCTAssertNil(BrandIcons.match(host: "example.org", title: "家里路由器"))
    }

    func testBuiltinEntryLookup() {
        XCTAssertNotNil(BrandIcons.entry(for: "wechat"))
        XCTAssertNil(BrandIcons.entry(for: "nope"))
        XCTAssertTrue(BrandIcons.all.count >= 30, "常见站点目录不应为空")
    }

    // MARK: - XML 持久化往返

    func testIconXMLRoundTrip() throws {
        var card = Card(id: 7)
        card.title = "GitHub"
        card.iconSource = IconService.sourceWebsite
        card.iconData = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        var db = PasswordDatabase()
        db.cards = [card]

        let parsed = try PasswordDatabase.parse(db.xmlData())
        XCTAssertEqual(parsed.cards.count, 1)
        XCTAssertEqual(parsed.cards[0].iconSource, IconService.sourceWebsite)
        XCTAssertEqual(parsed.cards[0].iconData, card.iconData)
    }

    func testBuiltinIconXMLRoundTripWithoutData() throws {
        var card = Card(id: 8)
        card.iconSource = IconService.sourceBuiltinPrefix + "wechat"
        var db = PasswordDatabase()
        db.cards = [card]

        let parsed = try PasswordDatabase.parse(db.xmlData())
        XCTAssertEqual(parsed.cards[0].iconSource, "builtin:wechat")
        XCTAssertNil(parsed.cards[0].iconData)
    }

    func testLegacyXMLWithoutIconParsesToNil() throws {
        let xml = Data("<?xml version=\"1.0\"?><database><card title=\"Old\" id=\"3\"/></database>".utf8)
        let parsed = try PasswordDatabase.parse(xml)
        XCTAssertNil(parsed.cards[0].iconSource)
        XCTAssertNil(parsed.cards[0].iconData)
    }

    // MARK: - 图片归一化

    /// 生成纯色 PNG 数据。
    private func solidPNG(width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep!)
        NSColor.red.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep!.representation(using: .png, properties: [:])!
    }

    func testNormalizedIconDownscalesLargeImage() async {
        let png = solidPNG(width: 512, height: 512)
        let normalized = await IconService.normalizedIconData(png)
        XCTAssertNotNil(normalized)
        let img = NSImage(data: normalized!)
        XCTAssertNotNil(img)
        XCTAssertLessThanOrEqual(max(img!.size.width, img!.size.height), CGFloat(IconService.maxIconPixelSize))
        XCTAssertLessThan(normalized!.count, png.count, "归一化后应明显小于原图")
    }

    func testNormalizedIconRejectsGarbage() async {
        let normalized = await IconService.normalizedIconData(Data("not an image".utf8))
        XCTAssertNil(normalized)
    }

    // MARK: - ICO 解码

    /// 把 PNG 帧包进 ICO 容器(经典 favicon.ico 就是这种结构)。
    private func icoWrapping(png: Data, dimension: Int) -> Data {
        var out = Data()
        out.append(contentsOf: [0, 0, 1, 0, 1, 0])          // reserved=0, type=1(icon), count=1
        out.append(UInt8(dimension >= 256 ? 0 : dimension)) // width
        out.append(UInt8(dimension >= 256 ? 0 : dimension)) // height
        out.append(contentsOf: [0, 0])                      // color count, reserved
        out.append(contentsOf: [1, 0])                      // planes
        out.append(contentsOf: [32, 0])                     // bit count
        var len = UInt32(png.count)
        var off = UInt32(6 + 16)
        out.append(contentsOf: withUnsafeBytes(of: &len) { Data($0) })
        out.append(contentsOf: withUnsafeBytes(of: &off) { Data($0) })
        out.append(png)
        return out
    }

    func testICODecoderPNGFrame() throws {
        let png = solidPNG(width: 32, height: 32)
        let ico = icoWrapping(png: png, dimension: 32)
        let img = try XCTUnwrap(IconService.decodeImage(ico), "PNG 帧的 ICO 必须能解码")
        XCTAssertEqual(img.size.width, 32)
    }

    func testICODecoderBMPFrame32bpp() throws {
        // 手工构造 16×16 的 32bpp DIB 帧(BGRA、自底向上、alpha 有效)
        let side = 16
        let stride = side * 4
        var dib = Data()
        func appendU32(_ v: UInt32) {
            withUnsafeBytes(of: v.littleEndian) { dib.append(contentsOf: $0) }
        }
        appendU32(40)           // biSize
        appendU32(UInt32(side)) // width
        appendU32(UInt32(side * 2)) // height(XOR+AND)
        dib.append(contentsOf: [1, 0])    // planes = 1 (WORD)
        dib.append(contentsOf: [32, 0])   // bitCount = 32 (WORD)
        appendU32(0)            // BI_RGB
        dib.append(contentsOf: [UInt8](repeating: 0, count: 20)) // 头部其余字段补到 40 字节
        var pixels = Data()
        for _ in 0..<(side * side) {
            pixels.append(contentsOf: [0x00, 0x00, 0xFF, 0xFF]) // 蓝色不透明(BGR)
        }
        dib.append(pixels)
        dib.append(Data(repeating: 0, count: stride * side / 8)) // AND 掩码

        var ico = Data()
        ico.append(contentsOf: [0, 0, 1, 0, 1, 0])
        ico.append(UInt8(side))
        ico.append(UInt8(side))
        ico.append(contentsOf: [0, 0, 1, 0, 32, 0])
        ico.append(contentsOf: withUnsafeBytes(of: UInt32(dib.count).littleEndian) { Data($0) })
        ico.append(contentsOf: withUnsafeBytes(of: UInt32(6 + 16).littleEndian) { Data($0) })
        ico.append(dib)

        let img = try XCTUnwrap(IconService.decodeImage(ico), "BMP 帧的 ICO 必须能解码")
        XCTAssertEqual(img.size.width, CGFloat(side))
    }

    func testICODecoderRejectsTruncated() {
        var ico = Data()
        ico.append(contentsOf: [0, 0, 1, 0, 3, 0])   // 声称 3 帧,数据为空
        XCTAssertNil(IconService.decodeImage(ico))
    }

    // MARK: - HTML link 解析

    func testIconLinkParsingRanking() {
        let html = """
        <html><head>
        <link rel="shortcut icon" href="/fav.ico">
        <LINK REL="ICON" HREF='/icon-64.png' sizes="64x64">
        <link rel="apple-touch-icon" href="/touch.png">
        <link rel="icon" href="https://cdn.example.org/svg/logo.svg" type="image/svg+xml">
        <link rel="stylesheet" href="/style.css">
        </head></html>
        """
        let links = IconService.iconLinks(inHTML: html, baseURL: URL(string: "https://example.org")!)
        XCTAssertEqual(links.count, 4)
        XCTAssertEqual(links.first, URL(string: "https://example.org/touch.png"))
        XCTAssertTrue(links.contains(URL(string: "https://cdn.example.org/svg/logo.svg")!))
        XCTAssertFalse(links.contains(URL(string: "https://example.org/style.css")!))
    }

    func testIconLinkParsingNilHTML() {
        XCTAssertTrue(IconService.iconLinks(inHTML: nil, baseURL: URL(string: "https://example.org")!).isEmpty)
    }

    // MARK: - iconSource 辅助

    func testIconSourceHelpers() {
        var card = Card(id: 1)
        XCTAssertFalse(card.iconIsFromWebsite)
        XCTAssertFalse(card.iconIsUserExplicit)
        XCTAssertNil(card.iconBuiltinKey)

        card.iconSource = IconService.sourceURLPrefix + "https://x.org/i.png"
        card.iconData = Data([1])
        XCTAssertTrue(card.iconIsFromUserURL)
        XCTAssertTrue(card.iconIsUserExplicit)

        card.iconSource = IconService.sourceBuiltinPrefix + "telegram"
        card.iconData = nil
        XCTAssertEqual(card.iconBuiltinKey, "telegram")
    }
}
