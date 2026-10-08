import Foundation

/// App 自带资源的统一取包入口。
/// SPM 构建(swift build / Xcode 打开包)时资源随 target bundle(Bundle.module)
/// 分发;xcodeproj target 直接构建时资源进主包(.main)——两套构建都经此取用。
enum AppResources {
    static let bundle: Bundle = {
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        return .main
        #endif
    }()
}
