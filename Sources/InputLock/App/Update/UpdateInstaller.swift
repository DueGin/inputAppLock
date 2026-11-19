import CryptoKit
import Foundation
import Security

// MARK: - SHA-256

enum Checksum {

    /// 解析 `shasum -a 256` 的输出：`<64 位十六进制>  <文件名>`。
    /// 文件里写了文件名时必须和安装包同名；只有摘要没有文件名也接受。
    static func parseSHA256File(_ text: String, expectedFileName: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard let first = fields.first else { continue }
            let digest = first.lowercased()
            guard digest.count == 64, digest.allSatisfy({ $0.isHexDigit }) else { continue }
            if fields.count == 2 {
                // shasum 二进制模式会在文件名前加 `*`
                var name = fields[1].trimmingCharacters(in: .whitespaces)
                if name.hasPrefix("*") { name.removeFirst() }
                guard name == expectedFileName else { continue }
            }
            return digest
        }
        return nil
    }

    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 安装器

/// 把下载好的 dmg 变成「退出后自动替换并重启」：
/// 校验 SHA-256 → 挂载 → 检查 bundle id / 版本 / 签名 → 复制到目标目录旁 → 启动替换脚本。
struct UpdateInstaller {

    let bundleIdentifier: String
    let appBundleName: String

    init(bundleIdentifier: String, appBundleName: String = "InputLock.app") {
        self.bundleIdentifier = bundleIdentifier
        self.appBundleName = appBundleName
    }

    // MARK: 能否原地更新

    /// 纯函数版本，方便测试：返回 nil 表示可以原地替换 `bundleURL`。
    static func installBlocker(
        for bundleURL: URL,
        isWritable: (String) -> Bool = FileManager.default.isWritableFile(atPath:)
    ) -> UpdateError? {
        guard bundleURL.pathExtension == "app" else {
            return .notRunningFromAppBundle
        }
        if bundleURL.path.contains("/AppTranslocation/") {
            return .appTranslocated
        }
        let parent = bundleURL.deletingLastPathComponent().path
        guard isWritable(parent) else {
            return .destinationNotWritable(path: parent)
        }
        guard isWritable(bundleURL.path) else {
            return .destinationNotWritable(path: bundleURL.path)
        }
        return nil
    }

    // MARK: 工作目录

    func makeWorkDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("InputLock-Update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    // MARK: 校验

    /// 整个文件的哈希放到后台算，调用方即使在主线程也不会卡 UI。
    func verify(_ file: URL, expectedSHA256: String) async throws {
        let actual = try await Task.detached(priority: .userInitiated) {
            try Checksum.sha256Hex(of: file)
        }.value
        guard actual == expectedSHA256.lowercased() else {
            throw UpdateError.checksumMismatch(expected: expectedSHA256, actual: actual)
        }
    }

    // MARK: 挂载

    /// 调用前必须已经用 `verify` 校验过整个文件的 SHA-256，所以这里用 `-noverify`
    /// 跳过 hdiutil 自己的镜像校验（实测能省 3 秒左右）。
    func mount(_ dmg: URL, under directory: URL) async throws -> URL {
        let result = try await Shell.run("/usr/bin/hdiutil", [
            "attach", dmg.path,
            "-nobrowse", "-readonly", "-noautoopen", "-noverify",
            "-mountrandom", directory.path,
            "-plist"
        ])
        guard result.status == 0 else {
            throw UpdateError.mountFailed(result.errorText)
        }
        let plist = try? PropertyListSerialization.propertyList(from: result.output, format: nil) as? [String: Any]
        let entities = plist?["system-entities"] as? [[String: Any]] ?? []
        if let mountPoint = entities.lazy.compactMap({ $0["mount-point"] as? String }).first {
            return URL(fileURLWithPath: mountPoint, isDirectory: true)
        }
        // attach 成功但拿不到挂载点：把已经挂上的设备卸掉，别留到下次重启
        for device in entities.compactMap({ $0["dev-entry"] as? String }) {
            _ = try? await Shell.run("/usr/bin/hdiutil", ["detach", device, "-force", "-quiet"])
        }
        await detachAll(under: directory)
        throw UpdateError.mountFailed("hdiutil 没有返回挂载点")
    }

    /// 卸载成功返回 true。卸载失败时不要再去删工作目录，否则会钻进仍挂着的卷里。
    @discardableResult
    func detach(_ mountPoint: URL) async -> Bool {
        if (try? await Shell.run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet"]))?.status == 0 {
            return true
        }
        return (try? await Shell.run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force", "-quiet"]))?.status == 0
    }

    /// `-mountrandom` 会在工作目录下建 `dmg.XXXXXX` 挂载点；兜底把它们都卸掉。
    @discardableResult
    func detachAll(under directory: URL) async -> Bool {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        var ok = true
        for child in children where child.lastPathComponent.hasPrefix("dmg.") {
            if !(await detach(child)) { ok = false }
        }
        return ok
    }

    // MARK: 检查新应用

    func locateApp(in mountPoint: URL) throws -> URL {
        let app = mountPoint.appendingPathComponent(appBundleName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: app.path) else {
            throw UpdateError.appNotFoundInImage
        }
        return app
    }

    struct BundleInfo: Equatable {
        let identifier: String
        let version: AppVersion
        let executable: String?
        let minimumSystemVersion: String?
    }

    /// 直接解析 Info.plist，而不是 `Bundle(url:)`：后者会把临时卷上的应用注册进 LaunchServices，
    /// 留下副作用（挂载点卸载后系统里可能残留一条已失效的应用记录）。
    static func readInfo(_ app: URL) throws -> BundleInfo {
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw UpdateError.bundleMismatch("读不到 Contents/Info.plist")
        }
        guard let identifier = plist["CFBundleIdentifier"] as? String else {
            throw UpdateError.bundleMismatch("Info.plist 里没有 CFBundleIdentifier")
        }
        guard let raw = plist["CFBundleShortVersionString"] as? String,
              let version = AppVersion(raw) else {
            throw UpdateError.bundleMismatch("Info.plist 里的版本号无法解析")
        }
        return BundleInfo(
            identifier: identifier,
            version: version,
            executable: plist["CFBundleExecutable"] as? String,
            minimumSystemVersion: plist["LSMinimumSystemVersion"] as? String
        )
    }

    /// 当前机器的 CPU 架构名（与 `lipo -archs` 的输出一致）。
    static var currentArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    /// 纯函数：新版本能不能在这台机器上跑。返回 nil 表示没问题，否则是给用户看的原因。
    static func compatibilityProblem(
        architectures: [String],
        minimumSystemVersion: String?,
        currentArchitecture: String = currentArchitecture,
        currentSystem: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> String? {
        if let minimum = minimumSystemVersion, let required = AppVersion(minimum) {
            let system = AppVersion("\(currentSystem.majorVersion).\(currentSystem.minorVersion).\(currentSystem.patchVersion)")
            if let system, system < required {
                return "新版本需要 macOS \(minimum) 或更新，这台 Mac 是 \(system)"
            }
        }
        // arm64e 的机器也能跑 arm64 的二进制
        let accepted: Set<String> = currentArchitecture == "arm64" ? ["arm64", "arm64e"] : [currentArchitecture]
        if !architectures.isEmpty, accepted.isDisjoint(with: architectures) {
            return "新版本只包含 \(architectures.joined(separator: " / ")) 架构，这台 Mac 是 \(currentArchitecture)"
        }
        return nil
    }

    /// 顺序：bundle id → 版本 → 系统版本 → 架构 → 签名。前几步只读 plist，最便宜。
    func validate(app: URL, expectedVersion: AppVersion) async throws {
        let info = try Self.readInfo(app)
        guard info.identifier == bundleIdentifier else {
            throw UpdateError.bundleMismatch("bundle id 是 \(info.identifier)，应为 \(bundleIdentifier)")
        }
        guard info.version == expectedVersion else {
            throw UpdateError.bundleMismatch("版本是 \(info.version)，应为 \(expectedVersion)")
        }
        if let problem = Self.compatibilityProblem(architectures: [], minimumSystemVersion: info.minimumSystemVersion) {
            throw UpdateError.incompatible(problem)
        }

        guard let executable = info.executable else {
            throw UpdateError.bundleMismatch("Info.plist 里没有 CFBundleExecutable")
        }
        let binary = app.appendingPathComponent("Contents/MacOS/\(executable)")
        let lipo = try await Shell.run("/usr/bin/lipo", ["-archs", binary.path])
        guard lipo.status == 0 else {
            throw UpdateError.bundleMismatch("无法读取可执行文件架构：\(lipo.errorText)")
        }
        let archs = (String(data: lipo.output, encoding: .utf8) ?? "")
            .split(whereSeparator: \.isWhitespace).map(String.init)
        if let problem = Self.compatibilityProblem(architectures: archs, minimumSystemVersion: nil) {
            throw UpdateError.incompatible(problem)
        }

        let result = try await Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard result.status == 0 else {
            throw UpdateError.signatureInvalid(result.errorText)
        }
    }

    // MARK: 暂存

    static let stagingPrefix = ".InputLock-update-"

    /// 把新应用复制到目标目录下的隐藏暂存目录（同一卷，替换时 `mv` 是原子的）。
    /// 返回 (暂存目录, 暂存目录里的新 .app)。
    func stage(app: URL, replacing destination: URL) async throws -> (directory: URL, app: URL) {
        let directory = destination.deletingLastPathComponent()
            .appendingPathComponent(Self.stagingPrefix + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        } catch {
            throw UpdateError.stagingFailed(error.localizedDescription)
        }
        let staged = directory.appendingPathComponent(appBundleName, isDirectory: true)
        // ditto 会保留签名、扩展属性和符号链接
        let result = try await Shell.run("/usr/bin/ditto", [app.path, staged.path])
        guard result.status == 0 else {
            try? FileManager.default.removeItem(at: directory)
            throw UpdateError.stagingFailed(result.errorText)
        }
        return (directory, staged)
    }

    /// 启动时清理上次残留的暂存目录（安装中途被强退、关机等）。
    /// 当前应用自己就在暂存目录里运行时（替换失败后从备份启动）不动，留给用户处理。
    static func cleanUpStaleStaging(around bundleURL: URL) -> [URL] {
        guard bundleURL.pathExtension == "app",
              !bundleURL.path.contains("/\(stagingPrefix)") else { return [] }
        let parent = bundleURL.deletingLastPathComponent()
        let children = (try? FileManager.default.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: nil, options: []
        )) ?? []
        var removed: [URL] = []
        for child in children where child.lastPathComponent.hasPrefix(stagingPrefix) {
            if (try? FileManager.default.removeItem(at: child)) != nil {
                removed.append(child)
            }
        }
        return removed
    }

    // MARK: 替换并重启

    /// 日志与结果文件的位置。
    struct Paths {
        let log: URL
        let result: URL

        static var standard: Paths {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return Paths(
                log: home.appendingPathComponent("Library/Logs/InputLock/update.log"),
                result: home.appendingPathComponent("Library/Application Support/InputLock/update-result")
            )
        }
    }

    /// 启动一个独立的 `/bin/sh` 进程：等当前进程退出 → 备份旧版 → 换上新版 → 重新打开。
    ///
    /// - Parameter resetAccessibilityFor: 非 nil 时，**只有替换成功**才执行
    ///   `tccutil reset Accessibility <bundle id>`。ad-hoc 签名每次构建都会变，
    ///   系统里旧的授权记录对新版无效却仍显示为已勾选，清掉它新版才能重新弹出授权提示。
    func launchReplacement(
        stagedApp: URL,
        stagingDirectory: URL,
        destination: URL,
        version: AppVersion,
        resetAccessibilityFor bundleID: String?,
        paths: Paths = .standard,
        waitingFor pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        environment: [String: String]? = nil
    ) throws -> Process {
        for directory in [paths.log, paths.result].map({ $0.deletingLastPathComponent() }) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try? FileManager.default.removeItem(at: paths.result)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", Self.replacementScript,
            "inputlock-update",                       // $0
            String(pid),
            stagedApp.path,
            stagingDirectory.path,
            destination.path,
            bundleID ?? "",
            paths.log.path,
            paths.result.path,
            version.description
        ]
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    /// 替换脚本。约束：
    /// - 参数全部走位置参数，不拼进脚本文本，路径里的特殊字符不会被当成命令；
    /// - 命令都用绝对路径，不依赖继承来的 PATH（测试可用 `INPUTLOCK_*` 环境变量注入桩）；
    /// - 任何失败都**不会删掉唯一一份可用的旧版本**；
    /// - 结果写进 `$result`（第一行 ok / failed，第二行说明），App 下次启动读取后提示用户。
    static let replacementScript = #"""
    pid="$1"; new_app="$2"; stage_dir="$3"; dest="$4"; reset_id="$5"; log="$6"; result="$7"; version="$8"
    MV="${INPUTLOCK_MV:-/bin/mv}"
    RM="${INPUTLOCK_RM:-/bin/rm}"
    OPEN="${INPUTLOCK_OPEN:-/usr/bin/open}"
    XATTR="${INPUTLOCK_XATTR:-/usr/bin/xattr}"
    TCCUTIL="${INPUTLOCK_TCCUTIL:-/usr/bin/tccutil}"
    WAIT_LIMIT="${INPUTLOCK_WAIT_LIMIT:-150}"

    # exec 的重定向失败会让整个 sh 直接退出，所以先在子 shell 里试写一次
    /bin/mkdir -p "$(/usr/bin/dirname "$log")" "$(/usr/bin/dirname "$result")" 2>/dev/null
    if ( : >>"$log" ) 2>/dev/null; then exec >>"$log" 2>&1; else exec >/dev/null 2>&1; fi
    echo "---- $(/bin/date '+%Y-%m-%d %H:%M:%S') update to $version: $dest"

    report() { printf '%s\n%s\n' "$1" "$2" >"$result" 2>/dev/null; echo "result: $1 $2"; }

    # kill -0 对僵尸进程也返回成功，所以还要看进程状态：只有非 Z 才算还在运行
    app_alive() {
      kill -0 "$pid" 2>/dev/null || return 1
      [ "$(/bin/ps -p "$pid" -o state= 2>/dev/null | /usr/bin/tr -d ' ')" != "Z" ]
    }

    i=0
    while app_alive; do
      i=$((i + 1))
      if [ "$i" -gt "$WAIT_LIMIT" ]; then
        report failed "旧进程没有在规定时间内退出，已取消更新"
        "$RM" -rf "$stage_dir"
        exit 1
      fi
      /bin/sleep 0.2
    done

    backup="$stage_dir/previous.app"
    if ! "$MV" "$dest" "$backup"; then
      report failed "无法移开旧版本（$dest），没有做任何改动"
      "$RM" -rf "$stage_dir"
      "$OPEN" "$dest"
      exit 1
    fi

    # 目标位置必须是空的：BSD mv 遇到已存在的目录会把新应用挪进它里面
    if [ ! -e "$dest" ] && "$MV" "$new_app" "$dest"; then
      echo "replaced"
      "$RM" -rf "$stage_dir"
      "$XATTR" -dr com.apple.quarantine "$dest" 2>/dev/null
      if [ -n "$reset_id" ]; then
        "$TCCUTIL" reset Accessibility "$reset_id" && echo "accessibility permission reset for $reset_id"
      fi
      report ok "$version"
      "$OPEN" "$dest"
      exit 0
    fi

    echo "cannot move new app into place, restoring old app"
    if [ ! -e "$dest" ] && "$MV" "$backup" "$dest"; then
      "$RM" -rf "$stage_dir"
      report failed "新版本无法放到 $dest，已恢复旧版本"
      "$OPEN" "$dest"
      exit 1
    fi

    # 恢复也失败：备份是唯一可用的版本，绝不删除，直接从备份位置启动
    report failed "替换失败且无法自动恢复。旧版本保存在 $backup，请手动把它移回 $dest"
    "$OPEN" "$backup"
    exit 1
    """#

    /// 解析脚本写下的结果文件。
    enum ReplacementOutcome: Equatable {
        case succeeded(version: String)
        case failed(reason: String)
    }

    static func readOutcome(at url: URL) -> ReplacementOutcome? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let status = lines.first else { return nil }
        let detail = lines.count > 1 ? lines[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        switch status {
        case "ok": return .succeeded(version: detail)
        case "failed": return .failed(reason: detail)
        default: return nil
        }
    }

    // MARK: 签名类型

    /// 是否是 ad-hoc 签名（`codesign --sign -`）。正式 Developer ID 签名的版本更新后权限会保留，不需要重置。
    static func isAdHocSigned(_ bundleURL: URL) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return false }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation))
        guard SecCodeCopySigningInformation(code, flags, &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              let signatureFlags = dictionary[kSecCodeInfoFlags as String] as? NSNumber else {
            return false
        }
        return signatureFlags.uint32Value & SecCodeSignatureFlags.adhoc.rawValue != 0
    }
}

// MARK: - 子进程

enum Shell {

    struct Result {
        let status: Int32
        let output: Data
        let error: Data

        var errorText: String {
            let text = String(data: error, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? "退出码 \(status)" : text
        }
    }

    /// 在后台线程运行命令并收集输出，不阻塞主线程。
    static func run(_ executable: String, _ arguments: [String]) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                // 两个管道分别在不同线程读，避免一边写满缓冲区导致死锁
                var errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                continuation.resume(returning: Result(status: process.terminationStatus, output: outData, error: errData))
            }
        }
    }
}
