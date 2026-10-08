import Foundation
import ImageIO
import UIKit
import CryptoKit

import UPasswordsCore

/// 网站图标（favicon）抓取与归一化（与 macOS IconService 同一套约定）:
/// 1. 站点首页 HTML `<link rel=icon>` 解析 → 候选 URL;
/// 2. 兜底 `/favicon.ico`;
/// 3. 下载后经 ImageIO 解码（含 ICO）、缩放 ≤128×128 转 PNG,
///    归一化数据随卡片写入加密库（Card.iconData,XML base64）。
///
/// 隐私红线:请求不携带 Cookie,日志只记 host、字节长度与耗时;
/// 内存图片缓存键用数据 SHA-256 摘要（不含敏感可逆映射）。
enum IconService {

    // MARK: - Card.iconSource 词表（与 macOS 保持一致,随 XML 持久化）

    static let sourceWebsite = "website"
    static let sourceCustom = "custom"
    static let sourceURLPrefix = "url:"
    static let sourceBuiltinPrefix = "builtin:"

    /// 抓取/上传的图标统一缩到该边长以内（base64 后 XML 体积可控）。
    static let maxIconPixelSize = 128
    /// 解码图元边长上限,防解压炸弹。
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
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 "
                + "(KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1",
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
                  let png = normalizedIconData(raw) else { continue }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            Log.info("icons", "favicon fetched host=\(host) bytes=\(png.count) ms=\(ms)")
            return png
        }
        throw IconError.notFound
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

    // MARK: - HTML <link rel=icon> 解析（与 macOS 同规则）

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

    // MARK: - 解码与归一化（ImageIO:ICO/PNG/JPEG/BMP 全支持,无需手写 ICO 解码器）

    /// 任意图标原始数据 → ≤128×128 的 PNG（非图/损坏返回 nil）。
    static func normalizedIconData(_ raw: Data) -> Data? {
        guard let image = decodeImage(raw) else { return nil }
        return pngData(image, maxPixel: maxIconPixelSize)
    }

    /// 取最大帧解码（ICO 多帧取最大;其他格式单帧）。
    static func decodeImage(_ raw: Data) -> CGImage? {
        let srcCG = CGImageSourceCreateWithData(raw as CFData, nil)
        guard let src = srcCG, CGImageSourceGetCount(src) > 0 else { return nil }
        var best: (image: CGImage, dim: Int)? = nil
        for i in 0..<CGImageSourceGetCount(src) {
            guard let img = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            let dim = max(img.width, img.height)
            guard dim >= 8, dim <= maxSourcePixelSize else { continue }
            if best.map({ dim > $0.dim }) ?? true { best = (img, dim) }
        }
        return best?.image
    }

    /// 等比缩放绘制到 ≤maxPixel 的位图,输出 PNG。
    private static func pngData(_ image: CGImage, maxPixel: Int) -> Data? {
        let srcW = CGFloat(image.width), srcH = CGFloat(image.height)
        guard srcW > 0, srcH > 0 else { return nil }
        let scale = min(1, CGFloat(maxPixel) / max(srcW, srcH))
        let w = max(1, Int((srcW * scale).rounded()))
        let h = max(1, Int((srcH * scale).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1   // 图标按像素 1:1,不吃设备缩放
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format)
        let out = renderer.image { ctx in
            UIColor.white.withAlphaComponent(0).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            // 等比适配 + 居中（非方形图标不拉伸变形）
            let s = min(CGFloat(w) / CGFloat(srcW), CGFloat(h) / CGFloat(srcH))
            let dw = CGFloat(srcW) * s
            let dh = CGFloat(srcH) * s
            let rect = CGRect(x: (CGFloat(w) - dw) / 2, y: (CGFloat(h) - dh) / 2, width: dw, height: dh)
            ctx.cgContext.interpolationQuality = .high
            ctx.cgContext.draw(image, in: rect)
        }
        return out.pngData()
    }

    // MARK: - 展示缓存

    private static let imageCache = NSCache<NSString, UIImage>()

    /// 展示用 UIImage 缓存：键为数据的 SHA-256 前缀（无敏感可逆映射）。
    static func cachedImage(forData data: Data) -> UIImage? {
        let digest = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
        if let hit = imageCache.object(forKey: digest as NSString) { return hit }
        guard let img = UIImage(data: data) else { return nil }
        imageCache.setObject(img, forKey: digest as NSString)
        return img
    }
}
