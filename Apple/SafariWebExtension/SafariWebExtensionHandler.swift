import Foundation

import UPasswordsCore

/// Safari Web Extension 的原生消息入口。
/// 前端脚本经 browser.runtime.sendNativeMessage 发来的请求在此分发;
/// 当前阶段仅回显握手消息,凭据查询在后续迭代接入本地加密库。
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private let messageTypeKey = "message"

    func beginRequest(with context: NSExtensionContext) {
        let item = NSExtensionItem()
        item.userInfo = [
            "response": [
                "received": true,
                "message": "UPasswords extension ready",
            ]
        ]
        context.completeRequest(returningItems: [item], completionHandler: nil)
        Log.debug("chrome", "safari native message handler beginRequest")
    }
}
