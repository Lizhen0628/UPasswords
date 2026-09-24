import Foundation
import AppKit
import CryptoKit

/// 网站图标（favicon）抓取与图片归一化：
/// 1. 站点首页 HTML `<link rel=icon>` 解析 → 候选 URL;
/// 2. 兜底 `/favicon.ico`;
/// 3. 下载后解码（含 ICO:PNG 帧 + BMP 帧）、缩放到 ≤128×128 并转 PNG,
///    归一化后的数据随卡片写入加密数据库（Card.iconData）。
///
/// 隐私红线：请求不携带 Cookie,日志只记 host、字节长度与耗时;
/// 内存图片缓存的键用数据的 SHA-256 摘要（同 PasswordStrength.scoreCache 约定）。
enum IconService {

    // MARK: - Card.iconSource 词表（随 XML 持久化）

    static let sourceWebsite = "website"
    static let sourceCustom = "custom"
    static let sourceURLPrefix = "url:"
    static let sourceBuiltinPrefix = "builtin:"

    // MARK: - 常量

    /// 抓取/上传的图标统一缩到该边长以内（base64 后 XML 体积可控）。
    static let maxIconPixelSize = 128
    /// 解码图元的边长上限,防解压炸弹。
    private static let maxSourcePixelSize = 4096
    private static let maxHTMLBytes = 512 * 1024
    private static let maxImageBytes = 1024 * 1024
    /// 单站点最多尝试的候选图标 URL 数。
    private static let maxCandidates = 4
    private static let requestTimeout: TimeInterval = 8
    private static let resourceTimeout: TimeInterval = 25

    enum IconError: LocalizedError {
        case badURL
        case notFound
        case notAnImage

        var errorDescription: String? {
            switch self {
            case .badURL: return L10n.t("icon_url_invalid", fallback: "Invalid image URL.")
            case .notFound: return L10n.t("icon_fetch_failed", fallback: "Could not load a website icon.")
            case .notAnImage: return L10n.t("custom_icon_format_error")
            }
        }
    }

    // MARK: - 网址 → host

    /// 从卡片的网址字段值提取规范化 host："https://www.GitHub.com/x" → "github.com"。
    /// 无效输入（空、含空格、无点号）返回 nil。
    static func host(fromWebsite raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        var spec = trimmed
        if !spec.contains("://") { spec = "https://" + spec }
        guard let url = URL(string: spec), let host = url.host?.lowercased(), host.contains(".") else {
            return nil
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: - 抓取

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral   // 不落 Cookie/缓存,减少痕迹
        cfg.timeoutIntervalForRequest = requestTimeout
        cfg.timeoutIntervalForResource = resourceTimeout
        cfg.httpShouldSetCookies = false
        cfg.httpAdditionalHeaders = [
            // 部分站点对默认 UA 返回 403,用常规浏览器 UA
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
                + "(KHTML, like Gecko) Version/17.4 Safari/605.1.15",
        ]
        return URLSession(configuration: cfg)
    }()

    /// 抓取站点的最佳图标,返回归一化（≤128px PNG）数据。全候选失败抛 IconError.notFound。
    static func fetchFavicon(host: String) async throws -> Data {
        guard let base = URL(string: "https://\(host)") else { throw IconError.badURL }
        let started = Date()
        let htmlData = try? await fetchLimited(base, maxBytes: maxHTMLBytes, htmlOnly: true)
        let html = htmlData.flatMap { String(data: $0, encoding: .utf8) }
        var candidates = iconLinks(inHTML: html, baseURL: base)
        candidates.append(base.appendingPathComponent("favicon.ico"))
        for url in candidates.prefix(maxCandidates) {
            guard let raw = try? await fetchLimited(url, maxBytes: maxImageBytes, htmlOnly: false),
                  let png = await normalizedIconData(raw) else { continue }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            Log.info("icons", "favicon fetched host=\(host) bytes=\(png.count) ms=\(ms)")
            return png
        }
        throw IconError.notFound
    }

    /// 下载用户显式提供的图标 URL（图标选择器「使用 URL」）。非图片或超限抛错。
    static func fetchImage(at url: URL) async throws -> Data {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw IconError.badURL
        }
        let raw = try await fetchLimited(url, maxBytes: maxImageBytes, htmlOnly: false)
        guard let png = await normalizedIconData(raw) else { throw IconError.notAnImage }
        Log.info("icons", "image fetched host=\(url.host ?? "?") bytes=\(png.count)")
        return png
    }

    /// 带字节上限的 GET：状态码 2xx、可选强制 HTML、超限中断。
    private static func fetchLimited(_ url: URL, maxBytes: Int, htmlOnly: Bool) async throws -> Data {
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw IconError.notFound
        }
        if htmlOnly, let mime = response.mimeType?.lowercased(), !mime.hasPrefix("text/") {
            throw IconError.notFound
        }
        var buffer = [UInt8]()
        buffer.reserveCapacity(8192)
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count > maxBytes {
                Log.debug("icons", "download over limit url.host=\(url.host ?? "?") max=\(maxBytes)")
                throw IconError.notFound
            }
        }
        return Data(buffer)
    }

    // MARK: - HTML <link rel=icon> 解析

    /// 解析首页 HTML 里的图标候选,按 apple-touch > svg > 普通 icon（面积降序）> shortcut 排序。
    static func iconLinks(inHTML html: String?, baseURL: URL) -> [URL] {
        guard let html, let tagRe = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: [.caseInsensitive]) else {
            return []
        }
        let ns = html as NSString
        var found: [(url: URL, rank: Int, area: Int)] = []
        for m in tagRe.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: m.range)
            guard let href = attribute("href", in: tag) else { continue }
            let rel = (attribute("rel", in: tag) ?? "").lowercased()
            guard rel.contains("icon") else { continue }
            guard let url = URL(string: href, relativeTo: baseURL)?.absoluteURL else { continue }
            var rank = 1
            var area = 0
            if rel.contains("apple-touch") {
                rank = 4
            } else if href.lowercased().hasSuffix(".svg") {
                rank = 3
            } else if rel.contains("shortcut") {
                rank = 0
            }
            if let sizes = attribute("sizes", in: tag) {
                let dims = sizes.lowercased()
                    .split(whereSeparator: { $0 == "x" || $0 == " " })
                    .compactMap { Int($0) }
                if let w = dims.first, let h = dims.last { area = w * h }
            }
            found.append((url, rank, area))
        }
        return found
            .sorted { l, r in l.rank != r.rank ? l.rank > r.rank : l.area > r.area }
            .map(\.url)
    }

    /// 取标签里单个属性值（双引号/单引号/裸值）。
    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\\b\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = tag as NSString
        guard let m = re.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)) else { return nil }
        for i in 1..<m.numberOfRanges where m.range(at: i).location != NSNotFound {
            let v = ns.substring(with: m.range(at: i)).trimmingCharacters(in: .whitespaces)
            if !v.isEmpty { return v }
        }
        return nil
    }

    // MARK: - 解码与归一化

    /// 任意图标原始数据 → ≤128×128 的 PNG（非图/损坏返回 nil）。
    static func normalizedIconData(_ raw: Data) async -> Data? {
        guard let image = decodeImage(raw) else { return nil }
        return pngData(image, maxPixel: maxIconPixelSize)
    }

    /// ICO 走自解码器（AppKit 不识别 .ico）,其余交给 NSImage。
    static func decodeImage(_ raw: Data) -> NSImage? {
        if isICO(raw) {
            guard let img = ICODecoder.image(from: raw) else { return nil }
            return sizeOK(img) ? img : nil
        }
        guard let img = NSImage(data: raw), sizeOK(img) else { return nil }
        return img
    }

    private static func sizeOK(_ img: NSImage) -> Bool {
        guard !img.representations.isEmpty else { return false }
        let dim = max(img.size.width, img.size.height)
        return dim >= 8 && dim <= CGFloat(maxSourcePixelSize)
    }

    private static func isICO(_ data: Data) -> Bool {
        data.count > 4 && data[0] == 0 && data[1] == 0 && data[2] == 1 && data[3] == 0
    }

    /// 等比缩放绘制到 ≤maxPixel 的位图,输出 PNG。
    private static func pngData(_ image: NSImage, maxPixel: Int) -> Data? {
        let srcW = image.size.width, srcH = image.size.height
        guard srcW > 0, srcH > 0 else { return nil }
        let scale = min(1, CGFloat(maxPixel) / max(srcW, srcH))
        let w = max(1, Int((srcW * scale).rounded()))
        let h = max(1, Int((srcH * scale).rounded()))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: w, height: h)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        // 等比适配 + 居中（非方形图标不拉伸变形）
        let fit = aspectFitRect(content: NSSize(width: srcW, height: srcH), in: NSSize(width: w, height: h))
        image.draw(in: fit, from: .zero, operation: .sourceOver, fraction: 1.0,
                   respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    private static func aspectFitRect(content: NSSize, in bounds: NSSize) -> NSRect {
        guard content.width > 0, content.height > 0 else { return NSRect(origin: .zero, size: bounds) }
        let scale = min(bounds.width / content.width, bounds.height / content.height)
        let size = NSSize(width: content.width * scale, height: content.height * scale)
        let origin = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        return NSRect(origin: origin, size: size)
    }

    // MARK: - 展示缓存

    private static let imageCache = NSCache<NSString, NSImage>()

    /// 展示用 NSImage 缓存：键为数据的 SHA-256 前缀（无敏感可逆映射）。
    static func cachedImage(forData data: Data) -> NSImage? {
        let digest = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
        if let hit = imageCache.object(forKey: digest as NSString) { return hit }
        guard let img = NSImage(data: data) else { return nil }
        imageCache.setObject(img, forKey: digest as NSString)
        return img
    }
}

// MARK: - ICO 解码（PNG 帧 + 32/24bit BMP 帧）

/// 最小 ICO 解码:取最大帧;PNG 帧直接交给 NSImage,BMP 帧手工解 DIB。
/// 覆盖常见 favicon 场景,罕见色深返回 nil 走默认图标。
private enum ICODecoder {

    /// ICO 目录头 6 字节 + 每条目 16 字节。
    private static let headerSize = 6
    private static let entrySize = 16
    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]

    static func image(from data: Data) -> NSImage? {
        let bytes = [UInt8](data)
        guard bytes.count >= headerSize else { return nil }
        let count = Int(u16(bytes, 4))
        guard count > 0, bytes.count >= headerSize + count * entrySize else { return nil }

        var best: (offset: Int, length: Int, dim: Int)? = nil
        for i in 0..<count {
            let base = headerSize + i * entrySize
            let w = Int(bytes[base]) == 0 ? 256 : Int(bytes[base])
            let h = Int(bytes[base + 1]) == 0 ? 256 : Int(bytes[base + 1])
            let length = Int(u32(bytes, base + 8))
            let offset = Int(u32(bytes, base + 12))
            guard length > 0, offset >= 0, length <= bytes.count, offset <= bytes.count - length else { continue }
            let dim = w * h
            if best.map({ dim > $0.dim }) ?? true {
                best = (offset, length, dim)
            }
        }
        guard let frame = best else { return nil }
        let frameData = data.subdata(in: frame.offset..<(frame.offset + frame.length))
        if frameData.starts(with: pngSignature) {
            return NSImage(data: frameData)   // PNG 帧
        }
        return dibImage(from: frameData)      // BMP 帧
    }

    /// 解析 BITMAPINFOHEADER:32bpp 直接读 BGRA;24bpp 读 BGR + 行尾 AND 掩码补 alpha。
    private static func dibImage(from data: Data) -> NSImage? {
        let bytes = [UInt8](data)
        guard bytes.count >= 40 else { return nil }
        let headerSize = Int(u32(bytes, 0))
        guard headerSize >= 40 else { return nil }
        let width = Int(Int32(bitPattern: u32(bytes, 4)))
        let dibHeight = Int(Int32(bitPattern: u32(bytes, 8)))
        let planes = Int(u16(bytes, 12))
        let bitCount = Int(u16(bytes, 14))
        let compression = Int(u32(bytes, 16))
        guard width > 0, dibHeight > 0, compression == 0,
              bitCount == 32 || bitCount == 24, planes == 1 else { return nil }
        let height = dibHeight / 2   // ICO BMP 高度含 AND 掩码,XOR 区为一半
        let rowStride = ((width * bitCount + 31) / 32) * 4
        guard height > 0, height <= 512, width <= 512 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var allAlphaZero = true
        for y in 0..<height {
            // DIB 像素自底向上
            let rowStart = headerSize + (height - 1 - y) * rowStride
            guard rowStart + width * (bitCount / 8) <= bytes.count else { return nil }
            for x in 0..<width {
                let p = rowStart + x * (bitCount / 8)
                let o = (y * width + x) * 4
                pixels[o] = bytes[p + 2]       // R
                pixels[o + 1] = bytes[p + 1]   // G
                pixels[o + 2] = bytes[p]       // B
                if bitCount == 32 {
                    let a = bytes[p + 3]
                    if a != 0 { allAlphaZero = false }
                    pixels[o + 3] = a
                } else {
                    pixels[o + 3] = 255
                }
            }
        }
        // 32bpp 帧全零 alpha 时按不透明处理（部分生成器不写 alpha 字节）
        if bitCount == 32 && allAlphaZero {
            for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 255 }
        }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32),
            let dest = rep.bitmapData else { return nil }
        pixels.withUnsafeBytes { raw in
            // width/height 已保证非空,baseAddress 必有值
            guard let src = raw.baseAddress else { return }
            UnsafeMutableRawPointer(dest).copyMemory(from: src, byteCount: pixels.count)
        }
        let img = NSImage(size: NSSize(width: width, height: height))
        img.addRepresentation(rep)
        return img
    }

    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[i]) | (UInt16(b[i + 1]) << 8)
    }
    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
    }
}
