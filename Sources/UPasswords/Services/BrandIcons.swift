import Foundation
import AppKit

/// 内置常见网站/服务品牌图标目录（第 2 层兜底:网址抓取失败时按域名/标题匹配）。
///
/// 与 SymbolModel 同一约定:不附带原厂商标图,图标由品牌色圆角方砖 + SF Symbol /
/// 字母花押在本地绘制;如需替换为真实图稿,把 `<key>.png` 放进 Resources/ 即可
/// （运行时优先读取 Bundle 内同名 PNG,读取失败回退到程序绘制）。
///
/// 匹配顺序（BrandIcons.match）:
/// 1. host 与 domains 精确/后缀匹配（"www.alipay.com" → "alipay.com"）;
/// 2. 卡片标题包含任一 keyword（"微信支付" → wechat）。
enum BrandIcons {

    struct Entry: Identifiable, Equatable {
        let key: String
        let hex: UInt32            // 方砖底色
        let domains: [String]
        let keywords: [String]
        let glyph: Glyph

        var id: String { key }

        init(_ key: String, _ hex: UInt32, domains: [String], keywords: [String] = [], _ glyph: Glyph) {
            self.key = key
            self.hex = hex
            self.domains = domains
            self.keywords = keywords
            self.glyph = glyph
        }
    }

    enum Glyph: Equatable {
        case sf(String)          // SF Symbol 名
        case monogram(String)    // 字母/文字花押
    }

    // MARK: - 目录

    static let all: [Entry] = [
        // 国际互联网
        Entry("google", 0x4285F4, domains: ["google.com", "gmail.com", "googlemail.com", "youtube.com", "youtu.be"],
              keywords: ["google", "谷歌"], .monogram("G")),
        Entry("youtube", 0xFF0000, domains: ["youtube.com", "youtu.be"], keywords: ["youtube", "油管"], .sf("play.rectangle.fill")),
        Entry("apple", 0x111111, domains: ["apple.com", "icloud.com"], keywords: ["apple", "icloud", "苹果"], .sf("apple.logo")),
        Entry("microsoft", 0x00A4EF, domains: ["microsoft.com", "live.com", "office.com", "outlook.com", "hotmail.com", "xbox.com", "onedrive.com"],
              keywords: ["microsoft", "outlook", "office", "xbox", "微软"], .sf("square.grid.2x2.fill")),
        Entry("github", 0x24292F, domains: ["github.com", "github.io", "githubusercontent.com"],
              keywords: ["github"], .monogram("G")),
        Entry("gitlab", 0xFC6D26, domains: ["gitlab.com"], keywords: ["gitlab"], .sf("arrow.triangle.branch")),
        Entry("x", 0x1D9BF0, domains: ["x.com", "twitter.com"], keywords: ["twitter", "推特"], .monogram("X")),
        Entry("facebook", 0x1877F2, domains: ["facebook.com"], keywords: ["facebook", "脸书"], .monogram("f")),
        Entry("instagram", 0xD6249F, domains: ["instagram.com"], keywords: ["instagram"], .sf("camera.fill")),
        Entry("telegram", 0x229ED9, domains: ["telegram.org", "t.me", "telegram.me"], keywords: ["telegram", "电报"], .sf("paperplane.fill")),
        Entry("whatsapp", 0x25D366, domains: ["whatsapp.com"], keywords: ["whatsapp"], .sf("phone.circle.fill")),
        Entry("reddit", 0xFF4500, domains: ["reddit.com"], keywords: ["reddit"], .sf("bubble.left.and.bubble.right.fill")),
        Entry("linkedin", 0x0A66C2, domains: ["linkedin.com"], keywords: ["linkedin", "领英"], .monogram("in")),
        Entry("netflix", 0xE50914, domains: ["netflix.com"], keywords: ["netflix"], .monogram("N")),
        Entry("spotify", 0x1DB954, domains: ["spotify.com"], keywords: ["spotify"], .sf("music.note")),
        Entry("discord", 0x5865F2, domains: ["discord.com", "discord.gg"], keywords: ["discord"], .sf("gamecontroller.fill")),
        Entry("amazon", 0xFF9900, domains: ["amazon.com", "amazon.de", "amazon.co.uk", "amazon.co.jp", "amazon.cn", "amazon.in"],
              keywords: ["amazon", "亚马逊"], .sf("cart.fill")),
        Entry("paypal", 0x003087, domains: ["paypal.com"], keywords: ["paypal"], .sf("dollarsign.circle.fill")),
        Entry("dropbox", 0x0061FF, domains: ["dropbox.com"], keywords: ["dropbox"], .sf("square.stack.3d.up.fill")),
        Entry("slack", 0x611F69, domains: ["slack.com"], keywords: ["slack"], .sf("number")),
        Entry("zoom", 0x2D8CFF, domains: ["zoom.us"], keywords: ["zoom"], .sf("video.fill")),
        Entry("notion", 0x333333, domains: ["notion.so"], keywords: ["notion"], .monogram("N")),
        Entry("steam", 0x171A21, domains: ["steampowered.com", "steamcommunity.com"], keywords: ["steam"], .monogram("S")),
        Entry("pinterest", 0xE60023, domains: ["pinterest.com"], keywords: ["pinterest"], .monogram("P")),
        // 中国互联网
        Entry("wechat", 0x07C160, domains: ["weixin.qq.com", "wechat.com"], keywords: ["wechat", "weixin", "微信"], .sf("message.fill")),
        Entry("alipay", 0x1677FF, domains: ["alipay.com", "alipayplus.com"], keywords: ["alipay", "支付宝"], .monogram("支")),
        Entry("qq", 0x12B7F5, domains: ["qq.com", "tencent.com", "gtimg.com"], keywords: ["tencent", "腾讯", "qq"], .monogram("QQ")),
        Entry("weibo", 0xE6162D, domains: ["weibo.com", "weibo.cn"], keywords: ["weibo", "微博"], .monogram("博")),
        Entry("bilibili", 0xFB7299, domains: ["bilibili.com", "bilivideo.com"], keywords: ["bilibili", "b站", "哔哩"], .monogram("B")),
        Entry("douyin", 0x161823, domains: ["douyin.com", "tiktok.com", "douyinpic.com"], keywords: ["douyin", "tiktok", "抖音"], .sf("music.note")),
        Entry("taobao", 0xFF5E00, domains: ["taobao.com", "tmall.com"], keywords: ["taobao", "淘宝", "天猫"], .monogram("淘")),
        Entry("jd", 0xE1251B, domains: ["jd.com", "360buy.com", "jd.hk"], keywords: ["京东"], .monogram("JD")),
        Entry("pinduoduo", 0xE02E24, domains: ["pinduoduo.com", "yangkeduo.com"], keywords: ["pinduoduo", "拼多多"], .monogram("拼")),
        Entry("zhihu", 0x0084FF, domains: ["zhihu.com"], keywords: ["zhihu", "知乎"], .monogram("知")),
        Entry("baidu", 0x2932E1, domains: ["baidu.com", "baidupan.com", "bcebos.com"], keywords: ["baidu", "百度"], .monogram("百")),
        Entry("netease", 0xD43C33, domains: ["163.com", "126.com", "netease.com", "netease.im"], keywords: ["netease", "网易"], .monogram("易")),
        Entry("xiaomi", 0xFF6900, domains: ["xiaomi.com", "mi.com", "miliao.com"], keywords: ["xiaomi", "小米"], .monogram("MI")),
        Entry("huawei", 0xCE0E2D, domains: ["huawei.com", "vmall.com"], keywords: ["huawei", "华为"], .monogram("华")),
    ]

    // MARK: - 查询

    static func entry(for key: String) -> Entry? {
        all.first { $0.key == key }
    }

    /// 域名 → 标题的两级匹配;都没有返回 nil（调用方落回默认符号图标）。
    /// - Parameters:
    ///   - host: 规范化 host（IconService.host(fromWebsite:) 的输出,已去 www.）
    ///   - title: 卡片标题（大小写不敏感的包含匹配）
    static func match(host: String?, title: String) -> Entry? {
        if let h = host?.lowercased() {
            for e in all where e.domains.contains(where: { h == $0 || h.hasSuffix(".\($0)") }) {
                return e
            }
        }
        let t = title.lowercased()
        for e in all where e.keywords.contains(where: { t.contains($0) }) {
            return e
        }
        return nil
    }

    // MARK: - 可选图稿覆盖

    /// `<key>.png` 图稿替换入口:资源在则优先使用（不随构建强校验）。
    static func bundledImage(for key: String) -> NSImage? {
        guard let url = Bundle.module.url(forResource: key, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
}
