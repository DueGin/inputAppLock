import Foundation
import Testing
@testable import InputLock

// MARK: - 版本号

@Suite("AppVersion")
struct AppVersionTests {

    @Test("解析常见写法", arguments: [
        ("1.0.0", [1, 0, 0], nil),
        ("v1.0.1", [1, 0, 1], nil),
        ("V2.3", [2, 3, 0], nil),
        ("1", [1, 0, 0], nil),
        ("1.2.3.4", [1, 2, 3, 4], nil),
        ("1.2.3.0", [1, 2, 3], nil),
        ("1.2.3-beta.1", [1, 2, 3], "beta.1"),
        ("1.2.3+build.9", [1, 2, 3], nil),
        (" 1.2.3 ", [1, 2, 3], nil),
    ])
    func parse(raw: String, expected: [Int], prerelease: String?) {
        let version = AppVersion(raw)
        #expect(version?.numbers == expected)
        #expect(version?.prerelease == prerelease)
    }

    @Test("拒绝非法输入", arguments: ["", "abc", "1..2", "1.2.3.4.5", "v", "1.2.x", "1.2.3-"])
    func rejects(raw: String) {
        #expect(AppVersion(raw) == nil)
    }

    @Test("按数字比较，不是按字符串", arguments: [
        ("1.10.0", "1.9.9", false),
        ("1.0.0", "1.0.0", false),
        ("v1.2.3", "1.2.3", false),
        ("1.2.3", "1.2.10", true),
        ("2.0", "1.99.99", false),
    ])
    func compares(lhs: String, rhs: String, isLess: Bool) {
        let left = AppVersion(lhs)!, right = AppVersion(rhs)!
        #expect((left < right) == isLess)
        if left == right {
            #expect(!(right < left))
        } else {
            #expect((right < left) == !isLess)
        }
    }

    @Test("正式版高于同号预发布版")
    func prereleaseOrdering() {
        #expect(AppVersion("1.0.0")! > AppVersion("1.0.0-beta.2")!)
        #expect(AppVersion("1.0.0-beta.10")! > AppVersion("1.0.0-beta.2")!)
        #expect(AppVersion("1.0.0-beta.2")! > AppVersion("1.0.0-alpha")!)
    }
}

// MARK: - 判断有没有新版本

@Suite("UpdateEvaluator")
struct UpdateEvaluatorTests {

    private func release(
        tag: String,
        assets: [String],
        draft: Bool = false,
        prerelease: Bool = false,
        assetBase: String = "https://github.com/DueGin/inputAppLock/releases/download/v0"
    ) -> GitHubRelease {
        let json = """
        {
          "tag_name": "\(tag)",
          "name": "InputLock \(tag)",
          "body": null,
          "html_url": "https://github.com/DueGin/inputAppLock/releases/tag/\(tag)",
          "draft": \(draft),
          "prerelease": \(prerelease),
          "published_at": "2026-11-17T18:10:24Z",
          "assets": [\(assets.map { asset in
              """
              {"name": "\(asset)", "browser_download_url": "\(assetBase)/\(asset)", "size": 876126}
              """
          }.joined(separator: ","))]
        }
        """
        return try! GitHubRelease.decode(from: Data(json.utf8))
    }

    @Test("有新版本时给出安装包和校验文件")
    func newer() throws {
        let result = try UpdateEvaluator.evaluate(
            release: release(tag: "v1.0.2", assets: ["InputLock-1.0.2.dmg", "InputLock-1.0.2.dmg.sha256"]),
            current: AppVersion("1.0.1")!
        )
        guard case .available(let update) = result else {
            Issue.record("应判定为有新版本")
            return
        }
        #expect(update.version == AppVersion("1.0.2"))
        #expect(update.installer.name == "InputLock-1.0.2.dmg")
        #expect(update.checksum?.name == "InputLock-1.0.2.dmg.sha256")
        #expect(update.release.publishedAt != nil)
    }

    @Test("同版本或更旧的版本视为已是最新", arguments: ["v1.0.1", "v1.0.0", "v0.9"])
    func upToDate(tag: String) throws {
        let result = try UpdateEvaluator.evaluate(
            release: release(tag: tag, assets: ["InputLock-\(tag.dropFirst()).dmg"]),
            current: AppVersion("1.0.1")!
        )
        #expect(result == .upToDate(latest: AppVersion(tag)!))
    }

    @Test("没有安装包时报错")
    func missingInstaller() {
        #expect(throws: UpdateError.installerAssetMissing(version: "1.0.2")) {
            try UpdateEvaluator.evaluate(
                release: release(tag: "v1.0.2", assets: ["InputLock-1.0.2.zip"]),
                current: AppVersion("1.0.1")!
            )
        }
    }

    @Test("没有校验文件时仍然可用，但 checksum 为 nil")
    func missingChecksum() throws {
        let result = try UpdateEvaluator.evaluate(
            release: release(tag: "v1.0.2", assets: ["InputLock-1.0.2.dmg"]),
            current: AppVersion("1.0.1")!
        )
        guard case .available(let update) = result else {
            Issue.record("应判定为有新版本")
            return
        }
        #expect(update.checksum == nil)
    }

    @Test("draft / prerelease 不推送")
    func skipsUnstable() throws {
        let draft = try UpdateEvaluator.evaluate(
            release: release(tag: "v2.0.0", assets: ["InputLock-2.0.0.dmg"], draft: true),
            current: AppVersion("1.0.1")!
        )
        #expect(draft == .upToDate(latest: AppVersion("2.0.0")!))

        let pre = try UpdateEvaluator.evaluate(
            release: release(tag: "v2.0.0", assets: ["InputLock-2.0.0.dmg"], prerelease: true),
            current: AppVersion("1.0.1")!
        )
        #expect(pre == .upToDate(latest: AppVersion("2.0.0")!))
    }

    @Test("tag 带预发布后缀但没标 prerelease：不推给正式版用户")
    func prereleaseTagWithoutFlag() throws {
        let beta = release(tag: "v1.1.0-beta.1", assets: ["InputLock-1.1.0-beta.1.dmg"])
        let stable = try UpdateEvaluator.evaluate(release: beta, current: AppVersion("1.0.1")!)
        #expect(stable == .upToDate(latest: AppVersion("1.1.0-beta.1")!))

        // 已经在用预发布版的用户可以收到更新的预发布版
        let tester = try UpdateEvaluator.evaluate(release: beta, current: AppVersion("1.1.0-alpha")!)
        guard case .available = tester else {
            Issue.record("预发布版用户应收到更新的预发布版")
            return
        }
    }

    @Test("安装包不是 GitHub 的 https 地址时拒绝")
    func untrustedInstallerURL() {
        #expect(throws: UpdateError.untrustedDownload("http://github.com/x/InputLock-1.0.2.dmg")) {
            try UpdateEvaluator.evaluate(
                release: release(tag: "v1.0.2", assets: ["InputLock-1.0.2.dmg"], assetBase: "http://github.com/x"),
                current: AppVersion("1.0.1")!
            )
        }
    }

    @Test("tag 无法解析时报错")
    func invalidTag() {
        #expect(throws: UpdateError.invalidReleaseTag("nightly")) {
            try UpdateEvaluator.evaluate(
                release: release(tag: "nightly", assets: ["InputLock-nightly.dmg"]),
                current: AppVersion("1.0.1")!
            )
        }
    }
}

// MARK: - 校验文件

@Suite("Checksum")
struct ChecksumTests {

    private let digest = "068f0a2d20ba0319885e4a7e6085efa0a4664825b444ec0c750129babcdffb0f"

    @Test("解析 shasum -a 256 的输出")
    func parsesShasum() {
        let text = "\(digest)  InputLock-1.0.1.dmg\n"
        #expect(Checksum.parseSHA256File(text, expectedFileName: "InputLock-1.0.1.dmg") == digest)
    }

    @Test("接受大写摘要和二进制模式的 * 前缀")
    func parsesVariants() {
        #expect(Checksum.parseSHA256File("\(digest.uppercased()) *InputLock-1.0.1.dmg\n",
                                         expectedFileName: "InputLock-1.0.1.dmg") == digest)
        #expect(Checksum.parseSHA256File("\(digest)\n", expectedFileName: "any.dmg") == digest)
    }

    @Test("文件名不同、长度不对、不是十六进制都拒绝")
    func rejectsInvalid() {
        #expect(Checksum.parseSHA256File("\(digest)  other.dmg\n", expectedFileName: "InputLock-1.0.1.dmg") == nil)
        #expect(Checksum.parseSHA256File("abc  InputLock-1.0.1.dmg\n", expectedFileName: "InputLock-1.0.1.dmg") == nil)
        #expect(Checksum.parseSHA256File(String(repeating: "z", count: 64), expectedFileName: "x") == nil)
    }

    @Test("文件摘要与 shasum 一致")
    func hashesFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("inputlock-sha-test-\(UUID())")
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try Checksum.sha256Hex(of: url) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

// MARK: - 能否原地更新

@Suite("UpdateInstaller.installBlocker")
struct InstallBlockerTests {

    @Test("正常位置的 .app 可以更新")
    func allowed() {
        let url = URL(fileURLWithPath: "/Applications/InputLock.app")
        #expect(UpdateInstaller.installBlocker(for: url, isWritable: { _ in true }) == nil)
    }

    @Test("裸二进制不能原地更新")
    func bareBinary() {
        let url = URL(fileURLWithPath: "/Users/x/repo/.build/release/InputLock")
        #expect(UpdateInstaller.installBlocker(for: url, isWritable: { _ in true }) == .notRunningFromAppBundle)
    }

    @Test("App Translocation 时要求用户先拖进应用程序")
    func translocated() {
        let url = URL(fileURLWithPath: "/private/var/folders/xy/AppTranslocation/1234/d/InputLock.app")
        guard case .appTranslocated = UpdateInstaller.installBlocker(for: url, isWritable: { _ in true }) else {
            Issue.record("应拒绝从 App Translocation 更新")
            return
        }
    }

    @Test("目录不可写时报出具体路径")
    func notWritable() {
        let url = URL(fileURLWithPath: "/Applications/InputLock.app")
        let blocker = UpdateInstaller.installBlocker(for: url, isWritable: { $0 == "/Applications/InputLock.app" })
        #expect(blocker == .destinationNotWritable(path: "/Applications"))
    }
}


// MARK: - 更新源与下载地址

@Suite("UpdateSource")
struct UpdateSourceTests {

    @Test("仓库名校验", arguments: [
        ("DueGin/inputAppLock", true),
        ("a-b/c.d_e", true),
        ("noslash", false),
        ("a/b/c", false),
        ("a /b", false),
        ("/b", false),
        ("../b", false),
        ("a/..", false),
        ("用户/仓库", false),
    ])
    func repository(value: String, valid: Bool) {
        #expect(UpdateSource.isValidRepository(value) == valid)
    }

    @Test("只信任 GitHub 的 https 下载地址", arguments: [
        ("https://github.com/DueGin/inputAppLock/releases/download/v1/InputLock-1.dmg", true),
        ("https://objects.githubusercontent.com/github-production-release-asset/1", true),
        ("https://release-assets.githubusercontent.com/x", true),
        ("http://github.com/x.dmg", false),
        ("https://evil.com/github.com/x.dmg", false),
        ("https://githubusercontent.com.evil.com/x.dmg", false),
        ("file:///tmp/x.dmg", false),
    ])
    func trustedURL(raw: String, trusted: Bool) {
        #expect(UpdateSource.isTrustedDownloadURL(URL(string: raw)!) == trusted)
    }
}

// MARK: - 自动检查节流

@Suite("UpdateController.isCheckDue")
struct CheckThrottleTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func neverChecked() {
        #expect(UpdateController.isCheckDue(lastSuccess: nil, now: now))
    }

    @Test func withinADay() {
        #expect(!UpdateController.isCheckDue(lastSuccess: now.addingTimeInterval(-3600), now: now))
    }

    @Test func afterADay() {
        #expect(UpdateController.isCheckDue(lastSuccess: now.addingTimeInterval(-86_400), now: now))
    }

    @Test("时钟被往回调也视为到期")
    func clockMovedBack() {
        #expect(UpdateController.isCheckDue(lastSuccess: now.addingTimeInterval(3600), now: now))
    }
}

// MARK: - 兼容性

@Suite("UpdateInstaller.compatibilityProblem")
struct CompatibilityTests {
    let sonoma = OperatingSystemVersion(majorVersion: 14, minorVersion: 5, patchVersion: 0)

    @Test func universalOnAppleSilicon() {
        #expect(UpdateInstaller.compatibilityProblem(
            architectures: ["x86_64", "arm64"], minimumSystemVersion: "13.0",
            currentArchitecture: "arm64", currentSystem: sonoma) == nil)
    }

    @Test func arm64OnlyOnIntel() {
        #expect(UpdateInstaller.compatibilityProblem(
            architectures: ["arm64"], minimumSystemVersion: "13.0",
            currentArchitecture: "x86_64", currentSystem: sonoma) != nil)
    }

    @Test func arm64eBinaryOnAppleSilicon() {
        #expect(UpdateInstaller.compatibilityProblem(
            architectures: ["arm64e"], minimumSystemVersion: nil,
            currentArchitecture: "arm64", currentSystem: sonoma) == nil)
    }

    @Test func requiresNewerMacOS() {
        #expect(UpdateInstaller.compatibilityProblem(
            architectures: [], minimumSystemVersion: "15.0",
            currentArchitecture: "arm64", currentSystem: sonoma) != nil)
        #expect(UpdateInstaller.compatibilityProblem(
            architectures: [], minimumSystemVersion: "14.5",
            currentArchitecture: "arm64", currentSystem: sonoma) == nil)
    }
}

// MARK: - 开机启动状态文案

@Suite("LaunchAtLogin.description")
struct LaunchAtLoginTests {
    let app = URL(fileURLWithPath: "/Applications/InputLock.app")
    let translocated = URL(fileURLWithPath: "/private/var/folders/ab/AppTranslocation/1234/d/InputLock.app")
    let bare = URL(fileURLWithPath: "/Users/x/repo/.build/release")

    @Test("从没注册过的正常 .app 返回 notFound，应显示「未开启」而不是「请先打包」")
    func notFoundInRealApp() {
        #expect(LaunchAtLogin.description(for: .notFound, bundleURL: app) == "未开启")
    }

    @Test func notFoundTranslocated() {
        #expect(LaunchAtLogin.description(for: .notFound, bundleURL: translocated).contains("拖进「应用程序」"))
    }

    @Test func notFoundBareBinary() {
        #expect(LaunchAtLogin.description(for: .notFound, bundleURL: bare) == "不可用（请先打包成 .app）")
    }

    @Test func otherStatuses() {
        #expect(LaunchAtLogin.description(for: .enabled, bundleURL: app) == "已开启")
        #expect(LaunchAtLogin.description(for: .notRegistered, bundleURL: app) == "未开启")
        #expect(LaunchAtLogin.description(for: .requiresApproval, bundleURL: app).contains("登录项"))
    }
}
