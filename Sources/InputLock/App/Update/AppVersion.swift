import Foundation

/// 语义化版本号：`major.minor.patch[.build][-prerelease][+metadata]`。
///
/// 用来比较本地 `CFBundleShortVersionString` 与 GitHub Release 的 tag（如 `v1.2.3`）。
/// - 允许前缀 `v` / `V`，`+` 之后的构建元数据会被忽略；
/// - 不足三段补 0（`1.2` == `1.2.0`），末尾多余的 0 段会被去掉（`1.2.3.0` == `1.2.3`）；
/// - 同一数字版本下，正式版高于预发布版（`1.0.0` > `1.0.0-beta.1`），
///   预发布标签按数字感知的方式比较（`beta.10` > `beta.2`）。
struct AppVersion: Comparable, CustomStringConvertible {

    /// 数字段，至少 3 段。
    let numbers: [Int]
    /// 预发布标签（`-` 之后的部分），正式版为 nil。
    let prerelease: String?

    init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") {
            text.removeFirst()
        }
        if let plus = text.firstIndex(of: "+") {
            text = String(text[..<plus])
        }

        var prerelease: String?
        if let dash = text.firstIndex(of: "-") {
            let tag = String(text[text.index(after: dash)...])
            guard !tag.isEmpty else { return nil }
            prerelease = tag
            text = String(text[..<dash])
        }

        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }

        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty,
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part) else { return nil }
            numbers.append(value)
        }
        while numbers.count < 3 { numbers.append(0) }
        while numbers.count > 3, numbers.last == 0 { numbers.removeLast() }

        self.numbers = numbers
        self.prerelease = prerelease
    }

    /// 当前运行的 App 版本；直接跑 `.build` 下的裸二进制时没有 Info.plist，返回 nil。
    static func current(bundle: Bundle = .main) -> AppVersion? {
        guard let raw = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return nil
        }
        return AppVersion(raw)
    }

    var isPrerelease: Bool { prerelease != nil }

    var description: String {
        let core = numbers.map(String.init).joined(separator: ".")
        if let prerelease { return "\(core)-\(prerelease)" }
        return core
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.numbers.count, rhs.numbers.count)
        for index in 0..<count {
            let left = index < lhs.numbers.count ? lhs.numbers[index] : 0
            let right = index < rhs.numbers.count ? rhs.numbers[index] : 0
            if left != right { return left < right }
        }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return false                                   // 数字全相同且都是正式版
        case (nil, .some):
            return false                                   // 正式版 > 预发布版
        case (.some, nil):
            return true                                    // 预发布版 < 正式版
        case let (.some(left), .some(right)):
            return left.compare(right, options: [.numeric, .caseInsensitive]) == .orderedAscending
        }
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}
