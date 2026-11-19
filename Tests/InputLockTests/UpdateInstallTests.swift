import Foundation
import Testing
@testable import InputLock

// MARK: - 测试夹具

/// 在临时目录里搭一套「已安装的旧版 + 暂存的新版」，所有外部命令（open / xattr / tccutil / mv）都打桩，
/// 只通过子进程环境变量注入，不改测试进程自身的 PATH，也绝不触碰真实应用与真实辅助功能权限。
private struct ReplacementFixture {
    let root: URL
    let dest: URL
    let stage: URL
    let staged: URL
    let backup: URL
    let openLog: URL
    let tccLog: URL
    let paths: UpdateInstaller.Paths

    init(logPath: URL? = nil) throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent("ilk-replace-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        dest = root.appendingPathComponent("InputLock.app")
        stage = root.appendingPathComponent(UpdateInstaller.stagingPrefix + "TEST")
        staged = stage.appendingPathComponent("InputLock.app")
        backup = stage.appendingPathComponent("previous.app")
        openLog = root.appendingPathComponent("open.log")
        tccLog = root.appendingPathComponent("tcc.log")
        paths = UpdateInstaller.Paths(
            log: logPath ?? root.appendingPathComponent("logs/update.log"),
            result: root.appendingPathComponent("support/update-result")
        )
        try Self.makeApp(at: dest, version: "1.0.0")
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        try Self.makeApp(at: staged, version: "9.9.9")
    }

    static func makeApp(at url: URL, version: String, identifier: String = "com.duegin.InputLock",
                        extra: String = "") throws {
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>\(identifier)</string>
        <key>CFBundleExecutable</key><string>InputLock</string>
        <key>CFBundleShortVersionString</key><string>\(version)</string>
        \(extra)
        </dict></plist>
        """.write(to: contents.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
    }

    func version(of url: URL) -> String? {
        try? UpdateInstaller.readInfo(url).version.description
    }

    func read(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    var outcome: UpdateInstaller.ReplacementOutcome? {
        UpdateInstaller.readOutcome(at: paths.result)
    }

    /// 生成桩命令。`failMoves` 里列出的源路径，`mv` 会直接失败。
    func environment(failMoves: [URL] = [], waitLimit: Int? = nil) throws -> [String: String] {
        let fm = FileManager.default
        let bin = root.appendingPathComponent("stub-bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        func stub(_ name: String, _ body: String) throws -> String {
            let url = bin.appendingPathComponent(name)
            try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url.path
        }
        let failCases = failMoves.map { "  \"\($0.path)\") echo \"stub mv: refusing $1\" >&2; exit 1 ;;" }
            .joined(separator: "\n")
        var env: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "INPUTLOCK_OPEN": try stub("open", "echo \"$@\" >> \"\(openLog.path)\""),
            "INPUTLOCK_XATTR": try stub("xattr", "exit 0"),
            "INPUTLOCK_TCCUTIL": try stub("tccutil", "echo \"$@\" >> \"\(tccLog.path)\""),
            "INPUTLOCK_MV": try stub("mv", "case \"$1\" in\n\(failCases)\nesac\nexec /bin/mv \"$@\""),
        ]
        if let waitLimit { env["INPUTLOCK_WAIT_LIMIT"] = String(waitLimit) }
        return env
    }

    /// 跑一次替换脚本并等它结束。
    func run(waitingFor pid: Int32, environment: [String: String], resetID: String? = "com.duegin.InputLock") throws {
        let process = try UpdateInstaller(bundleIdentifier: "com.duegin.InputLock").launchReplacement(
            stagedApp: staged,
            stagingDirectory: stage,
            destination: dest,
            version: AppVersion("9.9.9")!,
            resetAccessibilityFor: resetID,
            paths: paths,
            waitingFor: pid,
            environment: environment
        )
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        #expect(!process.isRunning, "替换脚本没有在 30 秒内结束")
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// 一个已经退出、并且已被回收（不是僵尸）的进程号，模拟「App 已经退出」。
private func exitedPID() throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try process.run()
    process.waitUntilExit()
    return process.processIdentifier
}

// MARK: - 替换脚本

@Suite("替换脚本", .serialized)
struct ReplacementScriptTests {

    @Test("成功：换上新版、清理暂存、重置授权、重新打开、写结果")
    func succeeds() throws {
        let f = try ReplacementFixture()
        defer { f.cleanUp() }
        try f.run(waitingFor: try exitedPID(), environment: try f.environment())

        #expect(f.version(of: f.dest) == "9.9.9")
        #expect(!FileManager.default.fileExists(atPath: f.stage.path), "暂存目录（含旧版备份）应被清理")
        #expect(f.read(f.openLog).contains(f.dest.path))
        #expect(f.read(f.tccLog).contains("reset Accessibility com.duegin.InputLock"))
        #expect(f.outcome == .succeeded(version: "9.9.9"))
    }

    @Test("不需要重置授权时不调用 tccutil")
    func noReset() throws {
        let f = try ReplacementFixture()
        defer { f.cleanUp() }
        try f.run(waitingFor: try exitedPID(), environment: try f.environment(), resetID: nil)
        #expect(f.version(of: f.dest) == "9.9.9")
        #expect(f.read(f.tccLog).isEmpty)
    }

    @Test("移不开旧版：不做任何改动，重新打开旧版")
    func cannotMoveOldAside() throws {
        let f = try ReplacementFixture()
        defer { f.cleanUp() }
        try f.run(waitingFor: try exitedPID(), environment: try f.environment(failMoves: [f.dest]))

        #expect(f.version(of: f.dest) == "1.0.0")
        #expect(!FileManager.default.fileExists(atPath: f.stage.path))
        #expect(f.read(f.openLog).contains(f.dest.path))
        #expect(f.read(f.tccLog).isEmpty, "失败时不能清掉旧版仍然有效的授权")
        guard case .failed = f.outcome else { Issue.record("应写入失败结果"); return }
    }

    @Test("新版放不进去：恢复旧版，不重置授权")
    func restoresOldApp() throws {
        let f = try ReplacementFixture()
        defer { f.cleanUp() }
        try f.run(waitingFor: try exitedPID(), environment: try f.environment(failMoves: [f.staged]))

        #expect(f.version(of: f.dest) == "1.0.0", "旧版应被挪回原位")
        #expect(!FileManager.default.fileExists(atPath: f.stage.path))
        #expect(f.read(f.openLog).contains(f.dest.path))
        #expect(f.read(f.tccLog).isEmpty)
        guard case .failed(let reason) = f.outcome else { Issue.record("应写入失败结果"); return }
        #expect(reason.contains("已恢复旧版本"))
    }

    @Test("恢复也失败：绝不删除备份，从备份位置启动并告诉用户在哪")
    func keepsBackupWhenRestoreFails() throws {
        let f = try ReplacementFixture()
        defer { f.cleanUp() }
        try f.run(waitingFor: try exitedPID(),
                  environment: try f.environment(failMoves: [f.staged, f.backup]))

        #expect(!FileManager.default.fileExists(atPath: f.dest.path))
        #expect(f.version(of: f.backup) == "1.0.0", "唯一可用的旧版必须保留")
        #expect(f.read(f.openLog).contains(f.backup.path))
        #expect(f.read(f.tccLog).isEmpty)
        guard case .failed(let reason) = f.outcome else { Issue.record("应写入失败结果"); return }
        #expect(reason.contains(f.backup.path))
    }

    @Test("旧进程一直不退出：超时放弃，不动已安装的版本")
    func timesOutWhenAppKeepsRunning() throws {
        let f = try ReplacementFixture()
        defer { f.cleanUp() }
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        defer { sleeper.terminate(); sleeper.waitUntilExit() }

        try f.run(waitingFor: sleeper.processIdentifier, environment: try f.environment(waitLimit: 3))

        #expect(f.version(of: f.dest) == "1.0.0")
        #expect(!FileManager.default.fileExists(atPath: f.stage.path))
        #expect(f.read(f.openLog).isEmpty, "旧进程还活着，不应再打开一份")
        guard case .failed = f.outcome else { Issue.record("应写入失败结果"); return }
    }

    @Test("日志写不进去也照常更新")
    func logUnwritable() throws {
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("ilk-blocker-\(UUID())")
        try "not a directory".write(to: blocker, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: blocker) }

        let f = try ReplacementFixture(logPath: blocker.appendingPathComponent("update.log"))
        defer { f.cleanUp() }
        try f.run(waitingFor: try exitedPID(), environment: try f.environment())

        #expect(f.version(of: f.dest) == "9.9.9")
        #expect(f.outcome == .succeeded(version: "9.9.9"))
    }
}

// MARK: - 安装前的校验

@Suite("UpdateInstaller 校验", .serialized)
struct InstallerValidationTests {

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ilk-validate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("SHA-256 不一致时拒绝")
    func checksumMismatch() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("x.dmg")
        try Data("abc".utf8).write(to: file)
        let installer = UpdateInstaller(bundleIdentifier: "com.duegin.InputLock")

        try await installer.verify(file, expectedSHA256: "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD")
        await #expect(throws: UpdateError.self) {
            try await installer.verify(file, expectedSHA256: String(repeating: "0", count: 64))
        }
    }

    @Test("bundle id 不同时拒绝")
    func wrongIdentifier() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = dir.appendingPathComponent("InputLock.app")
        try ReplacementFixture.makeApp(at: app, version: "2.0.0", identifier: "com.evil.InputLock")
        let installer = UpdateInstaller(bundleIdentifier: "com.duegin.InputLock")
        await #expect(throws: UpdateError.bundleMismatch("bundle id 是 com.evil.InputLock，应为 com.duegin.InputLock")) {
            try await installer.validate(app: app, expectedVersion: AppVersion("2.0.0")!)
        }
    }

    @Test("版本号对不上时拒绝")
    func wrongVersion() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = dir.appendingPathComponent("InputLock.app")
        try ReplacementFixture.makeApp(at: app, version: "1.9.0")
        let installer = UpdateInstaller(bundleIdentifier: "com.duegin.InputLock")
        await #expect(throws: UpdateError.bundleMismatch("版本是 1.9.0，应为 2.0.0")) {
            try await installer.validate(app: app, expectedVersion: AppVersion("2.0.0")!)
        }
    }

    @Test("要求更高的 macOS 时拒绝")
    func requiresNewerSystem() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = dir.appendingPathComponent("InputLock.app")
        try ReplacementFixture.makeApp(
            at: app, version: "2.0.0",
            extra: "<key>LSMinimumSystemVersion</key><string>99.0</string>")
        let installer = UpdateInstaller(bundleIdentifier: "com.duegin.InputLock")
        await #expect {
            try await installer.validate(app: app, expectedVersion: AppVersion("2.0.0")!)
        } throws: { error in
            if case UpdateError.incompatible = error { return true }
            return false
        }
    }

    @Test("读不到可执行文件架构时拒绝")
    func missingExecutable() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = dir.appendingPathComponent("InputLock.app")
        try ReplacementFixture.makeApp(at: app, version: "2.0.0")
        let installer = UpdateInstaller(bundleIdentifier: "com.duegin.InputLock")
        await #expect {
            try await installer.validate(app: app, expectedVersion: AppVersion("2.0.0")!)
        } throws: { error in
            if case UpdateError.bundleMismatch(let detail) = error { return detail.contains("架构") }
            return false
        }
    }

    @Test("真实的已打包 InputLock.app 能通过架构与签名校验")
    func realBuildPassesValidation() async throws {
        let built = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/InputLock.app")
        guard FileManager.default.fileExists(atPath: built.path),
              let info = try? UpdateInstaller.readInfo(built) else {
            return // 没有先跑 build_app.sh 时跳过
        }
        let installer = UpdateInstaller(bundleIdentifier: info.identifier)
        try await installer.validate(app: built, expectedVersion: info.version)
    }
}

// MARK: - 结果文件、残留清理、签名

@Suite("UpdateInstaller 杂项", .serialized)
struct InstallerMiscTests {

    @Test("解析替换结果文件")
    func parsesOutcome() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ilk-outcome-\(UUID())")
        defer { try? FileManager.default.removeItem(at: url) }

        try "ok\n1.2.3\n".write(to: url, atomically: true, encoding: .utf8)
        #expect(UpdateInstaller.readOutcome(at: url) == .succeeded(version: "1.2.3"))

        try "failed\n新版本无法放到 /Applications/InputLock.app，已恢复旧版本\n".write(to: url, atomically: true, encoding: .utf8)
        #expect(UpdateInstaller.readOutcome(at: url) == .failed(reason: "新版本无法放到 /Applications/InputLock.app，已恢复旧版本"))

        try "garbage".write(to: url, atomically: true, encoding: .utf8)
        #expect(UpdateInstaller.readOutcome(at: url) == nil)
    }

    @Test("启动时清理残留的暂存目录，但不动从备份里启动的自己")
    func cleansStaleStaging() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ilk-stale-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let app = root.appendingPathComponent("InputLock.app")
        let stale = root.appendingPathComponent(UpdateInstaller.stagingPrefix + "OLD")
        let unrelated = root.appendingPathComponent("Other.app")
        for dir in [app, stale.appendingPathComponent("InputLock.app"), unrelated] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let removed = UpdateInstaller.cleanUpStaleStaging(around: app)
        #expect(removed.map(\.lastPathComponent) == [stale.lastPathComponent])
        #expect(!fm.fileExists(atPath: stale.path))
        #expect(fm.fileExists(atPath: app.path) && fm.fileExists(atPath: unrelated.path))

        // 自己就在暂存目录里运行时什么都不删
        let inside = root.appendingPathComponent(UpdateInstaller.stagingPrefix + "NOW/previous.app")
        try fm.createDirectory(at: inside, withIntermediateDirectories: true)
        #expect(UpdateInstaller.cleanUpStaleStaging(around: inside).isEmpty)
        #expect(fm.fileExists(atPath: inside.path))
    }

    @Test("识别 ad-hoc 签名")
    func detectsAdHoc() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ilk-sign-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let app = root.appendingPathComponent("T.app")
        let macos = app.appendingPathComponent("Contents/MacOS")
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)
        let binary = macos.appendingPathComponent("T")
        try "#!/bin/sh\nexit 0\n".write(to: binary, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>com.duegin.t</string>
        <key>CFBundleExecutable</key><string>T</string>
        </dict></plist>
        """.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)

        let sign = try await Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        #expect(sign.status == 0, "ad-hoc 签名失败：\(sign.errorText)")
        #expect(UpdateInstaller.isAdHocSigned(app))
        #expect(!UpdateInstaller.isAdHocSigned(URL(fileURLWithPath: "/System/Applications/Calculator.app")))
    }
}
