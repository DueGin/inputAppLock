import Foundation

// MARK: - GitHub Release 数据

struct ReleaseAsset: Decodable, Equatable {
    let name: String
    let downloadURL: URL
    let size: Int

    private enum CodingKeys: String, CodingKey {
        case name
        case downloadURL = "browser_download_url"
        case size
    }
}

struct GitHubRelease: Decodable, Equatable {
    let tagName: String
    let name: String?
    let body: String?
    let pageURL: URL
    let isDraft: Bool
    let isPrerelease: Bool
    let publishedAt: Date?
    let assets: [ReleaseAsset]

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case pageURL = "html_url"
        case isDraft = "draft"
        case isPrerelease = "prerelease"
        case publishedAt = "published_at"
        case assets
    }

    static func decode(from data: Data) throws -> GitHubRelease {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GitHubRelease.self, from: data)
    }
}

/// 一个可以安装的新版本：版本号 + 安装包 + 校验文件。
struct AvailableUpdate: Equatable {
    let version: AppVersion
    let release: GitHubRelease
    let installer: ReleaseAsset
    let checksum: ReleaseAsset?
}

enum UpdateCheckResult: Equatable {
    case upToDate(latest: AppVersion)
    case available(AvailableUpdate)
}

// MARK: - 更新源

/// 更新从哪里来：GitHub 仓库 `owner/repo`。
///
/// 默认读 Info.plist 的 `InputLockUpdateRepository`，缺省时用上游仓库，fork 改一下 plist 就能指向自己的 Release。
struct UpdateSource: Equatable {
    static let infoPlistKey = "InputLockUpdateRepository"
    static let defaultRepository = "DueGin/inputAppLock"

    let repository: String

    static func fromBundle(_ bundle: Bundle = .main) -> UpdateSource {
        let configured = (bundle.object(forInfoDictionaryKey: infoPlistKey) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let configured, isValidRepository(configured) {
            return UpdateSource(repository: configured)
        }
        return UpdateSource(repository: defaultRepository)
    }

    /// 只接受 `owner/repo`，两段都只能是 GitHub 允许的字符；保证下面拼出来的 URL 一定合法。
    static func isValidRepository(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        return parts.allSatisfy { part in
            !part.isEmpty && part != "." && part != ".."
                && part.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
    }

    /// `releases/latest` 只返回最新的正式版（自动排除 draft 和 prerelease）。
    var latestReleaseAPI: URL {
        URL(string: "https://api.github.com/repos/\(repository)/releases/latest")
            ?? URL(string: "https://api.github.com/repos/\(Self.defaultRepository)/releases/latest")!
    }

    var releasesPage: URL {
        URL(string: "https://github.com/\(repository)/releases")
            ?? URL(string: "https://github.com/\(Self.defaultRepository)/releases")!
    }

    /// 下载地址必须是 https，并且指向 GitHub 自己的域名（Release 资产会被重定向到 githubusercontent）。
    static func isTrustedDownloadURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host.hasSuffix(".github.com") || host.hasSuffix(".githubusercontent.com")
    }
}

// MARK: - 判断是否有新版本

enum UpdateEvaluator {

    /// 发版脚本产出的安装包名：`InputLock-<version>.dmg`。
    static func installerAssetName(appName: String, tag: String) -> String {
        let version = tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
        return "\(appName)-\(version).dmg"
    }

    /// 纯函数：拿最新 Release 和当前版本比较，决定有没有可安装的新版本。
    static func evaluate(
        release: GitHubRelease,
        current: AppVersion,
        appName: String = "InputLock"
    ) throws -> UpdateCheckResult {
        guard let latest = AppVersion(release.tagName) else {
            throw UpdateError.invalidReleaseTag(release.tagName)
        }
        // 防御：即便接口哪天返回了 draft / prerelease，也不推给用户。
        // tag 本身带预发布后缀（如 v1.1.0-beta.1）但发版时没勾 prerelease 的，同样不推给正式版用户；
        // 自己就在用预发布版的用户才会收到。
        let unstable = release.isDraft || release.isPrerelease || (latest.isPrerelease && !current.isPrerelease)
        guard !unstable, latest > current else {
            return .upToDate(latest: latest)
        }

        let expectedName = installerAssetName(appName: appName, tag: release.tagName)
        let installer = release.assets.first { $0.name == expectedName }
            ?? release.assets.first {
                $0.name.hasPrefix("\(appName)-") && $0.name.lowercased().hasSuffix(".dmg")
            }
        guard let installer else {
            throw UpdateError.installerAssetMissing(version: latest.description)
        }
        guard UpdateSource.isTrustedDownloadURL(installer.downloadURL) else {
            throw UpdateError.untrustedDownload(installer.downloadURL.absoluteString)
        }
        let checksum = release.assets.first {
            $0.name == installer.name + ".sha256" && UpdateSource.isTrustedDownloadURL($0.downloadURL)
        }

        return .available(AvailableUpdate(
            version: latest,
            release: release,
            installer: installer,
            checksum: checksum
        ))
    }
}

// MARK: - 错误

enum UpdateError: LocalizedError, Equatable {
    case notRunningFromAppBundle
    case appTranslocated
    case destinationNotWritable(path: String)
    case httpStatus(Int)
    case rateLimited
    case noPublishedRelease
    case invalidReleaseTag(String)
    case installerAssetMissing(version: String)
    case checksumAssetMissing
    case checksumUnreadable
    case checksumMismatch(expected: String, actual: String)
    case mountFailed(String)
    case appNotFoundInImage
    case bundleMismatch(String)
    case signatureInvalid(String)
    case incompatible(String)
    case untrustedDownload(String)
    case downloadTooLarge
    case stagingFailed(String)

    var errorDescription: String? {
        switch self {
        case .notRunningFromAppBundle:
            return "当前不是以 InputLock.app 运行（例如直接运行了编译出的二进制），无法自动替换。"
        case .appTranslocated:
            return "InputLock 正在从系统的隔离位置运行（App Translocation），无法原地替换。请先把 InputLock 拖进「应用程序」文件夹再打开。"
        case .destinationNotWritable(let path):
            return "没有写入权限：\(path)。请手动下载安装包覆盖安装。"
        case .httpStatus(let code):
            return "GitHub 返回了 HTTP \(code)。"
        case .rateLimited:
            return "GitHub API 请求次数已达上限，请过一会儿再试。"
        case .noPublishedRelease:
            return "还没有找到已发布的正式版本。"
        case .invalidReleaseTag(let tag):
            return "无法识别最新发布的版本号：\(tag)。"
        case .installerAssetMissing(let version):
            return "版本 \(version) 的发布里没有找到 .dmg 安装包。"
        case .checksumAssetMissing:
            return "这个版本没有附带 .sha256 校验文件，为安全起见不自动安装。"
        case .checksumUnreadable:
            return "无法读取 .sha256 校验文件的内容。"
        case .checksumMismatch(let expected, let actual):
            return "安装包校验失败：SHA-256 不一致（期望 \(expected.prefix(12))…，实际 \(actual.prefix(12))…）。文件可能损坏或被篡改，已放弃安装。"
        case .mountFailed(let detail):
            return "无法打开安装包镜像：\(detail)"
        case .appNotFoundInImage:
            return "安装包里没有找到 InputLock.app。"
        case .bundleMismatch(let detail):
            return "安装包里的应用与当前应用不匹配：\(detail)"
        case .signatureInvalid(let detail):
            return "安装包里的应用签名校验失败：\(detail)"
        case .incompatible(let detail):
            return "新版本不能在这台 Mac 上运行：\(detail)。已保留当前版本。"
        case .untrustedDownload(let url):
            return "安装包地址不是 GitHub 的 https 地址，已拒绝下载：\(url)"
        case .downloadTooLarge:
            return "下载的数据超过了发布信息里声明的大小，已中止。"
        case .stagingFailed(let detail):
            return "准备新版本时出错：\(detail)"
        }
    }
}
