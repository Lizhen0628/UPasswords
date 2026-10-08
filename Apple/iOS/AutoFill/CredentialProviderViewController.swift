import AuthenticationServices
import SwiftUI

import UPasswordsCore

/// AutoFill 凭证提供程序扩展入口。
/// 用户在 Safari 等 App 的密码键盘栏选择 UPasswords 后,系统加载本控制器。
final class CredentialProviderViewController: ASCredentialProviderViewController {

    private let model = AutoFillModel()

    /// 展示凭证列表(按当前页面的服务标识做域名匹配与建议排序)。
    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        Log.info("app", "autofill: prepareCredentialList services=\(serviceIdentifiers.count)")
        model.attach(context: extensionContext, serviceIdentifiers: serviceIdentifiers)
        embed(AutoFillRootView(model: model))
    }

    /// iOS 17+ 通行密钥断言列表入口。
    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier],
                                        requestParameters: ASPasskeyCredentialRequestParameters) {
        Log.info("app", "autofill: prepareCredentialList passkey rp=\(requestParameters.relyingPartyIdentifier)")
        model.attachPasskeyList(context: extensionContext, params: requestParameters)
        embed(AutoFillRootView(model: model))
    }

    /// iOS 17+ 统一静默入口:本地加密库需解锁,一律转交互流程。
    override func provideCredentialWithoutUserInteraction(for credentialRequest: any ASCredentialRequest) {
        extensionContext.cancelRequest(withError: NSError(
            domain: ASExtensionErrorDomain,
            code: ASExtensionError.userInteractionRequired.rawValue))
    }

    /// iOS 17+ 指定请求交互入口(QuickType 选中或系统要求用户验证)。
    override func prepareInterfaceToProvideCredential(for credentialRequest: any ASCredentialRequest) {
        Log.info("app", "autofill: prepareInterfaceToProvideCredential request")
        model.attach(context: extensionContext, request: credentialRequest)
        embed(AutoFillRootView(model: model))
    }

    /// iOS 17+ 通行密钥注册入口。
    override func prepareInterface(forPasskeyRegistration registrationRequest: any ASCredentialRequest) {
        Log.info("app", "autofill: passkey registration entry")
        model.attachPasskeyRegistration(context: extensionContext, request: registrationRequest)
        embed(AutoFillRootView(model: model))
    }

    /// iOS 18+ 验证码填充入口:展示与当前页面匹配的一次性验证码(TOTP)列表。
    @available(iOS 18.0, *)
    override func prepareOneTimeCodeCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        Log.info("app", "autofill: prepareOneTimeCodeCredentialList services=\(serviceIdentifiers.count)")
        model.attach(context: extensionContext, serviceIdentifiers: serviceIdentifiers, flow: .oneTimeCode)
        embed(AutoFillRootView(model: model))
    }

    /// 本地加密库需主密码/生物验证,无法静默填充,交给交互流程。
    override func provideCredentialWithoutUserInteraction(for credentialIdentity: ASPasswordCredentialIdentity) {
        extensionContext.cancelRequest(withError: NSError(
            domain: ASExtensionErrorDomain,
            code: ASExtensionError.userInteractionRequired.rawValue))
    }

    private func embed<V: View>(_ rootView: V) {
        let host = UIHostingController(rootView: rootView)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
    }
}
