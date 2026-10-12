import UIKit

import UPasswordsCore

/// 设备展示名:营销型号 + 用户命名(如 "iPhone 13 · 李振的 iPhone")。
/// 云同步「管理设备」以此区分多台同类设备;未知新型号回退硬件标识
/// (仍是可区分的稳定信息),模拟器标注为模拟器。
enum DeviceIdentity {

    static func displayName() -> String {
        let hw = hardwareIdentifier()
        let marketing = marketingName(for: hw) ?? hw
        return "\(marketing) · \(UIDevice.current.name)"
    }

    /// utsname.machine(如 "iPhone14,5";模拟器为 "arm64"/"x86_64")。
    private static func hardwareIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return Mirror(reflecting: systemInfo.machine).children.reduce(into: "") { id, child in
            guard let value = child.value as? Int8, value != 0 else { return }
            id.append(Character(UnicodeScalar(UInt8(value))))
        }
    }

    /// 硬件标识 → 营销型号。未收录的新型号返回 nil(调用方回退硬件标识)。
    private static func marketingName(for hw: String) -> String? {
        if hw.contains("arm64") || hw.contains("x86") { return L10n.t("ios_device_name_simulator") }
        return iPhoneModels[hw] ?? iPadModels[hw]
    }

    private static let iPhoneModels: [String: String] = [
        "iPhone8,1": "iPhone 6s", "iPhone8,2": "iPhone 6s Plus", "iPhone8,4": "iPhone SE (1st)",
        "iPhone9,1": "iPhone 7", "iPhone9,3": "iPhone 7",
        "iPhone9,2": "iPhone 7 Plus", "iPhone9,4": "iPhone 7 Plus",
        "iPhone10,1": "iPhone 8", "iPhone10,4": "iPhone 8",
        "iPhone10,2": "iPhone 8 Plus", "iPhone10,5": "iPhone 8 Plus",
        "iPhone10,3": "iPhone X", "iPhone10,6": "iPhone X",
        "iPhone11,2": "iPhone XS", "iPhone11,4": "iPhone XS Max", "iPhone11,6": "iPhone XS Max",
        "iPhone11,8": "iPhone XR",
        "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max",
        "iPhone12,8": "iPhone SE (2nd)",
        "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12",
        "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13",
        "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max",
        "iPhone14,6": "iPhone SE (3rd)",
        "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus",
        "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,5": "iPhone 16e",
        "iPhone18,1": "iPhone 17", "iPhone18,2": "iPhone 17 Pro",
        "iPhone18,3": "iPhone 17 Pro Max", "iPhone18,4": "iPhone Air",
    ]

    private static let iPadModels: [String: String] = [
        "iPad5,1": "iPad mini 4", "iPad5,2": "iPad mini 4",
        "iPad5,3": "iPad Air 2", "iPad5,4": "iPad Air 2",
        "iPad6,3": "iPad Pro 9.7", "iPad6,4": "iPad Pro 9.7",
        "iPad6,7": "iPad Pro 12.9", "iPad6,8": "iPad Pro 12.9",
        "iPad6,11": "iPad (5th)", "iPad6,12": "iPad (5th)",
        "iPad7,1": "iPad Pro 12.9 (2nd)", "iPad7,2": "iPad Pro 12.9 (2nd)",
        "iPad7,3": "iPad Pro 10.5", "iPad7,4": "iPad Pro 10.5",
        "iPad7,5": "iPad (6th)", "iPad7,6": "iPad (6th)",
        "iPad7,11": "iPad (7th)", "iPad7,12": "iPad (7th)",
        "iPad8,1": "iPad Pro 11", "iPad8,2": "iPad Pro 11", "iPad8,3": "iPad Pro 11", "iPad8,4": "iPad Pro 11",
        "iPad8,5": "iPad Pro 12.9 (3rd)", "iPad8,6": "iPad Pro 12.9 (3rd)",
        "iPad8,7": "iPad Pro 12.9 (3rd)", "iPad8,8": "iPad Pro 12.9 (3rd)",
        "iPad8,9": "iPad Pro 11 (2nd)", "iPad8,10": "iPad Pro 11 (2nd)",
        "iPad8,11": "iPad Pro 12.9 (4th)", "iPad8,12": "iPad Pro 12.9 (4th)",
        "iPad11,1": "iPad mini (5th)", "iPad11,2": "iPad mini (5th)",
        "iPad11,3": "iPad Air (3rd)", "iPad11,4": "iPad Air (3rd)",
        "iPad12,1": "iPad (8th)", "iPad12,2": "iPad (8th)",
        "iPad13,1": "iPad Air (4th)", "iPad13,2": "iPad Air (4th)",
        "iPad13,4": "iPad Pro 11 (3rd)", "iPad13,5": "iPad Pro 11 (3rd)",
        "iPad13,6": "iPad Pro 11 (3rd)", "iPad13,7": "iPad Pro 11 (3rd)",
        "iPad13,8": "iPad Pro 12.9 (5th)", "iPad13,9": "iPad Pro 12.9 (5th)",
        "iPad13,10": "iPad Pro 12.9 (5th)", "iPad13,11": "iPad Pro 12.9 (5th)",
        "iPad13,16": "iPad Air (5th)", "iPad13,17": "iPad Air (5th)",
        "iPad13,18": "iPad (10th)", "iPad13,19": "iPad (10th)",
        "iPad14,1": "iPad mini (6th)", "iPad14,2": "iPad mini (6th)",
        "iPad14,3": "iPad Air (6th)", "iPad14,4": "iPad Air (6th)",
        "iPad14,5": "iPad Pro 11 (4th)", "iPad14,6": "iPad Pro 11 (4th)",
        "iPad14,7": "iPad Pro 12.9 (6th)", "iPad14,8": "iPad Pro 12.9 (6th)",
        "iPad15,7": "iPad (11th)", "iPad15,8": "iPad (11th)",
        "iPad16,1": "iPad Pro 13 (M4)", "iPad16,2": "iPad Pro 13 (M4)",
        "iPad16,3": "iPad Pro 11 (M4)", "iPad16,4": "iPad Pro 11 (M4)",
    ]
}
