import Foundation

/// GitHub Releases 的网络访问：查最新版本、下载安装包和校验文件。
///
/// 不依赖主线程，所有方法都是 nonisolated async，下载循环不会卡住菜单栏 UI。
struct UpdateClient {

    let session: URLSession
    let userAgent: String

    init(session: URLSession = .shared, currentVersion: AppVersion?) {
        self.session = session
        self.userAgent = "InputLock/\(currentVersion?.description ?? "dev") (macOS)"
    }

    // MARK: - 最新版本

    func fetchLatestRelease(from source: UpdateSource) async throws -> GitHubRelease {
        var request = URLRequest(url: source.latestReleaseAPI, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await session.data(for: request)
        try Self.check(response, notFound: .noPublishedRelease)
        return try GitHubRelease.decode(from: data)
    }

    // MARK: - 下载

    /// 下载 `.sha256` 文件并解析出期望的十六进制摘要。
    func fetchExpectedSHA256(for checksum: ReleaseAsset, installerName: String) async throws -> String {
        guard UpdateSource.isTrustedDownloadURL(checksum.downloadURL) else {
            throw UpdateError.untrustedDownload(checksum.downloadURL.absoluteString)
        }
        var request = URLRequest(url: checksum.downloadURL, timeoutInterval: 30)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try Self.check(response, notFound: .checksumAssetMissing)
        guard let text = String(data: data, encoding: .utf8),
              let digest = Checksum.parseSHA256File(text, expectedFileName: installerName) else {
            throw UpdateError.checksumUnreadable
        }
        return digest
    }

    /// 把安装包下载到 `directory`，`progress` 在后台线程回调 0...1（总大小未知时不回调）。
    func download(
        _ asset: ReleaseAsset,
        into directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        guard UpdateSource.isTrustedDownloadURL(asset.downloadURL) else {
            throw UpdateError.untrustedDownload(asset.downloadURL.absoluteString)
        }
        var request = URLRequest(url: asset.downloadURL, timeoutInterval: 60)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (bytes, response) = try await session.bytes(for: request)
        try Self.check(response, notFound: .installerAssetMissing(version: asset.name))

        let destination = directory.appendingPathComponent(asset.name)
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: destination)
        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw UpdateError.stagingFailed("无法创建下载文件 \(destination.path)")
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        let total = response.expectedContentLength > 0 ? response.expectedContentLength : Int64(asset.size)
        // 发布信息里写了大小就不允许明显超出（留 64 KB 余量），否则最多 200 MB
        let limit: Int64 = asset.size > 0 ? Int64(asset.size) + 64 * 1024 : 200 * 1024 * 1024
        let chunkSize = 64 * 1024
        var buffer = Data()
        buffer.reserveCapacity(chunkSize)
        var received: Int64 = 0

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= chunkSize {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if received > limit { throw UpdateError.downloadTooLarge }
                if total > 0 { progress(min(Double(received) / Double(total), 1)) }
                try Task.checkCancellation()
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
        }
        if received > limit { throw UpdateError.downloadTooLarge }
        progress(1)
        return destination
    }

    // MARK: - HTTP 状态

    private static func check(_ response: URLResponse, notFound: UpdateError) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300:
            return
        case 404:
            throw notFound
        case 403, 429:
            if http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" || http.statusCode == 429 {
                throw UpdateError.rateLimited
            }
            throw UpdateError.httpStatus(http.statusCode)
        default:
            throw UpdateError.httpStatus(http.statusCode)
        }
    }
}
